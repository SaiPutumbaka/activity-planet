-- ============================================================================
-- Activity Planet schema v2 — migration 24: location anywhere (D-040;
--   PLAN.md 4.1 to 4.4; amends D-036 and D-037). Fixes forward; every rebuilt
--   function starts from its latest body (named below) and changes only what
--   is listed. Checks: supabase/tests/location_anywhere.sql.
--
--   What this file does
--     1. profile_private.home_point (geography Point 4326, rounded to 0.01
--        degree, about 1 km, by a trigger on every write), home_label (at
--        most 120 characters) and home_set_at. Owner-only like home_area_id:
--        the existing read-own policy covers them; no client UPDATE grant.
--     2. public.collector_regions: where discovery should look (point,
--        radius_km, label, first_user_at, last_discovery_at, priority,
--        home_count). A row is added when someone saves a home point outside
--        every region, so coverage follows users. It carries a place and a
--        count, never a user id (no account-deletion change needed). Rounded
--        to 0.1 degree. Seeded with Atlanta. Service role writes; moderators
--        read; no client writes.
--     3. set_home_location(p_lat, p_lng, p_label, p_radius_km default null):
--        new definer RPC. Validates ranges, saves the rounded point and the
--        label, clears home_area_id, notes the point for discovery.
--     4. set_home_area (migration 11 body): also fills home_point and
--        home_label from the area, and notes the point for discovery.
--     5. complete_onboarding (migration 11 body) gains p_lat, p_lng, p_label
--        (defaulted, after p_area_id). A point saves any location in the
--        world; with neither a point nor an area the saved home is kept, else
--        Atlanta. The seven-argument overload is dropped and re-granted.
--     6. feed_events_v2 (migration 11 body): origin is the device point, else
--        home_point, else the home area centre, else Atlanta. Nothing else
--        changes: still invoker (events RLS with viewer_is_adult applies),
--        same filters, human-hosted rows above imported ones.
--     7. area_waitlist and join_area_waitlist stay (no data loss; D-040 has
--        no city waitlist and the app stops calling it).
--     8. feed_sources: kind adds jsonld, ticketmaster, seatgeek, socrata (ics
--        and rss were already allowed); region_point, region_radius_km,
--        region_label, discovered_from, robots_ok_at, denylisted, partner.
--        The GSU rows become partner = true and are switched off once, when
--        the column is added (D-040: partner sources are off by default; on
--        staging this stops the hourly GSU imports until they are switched
--        back on deliberately). A denylisted source cannot be enabled.
--     * meta.schema_version 2.20.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. profile_private home point
-- ---------------------------------------------------------------------------
alter table public.profile_private
  add column if not exists home_point  extensions.geography(Point, 4326),
  add column if not exists home_label  text,
  add column if not exists home_set_at timestamptz;

do $$ begin
  alter table public.profile_private
    add constraint profile_private_home_label_length check (home_label is null or char_length(home_label) <= 120);
exception when duplicate_object then null; end $$;

comment on column public.profile_private.home_point is
  'Saved home location (D-040), rounded to 0.01 degree (about 1 km) on every write. Owner-only. Written by set_home_location, set_home_area and complete_onboarding; the feed origin when no device point is sent.';
comment on column public.profile_private.home_label is
  'What the person typed or picked for home_point (a city or neighborhood), at most 120 characters. Owner-only.';
comment on column public.profile_private.home_set_at is
  'When home_point was last saved.';
comment on table public.profile_private is
  'Owner-only data: login email (synced from auth, not client-writable), birth date (18+ enforced by trigger, write-once), home point and label (set_home_location, set_home_area, complete_onboarding), home area and feed radius. The location columns are unused: a device point is sent per feed request and never stored (D-036); clients cannot update any of these columns.';

create or replace function public.profile_private_round_home_point()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.home_point is not null then
    new.home_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(extensions.ST_X(new.home_point::extensions.geometry)::numeric, 2)::double precision,
      round(extensions.ST_Y(new.home_point::extensions.geometry)::numeric, 2)::double precision),
      4326)::extensions.geography;
  end if;
  return new;
end $$;
comment on function public.profile_private_round_home_point() is
  'Trigger: rounds profile_private.home_point to 0.01 degree on every insert and update, whoever writes it.';

