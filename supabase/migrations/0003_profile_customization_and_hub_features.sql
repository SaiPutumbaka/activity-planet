-- ============================================================================
-- Activity Planet — Migration 0003
-- Profile customization (avatar, birthday, location) + per-hub features
-- (live chat, map). Run in the Supabase SQL Editor after 0001 and 0002.
-- ============================================================================

-- ============================================================================
-- 1. PROFILE CUSTOMIZATION
-- ============================================================================
alter table public.profiles
  add column avatar_url    text,
  add column birthday      date,
  add column location_text text not null default '',
  add column latitude      double precision,
  add column longitude     double precision;

alter table public.profiles
  add constraint profiles_location_text_length check (char_length(location_text) <= 120),
  add constraint profiles_latitude_range check (latitude is null or latitude between -90 and 90),
  add constraint profiles_longitude_range check (longitude is null or longitude between -180 and 180),
  -- Static bounds only (no current_date/now()) — CHECK constraints should
  -- stick to immutable expressions. "Not in the future" and "13+ years old"
  -- are enforced by app validation (see lib/validation/profile.ts); this is
  -- just a defense-in-depth backstop against garbage values.
  add constraint profiles_birthday_range check (
    birthday is null or birthday between date '1900-01-01' and date '2100-01-01'
  );

comment on column public.profiles.avatar_url is
  'Public URL of the file in the avatars storage bucket, or null.';
comment on column public.profiles.latitude is
  'Optional self-reported coordinate, captured client-side via the Geolocation API.';

-- ============================================================================
-- 2. EVENT COORDINATES
--    Optional so existing events (and future text-only locations) stay valid.
--    Powers "near you" sorting on Home and pins on each hub's map.
-- ============================================================================
alter table public.events
  add column latitude  double precision,
  add column longitude double precision;

alter table public.events
  add constraint events_latitude_range check (latitude is null or latitude between -90 and 90),
  add constraint events_longitude_range check (longitude is null or longitude between -180 and 180);

-- ============================================================================
-- 3. HUB MESSAGES
--    One live chat per hub. Both reading and posting require the caller's
--    profile to already list that hub in selected_hobbies — chat is a member
--    benefit, not a public feed, enforced at the database, not just the UI.
-- ============================================================================
create table public.hub_messages (
  id         uuid primary key default gen_random_uuid(),
  hub        text not null,
  sender_id  uuid not null references public.profiles (id) on delete cascade,
  body       text not null,
  created_at timestamptz not null default now(),

  constraint hub_messages_body_length check (char_length(body) between 1 and 1000),
  -- Mirrors events_category_allowed; extend both when adding new hubs.
  constraint hub_messages_hub_allowed check (
    hub in (
      'College Campus Life', 'Basketball', 'Pickleball', 'Anime',
      'TV Shows', 'Movies', 'Ping Pong', 'Pool'
    )
  )
);

create index hub_messages_hub_created_idx on public.hub_messages (hub, created_at);

alter table public.hub_messages enable row level security;

create policy "hub_messages_select_members"
  on public.hub_messages for select
  to authenticated
  using (
    exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and hub_messages.hub = any (profiles.selected_hobbies)
    )
  );

create policy "hub_messages_insert_members"
  on public.hub_messages for insert
  to authenticated
  with check (
    sender_id = (select auth.uid())
    and exists (
      select 1 from public.profiles
      where id = (select auth.uid())
        and hub_messages.hub = any (profiles.selected_hobbies)
    )
  );

-- No update/delete policy: messages are permanent once posted.

-- Broadcast inserts to subscribed clients (see src/components/shared/hub-chat.tsx).
alter publication supabase_realtime add table public.hub_messages;

-- ============================================================================
-- 4. AVATARS STORAGE BUCKET
--    Public read (avatars are meant to be visible); writes restricted to the
--    caller's own folder, avatars/<user_id>/<file>.
-- ============================================================================
insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "avatars_public_read"
  on storage.objects for select
  to public
  using (bucket_id = 'avatars');

create policy "avatars_insert_own_folder"
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars_update_own_folder"
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy "avatars_delete_own_folder"
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );
