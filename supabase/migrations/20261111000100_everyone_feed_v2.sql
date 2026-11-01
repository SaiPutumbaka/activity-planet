-- ============================================================================
-- Activity Planet schema v2 — migration 10: everyone-first areas and Feed v2
--   (D-035 everyone in Atlanta 18+, D-036 location for Feed v2, D-038 week-4
--   venue privacy groundwork).
--
--   What this file does
--     * public.areas: Atlanta plus intown neighborhoods and nearby cities
--       (centroid + default radius, not polygons), seeded idempotently on
--       slug. Readable by everyone; written by moderators only.
--     * profiles.home_area_id (on delete set null): the saved feed origin. It
--       is set only through complete_onboarding and set_home_area, never by a
--       direct client update. profiles has table-level SELECT for
--       authenticated (no column grants), so like home_campus_id it is
--       readable by signed-in users; the app does not show it publicly.
--     * profile_private.feed_radius_km (1 to 50, default 10). Client UPDATE on
--       profile_private.location / location_text / location_updated_at is
--       revoked: a device location is sent per feed request and never stored.
--     * complete_onboarding gains p_area_id (validated; null keeps the saved
--       area or falls back to Atlanta). The 6-argument overload is dropped.
--       New RPC set_home_area(p_area_id, p_radius_km).
--     * public.area_waitlist (one row per user, a city outside Atlanta) and
--       RPC join_area_waitlist(p_city). Removed by request_account_deletion,
--       which also clears home_area_id.
--     * feed_events_v2: SECURITY INVOKER, so the events policies still decide
--       every row. Candidates are published events starting in the window
--       that are in my hubs, tagged to my verified campus, or public within
--       the radius of the origin (device point rounded to 0.01 degree, else
--       home area, else home campus, else Atlanta). Approved-only events are
--       an approximate area: the radius gets 8 km of slack and the band is
--       'approximate'. Returns distance bands only (never a distance, a
--       coordinate or the origin), a section in America/New_York, is_imported
--       and matched_by. feed_events is unchanged.
--     * hub_chapters: org_id nullable, area_id added, one of them required;
--       the unique place index now covers area_id. chapter_members_insert_own
--       lets anyone join an area chapter (no organization to verify against).
--     * Venues (D-038): new venues are private unless the caller passes
--       is_public = true (a geocoder place_id no longer implies public).
--       event_set_location uses the campus centroid for approved-only events
--       only when the venue is within 2 km of that campus, else the 0.1
--       degree cell; stored points of approved-only events are backfilled.
--     * meta.schema_version 2.10.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Areas
-- ---------------------------------------------------------------------------
create table if not exists public.areas (
  id                uuid primary key default gen_random_uuid(),
  slug              text not null unique,
  name              text not null,
  kind              text not null default 'neighborhood',
  parent_id         uuid references public.areas (id) on delete set null,
  center            extensions.geography(Point, 4326) not null,
  default_radius_km smallint not null default 10,
  timezone          text not null default 'America/New_York',
  sort              smallint not null default 100,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint areas_kind check (kind in ('city', 'neighborhood')),
  constraint areas_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint areas_name_length check (char_length(name) between 2 and 60),
  constraint areas_radius_range check (default_radius_km between 1 and 50),
  constraint areas_timezone_length check (char_length(timezone) between 1 and 64),
  constraint areas_not_own_parent check (parent_id is null or parent_id <> id)
);
create index if not exists areas_parent_idx on public.areas (parent_id);
comment on table public.areas is
  'Places a person can pick as home (D-036): a city and its neighborhoods, as a centroid plus a default radius (not polygons). Read by everyone; written by moderators.';
create or replace trigger areas_set_updated_at before update on public.areas
  for each row execute function public.set_updated_at();

insert into public.areas (slug, name, kind, center, default_radius_km, sort)
values ('atlanta', 'Atlanta', 'city',
        extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.7490), 4326)::extensions.geography, 15, 0)
on conflict (slug) do update
   set name = excluded.name, kind = excluded.kind, center = excluded.center,
       default_radius_km = excluded.default_radius_km, sort = excluded.sort, parent_id = null;