drop trigger if exists profile_private_round_home_point on public.profile_private;
create trigger profile_private_round_home_point
  before insert or update of home_point on public.profile_private
  for each row execute function public.profile_private_round_home_point();

revoke update (home_point, home_label, home_set_at) on public.profile_private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. collector_regions: discovery follows users
-- ---------------------------------------------------------------------------
create table if not exists public.collector_regions (
  id                uuid primary key default gen_random_uuid(),
  point             extensions.geography(Point, 4326) not null,
  radius_km         smallint not null default 25,
  label             text,
  first_user_at     timestamptz,
  last_discovery_at timestamptz,
  priority          smallint not null default 100,   -- lower is discovered sooner
  home_count        integer not null default 0,      -- home saves that moved into it; never a user id
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint collector_regions_radius_range check (radius_km between 1 and 200),
  constraint collector_regions_label_length check (label is null or char_length(label) <= 120),
  constraint collector_regions_home_count_nonneg check (home_count >= 0)
);
create index if not exists collector_regions_point_idx on public.collector_regions using gist (point);
create index if not exists collector_regions_queue_idx on public.collector_regions (priority, last_discovery_at nulls first);
comment on table public.collector_regions is
  'Collector discovery queue (D-040): places where sources should be found, as a point rounded to 0.1 degree plus a radius. Added when someone saves a home point outside every region (collector_note_home_point); carries a label and a count, never a user id. Service role writes; moderators read.';
create or replace trigger collector_regions_set_updated_at before update on public.collector_regions
  for each row execute function public.set_updated_at();

alter table public.collector_regions enable row level security;
revoke all on public.collector_regions from public, anon, authenticated;
grant select on public.collector_regions to authenticated;   -- rows only through the moderator policy
grant all on public.collector_regions to service_role;
drop policy if exists "collector_regions_select_mod" on public.collector_regions;
create policy "collector_regions_select_mod" on public.collector_regions for select to authenticated
  using ((select public.is_moderator()));

-- Atlanta is seeded first because the founder recruits there (D-040).
insert into public.collector_regions (point, radius_km, label, priority)
select a.center, 50, 'Atlanta', 5
  from public.areas a
 where a.slug = 'atlanta'
   and not exists (select 1 from public.collector_regions r
                    where extensions.ST_DWithin(r.point, a.center, r.radius_km * 1000.0));

-- Internal: called by the definer RPCs below with the newly saved point and
-- the one it replaced. Adds a region when the point is outside every region
-- (serialised, so two people saving at once make one row); otherwise counts
-- the save on the nearest containing region when the person moved into it.
create or replace function public.collector_note_home_point(
  p_point extensions.geography, p_label text, p_old_point extensions.geography default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_region uuid;
begin
  if p_point is null then
    return false;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.collector_regions'));

  select r.id into v_region
    from public.collector_regions r
   where extensions.ST_DWithin(r.point, p_point, r.radius_km * 1000.0)
   order by extensions.ST_Distance(r.point, p_point)
   limit 1;

  if v_region is not null then
    if p_old_point is null or not exists (
         select 1 from public.collector_regions r
          where r.id = v_region and extensions.ST_DWithin(r.point, p_old_point, r.radius_km * 1000.0)) then
      update public.collector_regions set home_count = home_count + 1 where id = v_region;
    end if;
    return false;
  end if;

  insert into public.collector_regions (point, radius_km, label, first_user_at, priority, home_count)
  values (
    extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(extensions.ST_X(p_point::extensions.geometry)::numeric, 1)::double precision,
      round(extensions.ST_Y(p_point::extensions.geometry)::numeric, 1)::double precision),
      4326)::extensions.geography,
    25,
    left(nullif(btrim(coalesce(p_label, '')), ''), 120),
    now(),
    10,
    1);
  return true;
end $$;
comment on function public.collector_note_home_point(extensions.geography, text, extensions.geography) is
  'Internal (D-040): adds a collector_regions row (point rounded to 0.1 degree, 25 km, priority 10) when p_point is outside every region, else counts the save on the nearest containing region if p_old_point was not already in it. Returns true when a region was added. Called only by set_home_location, set_home_area and complete_onboarding.';

