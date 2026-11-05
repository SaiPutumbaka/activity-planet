-- ============================================================================
-- Activity Planet schema v2 — migration 57: the feed is distance-based for
--   every member (D-040, PLAN.md 4.3). Fixes forward; the one rebuilt
--   function (feed_events_v2) starts from its latest body (migration 35,
--   20261129000100_places_lifecycle_odbl.sql) and keeps its signature.
--   Checks: supabase/tests/feed_distance.sql and
--   supabase/tests/everyone_feed_v2.sql (schema_version 2.53).
--
--   The bug (browser QA): the hub and campus arms of feed_events_v2 had no
--   distance check, so a member in London who joined a hub saw an Atlanta
--   member's plans in that hub under "Today", next to the "Not much close by,
--   so this goes a little further out (within 50 km)" note. Plans with only a
--   described location (no point) came in from every joined hub worldwide.
--
--   What this file does
--     1. feed_event_area(event_id), security definer: where a plan with no
--        point stands, for the feed only. Its chapter's area centre, else its
--        chapter's campus, else its own campus, else the host's home area
--        centre, else the host's home point rounded to 0.1 degree (about
--        11 km, coarser than the 0.01 degree it is saved at). Null for
--        imported rows, rows with a point, rows that are not published, are
--        moderated, are over the caller's age or are campus-only to someone
--        outside the campus, and when the caller is signed out. Never the
--        host's saved point itself.
--     2. feed_events_v2 (migration 35 body), same signature and columns:
--          * the hub and campus arms still widen what a member can see
--            (campus-visibility plans), but every row must now be near the
--            origin (device point, else home point, else home area, else
--            Atlanta) within the radius the app sends (the 10, 25, 50 km
--            ladder, capped at 50 km). Point rows: unchanged rule (radius,
--            approved-only radius + 8 km). Rows with no point: placed by
--            feed_event_area with the 8 km slack and distance_band
--            'approximate'; with no area they are left out of other members'
--            feeds. The host always sees their own plans.
--          * imported rows with no point are left out (no place to rank).
--          * the schema has no online plans, so there is nothing to keep.
--        Everything else (the window, filters, sections, time zones, order,
--        listing_kind, errors) is unchanged.
--     3. Grants (explicit) and meta.schema_version 2.53.
--
--   Account deletion: no new table or column; feed_event_area reads the
--   host's profile_private row, which request_account_deletion already
--   removes (and events.host_id is set null when the profile goes).
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. feed_event_area
-- ---------------------------------------------------------------------------
create or replace function public.feed_event_area(p_event_id uuid)
returns extensions.geography language sql stable security definer set search_path = '' as $$
  select coalesce(
           ca.center,
           cc.location,
           ec.location,
           ha.center,
           case when pp.home_point is not null then
             extensions.ST_SetSRID(extensions.ST_MakePoint(
               round(extensions.ST_X(pp.home_point::extensions.geometry)::numeric, 1)::double precision,
               round(extensions.ST_Y(pp.home_point::extensions.geometry)::numeric, 1)::double precision), 4326)::extensions.geography
           end)
    from public.events e
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.areas ca on ca.id = ch.area_id
    left join public.org_campuses cc on cc.id = ch.campus_id
    left join public.org_campuses ec on ec.id = e.campus_id
    left join public.profiles hp on hp.id = e.host_id and hp.deleted_at is null
    left join public.profile_private pp on pp.user_id = hp.id
    left join public.areas ha on ha.id = pp.home_area_id
   where (select auth.uid()) is not null
     and e.id = p_event_id
     and e.approx_point is null
     and e.kind <> 'imported'
     and e.status = 'published'
     and e.moderation_state is null
     and e.min_age <= coalesce((select public.viewer_age()), 18)
     and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id));