insert into public.areas (slug, name, kind, parent_id, center, default_radius_km, sort)
select n.slug, n.name, 'neighborhood', atl.id,
       extensions.ST_SetSRID(extensions.ST_MakePoint(n.lng, n.lat), 4326)::extensions.geography,
       n.radius, n.sort
  from public.areas atl
 cross join (values
   ('downtown',          'Downtown',          33.7550, -84.3900,  5, 10),
   ('midtown',           'Midtown',           33.7840, -84.3830,  5, 20),
   ('old-fourth-ward',   'Old Fourth Ward',   33.7640, -84.3720,  5, 30),
   ('inman-park',        'Inman Park',        33.7590, -84.3530,  5, 40),
   ('virginia-highland', 'Virginia-Highland', 33.7810, -84.3530,  5, 50),
   ('grant-park',        'Grant Park',        33.7380, -84.3700,  5, 60),
   ('west-end',          'West End',          33.7360, -84.4130,  5, 70),
   ('westside',          'Westside',          33.7820, -84.4120,  5, 80),
   ('buckhead',          'Buckhead',          33.8400, -84.3800,  8, 90),
   ('decatur',           'Decatur',           33.7748, -84.2963,  8, 100),
   ('kirkwood',          'Kirkwood',          33.7530, -84.3200,  5, 110),
   ('east-atlanta',      'East Atlanta',      33.7400, -84.3430,  5, 120),
   ('sandy-springs',     'Sandy Springs',     33.9304, -84.3733, 10, 130),
   ('smyrna',            'Smyrna',            33.8840, -84.5144, 10, 140)
 ) as n(slug, name, lat, lng, radius, sort)
 where atl.slug = 'atlanta'
on conflict (slug) do update
   set name = excluded.name, kind = excluded.kind, parent_id = excluded.parent_id, center = excluded.center,
       default_radius_km = excluded.default_radius_km, sort = excluded.sort;

alter table public.areas enable row level security;
drop policy if exists "areas_read" on public.areas;
create policy "areas_read" on public.areas for select to anon, authenticated using (true);
drop policy if exists "areas_insert_mod" on public.areas;
create policy "areas_insert_mod" on public.areas for insert to authenticated
  with check ((select public.is_moderator()));
drop policy if exists "areas_update_mod" on public.areas;
create policy "areas_update_mod" on public.areas for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
drop policy if exists "areas_delete_mod" on public.areas;
create policy "areas_delete_mod" on public.areas for delete to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 2. Home area and feed radius; device location is never stored
-- ---------------------------------------------------------------------------
alter table public.profiles
  add column if not exists home_area_id uuid references public.areas (id) on delete set null;
create index if not exists profiles_home_area_idx on public.profiles (home_area_id);
comment on column public.profiles.home_area_id is
  'Saved feed origin (D-036). Set by complete_onboarding and set_home_area only; not shown on public profiles for now.';

alter table public.profile_private
  add column if not exists feed_radius_km smallint not null default 10
    constraint profile_private_feed_radius_range check (feed_radius_km between 1 and 50);

revoke update (location, location_text, location_updated_at) on public.profile_private from authenticated;
comment on table public.profile_private is
  'Owner-only data: login email (synced from auth, not client-writable), birth date (18+ enforced by trigger, write-once), feed radius (set_home_area). The location columns are unused: a device point is sent per feed request and never stored (D-036); clients cannot update them.';

-- ---------------------------------------------------------------------------
-- 3. City waitlist for people outside the Atlanta areas
-- ---------------------------------------------------------------------------
create table if not exists public.area_waitlist (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  city       text not null,
  created_at timestamptz not null default now(),
  constraint area_waitlist_city_length check (char_length(city) between 2 and 80)
);
comment on table public.area_waitlist is
  'One row per person who asked to be told when Activity Planet reaches their city. Written by join_area_waitlist; owner reads; removed by request_account_deletion.';
alter table public.area_waitlist enable row level security;
drop policy if exists "area_waitlist_read_own" on public.area_waitlist;
create policy "area_waitlist_read_own" on public.area_waitlist for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));

create or replace function public.join_area_waitlist(p_city text)
returns public.area_waitlist language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_city text := btrim(regexp_replace(coalesce(p_city, ''), '\s+', ' ', 'g'));
  result public.area_waitlist;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if char_length(v_city) not between 2 and 80 then
    raise exception 'city_length' using errcode = 'check_violation', hint = '2 to 80 characters.';
  end if;
  insert into public.area_waitlist (user_id, city)
  values (uid, v_city)
  on conflict (user_id) do update set city = excluded.city
  returning * into result;
  return result;
