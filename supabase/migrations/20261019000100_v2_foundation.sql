-- ============================================================================
-- Activity Planet schema v2 — migration 1: foundation (revision 2, after review)
--   identity (public/private/secret profile split, 18+ enforced in the database),
--   account lifecycle, organizations + campuses + verified org emails,
--   hubs / chapters / membership / requests / stats, roles, notification prefs,
--   push devices, storage bucket, and a guarded reset of the July 2026 v1 tables.
-- Applied with the Supabase CLI or the management API; never pasted by hand.
-- Conventions:
--   * every table has RLS; catalog tables are readable by anon, everything else
--     is `to authenticated`; auth.uid() and is_moderator() are wrapped in
--     (select ...) so they evaluate once per statement;
--   * privileges are explicit (Supabase stops auto-granting on 2026-10-30);
--     clients get column-level UPDATE only on self-service columns;
--   * secrets (verification codes, provider tokens) live in tables with RLS on
--     and no policies: service role only;
--   * content tables added later reference profiles(id) ON DELETE SET NULL so
--     deletion anonymizes rather than erases; pure membership rows cascade.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
create extension if not exists "pgcrypto" with schema "extensions";
create extension if not exists "postgis" with schema "extensions";
create extension if not exists "pg_trgm" with schema "extensions";

-- ---------------------------------------------------------------------------
-- 1. Reset v1, only when the v1 shape is present; refuse to run twice.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public' and table_name = 'profiles' and column_name = 'selected_hobbies'
  ) then
    drop table if exists public.hub_messages cascade;
    drop table if exists public.rsvps cascade;
    drop table if exists public.events cascade;
    drop table if exists public.profiles cascade;
  elsif exists (select 1 from pg_tables where schemaname = 'public' and tablename = 'profiles') then
    raise exception 'schema v2 already present; refusing to re-run the v1 reset'
      using hint = 'Repair the migration history instead of re-applying (supabase migration repair 20261019000100 --status applied --linked).';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Schema metadata (read by /api/health)
-- ---------------------------------------------------------------------------
create table if not exists public.meta (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- 3. Shared helpers and enums
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

create or replace function public.immutable_array_to_string(text[], text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select array_to_string($1, $2)
$$;

do $$ begin create type public.org_kind as enum ('university', 'company', 'community'); exception when duplicate_object then null; end $$;
do $$ begin create type public.org_role as enum ('member', 'officer', 'admin'); exception when duplicate_object then null; end $$;
do $$ begin create type public.app_role as enum ('moderator', 'admin'); exception when duplicate_object then null; end $$;
do $$ begin create type public.chapter_role as enum ('member', 'captain', 'organizer'); exception when duplicate_object then null; end $$;
do $$ begin create type public.device_platform as enum ('web', 'ios', 'android'); exception when duplicate_object then null; end $$;
do $$ begin create type public.account_status as enum ('active', 'suspended', 'banned', 'deleted'); exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 4. Organizations, email domains, campuses
-- ---------------------------------------------------------------------------
create table if not exists public.organizations (
  id          uuid primary key default gen_random_uuid(),
  slug        text not null unique,
  name        text not null,
  kind        public.org_kind not null default 'university',
  website     text,
  logo_url    text,
  is_verified boolean not null default false,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint organizations_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint organizations_name_length check (char_length(name) between 2 and 120)
);
create or replace trigger organizations_set_updated_at before update on public.organizations
  for each row execute function public.set_updated_at();

-- One row per email domain; a domain belongs to exactly one organization.
create table if not exists public.org_email_domains (
  domain     text primary key,
  org_id     uuid not null references public.organizations (id) on delete cascade,
  created_at timestamptz not null default now(),
  constraint org_email_domains_format check (domain = lower(domain) and domain ~ '^[a-z0-9.-]+\.[a-z]{2,}$')
);
create index if not exists org_email_domains_org_idx on public.org_email_domains (org_id);

create table if not exists public.org_campuses (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  slug       text not null,
  name       text not null,
  location   extensions.geography(Point, 4326),
  timezone   text not null default 'America/New_York',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (org_id, slug),
  constraint org_campuses_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);
create index if not exists org_campuses_org_idx on public.org_campuses (org_id);
create or replace trigger org_campuses_set_updated_at before update on public.org_campuses
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Profiles: public row, private row, secret row, lifecycle ledger
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id                      uuid primary key references auth.users (id) on delete cascade,
  handle                  text not null,
  first_name              text not null default '',
  bio                     text not null default '',
  avatar_url              text,
  home_org_id             uuid references public.organizations (id) on delete set null,
  home_campus_id          uuid references public.org_campuses (id) on delete set null,
  status                  public.account_status not null default 'active',
  onboarding_completed_at timestamptz,
  handle_changed_at       timestamptz,
  deletion_requested_at   timestamptz,
  deleted_at              timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint profiles_handle_length check (char_length(handle) between 3 and 24),
  constraint profiles_handle_format check (handle ~ '^[a-zA-Z0-9_]+$'),
  constraint profiles_first_name_length check (char_length(first_name) <= 40),
  constraint profiles_bio_length check (char_length(bio) <= 280)
);
create unique index if not exists profiles_handle_lower_idx on public.profiles (lower(handle));
create index if not exists profiles_home_org_idx on public.profiles (home_org_id);
create index if not exists profiles_home_campus_idx on public.profiles (home_campus_id);
create index if not exists profiles_status_idx on public.profiles (status) where status <> 'active';
comment on table public.profiles is
  'Public profile. Created by trigger at signup. home_org_id/home_campus_id are the user''s declared affiliation (self-service); verified affiliation lives in org_memberships and is the only thing campus spaces may gate on. No email, birth date or precise location here.';
create or replace trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table if not exists public.profile_private (
  user_id             uuid primary key references public.profiles (id) on delete cascade,
  email               text not null,
  birth_date          date,
  location            extensions.geography(Point, 4326),
  location_text       text not null default '',
  location_updated_at timestamptz,
  last_seen_at        timestamptz,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint profile_private_location_text_length check (char_length(location_text) <= 120),
  constraint profile_private_birth_date_bounds check (birth_date is null or birth_date >= date '1900-01-01')
);
comment on table public.profile_private is
  'Owner-only data: login email (synced from auth, not client-writable), birth date (18+ enforced by trigger, write-once), precise location, last_seen_at (throttled).';
create or replace trigger profile_private_set_updated_at before update on public.profile_private
  for each row execute function public.set_updated_at();

-- Provider tokens (Apple refresh token for sign-in revocation on deletion). Service role only.
create table if not exists public.auth_provider_secrets (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  provider   text not null check (provider in ('apple')),
  secret     text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, provider)
);
create or replace trigger auth_provider_secrets_set_updated_at before update on public.auth_provider_secrets
  for each row execute function public.set_updated_at();