-- ---------------------------------------------------------------------------
-- 3. set_home_location: any place in the world
-- ---------------------------------------------------------------------------
create or replace function public.set_home_location(
  p_lat       double precision,
  p_lng       double precision,
  p_label     text default null,
  p_radius_km smallint default null
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_label  text := nullif(btrim(regexp_replace(coalesce(p_label, ''), '\s+', ' ', 'g')), '');
  v_point  extensions.geography;
  v_old    extensions.geography;
  v_radius smallint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null
     or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_label is not null and char_length(v_label) > 120 then
    raise exception 'label_too_long' using errcode = 'check_violation', hint = 'At most 120 characters.';
  end if;
  if p_radius_km is not null and p_radius_km not between 1 and 50 then
    raise exception 'radius_out_of_range' using errcode = 'check_violation', hint = '1 to 50 km.';
  end if;
  if not exists (select 1 from public.profiles where id = uid and deleted_at is null) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
    round(p_lng::numeric, 2)::double precision,
    round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography;

  select pp.home_point into v_old from public.profile_private pp where pp.user_id = uid;

  update public.profile_private
     set home_point     = v_point,
         home_label     = v_label,
         home_set_at    = now(),
         home_area_id   = null,
         feed_radius_km = coalesce(p_radius_km, feed_radius_km)
   where user_id = uid
  returning feed_radius_km into v_radius;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  perform public.collector_note_home_point(v_point, v_label, v_old);

  return jsonb_build_object(
    'lat', round(p_lat::numeric, 2), 'lng', round(p_lng::numeric, 2),
    'label', v_label, 'feed_radius_km', v_radius);
end $$;
comment on function public.set_home_location(double precision, double precision, text, smallint) is
  'Saves the caller''s home location anywhere (D-040): p_lat/p_lng rounded to 0.01 degree into profile_private.home_point, p_label (trimmed, at most 120) into home_label, clears home_area_id, and sets feed_radius_km to p_radius_km (1 to 50) when given, else keeps it. A point outside every collector region adds one. Returns {lat, lng, label, feed_radius_km}. Errors: not_authenticated, invalid_coordinates, label_too_long, radius_out_of_range, profile_missing.';

-- ---------------------------------------------------------------------------
-- 4. set_home_area (migration 11 body): also fills home_point from the area
-- ---------------------------------------------------------------------------
create or replace function public.set_home_area(p_area_id uuid, p_radius_km smallint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_area   public.areas%rowtype;
  v_radius smallint;
  v_old    extensions.geography;
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
  if not exists (select 1 from public.profiles where id = uid and deleted_at is null) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  select pp.home_point into v_old from public.profile_private pp where pp.user_id = uid;

  update public.profile_private
     set home_area_id   = v_area.id,
         feed_radius_km = coalesce(p_radius_km, greatest(1, least(50, v_area.default_radius_km))),
         home_point     = v_area.center,
         home_label     = left(v_area.name, 120),
         home_set_at    = now()
   where user_id = uid
  returning feed_radius_km into v_radius;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  perform public.collector_note_home_point(v_area.center, v_area.name, v_old);

  return jsonb_build_object(
    'area_id', v_area.id, 'slug', v_area.slug, 'name', v_area.name,
    'feed_radius_km', v_radius);
end $$;
comment on function public.set_home_area(uuid, smallint) is
  'Saves the caller''s home area (profile_private.home_area_id, and home_point/home_label from the area''s centre and name) and the feed radius: p_radius_km (1 to 50 km) when given, else the area''s default_radius_km. Returns {area_id, slug, name, feed_radius_km}. Errors: not_authenticated, area_required, area_not_found, radius_out_of_range, profile_missing.';

-- ---------------------------------------------------------------------------
-- 5. complete_onboarding (migration 11 body) with an optional point
-- ---------------------------------------------------------------------------
drop function if exists public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid);

create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null,
  p_org_id     uuid default null,
  p_area_id    uuid default null,
  p_lat        double precision default null,
  p_lng        double precision default null,
  p_label      text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid     uuid := (select auth.uid());
  v_org   uuid;
  v_age   integer;
  v_area  uuid;
  v_point extensions.geography;
  v_old   extensions.geography;
  v_label text := nullif(btrim(regexp_replace(coalesce(p_label, ''), '\s+', ' ', 'g')), '');
  result  public.profiles;
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

  -- Home (D-036, D-040): a point (any place in the world) or an area, not
  -- both. A passed area id must exist; neither keeps the saved home or falls
  -- back to Atlanta, so every onboarded profile has a feed origin.
  if (p_lat is null) <> (p_lng is null)
     or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if p_lat is not null and p_area_id is not null then
    raise exception 'location_conflict' using errcode = 'check_violation', hint = 'Send a point or an area, not both.';
  end if;
  if v_label is not null and char_length(v_label) > 120 then
    raise exception 'label_too_long' using errcode = 'check_violation', hint = 'At most 120 characters.';
  end if;
  if p_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(p_lng::numeric, 2)::double precision,
      round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography;
  end if;
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
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  select pp.home_point into v_old from public.profile_private pp where pp.user_id = uid;

  if v_point is not null then
    -- A point: saved as home, the area cleared, the radius kept.
    update public.profile_private
       set home_point   = v_point,
           home_label   = v_label,
           home_set_at  = now(),
           home_area_id = null
     where user_id = uid;
    perform public.collector_note_home_point(v_point, v_label, v_old);
  elsif v_area is not null or v_old is null then
    -- Home area and radius are owner-only (profile_private). A new or changed
    -- area resets the radius to that area's default; an unchanged one keeps it.
    -- A passed area also becomes the home point; the Atlanta fallback does not.
    update public.profile_private pp
       set home_area_id   = n.area_id,
           feed_radius_km = case when pp.home_area_id is distinct from n.area_id
                                 then n.default_radius_km else pp.feed_radius_km end,
           home_point     = case when v_area is not null then n.center else pp.home_point end,
           home_label     = case when v_area is not null then left(n.name, 120) else pp.home_label end,
           home_set_at    = case when v_area is not null then now() else pp.home_set_at end
      from (select a.id as area_id, a.default_radius_km, a.center, a.name
              from public.areas a
             where a.id = coalesce(v_area,
                                   (select x.home_area_id from public.profile_private x where x.user_id = uid),
                                   (select y.id from public.areas y where y.slug = 'atlanta'))) n
     where pp.user_id = uid;
    if v_area is not null then
      perform public.collector_note_home_point((select a.center from public.areas a where a.id = v_area),
                                               (select a.name from public.areas a where a.id = v_area), v_old);
    end if;
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

comment on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid, double precision, double precision, text) is
  'Finishes onboarding: write-once birth date (18+), handle, first name, optional declared campus or organization, home in profile_private (p_lat/p_lng anywhere in the world, rounded to 0.01 degree, with p_label, clearing the area; or p_area_id, which must exist and also sets the home point; neither keeps the saved home or falls back to Atlanta; a new area resets feed_radius_km to its default), and at least one hub (21+ hubs refused under 21). A point outside every collector region adds one. Errors: not_authenticated, birth_date_required, first_name_required, pick_at_least_one_hub, too_many_hubs, handle_reserved, handle_taken, campus_not_found, org_not_found, invalid_coordinates, location_conflict, label_too_long, area_not_found, birth_date_locked, hub_min_age, profile_missing.';