end $$;
comment on function public.join_area_waitlist(text) is
  'Records (or replaces) the caller''s city on the waitlist. Errors: not_authenticated, city_length.';

-- ---------------------------------------------------------------------------
-- 4. complete_onboarding with a home area (the old overload is dropped so a
--    single signature exists), and set_home_area
-- ---------------------------------------------------------------------------
drop function if exists public.complete_onboarding(text, text, date, uuid[], uuid, uuid);

create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null,
  p_org_id     uuid default null,
  p_area_id    uuid default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid    uuid := (select auth.uid());
  v_org  uuid;
  v_age  integer;
  v_area uuid;
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

  -- Home area (D-036): a passed id must exist; none keeps the saved area or
  -- falls back to Atlanta, so every onboarded profile has a feed origin.
  if p_area_id is not null then
    select id into v_area from public.areas where id = p_area_id;
    if v_area is null then
      raise exception 'area_not_found' using errcode = 'foreign_key_violation';
    end if;
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
  v_age := extract(year from age(current_date::timestamp, p_birth_date::timestamp))::integer;
  if exists (select 1 from public.hubs h where h.id = any (p_hub_ids) and h.is_active and h.min_age > v_age) then
    raise exception 'hub_min_age' using errcode = 'check_violation',
      hint = 'One of the picked hubs is 21+.';
  end if;

  update public.profiles
     set handle = p_handle,
         first_name = btrim(p_first_name),
         home_org_id = coalesce(v_org, home_org_id),
         home_campus_id = coalesce(p_campus_id, home_campus_id),
         home_area_id = coalesce(v_area, home_area_id, (select a.id from public.areas a where a.slug = 'atlanta')),
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  insert into public.hub_members (user_id, hub_id)
  select uid, h.id
    from public.hubs h
   where h.id = any (p_hub_ids) and h.is_active and h.min_age <= v_age
  on conflict do nothing;

  if not exists (select 1 from public.hub_members where user_id = uid) then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;

  return result;
end $$;

comment on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) is
  'Finishes onboarding: write-once birth date (18+), handle, first name, optional declared campus or organization, home area (p_area_id must exist; null keeps the saved area or falls back to Atlanta), and at least one hub (21+ hubs refused under 21). Errors: not_authenticated, birth_date_required, first_name_required, pick_at_least_one_hub, too_many_hubs, handle_reserved, handle_taken, campus_not_found, org_not_found, area_not_found, birth_date_locked, hub_min_age, profile_missing.';