-- Deletion ledger: outlives the profile on purpose (no FK). Service role only.
create table if not exists public.account_deletions (
  user_id                uuid primary key,
  email_hash             text not null,
  requested_at           timestamptz not null default now(),
  completed_at           timestamptz,
  apple_token_revoked_at timestamptz,
  processors_notified    jsonb not null default '{}'::jsonb,
  retain_evidence_until  timestamptz,
  reason                 text
);

create table if not exists public.notification_prefs (
  user_id             uuid primary key references public.profiles (id) on delete cascade,
  timezone            text not null default 'America/New_York',
  email_enabled       boolean not null default true,
  push_enabled        boolean not null default true,
  event_reminders     boolean not null default true,
  event_updates       boolean not null default true,
  hub_activity        boolean not null default true,
  messages            boolean not null default true,
  checkin_prompts     boolean not null default true,
  weekly_digest       boolean not null default true,
  quiet_start         time,
  quiet_end           time,
  unsubscribed_all_at timestamptz,
  updated_at          timestamptz not null default now()
);
create or replace trigger notification_prefs_set_updated_at before update on public.notification_prefs
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. Roles and privilege helpers
-- ---------------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.app_role not null,
  granted_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function public.has_role(p_role public.app_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.user_roles
    where user_id = (select auth.uid()) and role = p_role
  );
$$;

create or replace function public.is_moderator()
returns boolean language sql stable security definer set search_path = '' as $$
  select public.has_role('moderator'::public.app_role) or public.has_role('admin'::public.app_role);
$$;

-- "service role, migration owner, or moderator": used by guard triggers that run as the caller.
create or replace function public.is_privileged()
returns boolean language sql stable security definer set search_path = '' as $$
  select current_user in ('postgres', 'service_role', 'supabase_admin') or public.is_moderator();
$$;

-- ---------------------------------------------------------------------------
-- 7. Verified organization emails and memberships
-- ---------------------------------------------------------------------------
-- Clean, owner-readable record of a verified address.
create table if not exists public.verified_emails (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  email       text not null,
  domain      text generated always as (lower(split_part(email, '@', 2))) stored,
  org_id      uuid references public.organizations (id) on delete set null,
  verified_at timestamptz not null default now(),
  created_at  timestamptz not null default now(),
  constraint verified_emails_email_format check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
create index if not exists verified_emails_user_idx on public.verified_emails (user_id);
create unique index if not exists verified_emails_one_per_address on public.verified_emails (lower(email));

-- One-time codes: issued and checked by an Edge Function with the service role. No client access.
create table if not exists public.email_verification_codes (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  email        text not null,
  org_id       uuid references public.organizations (id) on delete set null,
  code_hmac    text not null,
  attempts     int  not null default 0 check (attempts between 0 and 10),
  send_count   int  not null default 1,
  last_sent_at timestamptz not null default now(),
  expires_at   timestamptz not null,
  consumed_at  timestamptz,
  created_at   timestamptz not null default now(),
  constraint email_verification_codes_email_format check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$')
);
create unique index if not exists email_verification_codes_one_open
  on public.email_verification_codes (user_id, lower(email)) where consumed_at is null;
create index if not exists email_verification_codes_user_idx on public.email_verification_codes (user_id);

create table if not exists public.org_memberships (
  user_id           uuid not null references public.profiles (id) on delete cascade,
  org_id            uuid not null references public.organizations (id) on delete cascade,
  campus_id         uuid references public.org_campuses (id) on delete set null,
  role              public.org_role not null default 'member',
  source            text not null default 'edu_email' check (source in ('edu_email', 'manual', 'invite')),
  verified_email_id uuid references public.verified_emails (id) on delete set null,
  granted_by        uuid references public.profiles (id) on delete set null,
  verified_at       timestamptz not null default now(),
  expires_at        timestamptz,
  primary key (user_id, org_id)
);
create index if not exists org_memberships_org_campus_idx on public.org_memberships (org_id, campus_id);

create or replace function public.has_org_role(p_org uuid, p_role public.org_role)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.org_memberships
    where user_id = (select auth.uid()) and org_id = p_org and role >= p_role
      and (expires_at is null or expires_at > now())
  );
