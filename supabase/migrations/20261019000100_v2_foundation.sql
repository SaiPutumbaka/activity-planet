-- ============================================================================
-- Activity Planet schema v2 — migration 1: foundation
--   identity (public/private profile split, 18+), organizations and campuses,
--   .edu verification, hubs / chapters / membership, roles, push devices,
--   and the reset of the July 2026 v1 tables (test data only; auth.users kept).
-- Applied with the Supabase CLI or the management API; never pasted by hand.
-- Conventions: every table has RLS enabled; policies are `to authenticated`
-- unless a table is public catalog data; auth.uid() is always wrapped in a
-- subselect so it is evaluated once per statement.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 0. Extensions
-- ---------------------------------------------------------------------------
create extension if not exists "pgcrypto";
create extension if not exists "postgis" with schema "extensions";
create extension if not exists "vector" with schema "extensions";
create extension if not exists "pg_trgm" with schema "extensions";

-- ---------------------------------------------------------------------------
-- 1. Reset v1 (the four MVP tables; data was 4 test profiles, 1 event, 2 messages)
-- ---------------------------------------------------------------------------
drop table if exists public.hub_messages cascade;
drop table if exists public.rsvps cascade;
drop table if exists public.events cascade;
drop table if exists public.profiles cascade;

-- ---------------------------------------------------------------------------
-- 2. Schema metadata (the health check reads this; no column churn needed)
-- ---------------------------------------------------------------------------
create table if not exists public.meta (
  key        text primary key,
  value      text not null,
  updated_at timestamptz not null default now()
);
alter table public.meta enable row level security;
create policy "meta_read_all" on public.meta for select to anon, authenticated using (true);
insert into public.meta (key, value) values ('schema_version', '2.1')
  on conflict (key) do update set value = excluded.value, updated_at = now();