create or replace function public.set_home_area(p_area_id uuid, p_radius_km smallint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_area   public.areas%rowtype;
  v_radius smallint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_area_id is null then
    raise exception 'area_required' using errcode = 'check_violation';
  end if;
  select * into v_area from public.areas where id = p_area_id;
  if not found then
    raise exception 'area_not_found' using errcode = 'P0002';
  end if;
  if p_radius_km is not null and p_radius_km not between 1 and 50 then
    raise exception 'radius_out_of_range' using errcode = 'check_violation', hint = '1 to 50 km.';
  end if;

  update public.profiles
     set home_area_id = v_area.id
   where id = uid and deleted_at is null;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  update public.profile_private
     set feed_radius_km = coalesce(p_radius_km, feed_radius_km)
   where user_id = uid
  returning feed_radius_km into v_radius;

  return jsonb_build_object(
    'area_id', v_area.id, 'slug', v_area.slug, 'name', v_area.name,
    'feed_radius_km', v_radius);
end $$;
comment on function public.set_home_area(uuid, smallint) is
  'Saves the caller''s home area and, when given, the feed radius (1 to 50 km). Returns {area_id, slug, name, feed_radius_km}. Errors: not_authenticated, area_required, area_not_found, radius_out_of_range, profile_missing.';

-- ---------------------------------------------------------------------------
-- 5. feed_events_v2 (SECURITY INVOKER: the events policies decide every row)
-- ---------------------------------------------------------------------------
create or replace function public.feed_events_v2(
  p_from      timestamptz,
  p_to        timestamptz,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_hub_ids   uuid[] default null,
  p_free_only boolean default false,
  p_limit     integer default 60
)
returns table (
  id                 uuid,
  kind               public.event_kind,
  hub_id             uuid,
  hub_slug           text,
  hub_name           text,
  hub_emoji          text,
  chapter_id         uuid,
  campus_id          uuid,
  host_id            uuid,
  series_id          uuid,
  occurrence_date    date,
  title              text,
  description        text,
  cover_url          text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  timezone           text,
  min_age            smallint,
  capacity           integer,
  waitlist_enabled   boolean,
  min_headcount      integer,
  members_only       boolean,
  is_free            boolean,
  price_text         text,
  status             public.event_status,
  visibility         public.event_visibility,
  address_visibility public.address_visibility,
  location_hint      text,
  going_count        integer,
  waitlist_count     integer,
  interested_count   integer,
  external_url       text,
  source_name        text,
  created_at         timestamptz,
  updated_at         timestamptz,
  distance_band      text,
  section            text,
  is_imported        boolean,
  matched_by         text
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_origin   extensions.geography;
  v_radius_m double precision;
  v_today    date := (now() at time zone 'America/New_York')::date;
  v_limit    integer := greatest(1, least(coalesce(p_limit, 60), 200));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_window' using errcode = 'check_violation';
  end if;
  if p_to - p_from > interval '93 days' then
    raise exception 'window_too_long' using errcode = 'check_violation', hint = 'Up to 93 days.';
  end if;
  if (p_lat is null) <> (p_lng is null)
     or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;

  -- Origin: the device point (about 1 km, never stored), else the home area,
  -- else the declared home campus, else Atlanta.
  v_origin := coalesce(
    case when p_lat is not null then
      extensions.ST_SetSRID(extensions.ST_MakePoint(
        round(p_lng::numeric, 2)::double precision,
        round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography
    end,
    (select a.center from public.profiles p join public.areas a on a.id = p.home_area_id where p.id = uid),
    (select c.location from public.profiles p join public.org_campuses c on c.id = p.home_campus_id where p.id = uid),
    (select a.center from public.areas a where a.slug = 'atlanta'));

  v_radius_m := 1000.0 * greatest(1, least(50, coalesce(
    p_radius_km,
    (select pp.feed_radius_km::integer from public.profile_private pp where pp.user_id = uid),
    (select a.default_radius_km::integer from public.profiles p join public.areas a on a.id = p.home_area_id where p.id = uid),
    (select a.default_radius_km::integer from public.areas a where a.slug = 'atlanta'),
    10)));

  return query
  with my_hubs as (
    select hm.hub_id from public.hub_members hm where hm.user_id = uid
  ), my_campuses as (
    select m.campus_id from public.org_memberships m
     where m.user_id = uid and m.campus_id is not null
       and (m.expires_at is null or m.expires_at > now())
  ), cand as (
    select e.*,
           h.slug  as h_slug,
           h.name  as h_name,
           h.emoji as h_emoji,
           (e.hub_id in (select hub_id from my_hubs)) as by_hub,
           (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses)) as by_campus
      from public.events e
      join public.hubs h on h.id = e.hub_id
     where e.status = 'published'
       and e.starts_at >= p_from and e.starts_at < p_to
       and (p_hub_ids is null or e.hub_id = any (p_hub_ids))
       and (not coalesce(p_free_only, false) or e.is_free)
       and (
         e.hub_id in (select hub_id from my_hubs)
         or (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses))
         or (
           e.visibility = 'public'
           and e.approx_point is not null
           and extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m + 8000)
           and (e.address_visibility = 'approved_only'
                or extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m))
         )
       )
  ), banded as (
    select c.*,
           case when c.approx_point is null then null::double precision
                else extensions.ST_Distance(c.approx_point, v_origin) end as dist_m,
           (c.starts_at at time zone 'America/New_York')::date as local_day
      from cand c
  )
  select b.id, b.kind, b.hub_id, b.h_slug, b.h_name, b.h_emoji, b.chapter_id, b.campus_id, b.host_id,
         b.series_id, b.occurrence_date, b.title, b.description, b.cover_url, b.starts_at, b.ends_at,
         b.timezone, b.min_age, b.capacity, b.waitlist_enabled, b.min_headcount, b.members_only,
         b.is_free, b.price_text, b.status, b.visibility, b.address_visibility, b.location_hint,
         b.going_count, b.waitlist_count, b.interested_count, b.external_url, b.source_name,
         b.created_at, b.updated_at,
         case
           when b.dist_m is null then null::text
           when b.address_visibility = 'approved_only' then 'approximate'
           when b.dist_m < 1609.344  then '<1 mi'
           when b.dist_m < 8046.72   then '1-5 mi'
           when b.dist_m < 16093.44  then '5-10 mi'
           when b.dist_m < 40233.6   then '10-25 mi'
           else '25+ mi'
         end,
         case
           when b.local_day <= v_today     then 'today'
           when b.local_day <  v_today + 7 then 'this_week'
           else 'later'
         end,
         (b.kind = 'imported'),
         case when b.by_hub then 'hub' when b.by_campus then 'campus' else 'nearby' end
    from banded b
   order by (b.kind = 'imported'), (not (b.by_hub or b.by_campus)), b.starts_at, b.id
   limit v_limit;