$$;

-- ---------------------------------------------------------------------------
-- 8. Hubs, chapters, membership, requests, stats
-- ---------------------------------------------------------------------------
create table if not exists public.hub_categories (
  slug         text primary key,
  name         text not null,
  color_key    text not null,
  sort_order   int not null default 100,
  is_sensitive boolean not null default false,  -- membership hidden from other members
  scope        text not null default 'general' check (scope in ('general', 'campus')),
  min_age      smallint not null default 18 check (min_age in (18, 21)),
  constraint hub_categories_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);

create table if not exists public.hubs (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  category_slug text not null references public.hub_categories (slug) on update cascade,
  emoji         text not null default '',
  description   text not null default '',
  aliases       text[] not null default '{}',
  search_text   text generated always as (lower(name || ' ' || public.immutable_array_to_string(aliases, ' '))) stored,
  scope         text not null default 'general' check (scope in ('general', 'campus')),
  min_age       smallint not null default 18 check (min_age in (18, 21)),
  cover_url     text,
  is_featured   boolean not null default false,
  is_active     boolean not null default true,
  created_by    uuid references public.profiles (id) on delete set null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint hubs_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint hubs_name_length check (char_length(name) between 2 and 60),
  constraint hubs_description_length check (char_length(description) <= 500)
);
create index if not exists hubs_category_idx on public.hubs (category_slug);
create index if not exists hubs_search_trgm_idx on public.hubs using gin (search_text extensions.gin_trgm_ops);
create index if not exists hubs_featured_idx on public.hubs (is_featured) where is_featured;
create or replace trigger hubs_set_updated_at before update on public.hubs
  for each row execute function public.set_updated_at();

create table if not exists public.hub_chapters (
  id          uuid primary key default gen_random_uuid(),
  hub_id      uuid not null references public.hubs (id) on delete cascade,
  org_id      uuid not null references public.organizations (id) on delete cascade,
  campus_id   uuid references public.org_campuses (id) on delete restrict,
  slug        text not null unique,
  name        text not null,
  description text not null default '',
  cover_url   text,
  is_active   boolean not null default true,
  created_by  uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  constraint hub_chapters_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint hub_chapters_name_length check (char_length(name) between 2 and 100),
  constraint hub_chapters_description_length check (char_length(description) <= 1000)
);
create unique index if not exists hub_chapters_unique_place
  on public.hub_chapters (hub_id, org_id, campus_id) nulls not distinct;
create index if not exists hub_chapters_org_idx on public.hub_chapters (org_id, campus_id);
create or replace trigger hub_chapters_set_updated_at before update on public.hub_chapters
  for each row execute function public.set_updated_at();

create table if not exists public.hub_members (
  user_id   uuid not null references public.profiles (id) on delete cascade,
  hub_id    uuid not null references public.hubs (id) on delete cascade,
  notify    boolean not null default true,
  joined_at timestamptz not null default now(),
  primary key (user_id, hub_id)
);
create index if not exists hub_members_hub_idx on public.hub_members (hub_id);

create table if not exists public.chapter_members (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  chapter_id uuid not null references public.hub_chapters (id) on delete cascade,
  role       public.chapter_role not null default 'member',
  notify     boolean not null default true,
  joined_at  timestamptz not null default now(),
  primary key (user_id, chapter_id)
);
create index if not exists chapter_members_chapter_idx on public.chapter_members (chapter_id);

create table if not exists public.hub_requests (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid references public.profiles (id) on delete set null,
  name        text not null check (char_length(name) between 2 and 60),
  note        text not null default '' check (char_length(note) <= 280),
  status      text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'merged')),
  hub_id      uuid references public.hubs (id) on delete set null,
  reviewed_by uuid references public.profiles (id) on delete set null,
  created_at  timestamptz not null default now(),
  reviewed_at timestamptz
);
create index if not exists hub_requests_status_idx on public.hub_requests (status, created_at);

