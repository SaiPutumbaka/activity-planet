-- ============================================================================
-- Activity Planet schema v2 — migration 26: the viewer's own time zone for the
--   feed, and venues without an assumed country (D-040 gaps left by
--   migrations 24 and 25). Fixes forward; every rebuilt function starts from
--   its latest body (named below) and changes only what is listed.
--   Checks: supabase/tests/viewer_timezone.sql.
--
--   What this file does
--     1. profile_private.timezone: the person's IANA time zone (as the
--        device reports it, Intl.DateTimeFormat().resolvedOptions().timeZone),
--        null until the app saves one. Validated against pg_timezone_names
--        (a name with a '/', at most 64 characters) by a trigger on every
--        write, whoever writes it. Owner-only like the rest of the row: the
--        existing read-own policy covers it; no client UPDATE grant. Deleted
--        with the row on account deletion (delete_my_account removes
--        profile_private whole), so no deletion change is needed.
--     2. set_my_timezone(p_timezone): new definer RPC that saves it (null or
--        blank clears it). Errors: not_authenticated, timezone_invalid,
--        profile_missing.
--     3. feed_events_v2 (migration 24 body, 20261119000100) gains
--        p_timezone text default null (last). Today / This week / Later are
--        computed in the zone sent (when valid), else the saved
--        profile_private.timezone, else the event's own timezone, else
--        America/New_York; an unknown zone sent is ignored, never an error,
--        so the feed always loads. Nothing else changes: still invoker
--        (events RLS with viewer_is_adult applies), same origin chain,
--        filters, bands and order. The eight-argument overload is dropped
--        and the new one granted to authenticated only.
--     4. venues.country: no default and nullable. upsert_venue (migration 23
--        body, 20261118000100) stores the country only when one is sent
--        (two letters, upper-cased); none sent stays null instead of 'US'.
--        The cross-user content match compares country with IS NOT DISTINCT
--        FROM (a null never matches 'US'), and the creator's fill of empty
--        fields also fills a null country from the one sent. Existing rows
--        are left as they are.
--     * meta.schema_version 2.22.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. profile_private.timezone
-- ---------------------------------------------------------------------------
alter table public.profile_private
  add column if not exists timezone text;

do $$ begin
  alter table public.profile_private
    add constraint profile_private_timezone_length check (timezone is null or char_length(timezone) between 3 and 64);
exception when duplicate_object then null; end $$;

comment on column public.profile_private.timezone is
  'The person''s IANA time zone (D-040), as the device reports it; null until the app saves one with set_my_timezone. Validated against pg_timezone_names on every write. feed_events_v2 files Today / This week / Later in it. Owner-only.';

create or replace function public.profile_private_check_timezone()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.timezone is not null
     and (new.timezone not like '%/%'
          or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = new.timezone)) then
    raise exception 'timezone_invalid' using errcode = 'check_violation', hint = 'An IANA zone such as Europe/London.';
  end if;
  return new;
end $$;
comment on function public.profile_private_check_timezone() is
  'Trigger: refuses a profile_private.timezone that is not an IANA zone name in pg_timezone_names (with a ''/''; abbreviations such as EST never observe DST), whoever writes it.';

drop trigger if exists profile_private_check_timezone on public.profile_private;
create trigger profile_private_check_timezone
  before insert or update of timezone on public.profile_private
  for each row execute function public.profile_private_check_timezone();

revoke update (timezone) on public.profile_private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. set_my_timezone
-- ---------------------------------------------------------------------------
create or replace function public.set_my_timezone(p_timezone text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  v_tz text := nullif(btrim(coalesce(p_timezone, '')), '');
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_tz is not null and not public.is_valid_timezone(v_tz) then
    raise exception 'timezone_invalid' using errcode = 'check_violation', hint = 'An IANA zone such as Europe/London.';
  end if;
  if not exists (select 1 from public.profiles where id = uid and deleted_at is null) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  update public.profile_private
     set timezone = v_tz
   where user_id = uid
     and timezone is distinct from v_tz;
  if not found and not exists (select 1 from public.profile_private where user_id = uid) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  return jsonb_build_object('timezone', v_tz);
end $$;
comment on function public.set_my_timezone(text) is
  'Saves the caller''s IANA time zone (D-040) into profile_private.timezone; null or blank clears it. feed_events_v2 uses it for Today / This week / Later when the app sends no zone. Returns {timezone}. Errors: not_authenticated, timezone_invalid, profile_missing.';

-- ---------------------------------------------------------------------------
-- 3. feed_events_v2 (migration 24 body): the viewer's zone for the sections
-- ---------------------------------------------------------------------------
drop function if exists public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer);

