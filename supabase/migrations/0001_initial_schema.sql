-- ============================================================================
-- Activity Planet — Initial Schema & Row Level Security
-- Run this in the Supabase SQL Editor (Dashboard > SQL Editor > New query).
-- Idempotent-ish: safe to re-run only on a fresh project.
-- ============================================================================

-- gen_random_uuid() ships with pgcrypto (enabled by default on Supabase,
-- kept here so the migration is self-contained).
create extension if not exists "pgcrypto";

-- ============================================================================
-- 1. PROFILES
--    One row per user, keyed to auth.users. A missing row means the user has
--    not completed onboarding yet (Phase 4 relies on this).
-- ============================================================================
create table public.profiles (
  id               uuid primary key references auth.users (id) on delete cascade,
  email            text not null,
  username         text not null,
  university       text not null default 'Georgia State University',
  bio              text not null default '',
  selected_hobbies text[] not null default '{}',
  created_at       timestamptz not null default now(),

  -- Defense in depth: enforce shape at the database even if app validation
  -- is bypassed.
  constraint profiles_username_length check (char_length(username) between 3 and 24),
  constraint profiles_username_format check (username ~ '^[a-zA-Z0-9_]+$'),
  constraint profiles_university_length check (char_length(university) between 2 and 120),
  constraint profiles_bio_length check (char_length(bio) <= 280),
  constraint profiles_hobbies_max check (coalesce(array_length(selected_hobbies, 1), 0) <= 8)
);

-- Case-insensitive uniqueness: "SaiP" and "saip" are the same handle.
create unique index profiles_username_lower_idx on public.profiles (lower(username));

comment on table public.profiles is
  'User profile, created during onboarding. Absence of a row = onboarding incomplete.';

-- ============================================================================
-- 2. EVENTS
-- ============================================================================
create table public.events (
  id              uuid primary key default gen_random_uuid(),
  creator_id      uuid not null references public.profiles (id) on delete cascade,
  title           text not null,
  description     text not null default '',
  category        text not null,
  location        text not null,
  event_timestamp timestamptz not null,
  created_at      timestamptz not null default now(),

  constraint events_title_length check (char_length(title) between 3 and 100),
  constraint events_description_length check (char_length(description) <= 2000),
  constraint events_location_length check (char_length(location) between 2 and 200),
  -- Categories mirror the hub list; extend this check when adding new hubs.
  constraint events_category_allowed check (
    category in (
      'College Campus Life', 'Basketball', 'Pickleball', 'Anime',
      'TV Shows', 'Movies', 'Ping Pong', 'Pool'
    )
  )
);

-- Indexes on frequently queried columns.
create index events_category_idx        on public.events (category);
create index events_location_idx        on public.events (location);
create index events_event_timestamp_idx on public.events (event_timestamp);
create index events_creator_id_idx      on public.events (creator_id);

-- ============================================================================
-- 3. RSVPS
--    Composite primary key prevents duplicate RSVPs by design.
-- ============================================================================
create table public.rsvps (
  event_id   uuid not null references public.events (id) on delete cascade,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),

  primary key (event_id, user_id)
);

-- The PK covers event_id lookups; this covers "events I've RSVP'd to".
create index rsvps_user_id_idx on public.rsvps (user_id);

-- ============================================================================
-- 4. ROW LEVEL SECURITY
--    Every policy is scoped `to authenticated` — the anon role has NO access
--    to any table. (select auth.uid()) is wrapped in a subselect so Postgres
--    evaluates it once per statement instead of once per row.
-- ============================================================================
alter table public.profiles enable row level security;
alter table public.events   enable row level security;
alter table public.rsvps    enable row level security;

-- ---- PROFILES --------------------------------------------------------------
-- Any signed-in user can view profiles (social discovery).
create policy "profiles_select_authenticated"
  on public.profiles for select
  to authenticated
  using (true);

-- A user may create only their own profile row, and the stored email must
-- match the email on their JWT — they cannot impersonate another address.
create policy "profiles_insert_own"
  on public.profiles for insert
  to authenticated
  with check (
    id = (select auth.uid())
    and email = (select auth.jwt() ->> 'email')
  );

-- Users can update only their own profile, and cannot re-point the row at
-- another user or change the stored email.
create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (id = (select auth.uid()))
  with check (
    id = (select auth.uid())
    and email = (select auth.jwt() ->> 'email')
  );

-- No delete policy: profile rows are removed only via auth.users cascade
-- (account deletion), never directly by clients.

-- ---- EVENTS ----------------------------------------------------------------
-- All signed-in users can browse every event.
create policy "events_select_authenticated"
  on public.events for select
  to authenticated
  using (true);

-- Users can only create events attributed to themselves.
create policy "events_insert_own"
  on public.events for insert
  to authenticated
  with check (creator_id = (select auth.uid()));

-- Only the creator can edit, and cannot transfer ownership.
create policy "events_update_own"
  on public.events for update
  to authenticated
  using (creator_id = (select auth.uid()))
  with check (creator_id = (select auth.uid()));

-- Only the creator can delete.
create policy "events_delete_own"
  on public.events for delete
  to authenticated
  using (creator_id = (select auth.uid()));

-- ---- RSVPS -----------------------------------------------------------------
-- Signed-in users can see who is attending (needed for attendee counts).
create policy "rsvps_select_authenticated"
  on public.rsvps for select
  to authenticated
  using (true);

-- Only authenticated users may RSVP, and only as themselves.
create policy "rsvps_insert_own"
  on public.rsvps for insert
  to authenticated
  with check (user_id = (select auth.uid()));

-- Users can withdraw their own RSVP.
create policy "rsvps_delete_own"
  on public.rsvps for delete
  to authenticated
  using (user_id = (select auth.uid()));

-- No update policy: an RSVP is created or deleted, never edited.