-- Materialized ranking row per hub (and per campus); written by a scheduled job, never by clients.
create table if not exists public.hub_stats (
  hub_id             uuid not null references public.hubs (id) on delete cascade,
  campus_id          uuid references public.org_campuses (id) on delete cascade,
  member_count       int not null default 0,
  chapter_count      int not null default 0,
  events_next_7d     int not null default 0,
  active_members_30d int not null default 0,
  activity_score     numeric(10, 3) not null default 0,
  computed_at        timestamptz not null default now()
);
create unique index if not exists hub_stats_key on public.hub_stats (hub_id, campus_id) nulls not distinct;
create index if not exists hub_stats_rank_idx on public.hub_stats (campus_id, activity_score desc);

-- ---------------------------------------------------------------------------
-- 9. Push devices
-- ---------------------------------------------------------------------------
create table if not exists public.push_devices (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null references public.profiles (id) on delete cascade,
  platform        public.device_platform not null,
  subscription    jsonb not null,
  token_hash      text not null,
  user_agent      text,
  app_version     text,
  failure_count   int not null default 0,
  last_failure_at timestamptz,
  revoked_at      timestamptz,
  last_seen_at    timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  unique (user_id, token_hash),
  constraint push_devices_web_subscription_shape check (
    platform <> 'web' or ((subscription ? 'endpoint') and (subscription ->> 'endpoint') ~ '^https://')
  )
);
create index if not exists push_devices_live_idx on public.push_devices (user_id) where revoked_at is null;

-- ---------------------------------------------------------------------------
-- 10. Handles: reserved words, history, opaque defaults
-- ---------------------------------------------------------------------------
create table if not exists public.reserved_handles (
  handle text primary key check (handle = lower(handle))
);
insert into public.reserved_handles (handle) values
  ('admin'), ('administrator'), ('support'), ('help'), ('staff'), ('moderator'), ('mod'), ('official'),
  ('activityplanet'), ('activity_planet'), ('georgiastate'), ('georgia_state'), ('gsu'), ('panthers'),
  ('system'), ('root'), ('team'), ('deleted'), ('member')
on conflict do nothing;

create table if not exists public.handle_history (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  handle      text not null,
  released_at timestamptz not null default now()
);
create index if not exists handle_history_lower_idx on public.handle_history (lower(handle), released_at desc);

-- Opaque default handle; the user picks a real one during onboarding.
create or replace function public.generate_handle(p_email text)
returns text language plpgsql set search_path = '' as $$
declare
  candidate text;
begin
  loop
    candidate := 'member_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = candidate);
  end loop;
  return candidate;
end $$;

-- Handle changes: reserved words always refused; after onboarding, one change per 30 days,
-- released handles held for 30 days, previous handle recorded.
create or replace function public.guard_handle_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if lower(new.handle) is distinct from lower(old.handle) then
    if exists (select 1 from public.reserved_handles where handle = lower(new.handle)) then
      raise exception 'handle_reserved' using errcode = 'check_violation';
    end if;
    if old.onboarding_completed_at is not null and not public.is_privileged() then
      if old.handle_changed_at is not null and old.handle_changed_at > now() - interval '30 days' then
        raise exception 'handle_cooldown' using errcode = 'check_violation',
          hint = 'Handles can change once every 30 days.';
      end if;
      if exists (
        select 1 from public.handle_history
        where lower(handle) = lower(new.handle) and user_id <> new.id
          and released_at > now() - interval '30 days'
      ) then
        raise exception 'handle_taken' using errcode = 'unique_violation';
      end if;
      insert into public.handle_history (user_id, handle) values (old.id, old.handle);
    end if;
    new.handle_changed_at := now();
  end if;
  return new;
end $$;
create or replace trigger profiles_guard_handle before update of handle on public.profiles
  for each row execute function public.guard_handle_change();

-- ---------------------------------------------------------------------------
-- 11. Age and onboarding guards
-- ---------------------------------------------------------------------------
-- 18+ at the database layer; a recorded date can never be cleared.
create or replace function public.enforce_minimum_age()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' and old.birth_date is not null and new.birth_date is null then
    raise exception 'birth_date_required' using errcode = 'check_violation';
  end if;
  if new.birth_date is not null
     and new.birth_date > (current_date - interval '18 years')::date then
    raise exception 'minimum_age' using errcode = 'check_violation',
      hint = 'Accounts require the holder to be 18 or older.';
  end if;
  return new;
end $$;
create or replace trigger profile_private_minimum_age before insert or update of birth_date on public.profile_private
  for each row execute function public.enforce_minimum_age();

-- Birth date is write-once for the owner; support corrects it with the service role.
create or replace function public.protect_birth_date()
returns trigger language plpgsql set search_path = '' as $$
begin
  if old.birth_date is not null and new.birth_date is distinct from old.birth_date
     and not public.is_privileged() then
    raise exception 'birth_date_locked' using errcode = 'check_violation',
      hint = 'Contact support to correct a date of birth.';
  end if;
  return new;
end $$;
create or replace trigger profile_private_birth_date_once before update of birth_date on public.profile_private
  for each row execute function public.protect_birth_date();