create or replace function public.feed_events_v2(
  p_from      timestamptz,
  p_to        timestamptz,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_hub_ids   uuid[] default null,
  p_free_only boolean default false,
  p_limit     integer default 60,
  p_timezone  text default null
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
  v_tz       text;
  v_zones    text[];
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

  -- Day boundaries (migration 26): the zone the app sent when it is a known
  -- IANA name, else the saved profile_private.timezone, else (per event) the
  -- event's own timezone, else America/New_York. An unknown zone is ignored.
  select t.tz into v_tz
    from (values (1, nullif(btrim(coalesce(p_timezone, '')), '')),
                 (2, (select pp.timezone from public.profile_private pp where pp.user_id = uid))) t(o, tz)
   where t.tz is not null and char_length(t.tz) <= 64 and t.tz like '%/%'
     and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = t.tz)
   order by t.o
   limit 1;
  if v_tz is null then
    v_zones := array(select z.name from pg_catalog.pg_timezone_names z where z.name like '%/%');
  end if;

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
  ), zoned as (
    select c.*,
           case when v_tz is not null then v_tz
                when c.timezone = any (v_zones) then c.timezone
                else 'America/New_York' end as day_tz
      from cand c
  ), banded as (
    select z.*,
           case when z.approx_point is null then null::double precision
                else extensions.ST_Distance(z.approx_point, v_origin) end as dist_m,
           (z.starts_at at time zone z.day_tz)::date as local_day,
           (now() at time zone z.day_tz)::date as today_day
      from zoned z
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
           when b.local_day <= b.today_day     then 'today'
           when b.local_day <  b.today_day + 7 then 'this_week'
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

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text) is
  'Feed v2 (D-036): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public within the radius of the origin (p_lat/p_lng rounded to 0.01 degree, else profile_private.home_point, else profile_private.home_area_id, else Atlanta, never the declared campus; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km). Events without a point come only through hubs or campus. Approved-only events get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in the viewer''s zone: p_timezone when it is a known IANA name (an unknown one is ignored), else profile_private.timezone, else the event''s timezone, else America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, then start time, hub or campus matches first on a tie. Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates.';

-- ---------------------------------------------------------------------------
-- 4. venues.country: null unless sent
-- ---------------------------------------------------------------------------
alter table public.venues alter column country drop default;
alter table public.venues alter column country drop not null;
comment on column public.venues.country is
  'Two-letter country code (upper case) when the host''s pick or the caller supplied one; null when unknown (migration 26: never assumed).';

-- upsert_venue: body of migration 23 (20261118000100); only the country
-- default, the country comparison in the cross-user lookup and the fill of a
-- null country changed.
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
  -- Migration 26: no country sent stays null (never assumed to be 'US').
  v_country  text := upper(nullif(btrim(coalesce(a ->> 'country', '')), ''));
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
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
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
    -- A place_id is client-supplied, so it never hands over someone else's
    -- row by itself (migration 22): the caller's own public row for the
    -- place, else another public row whose stored point is within 300 m of
    -- the coordinates the caller sent and whose name and address equal the
    -- ones sent (migration 23). Otherwise the caller gets a new row.
    if v_place_id is not null then
      select * into v from public.venues
       where place_id = v_place_id and is_public and created_by = uid
       order by created_at
       limit 1;
      if v.id is null and v_point is not null then
        select * into v from public.venues x
         where x.place_id = v_place_id and x.is_public and x.location is not null
           and extensions.ST_DWithin(x.location, v_point, 300)
           -- Migration 23: the row's content must match what the caller sent.
           and lower(x.name)          = lower(v_name)
           and lower(x.address_line1) = lower(v_addr1)
           and lower(x.address_line2) = lower(v_addr2)
           and lower(x.city)          = lower(v_city)
           and lower(x.state)         = lower(v_state)
           and x.postal_code          = v_postal
           and x.country is not distinct from v_country   -- migration 26: null only matches null
         order by extensions.ST_Distance(x.location, v_point), x.created_at
         limit 1;
      end if;
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
    -- Migration 23: the creator fills empty fields only while no other
    -- host's event uses the row, so a shared venue's text cannot change
    -- after someone else attached it.
    if v_mod or (v.created_by = uid
                 and not exists (select 1 from public.event_addresses ea
                                   join public.events e on e.id = ea.event_id
                                  where ea.venue_id = v.id and e.host_id is distinct from uid)) then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             country       = coalesce(country, v_country),   -- migration 26: an empty country is filled too
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
  'Finds or creates a venue for the caller. New venues are private unless is_public = true is passed (D-038). country is the two-letter code sent (upper-cased), else null (never assumed). Public requests match place_id among the caller''s own public venues, then among other public venues whose point is within 300 m of the lat/lng sent and whose name and address (lines, city, state, postal code, country; a null country matches only null) equal the ones sent (never by place_id or coordinates alone; the creator fills empty fields, a null country included, only while no other host''s event uses the row), then (name, postal code) among the caller''s own; private requests match the caller''s own private rows. Twenty new venues a day. Errors: not_authenticated, onboarding_required, name_required, name_length, country_invalid, invalid_coordinates, campus_not_found, too_many_venues, or a table constraint name.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.profile_private_check_timezone() from public, anon, authenticated, service_role;
revoke all on function public.set_my_timezone(text) from public, anon;
grant execute on function public.set_my_timezone(text) to authenticated;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text) to authenticated;
revoke all on function public.upsert_venue(jsonb) from public, anon;
grant execute on function public.upsert_venue(jsonb) to authenticated;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.22')
  on conflict (key) do update set value = excluded.value, updated_at = now();