-- ---------------------------------------------------------------------------
-- 3. Shared helpers
-- ---------------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- Enums
do $$ begin
  create type public.org_kind as enum ('university', 'company', 'community');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.app_role as enum ('moderator', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.chapter_role as enum ('member', 'captain', 'organizer');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.device_platform as enum ('web', 'ios', 'android');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 4. Organizations and campuses (Georgia State first; any org later)
-- ---------------------------------------------------------------------------
create table if not exists public.organizations (
  id            uuid primary key default gen_random_uuid(),
  slug          text not null unique,
  name          text not null,
  kind          public.org_kind not null default 'university',
  email_domains text[] not null default '{}',
  website       text,
  logo_url      text,
  is_verified   boolean not null default false,
  created_at    timestamptz not null default now(),
  constraint organizations_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint organizations_name_length check (char_length(name) between 2 and 120)
);

create table if not exists public.org_campuses (
  id         uuid primary key default gen_random_uuid(),
  org_id     uuid not null references public.organizations (id) on delete cascade,
  slug       text not null,
  name       text not null,
  location   extensions.geography(Point, 4326),
  created_at timestamptz not null default now(),
  unique (org_id, slug),
  constraint org_campuses_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);
create index if not exists org_campuses_org_idx on public.org_campuses (org_id);

-- ---------------------------------------------------------------------------
-- 5. Profiles: public row + private row
-- ---------------------------------------------------------------------------
create table if not exists public.profiles (
  id                      uuid primary key references auth.users (id) on delete cascade,
  handle                  text not null,
  first_name              text not null default '',
  bio                     text not null default '',
  avatar_url              text,
  home_org_id             uuid references public.organizations (id) on delete set null,
  home_campus_id          uuid references public.org_campuses (id) on delete set null,
  onboarding_completed_at timestamptz,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now(),
  constraint profiles_handle_length check (char_length(handle) between 3 and 24),
  constraint profiles_handle_format check (handle ~ '^[a-zA-Z0-9_]+$'),
  constraint profiles_first_name_length check (char_length(first_name) <= 40),
  constraint profiles_bio_length check (char_length(bio) <= 280)
);
create unique index if not exists profiles_handle_lower_idx on public.profiles (lower(handle));
create index if not exists profiles_home_org_idx on public.profiles (home_org_id);
comment on table public.profiles is
  'Public profile. Created by trigger at signup; onboarding_completed_at marks a finished first run. No email, birth date or precise location here.';

create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table if not exists public.profile_private (
  user_id             uuid primary key references public.profiles (id) on delete cascade,
  email               text not null,
  birth_date          date,
  location            extensions.geography(Point, 4326),
  location_text       text not null default '',
  location_updated_at timestamptz,
  apple_refresh_token text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  constraint profile_private_location_text_length check (char_length(location_text) <= 120),
  constraint profile_private_birth_date_bounds check (birth_date is null or birth_date >= date '1900-01-01')
);
comment on table public.profile_private is
  'Owner-only data: login email (synced from auth), birth date (18+ enforced by trigger), precise location, Apple refresh token for sign-in revocation on deletion.';

create trigger profile_private_set_updated_at before update on public.profile_private
  for each row execute function public.set_updated_at();

-- 18+ at the database layer, not only in the form. Computed on calendar parts.
create or replace function public.enforce_minimum_age()
returns trigger language plpgsql as $$
begin
  if new.birth_date is not null
     and new.birth_date > (current_date - interval '18 years')::date then
    raise exception 'minimum_age' using errcode = 'check_violation',
      hint = 'Accounts require the holder to be 18 or older.';
  end if;
  return new;
end $$;

create trigger profile_private_minimum_age before insert or update of birth_date on public.profile_private
  for each row execute function public.enforce_minimum_age();

-- Generate a unique handle from an email local part (letters, digits, underscore).
create or replace function public.generate_handle(p_email text)
returns text language plpgsql as $$
declare
  base      text;
  candidate text;
  n         int := 0;
begin
  base := lower(regexp_replace(split_part(coalesce(p_email, ''), '@', 1), '[^a-zA-Z0-9_]', '', 'g'));
  if char_length(base) < 3 then base := 'member'; end if;
  base := left(base, 18);
  candidate := base;
  while exists (select 1 from public.profiles where lower(handle) = lower(candidate)) loop
    n := n + 1;
    candidate := base || '_' || to_char(floor(random() * 9000 + 1000)::int, 'FM0000');
    if n > 20 then
      candidate := 'member_' || replace(gen_random_uuid()::text, '-', '');
      candidate := left(candidate, 24);
    end if;
  end loop;
  return candidate;
end $$;

-- Create both profile rows the moment an auth user exists, so a failed onboarding step can
-- never leave a ghost account (the July 2026 outage class).
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, handle)
  values (new.id, public.generate_handle(new.email))
  on conflict (id) do nothing;

  insert into public.profile_private (user_id, email)
  values (new.id, coalesce(new.email, ''))
  on conflict (user_id) do nothing;

  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Keep the private email in sync when a user changes it in Auth.
create or replace function public.handle_user_email_change()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  update public.profile_private set email = coalesce(new.email, '') where user_id = new.id;
  return new;
end $$;

drop trigger if exists on_auth_user_email_changed on auth.users;
create trigger on_auth_user_email_changed after update of email on auth.users
  for each row when (old.email is distinct from new.email)
  execute function public.handle_user_email_change();

-- Backfill the existing auth users (the restored test accounts).
insert into public.profiles (id, handle)
select u.id, public.generate_handle(u.email) from auth.users u
on conflict (id) do nothing;
insert into public.profile_private (user_id, email)
select u.id, coalesce(u.email, '') from auth.users u
on conflict (user_id) do nothing;

-- ---------------------------------------------------------------------------
-- 6. Roles (moderator/admin) and the helper RLS uses
-- ---------------------------------------------------------------------------
create table if not exists public.user_roles (
  user_id    uuid not null references public.profiles (id) on delete cascade,
  role       public.app_role not null,
  granted_by uuid references public.profiles (id) on delete set null,
  created_at timestamptz not null default now(),
  primary key (user_id, role)
);

create or replace function public.has_role(p_role public.app_role)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.user_roles
    where user_id = (select auth.uid()) and role = p_role
  );
$$;

create or replace function public.is_moderator()
returns boolean language sql stable security definer set search_path = public as $$
  select public.has_role('moderator') or public.has_role('admin');
$$;

-- ---------------------------------------------------------------------------
-- 7. Organization membership and .edu verification
-- ---------------------------------------------------------------------------
create table if not exists public.org_memberships (
  user_id     uuid not null references public.profiles (id) on delete cascade,
  org_id      uuid not null references public.organizations (id) on delete cascade,
  campus_id   uuid references public.org_campuses (id) on delete set null,
  verified_at timestamptz not null default now(),
  primary key (user_id, org_id)
);
create index if not exists org_memberships_org_idx on public.org_memberships (org_id);