-- Onboarding cannot complete without a stored date of birth, whatever path writes it.
create or replace function public.require_birth_date_for_onboarding()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.onboarding_completed_at is not null and old.onboarding_completed_at is null
     and not exists (select 1 from public.profile_private where user_id = new.id and birth_date is not null) then
    raise exception 'birth_date_required' using errcode = 'check_violation';
  end if;
  return new;
end $$;
create or replace trigger profiles_require_birth_date before update of onboarding_completed_at on public.profiles
  for each row execute function public.require_birth_date_for_onboarding();

-- ---------------------------------------------------------------------------
-- 12. Signup triggers and backfill
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  attempt int := 0;
begin
  loop
    begin
      insert into public.profiles (id, handle)
      values (new.id, public.generate_handle(new.email))
      on conflict (id) do nothing;
      exit;
    exception when unique_violation then
      attempt := attempt + 1;
      if attempt > 3 then raise; end if;
    end;
  end loop;

  insert into public.profile_private (user_id, email)
  values (new.id, coalesce(new.email, ''))
  on conflict (user_id) do nothing;

  insert into public.notification_prefs (user_id)
  values (new.id)
  on conflict (user_id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  update public.profile_private set email = coalesce(new.email, '') where user_id = new.id;
  return new;
end $$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

insert into public.profiles (id, handle)
select u.id, public.generate_handle(u.email) from auth.users u
on conflict (id) do nothing;
insert into public.profile_private (user_id, email)
select u.id, coalesce(u.email, '') from auth.users u
on conflict (user_id) do nothing;
insert into public.notification_prefs (user_id)
select u.id from auth.users u
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 13. RPCs
-- ---------------------------------------------------------------------------
-- First-run writes in one transaction. SECURITY DEFINER so onboarding_completed_at and
-- birth_date never need to be client-writable; every write is scoped to auth.uid().
create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null,
  p_org_id     uuid default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid    uuid := (select auth.uid());
  v_org  uuid;
  result public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_birth_date is null then
    raise exception 'birth_date_required' using errcode = 'check_violation';
  end if;
  if nullif(btrim(coalesce(p_first_name, '')), '') is null then
    raise exception 'first_name_required' using errcode = 'check_violation';
  end if;
  if p_hub_ids is null or array_length(p_hub_ids, 1) is null then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;
  if array_length(p_hub_ids, 1) > 25 then
    raise exception 'too_many_hubs' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.reserved_handles where handle = lower(p_handle)) then
    raise exception 'handle_reserved' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.profiles where lower(handle) = lower(p_handle) and id <> uid) then
    raise exception 'handle_taken' using errcode = 'unique_violation';
  end if;

  if p_campus_id is not null then
    select org_id into v_org from public.org_campuses where id = p_campus_id;
    if v_org is null then
      raise exception 'campus_not_found' using errcode = 'foreign_key_violation';
    end if;
  elsif p_org_id is not null then
    if not exists (select 1 from public.organizations where id = p_org_id) then
      raise exception 'org_not_found' using errcode = 'foreign_key_violation';
    end if;
    v_org := p_org_id;
  end if;

  -- Birth date first (write-once), so the age trigger aborts before anything else changes.
  update public.profile_private
     set birth_date = p_birth_date
   where user_id = uid
     and (birth_date is null or birth_date = p_birth_date);
  if not found then
    raise exception 'birth_date_locked' using errcode = 'check_violation',
      hint = 'The birth date is recorded once; contact support to correct it.';
  end if;

  update public.profiles
     set handle = p_handle,
         first_name = btrim(p_first_name),
         home_org_id = coalesce(v_org, home_org_id),
         home_campus_id = coalesce(p_campus_id, home_campus_id),
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  insert into public.hub_members (user_id, hub_id)
  select uid, h.id
    from public.hubs h
   where h.id = any (p_hub_ids) and h.is_active
  on conflict do nothing;

  if not exists (select 1 from public.hub_members where user_id = uid) then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;

  return result;
end $$;

-- Availability check for signed-in users (reserved words and recently released handles count as taken).
create or replace function public.handle_available(p_handle text)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and not exists (select 1 from public.profiles
                     where lower(handle) = lower(p_handle) and id is distinct from (select auth.uid()))
     and not exists (select 1 from public.reserved_handles where handle = lower(p_handle))
     and not exists (select 1 from public.handle_history
                     where lower(handle) = lower(p_handle) and released_at > now() - interval '30 days'
                       and user_id is distinct from (select auth.uid()));
$$;

-- Role changes inside a chapter: moderators now; org officers and chapter organizers in week 4.
create or replace function public.set_chapter_role(p_chapter uuid, p_user uuid, p_role public.chapter_role)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.chapter_members set role = p_role where chapter_id = p_chapter and user_id = p_user;
  if not found then
    raise exception 'not_a_member' using errcode = 'P0002';
  end if;
end $$;