end $$;

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) is
  'Feed v2 (D-036): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public within the radius of the origin (p_lat/p_lng rounded to 0.01 degree, else home area, else home campus, else Atlanta; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km). Events without a point come only through hubs or campus. Approved-only events get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, hub or campus matches first, then start time. Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates.';

-- ---------------------------------------------------------------------------
-- 6. Chapters may belong to an area (run by a verified captain) instead of
--    an organization (D-035). Staging and production hold 0 chapters.
-- ---------------------------------------------------------------------------
alter table public.hub_chapters alter column org_id drop not null;
alter table public.hub_chapters
  add column if not exists area_id uuid references public.areas (id) on delete restrict;
do $$ begin
  alter table public.hub_chapters
    add constraint hub_chapters_owner_required check (org_id is not null or area_id is not null);
exception when duplicate_object then null; end $$;
drop index if exists public.hub_chapters_unique_place;
create unique index if not exists hub_chapters_unique_place_v2
  on public.hub_chapters (hub_id, org_id, campus_id, area_id) nulls not distinct;
create index if not exists hub_chapters_area_idx on public.hub_chapters (area_id);

-- Joining: an organization's chapter still needs a verified membership in it;
-- an area chapter has no organization to verify against, so anyone may join.
drop policy if exists "chapter_members_insert_own" on public.chapter_members;
create policy "chapter_members_insert_own" on public.chapter_members for insert to authenticated
  with check (
    user_id = (select auth.uid()) and role = 'member'
    and exists (
      select 1
        from public.hub_chapters c
       where c.id = chapter_id and c.is_active
         and (
           c.org_id is null
           or exists (
             select 1 from public.org_memberships m
              where m.org_id = c.org_id and m.user_id = (select auth.uid())
                and (m.expires_at is null or m.expires_at > now())
           )
         )
    )
  );

-- ---------------------------------------------------------------------------
-- 7. Venue privacy (D-038)
-- ---------------------------------------------------------------------------
alter table public.venues alter column is_public set default false;
comment on table public.venues is
  'Geocoded places (Geoapify results may be stored). lat/lng are generated from location. is_public = false marks a private address (the default; only an explicit is_public = true makes a venue public): readable by its creator, moderators and through a readable event_addresses row only. Written through upsert_venue.';