$$;
comment on function public.feed_event_area(uuid) is
  'Migration 57 (D-040): where a published plan with no point stands, for feed_events_v2''s distance check. Its chapter''s area centre, else the chapter''s campus, else its campus, else the host''s home area centre, else the host''s home point rounded to 0.1 degree (about 11 km). Null for imported rows, rows with a point, unpublished or moderated rows, rows over the caller''s age, campus-only rows outside the caller''s campus, and signed-out callers.';

-- ---------------------------------------------------------------------------
-- 2. feed_events_v2 (migration 35 body): distance for every arm
-- ---------------------------------------------------------------------------
create or replace function public.feed_events_v2(
  p_from      timestamptz,
  p_to        timestamptz,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_hub_ids   uuid[] default null,
  p_free_only boolean default false,
  p_limit     integer default 60,
  p_timezone  text default null,
  p_listing_kind text default 'plan'
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
  v_kind     text := coalesce(p_listing_kind, 'plan');
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
  if v_kind not in ('plan', 'show') then
    raise exception 'listing_kind_invalid' using errcode = 'check_violation';
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
       and e.listing_kind = v_kind
       and (p_hub_ids is null or e.hub_id = any (p_hub_ids))
       and (not coalesce(p_free_only, false) or e.is_free)
       and (
         e.hub_id in (select hub_id from my_hubs)
         or (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses))
         or e.visibility = 'public'
       )
       -- Migration 57: every arm is distance-based (a hub or campus match no
       -- longer brings in a plan from another city). A plan with a point is
       -- kept within the radius (approved-only: radius + 8 km slack); a plan
       -- with only a described location is placed below; the host always
       -- sees their own plans.
       and (
         e.host_id = uid
         or (e.approx_point is not null
             and extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m + 8000)
             and (e.address_visibility = 'approved_only'
                  or extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m)))
         or (e.approx_point is null and e.kind <> 'imported')
       )
  ), placed as (
    -- A plan with no point stands at its chapter's area or campus, else its
    -- campus, else the host's home area, else the host's home point to 0.1
    -- degree (feed_event_area); with none of those it is left out.
    select c.*,
           case when c.approx_point is not null then c.approx_point
                when c.kind <> 'imported' then public.feed_event_area(c.id)
           end as pt
      from cand c
  ), located as (
    select p.*
      from placed p
     where p.host_id = uid
        or p.approx_point is not null
        or (p.pt is not null and extensions.ST_DWithin(p.pt, v_origin, v_radius_m + 8000))
  ), zoned as (
    select c.*,
           case when v_tz is not null then v_tz
                when c.timezone = any (v_zones) then c.timezone
                else 'America/New_York' end as day_tz
      from located c
  ), banded as (
    select z.*,
           case when z.pt is null then null::double precision
                else extensions.ST_Distance(z.pt, v_origin) end as dist_m,
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
           when b.address_visibility = 'approved_only' or b.approx_point is null then 'approximate'
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

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) is
  'Feed v2 (D-036, D-040): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public, and (migration 57) in every case near the origin: p_lat/p_lng rounded to 0.01 degree, else profile_private.home_point, else profile_private.home_area_id, else Atlanta, never the declared campus; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km. A hub or campus match no longer brings in a plan from another city. Events without a point are placed by feed_event_area (chapter area or campus, else campus, else the host''s home area, else the host''s home point to 0.1 degree) and left out when there is none; the host always sees their own plans. Approved-only events and events placed by area get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in the viewer''s zone: p_timezone when it is a known IANA name (an unknown one is ignored), else profile_private.timezone, else the event''s timezone, else America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, then start time, hub or campus matches first on a tie. p_listing_kind (migration 35, D-041) is plan (the default: plans and the imported shelf) or show (the "Shows and games" row). Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates, listing_kind_invalid.';

-- ---------------------------------------------------------------------------
-- 3. Grants and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.feed_event_area(uuid) from public, anon;
grant execute on function public.feed_event_area(uuid) to authenticated;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.53')
  on conflict (key) do update set value = excluded.value, updated_at = now();