-- Member counts without exposing membership rows (sensitive categories).
create or replace function public.hub_member_counts(p_hub_ids uuid[])
returns table (hub_id uuid, members bigint)
language sql stable security definer set search_path = '' as $$
  select hub_id, count(*) from public.hub_members where hub_id = any (p_hub_ids) group by hub_id;
$$;

-- Throttled presence write on the private row.
create or replace function public.touch_last_seen()
returns void language sql security definer set search_path = '' as $$
  update public.profile_private
     set last_seen_at = now()
   where user_id = (select auth.uid())
     and (last_seen_at is null or last_seen_at < now() - interval '15 minutes');
$$;

-- ---------------------------------------------------------------------------
-- 14. Row Level Security
-- ---------------------------------------------------------------------------
alter table public.meta                     enable row level security;
alter table public.organizations            enable row level security;
alter table public.org_email_domains        enable row level security;
alter table public.org_campuses             enable row level security;
alter table public.profiles                 enable row level security;
alter table public.profile_private          enable row level security;
alter table public.auth_provider_secrets    enable row level security;
alter table public.account_deletions        enable row level security;
alter table public.notification_prefs       enable row level security;
alter table public.user_roles               enable row level security;
alter table public.verified_emails          enable row level security;
alter table public.email_verification_codes enable row level security;
alter table public.org_memberships          enable row level security;
alter table public.hub_categories           enable row level security;
alter table public.hubs                     enable row level security;
alter table public.hub_chapters             enable row level security;
alter table public.hub_members              enable row level security;
alter table public.chapter_members          enable row level security;
alter table public.hub_requests             enable row level security;
alter table public.hub_stats                enable row level security;
alter table public.push_devices             enable row level security;
alter table public.reserved_handles         enable row level security;
alter table public.handle_history           enable row level security;

-- meta: readable by everyone.
drop policy if exists "meta_read_all" on public.meta;
create policy "meta_read_all" on public.meta for select to anon, authenticated using (true);

-- Catalog data: readable logged out; organizations/domains/campuses writable by admins, hubs by moderators.
drop policy if exists "organizations_read" on public.organizations;
create policy "organizations_read" on public.organizations for select to anon, authenticated using (true);
drop policy if exists "organizations_write_mod" on public.organizations;
drop policy if exists "organizations_write_admin" on public.organizations;
create policy "organizations_write_admin" on public.organizations for all to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));

drop policy if exists "org_email_domains_read" on public.org_email_domains;
create policy "org_email_domains_read" on public.org_email_domains for select to anon, authenticated using (true);
drop policy if exists "org_email_domains_write_admin" on public.org_email_domains;
create policy "org_email_domains_write_admin" on public.org_email_domains for all to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));

drop policy if exists "org_campuses_read" on public.org_campuses;
create policy "org_campuses_read" on public.org_campuses for select to anon, authenticated using (true);
drop policy if exists "org_campuses_write_mod" on public.org_campuses;
drop policy if exists "org_campuses_write_admin" on public.org_campuses;
create policy "org_campuses_write_admin" on public.org_campuses for all to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));

drop policy if exists "hub_categories_read" on public.hub_categories;
create policy "hub_categories_read" on public.hub_categories for select to anon, authenticated using (true);
drop policy if exists "hub_categories_write_mod" on public.hub_categories;
create policy "hub_categories_write_mod" on public.hub_categories for all to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

drop policy if exists "hubs_read" on public.hubs;
create policy "hubs_read" on public.hubs for select to anon, authenticated
  using (is_active or (select public.is_moderator()));
drop policy if exists "hubs_write_mod" on public.hubs;
create policy "hubs_write_mod" on public.hubs for all to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

drop policy if exists "hub_chapters_read" on public.hub_chapters;
create policy "hub_chapters_read" on public.hub_chapters for select to anon, authenticated
  using (is_active or (select public.is_moderator()));
drop policy if exists "hub_chapters_write_mod" on public.hub_chapters;
create policy "hub_chapters_write_mod" on public.hub_chapters for all to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

drop policy if exists "hub_stats_read" on public.hub_stats;
create policy "hub_stats_read" on public.hub_stats for select to anon, authenticated using (true);

-- Profiles: members see non-deleted public rows; owner edits own row (self-service columns only, see grants).
drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated" on public.profiles for select to authenticated
  using (deleted_at is null or id = (select auth.uid()) or (select public.is_moderator()));
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Private data: owner only (location columns are the only client-writable ones, see grants).
drop policy if exists "profile_private_read_own" on public.profile_private;
create policy "profile_private_read_own" on public.profile_private for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "profile_private_update_own" on public.profile_private;
create policy "profile_private_update_own" on public.profile_private for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Notification preferences: owner only.
drop policy if exists "notification_prefs_read_own" on public.notification_prefs;
create policy "notification_prefs_read_own" on public.notification_prefs for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "notification_prefs_update_own" on public.notification_prefs;
create policy "notification_prefs_update_own" on public.notification_prefs for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Roles and org memberships: own rows plus moderators; writes happen server-side.
drop policy if exists "user_roles_read_own" on public.user_roles;
create policy "user_roles_read_own" on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));
drop policy if exists "org_memberships_read_own" on public.org_memberships;
create policy "org_memberships_read_own" on public.org_memberships for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));