-- upsert_venue: same body as migration 6 except the is_public default, which
-- is now false unless the caller passes true (a place_id no longer implies a
-- public place: a geocoded street address is somebody's home as often as not).
create or replace function public.upsert_venue(p_args jsonb)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v          public.venues%rowtype;
  v_mod      boolean;
  v_name     text := btrim(coalesce(a ->> 'name', ''));
  v_addr1    text := btrim(coalesce(a ->> 'address_line1', ''));
  v_addr2    text := btrim(coalesce(a ->> 'address_line2', ''));
  v_city     text := btrim(coalesce(a ->> 'city', ''));
  v_state    text := btrim(coalesce(a ->> 'state', ''));
  v_postal   text := btrim(coalesce(a ->> 'postal_code', ''));
  v_country  text := upper(coalesce(nullif(btrim(coalesce(a ->> 'country', '')), ''), 'US'));
  v_place_id text := nullif(btrim(coalesce(a ->> 'place_id', '')), '');
  v_campus   uuid := (a ->> 'campus_id')::uuid;
  v_public   boolean;
  v_lat      double precision := (a ->> 'lat')::double precision;
  v_lng      double precision := (a ->> 'lng')::double precision;
  v_point    extensions.geography;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_mod    := public.is_moderator();
  v_public := coalesce((a ->> 'is_public')::boolean, false);   -- D-038: private unless the caller says so
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'name_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    raise exception 'country_invalid' using errcode = 'check_violation', hint = 'Two-letter country code.';
  end if;
  if (v_lat is null) <> (v_lng is null)
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  if v_campus is not null and not exists (select 1 from public.org_campuses where id = v_campus) then
    raise exception 'campus_not_found' using errcode = 'P0002';
  end if;

  -- Serialize concurrent creates of the same place; hashtext is stable per key.
  perform pg_advisory_xact_lock(hashtext('venue:' || coalesce(v_place_id, lower(v_name) || '|' || v_postal)));

  if v_public then
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and is_public;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  else
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and not is_public and created_by = uid
       order by created_at limit 1;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and not is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  end if;

  if v.id is not null then
    if v.created_by = uid or v_mod then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             location      = coalesce(location, v_point),
             campus_id     = coalesce(campus_id, v_campus),
             place_id      = case when place_id is null and v_place_id is not null
                                   and not exists (select 1 from public.venues x where x.place_id = v_place_id and x.is_public)
                                  then v_place_id else place_id end
       where id = v.id
       returning * into v;
    end if;
    return v;
  end if;

  if not v_mod then
    perform pg_advisory_xact_lock(hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, address_line2, city, state, postal_code, country,
                             location, place_id, campus_id, created_by, is_public)
  values (v_name, v_addr1, v_addr2, v_city, v_state, v_postal, v_country,
          v_point, v_place_id, v_campus, uid, v_public)
  returning * into v;
  return v;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.upsert_venue(jsonb) is
  'Finds or creates a venue for the caller. New venues are private unless is_public = true is passed (D-038). Public requests match place_id among public venues or (name, postal code) among the caller''s own; private requests match the caller''s own private rows. Twenty new venues a day. Errors: not_authenticated, onboarding_required, name_required, name_length, country_invalid, invalid_coordinates, campus_not_found, too_many_venues, or a table constraint name.';

-- event_set_location: same body as migration 6 except the approved-only
-- point, which is the campus centroid only when the venue is within 2 km of
-- the campus (or has no point), else the venue snapped to the 0.1 degree grid.
create or replace function public.event_set_location(
  p_event_id           uuid,
  p_venue_id           uuid,
  p_location_text      text,
  p_address_note       text,
  p_address_visibility public.address_visibility,
  p_location_hint      text,
  p_campus_id          uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_venue  public.venues%rowtype;
  v_host   uuid;
  v_campus public.org_campuses%rowtype;
  v_hint   text;
  v_point  extensions.geography;
  v_text   text := btrim(coalesce(p_location_text, ''));
begin
  select host_id into v_host from public.events where id = p_event_id;
  if p_venue_id is not null then
    select * into v_venue from public.venues where id = p_venue_id;
    if not found then
      raise exception 'venue_not_found' using errcode = 'P0002';
    end if;
  end if;
  if p_campus_id is not null then
    select * into v_campus from public.org_campuses where id = p_campus_id;
  end if;

  if p_address_visibility = 'public' then
    if v_venue.id is not null and not v_venue.is_public then
      raise exception 'private_venue_requires_approval' using errcode = 'check_violation';
    end if;
    v_hint  := coalesce(nullif(btrim(coalesce(p_location_hint, '')), ''), v_venue.name, nullif(v_text, ''), '');
    v_point := v_venue.location;
  else
    if v_venue.id is not null and v_venue.is_public and v_venue.created_by is not null and v_venue.created_by = v_host
       and not exists (
         select 1 from public.event_addresses ea
           join public.events e2 on e2.id = ea.event_id
          where ea.venue_id = v_venue.id and ea.event_id <> p_event_id and e2.address_visibility = 'public') then
      update public.venues set is_public = false where id = v_venue.id;
      v_venue.is_public := false;
    end if;
    v_hint := coalesce(
      nullif(btrim(coalesce(p_location_hint, '')), ''),
      case when v_campus.id is not null then 'Near ' || v_campus.name end,
      case when nullif(v_venue.city, '') is not null then 'Near ' || v_venue.city end,
      'Address shared after approval');
    -- The campus centroid stands in only when the venue is within 2 km of the
    -- campus (or the venue has no point at all); a venue farther out would be
    -- placed kilometres from where it is, so it gets the 0.1 degree cell (D-038).
    if v_campus.location is not null
       and (v_venue.location is null or extensions.ST_DWithin(v_venue.location, v_campus.location, 2000)) then
      v_point := v_campus.location;
    elsif v_venue.location is not null then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
                   round(extensions.ST_X(v_venue.location::extensions.geometry)::numeric, 1)::double precision,
                   round(extensions.ST_Y(v_venue.location::extensions.geometry)::numeric, 1)::double precision
                 ), 4326)::extensions.geography;
    end if;
  end if;

  insert into public.event_addresses (event_id, venue_id, location_text, address_note)
  values (p_event_id, p_venue_id, v_text, btrim(coalesce(p_address_note, '')))
  on conflict (event_id) do update
     set venue_id      = excluded.venue_id,
         location_text = excluded.location_text,
         address_note  = excluded.address_note;

  update public.events
     set location_hint = left(v_hint, 120),
         approx_point  = v_point
   where id = p_event_id
     and (location_hint is distinct from left(v_hint, 120) or approx_point::text is distinct from v_point::text);