-- ---------------------------------------------------------------------------
-- 6. feed_events_v2 (migration 11 body): home point in the origin chain
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

  -- Origin: the device point (about 1 km, never stored), else the saved home
  -- point (D-040, about 1 km), else the home area, else Atlanta. A declared
  -- campus is never the origin (D-036).
  v_origin := coalesce(
    case when p_lat is not null then
      extensions.ST_SetSRID(extensions.ST_MakePoint(
        round(p_lng::numeric, 2)::double precision,
        round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography
    end,
    (select pp.home_point from public.profile_private pp where pp.user_id = uid),
    (select a.center from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.center from public.areas a where a.slug = 'atlanta'));

  v_radius_m := 1000.0 * greatest(1, least(50, coalesce(
    p_radius_km,
    (select pp.feed_radius_km::integer from public.profile_private pp where pp.user_id = uid),
    (select a.default_radius_km::integer from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
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
   -- Human-hosted rows by start time (hub or campus matches first only on a
   -- tie), so a busy hub list cannot push every nearby event past the limit.
   order by (b.kind = 'imported'), b.starts_at, (not (b.by_hub or b.by_campus)), b.id
   limit v_limit;
end $$;

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) is
  'Feed v2 (D-036): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public within the radius of the origin (p_lat/p_lng rounded to 0.01 degree, else profile_private.home_point, else profile_private.home_area_id, else Atlanta, never the declared campus; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km). Events without a point come only through hubs or campus. Approved-only events get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, then start time, hub or campus matches first on a tie. Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates.';

-- ---------------------------------------------------------------------------
-- 7. area_waitlist: kept, no longer used (D-040 has no city waitlist)
-- ---------------------------------------------------------------------------
comment on table public.area_waitlist is
  'Unused since D-040 (2026-11-03): every city is served, so nothing in the app writes here any more. Kept so no row is lost. One row per person who asked to be told when Activity Planet reaches their city; owner reads; removed by request_account_deletion.';
comment on function public.join_area_waitlist(text) is
  'Unused since D-040 (kept callable; the app no longer calls it). Records (or replaces) the caller''s city on the waitlist. Errors: not_authenticated, city_length.';

-- ---------------------------------------------------------------------------
-- 8. feed_sources: collector kinds, regions, discovery, denylist, partners
-- ---------------------------------------------------------------------------
alter table public.feed_sources drop constraint if exists feed_sources_kind;
alter table public.feed_sources
  add constraint feed_sources_kind check (kind in (
    'localist', 'engage_rss', 'ics', 'rss', 'jsonld', 'ticketmaster', 'seatgeek', 'socrata'));

alter table public.feed_sources
  add column if not exists region_point     extensions.geography(Point, 4326),
  add column if not exists region_radius_km smallint,
  add column if not exists region_label     text,
  add column if not exists discovered_from  text,
  add column if not exists robots_ok_at     timestamptz,
  add column if not exists denylisted       boolean not null default false;

-- partner arrives with a one-time switch-off of the GSU rows (D-040: partner
-- sources are optional and off by default). Guarded by the column's absence,
-- so a re-run never turns a deliberately re-enabled partner source off.
do $$ begin
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'feed_sources' and column_name = 'partner') then
    alter table public.feed_sources add column partner boolean not null default false;
    update public.feed_sources
       set partner = true, enabled = false
     where slug in ('gsu-localist', 'gsu-pin');
  end if;
end $$;

do $$ begin
  alter table public.feed_sources
    add constraint feed_sources_region_radius_range check (region_radius_km is null or region_radius_km between 1 and 200);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources
    add constraint feed_sources_region_label_length check (region_label is null or char_length(region_label) <= 120);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources
    add constraint feed_sources_discovered_from_length check (discovered_from is null or char_length(discovered_from) <= 500);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.feed_sources
    add constraint feed_sources_denylisted_off check (not (denylisted and enabled));
exception when duplicate_object then null; end $$;

create index if not exists feed_sources_region_point_idx on public.feed_sources using gist (region_point);

comment on table public.feed_sources is
  'Collector sources (D-037, D-040). One row per feed or API: kind localist, engage_rss, ics, rss, jsonld (schema.org Event pages), ticketmaster, seatgeek, socrata. enabled defaults to false; partner rows (GSU) stay off until their partnership and D-037''s courtesy notice allow it; a denylisted row cannot be enabled. region_* is the area a source covers; discovered_from is the page or dataset it was found from; robots_ok_at is the last robots.txt check. Written by migrations, data files, the service role and the import RPCs; moderators can read it.';
comment on column public.feed_sources.partner is
  'True for optional partner sources (Georgia State Localist and PIN, D-040). Off by default.';
comment on column public.feed_sources.denylisted is
  'Blocked on request or after a terms change (D-040). A denylisted source cannot be enabled.';

-- No client writes on collector tables (feed_sources keeps its moderator read).
revoke insert, update, delete, truncate, references, trigger on public.feed_sources from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.profile_private_round_home_point() from public, anon, authenticated, service_role;
revoke all on function public.collector_note_home_point(extensions.geography, text, extensions.geography) from public, anon, authenticated, service_role;
revoke all on function public.set_home_location(double precision, double precision, text, smallint) from public, anon;
grant execute on function public.set_home_location(double precision, double precision, text, smallint) to authenticated;
revoke all on function public.set_home_area(uuid, smallint) from public, anon;
grant execute on function public.set_home_area(uuid, smallint) to authenticated;
revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid, double precision, double precision, text) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid, double precision, double precision, text) to authenticated;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) to authenticated;
revoke all on function public.join_area_waitlist(text) from public, anon;
grant execute on function public.join_area_waitlist(text) to authenticated;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.20')
  on conflict (key) do update set value = excluded.value, updated_at = now();