-- Verified emails: owner reads the clean record. Codes table has no policies at all.
drop policy if exists "verified_emails_read_own" on public.verified_emails;
create policy "verified_emails_read_own" on public.verified_emails for select to authenticated
  using (user_id = (select auth.uid()));

-- Hub membership: own rows always; other members' rows only for non-sensitive categories.
drop policy if exists "hub_members_read" on public.hub_members;
create policy "hub_members_read" on public.hub_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or not exists (
      select 1 from public.hubs h
      join public.hub_categories c on c.slug = h.category_slug
      where h.id = hub_members.hub_id and c.is_sensitive
    )
  );
drop policy if exists "hub_members_insert_own" on public.hub_members;
create policy "hub_members_insert_own" on public.hub_members for insert to authenticated
  with check (user_id = (select auth.uid())
    and exists (select 1 from public.hubs h where h.id = hub_id and h.is_active));
drop policy if exists "hub_members_update_own" on public.hub_members;
create policy "hub_members_update_own" on public.hub_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "hub_members_delete_own" on public.hub_members;
create policy "hub_members_delete_own" on public.hub_members for delete to authenticated
  using (user_id = (select auth.uid()));

-- Chapter membership: joining requires a verified membership in the chapter's organization.
drop policy if exists "chapter_members_read" on public.chapter_members;
create policy "chapter_members_read" on public.chapter_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or not exists (
      select 1 from public.hub_chapters ch
      join public.hubs h on h.id = ch.hub_id
      join public.hub_categories c on c.slug = h.category_slug
      where ch.id = chapter_members.chapter_id and c.is_sensitive
    )
  );
drop policy if exists "chapter_members_insert_own" on public.chapter_members;
create policy "chapter_members_insert_own" on public.chapter_members for insert to authenticated
  with check (
    user_id = (select auth.uid()) and role = 'member'
    and exists (
      select 1
        from public.hub_chapters c
        join public.org_memberships m
          on m.org_id = c.org_id and m.user_id = (select auth.uid())
         and (m.expires_at is null or m.expires_at > now())
       where c.id = chapter_id and c.is_active
    )
  );
drop policy if exists "chapter_members_update_own_notify" on public.chapter_members;
drop policy if exists "chapter_members_update_own" on public.chapter_members;
create policy "chapter_members_update_own" on public.chapter_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "chapter_members_delete_own" on public.chapter_members;
create policy "chapter_members_delete_own" on public.chapter_members for delete to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "chapter_members_write_mod" on public.chapter_members;
create policy "chapter_members_write_mod" on public.chapter_members for all to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

-- Hub requests: anyone signed in may ask; moderators review.
drop policy if exists "hub_requests_insert_own" on public.hub_requests;
create policy "hub_requests_insert_own" on public.hub_requests for insert to authenticated
  with check (user_id = (select auth.uid()));
drop policy if exists "hub_requests_read" on public.hub_requests;
create policy "hub_requests_read" on public.hub_requests for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));
drop policy if exists "hub_requests_review_mod" on public.hub_requests;
create policy "hub_requests_review_mod" on public.hub_requests for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));

-- Push devices: owner only, capped at 20 live rows per user.
drop policy if exists "push_devices_all_own" on public.push_devices;
drop policy if exists "push_devices_select_own" on public.push_devices;
create policy "push_devices_select_own" on public.push_devices for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "push_devices_insert_own" on public.push_devices;
create policy "push_devices_insert_own" on public.push_devices for insert to authenticated
  with check (user_id = (select auth.uid())
    and (select count(*) from public.push_devices d where d.user_id = (select auth.uid()) and d.revoked_at is null) < 20);
drop policy if exists "push_devices_update_own" on public.push_devices;
create policy "push_devices_update_own" on public.push_devices for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
drop policy if exists "push_devices_delete_own" on public.push_devices;
create policy "push_devices_delete_own" on public.push_devices for delete to authenticated
  using (user_id = (select auth.uid()));

-- Reserved handles: readable (the signup form can explain why a handle is refused).
drop policy if exists "reserved_handles_read" on public.reserved_handles;
create policy "reserved_handles_read" on public.reserved_handles for select to anon, authenticated using (true);

-- No policies on purpose (service role only): auth_provider_secrets, account_deletions,
-- email_verification_codes, handle_history.

-- ---------------------------------------------------------------------------
-- 15. Privileges (explicit; RLS still decides rows)
-- ---------------------------------------------------------------------------
-- Stop depending on Supabase's auto-grant defaults for everything created after this file.
alter default privileges for role postgres in schema public revoke all on tables from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on functions from anon, authenticated;
alter default privileges for role postgres in schema public revoke all on sequences from anon, authenticated;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from anon, authenticated;
grant all on all tables in schema public to service_role;
grant usage on schema public to anon, authenticated, service_role;