end $$;

-- Backfill the stored point of approved-only events with the same rule.
update public.events e
   set approx_point = case
         when c.location is not null and extensions.ST_DWithin(v.location, c.location, 2000) then c.location
         else extensions.ST_SetSRID(extensions.ST_MakePoint(
                round(extensions.ST_X(v.location::extensions.geometry)::numeric, 1)::double precision,
                round(extensions.ST_Y(v.location::extensions.geometry)::numeric, 1)::double precision
              ), 4326)::extensions.geography
       end
  from public.event_addresses ea
  join public.venues v on v.id = ea.venue_id
  left join public.org_campuses c on c.id = (select e2.campus_id from public.events e2 where e2.id = ea.event_id)
 where ea.event_id = e.id
   and e.address_visibility = 'approved_only'
   and v.location is not null
   and e.approx_point::text is distinct from (case
         when c.location is not null and extensions.ST_DWithin(v.location, c.location, 2000) then c.location
         else extensions.ST_SetSRID(extensions.ST_MakePoint(
                round(extensions.ST_X(v.location::extensions.geometry)::numeric, 1)::double precision,
                round(extensions.ST_Y(v.location::extensions.geometry)::numeric, 1)::double precision
              ), 4326)::extensions.geography
       end)::text;

-- ---------------------------------------------------------------------------
-- 8. request_account_deletion: same body as migration 6 plus home_area_id and
--    the city waitlist
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_event   uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    now() + interval '30 days',
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         home_area_id           = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
   where host_id = uid and status = 'published' and starts_at > now();
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  delete from public.area_waitlist            where user_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;

comment on function public.request_account_deletion(text) is
  'Deletes the caller''s account immediately: ledger row, tombstone profile (home area cleared), handle released, private data, memberships and the city waitlist row removed, hosted series and future events cancelled with their addresses, private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 9. Privileges (explicit; RLS still decides rows)
-- ---------------------------------------------------------------------------
grant all on public.areas, public.area_waitlist to service_role;
grant select on public.areas to anon, authenticated;
grant insert, update, delete on public.areas to authenticated;   -- moderators, via RLS
revoke all on public.area_waitlist from anon, authenticated;
grant select on public.area_waitlist to authenticated;

revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) to authenticated;
revoke all on function public.set_home_area(uuid, smallint) from public, anon;
grant execute on function public.set_home_area(uuid, smallint) to authenticated;
revoke all on function public.join_area_waitlist(text) from public, anon;
grant execute on function public.join_area_waitlist(text) to authenticated;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) to authenticated;
revoke all on function public.upsert_venue(jsonb) from public, anon;
grant execute on function public.upsert_venue(jsonb) to authenticated;
revoke all on function public.event_set_location(uuid, uuid, text, text, public.address_visibility, text, uuid)
  from public, anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. Version stamp (last, so /api/health only sees it when everything landed)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.10')
  on conflict (key) do update set value = excluded.value, updated_at = now();