-- One-time-code verification of a second email (e.g. a .edu address). Codes are issued and
-- checked by an Edge Function with the service role; clients only read their own rows.
create table if not exists public.verified_emails (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  email       text not null,
  domain      text generated always as (lower(split_part(email, '@', 2))) stored,
  org_id      uuid references public.organizations (id) on delete set null,
  code_hash   text not null,
  attempts    int not null default 0,
  expires_at  timestamptz not null,
  verified_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint verified_emails_email_format check (email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  constraint verified_emails_attempts_max check (attempts between 0 and 10)
);
create index if not exists verified_emails_user_idx on public.verified_emails (user_id);
create unique index if not exists verified_emails_one_verified_per_email
  on public.verified_emails (lower(email)) where verified_at is not null;

-- ---------------------------------------------------------------------------
-- 8. Hubs, chapters, membership
-- ---------------------------------------------------------------------------
create table if not exists public.hub_categories (
  slug       text primary key,
  name       text not null,
  color_key  text not null,          -- maps to the design system's category palette
  sort_order int not null default 100,
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
create index if not exists hubs_name_trgm_idx on public.hubs using gin (name extensions.gin_trgm_ops);
create index if not exists hubs_aliases_idx on public.hubs using gin (aliases);
create trigger hubs_set_updated_at before update on public.hubs
  for each row execute function public.set_updated_at();

-- A hub at a place: "Table Tennis at Georgia State Atlanta". Campus may be null for an
-- organization without campuses.
create table if not exists public.hub_chapters (
  id          uuid primary key default gen_random_uuid(),
  hub_id      uuid not null references public.hubs (id) on delete cascade,
  org_id      uuid not null references public.organizations (id) on delete cascade,
  campus_id   uuid references public.org_campuses (id) on delete cascade,
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
create trigger hub_chapters_set_updated_at before update on public.hub_chapters
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

-- ---------------------------------------------------------------------------
-- 9. Push devices (web push now; APNs/FCM tokens later)
-- ---------------------------------------------------------------------------
create table if not exists public.push_devices (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  platform     public.device_platform not null,
  subscription jsonb not null,            -- web push subscription or native token payload
  token_hash   text not null,              -- sha256 of endpoint/token, for uniqueness
  user_agent   text,
  last_seen_at timestamptz not null default now(),
  created_at   timestamptz not null default now(),
  unique (user_id, token_hash)
);
create index if not exists push_devices_user_idx on public.push_devices (user_id);

-- ---------------------------------------------------------------------------
-- 10. Onboarding RPC: one transaction for the first-run writes
-- ---------------------------------------------------------------------------
create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null
)
returns public.profiles
language plpgsql
security invoker
set search_path = public
as $$
declare
  uid     uuid := (select auth.uid());
  v_org   uuid;
  result  public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_hub_ids is null or array_length(p_hub_ids, 1) is null then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;
  if array_length(p_hub_ids, 1) > 25 then
    raise exception 'too_many_hubs' using errcode = 'check_violation';
  end if;

  if p_campus_id is not null then
    select org_id into v_org from public.org_campuses where id = p_campus_id;
  end if;

  update public.profiles
     set handle = p_handle,
         first_name = p_first_name,
         home_org_id = coalesce(v_org, home_org_id),
         home_campus_id = coalesce(p_campus_id, home_campus_id),
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;

  update public.profile_private
     set birth_date = p_birth_date
   where user_id = uid;

  insert into public.hub_members (user_id, hub_id)
  select uid, h.id
    from public.hubs h
   where h.id = any (p_hub_ids) and h.is_active
  on conflict do nothing;

  return result;
end $$;

create or replace function public.handle_available(p_handle text)
returns boolean language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from public.profiles
    where lower(handle) = lower(p_handle) and id is distinct from (select auth.uid())
  );
$$;

-- ---------------------------------------------------------------------------
-- 11. Row Level Security
-- ---------------------------------------------------------------------------
alter table public.organizations   enable row level security;
alter table public.org_campuses    enable row level security;
alter table public.profiles        enable row level security;
alter table public.profile_private enable row level security;
alter table public.user_roles      enable row level security;
alter table public.org_memberships enable row level security;
alter table public.verified_emails enable row level security;
alter table public.hub_categories  enable row level security;
alter table public.hubs            enable row level security;
alter table public.hub_chapters    enable row level security;
alter table public.hub_members     enable row level security;
alter table public.chapter_members enable row level security;
alter table public.push_devices    enable row level security;

-- Catalog data: readable logged out (public hub/chapter pages), writable by moderators.
create policy "organizations_read" on public.organizations for select to anon, authenticated using (true);
create policy "organizations_write_mod" on public.organizations for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

create policy "org_campuses_read" on public.org_campuses for select to anon, authenticated using (true);
create policy "org_campuses_write_mod" on public.org_campuses for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

create policy "hub_categories_read" on public.hub_categories for select to anon, authenticated using (true);
create policy "hub_categories_write_mod" on public.hub_categories for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

create policy "hubs_read" on public.hubs for select to anon, authenticated using (is_active or public.is_moderator());
create policy "hubs_write_mod" on public.hubs for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

create policy "hub_chapters_read" on public.hub_chapters for select to anon, authenticated using (is_active or public.is_moderator());
create policy "hub_chapters_write_mod" on public.hub_chapters for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

-- Profiles: public fields readable by signed-in members; owner edits own row; no client insert/delete.
create policy "profiles_read_authenticated" on public.profiles for select to authenticated using (true);
create policy "profiles_update_own" on public.profiles for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- Private data: owner only.
create policy "profile_private_read_own" on public.profile_private for select to authenticated
  using (user_id = (select auth.uid()));
create policy "profile_private_update_own" on public.profile_private for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Roles: a user can see their own roles; grants happen server-side.
create policy "user_roles_read_own" on public.user_roles for select to authenticated
  using (user_id = (select auth.uid()) or public.is_moderator());

-- Org memberships: own rows, plus moderators; writes happen in the verification function.
create policy "org_memberships_read_own" on public.org_memberships for select to authenticated
  using (user_id = (select auth.uid()) or public.is_moderator());

-- Verification requests: own rows only; writes are service-role only.
create policy "verified_emails_read_own" on public.verified_emails for select to authenticated
  using (user_id = (select auth.uid()));

-- Hub membership: visible to members (member lists and counts); self-managed.
create policy "hub_members_read" on public.hub_members for select to authenticated using (true);
create policy "hub_members_insert_own" on public.hub_members for insert to authenticated
  with check (user_id = (select auth.uid()));
create policy "hub_members_update_own" on public.hub_members for update to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
create policy "hub_members_delete_own" on public.hub_members for delete to authenticated
  using (user_id = (select auth.uid()));

-- Chapter membership: self-join as a plain member; role changes by moderators (captain tools later).
create policy "chapter_members_read" on public.chapter_members for select to authenticated using (true);
create policy "chapter_members_insert_own" on public.chapter_members for insert to authenticated
  with check (user_id = (select auth.uid()) and role = 'member');
create policy "chapter_members_update_own_notify" on public.chapter_members for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and role = (select cm.role from public.chapter_members cm where cm.user_id = (select auth.uid()) and cm.chapter_id = chapter_members.chapter_id));
create policy "chapter_members_delete_own" on public.chapter_members for delete to authenticated
  using (user_id = (select auth.uid()));
create policy "chapter_members_write_mod" on public.chapter_members for all to authenticated
  using (public.is_moderator()) with check (public.is_moderator());

-- Push devices: owner only.
create policy "push_devices_all_own" on public.push_devices for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

-- Function execution: only signed-in users may call the RPCs.
revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid) to authenticated;
revoke all on function public.handle_available(text) from public;
grant execute on function public.handle_available(text) to anon, authenticated;
revoke all on function public.generate_handle(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 12. Storage: tighten the v1 avatars bucket (limits were client-side only)
-- ---------------------------------------------------------------------------
update storage.buckets
   set file_size_limit = 5242880,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'avatars';

-- ---------------------------------------------------------------------------
-- 13. Seed: Georgia State University and its campuses
-- ---------------------------------------------------------------------------
insert into public.organizations (slug, name, kind, email_domains, website, is_verified)
values ('georgia-state', 'Georgia State University', 'university',
        array['gsu.edu', 'student.gsu.edu'], 'https://www.gsu.edu', false)
on conflict (slug) do update set email_domains = excluded.email_domains;

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