-- Catalog reads
grant select on public.meta, public.organizations, public.org_email_domains, public.org_campuses,
  public.hub_categories, public.hubs, public.hub_chapters, public.hub_stats, public.reserved_handles
  to anon, authenticated;
-- Catalog writes (admins/moderators via RLS)
grant insert, update, delete on public.organizations, public.org_email_domains, public.org_campuses,
  public.hub_categories, public.hubs, public.hub_chapters to authenticated;

-- Identity
grant select on public.profiles, public.profile_private, public.notification_prefs, public.user_roles,
  public.org_memberships, public.verified_emails to authenticated;
grant update (handle, first_name, bio, avatar_url, home_org_id, home_campus_id) on public.profiles to authenticated;
grant update (location, location_text, location_updated_at) on public.profile_private to authenticated;
grant update (timezone, email_enabled, push_enabled, event_reminders, event_updates, hub_activity, messages,
  checkin_prompts, weekly_digest, quiet_start, quiet_end, unsubscribed_all_at) on public.notification_prefs to authenticated;

-- Membership and requests
grant select, insert, delete on public.hub_members to authenticated;
grant update (notify) on public.hub_members to authenticated;
grant select, insert, delete on public.chapter_members to authenticated;
grant update (notify) on public.chapter_members to authenticated;
grant select, insert on public.hub_requests to authenticated;
grant update (status, hub_id, reviewed_by, reviewed_at) on public.hub_requests to authenticated;

-- Devices
grant select, insert, update, delete on public.push_devices to authenticated;

-- Functions
revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid) to authenticated;
revoke all on function public.handle_available(text) from public, anon;
grant execute on function public.handle_available(text) to authenticated;
revoke all on function public.set_chapter_role(uuid, uuid, public.chapter_role) from public, anon;
grant execute on function public.set_chapter_role(uuid, uuid, public.chapter_role) to authenticated;
revoke all on function public.hub_member_counts(uuid[]) from public;
grant execute on function public.hub_member_counts(uuid[]) to anon, authenticated;
revoke all on function public.touch_last_seen() from public, anon;
grant execute on function public.touch_last_seen() to authenticated;
revoke all on function public.generate_handle(text) from public, anon, authenticated;
revoke all on function public.immutable_array_to_string(text[], text) from public, anon, authenticated;
-- Policy helpers: anon evaluates hubs_read / hub_chapters_read, so both roles need execute.
grant execute on function public.is_moderator() to anon, authenticated;
grant execute on function public.has_role(public.app_role) to anon, authenticated;
grant execute on function public.has_org_role(uuid, public.org_role) to authenticated;
grant execute on function public.is_privileged() to authenticated;

-- ---------------------------------------------------------------------------
-- 16. Storage: avatars bucket exists on every project with the same limits and policies
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update
   set public             = excluded.public,
       file_size_limit    = excluded.file_size_limit,
       allowed_mime_types = excluded.allowed_mime_types;

-- Replace any v1-era avatar policies (names varied) with the v2 set.
do $$
declare p record;
begin
  for p in select policyname from pg_policies where schemaname = 'storage' and tablename = 'objects' and policyname like 'avatars%' loop
    execute format('drop policy if exists %I on storage.objects', p.policyname);
  end loop;
end $$;

create policy "avatars_public_read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');
create policy "avatars_insert_own_folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars_update_own_folder" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text)
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "avatars_delete_own_folder" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------------------------------------------------------------------------
-- 17. Seed: Georgia State University, its domains and campuses
-- ---------------------------------------------------------------------------
insert into public.organizations (slug, name, kind, website, is_verified)
values ('georgia-state', 'Georgia State University', 'university', 'https://www.gsu.edu', false)
on conflict (slug) do nothing;

insert into public.org_email_domains (domain, org_id)
select d.domain, o.id
from public.organizations o
cross join (values ('gsu.edu'), ('student.gsu.edu')) as d(domain)
where o.slug = 'georgia-state'
on conflict (domain) do nothing;

insert into public.org_campuses (org_id, slug, name, location)
select o.id, c.slug, c.name, extensions.ST_SetSRID(extensions.ST_MakePoint(c.lng, c.lat), 4326)::extensions.geography
from public.organizations o
cross join (values
  ('atlanta',    'Atlanta (Downtown)', 33.7530, -84.3853),
  ('clarkston',  'Clarkston',          33.8098, -84.2399),
  ('decatur',    'Decatur',            33.7312, -84.2880),
  ('dunwoody',   'Dunwoody',           33.9302, -84.3390),
  ('alpharetta', 'Alpharetta',         34.0520, -84.2440),
  ('newton',     'Newton',             33.5780, -83.9100)
) as c(slug, name, lat, lng)
where o.slug = 'georgia-state'
on conflict (org_id, slug) do nothing;

-- ---------------------------------------------------------------------------
-- 18. Version stamp (last, so /api/health only sees it when everything landed)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.1')
  on conflict (key) do update set value = excluded.value, updated_at = now();
