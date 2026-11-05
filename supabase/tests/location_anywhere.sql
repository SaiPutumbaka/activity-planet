-- ============================================================================
-- Staging check for migration 20261119000100_location_anywhere.sql (D-040).
-- One transaction: sets up throwaway users and events, asserts with DO blocks
-- that raise on failure, then rolls everything back. Prints pass/fail only.
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_l1    uuid := gen_random_uuid();   -- London, saves a point during onboarding
  v_l2    uuid := gen_random_uuid();   -- London, about 2 km away, saves later
  v_none  uuid := gen_random_uuid();   -- gives no location
  v_host  uuid := gen_random_uuid();
  v_hub_a uuid;
  v_hub_b uuid;
  v_t     timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_id    uuid;
  v_london extensions.geography :=
    extensions.ST_SetSRID(extensions.ST_MakePoint(-0.1278, 51.5074), 4326)::extensions.geography;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'locany-' || substr(u::text, 1, 8) || '@example.com', now(), now()
    from unnest(array[v_l1, v_l2, v_none, v_host]) as u;

  select id into v_hub_a from public.hubs
   where is_active and min_age = 18 and scope = 'general' order by slug limit 1;
  select id into v_hub_b from public.hubs
   where is_active and min_age = 18 and scope = 'general' and id <> v_hub_a order by slug desc limit 1;
  if v_hub_a is null or v_hub_b is null then
    raise exception 'setup: need two general hubs on staging';
  end if;

  -- A member who saved a London home on staging (the browser QA account does) leaves a region
  -- there; this check needs London uncovered, so drop it inside the transaction (rolled back).
  delete from public.collector_regions r
   where extensions.ST_DWithin(r.point, v_london, r.radius_km * 1000.0);
  perform set_config('test.regions_before', (select count(*) from public.collector_regions)::text, true);

  -- Public events in a hub nobody here joins: 3 km and 40 km north of London,
  -- and 3 km north of the Atlanta centre.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_b, v_host, 'Location anywhere London near', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-0.1278, 51.5344), 4326)::extensions.geography)
  returning id into v_id;
  perform set_config('test.e_lon_near', v_id::text, true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_b, v_host, 'Location anywhere London far', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-0.1278, 51.8674), 4326)::extensions.geography)
  returning id into v_id;
  perform set_config('test.e_lon_far', v_id::text, true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_b, v_host, 'Location anywhere Atlanta near', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.7760), 4326)::extensions.geography)
  returning id into v_id;
  perform set_config('test.e_atl_near', v_id::text, true);

  perform set_config('test.l1', v_l1::text, true);
  perform set_config('test.l2', v_l2::text, true);
  perform set_config('test.none', v_none::text, true);
  perform set_config('test.hub_a', v_hub_a::text, true);
end $$;

-- Static checks (as the owner)
do $$
declare v_def text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 20] then
    raise exception 'FAIL schema_version is older than 2.20';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'complete_onboarding') <> 1 then
    raise exception 'FAIL complete_onboarding has more than one overload';
  end if;
  select pg_get_constraintdef(c.oid) into v_def from pg_constraint c
   where c.conrelid = 'public.feed_sources'::regclass and c.conname = 'feed_sources_kind';
  if v_def is null or v_def not like '%jsonld%' or v_def not like '%ticketmaster%'
     or v_def not like '%seatgeek%' or v_def not like '%socrata%' or v_def not like '%ics%' or v_def not like '%rss%' then
    raise exception 'FAIL feed_sources_kind does not allow every collector kind';
  end if;
  if (select count(*) from public.feed_sources where slug in ('gsu-localist', 'gsu-pin')) <> 2 then
    raise exception 'FAIL GSU feed sources missing';
  end if;
  if exists (select 1 from public.feed_sources
              where slug in ('gsu-localist', 'gsu-pin') and (not partner or enabled)) then
    raise exception 'FAIL GSU feed sources are not partner = true and disabled';
  end if;
  if exists (select 1 from public.feed_sources where partner and slug not in ('gsu-localist', 'gsu-pin')) then
    raise exception 'FAIL a non-GSU source is marked partner';
  end if;
  if has_table_privilege('authenticated', 'public.collector_regions', 'insert')
     or has_table_privilege('authenticated', 'public.collector_regions', 'update')
     or has_table_privilege('authenticated', 'public.collector_regions', 'delete')
     or has_table_privilege('anon', 'public.collector_regions', 'select')
     or has_table_privilege('authenticated', 'public.feed_sources', 'insert')
     or has_table_privilege('authenticated', 'public.feed_sources', 'update')
     or has_table_privilege('authenticated', 'public.feed_sources', 'delete') then
    raise exception 'FAIL a client role can write a collector table';
  end if;
  if has_column_privilege('authenticated', 'public.profile_private', 'home_point', 'update')
     or has_column_privilege('authenticated', 'public.profile_private', 'home_label', 'update') then
    raise exception 'FAIL clients can update the home point directly';
  end if;
  if has_function_privilege('authenticated',
       'public.collector_note_home_point(extensions.geography, text, extensions.geography)', 'execute') then
    raise exception 'FAIL clients can call collector_note_home_point';
  end if;
  if not exists (select 1 from information_schema.tables
                  where table_schema = 'public' and table_name = 'area_waitlist') then
    raise exception 'FAIL area_waitlist was dropped';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- London user 1: onboarding saves a point
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.l1'), 'role', 'authenticated')::text, true);

do $$
declare
  v_pp public.profile_private;
begin
  perform public.complete_onboarding(
    p_handle     => 'la1_' || substr(replace(current_setting('test.l1'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1994-04-04',
    p_hub_ids    => array[current_setting('test.hub_a')::uuid],
    p_lat        => 51.5074,
    p_lng        => -0.1278,
    p_label      => 'London');
  select * into v_pp from public.profile_private where user_id = auth.uid();
  if v_pp.home_point is null then
    raise exception 'FAIL onboarding with a point saved no home_point';
  end if;
  if extensions.ST_Y(v_pp.home_point::extensions.geometry) <> 51.51
     or extensions.ST_X(v_pp.home_point::extensions.geometry) <> -0.13 then
    raise exception 'FAIL home_point is not rounded to 0.01 degree';
  end if;
  if v_pp.home_label is distinct from 'London' or v_pp.home_set_at is null then
    raise exception 'FAIL home_label or home_set_at not saved';
  end if;
  if v_pp.home_area_id is not null then
    raise exception 'FAIL a point home kept a home area';
  end if;

  -- Validation
  begin
    perform public.set_home_location(91, 0, null, null);
    raise exception 'FAIL latitude 91 accepted';
  exception when check_violation then
    if sqlerrm <> 'invalid_coordinates' then raise exception 'FAIL latitude 91 gave %', sqlerrm; end if;
  end;
  begin
    perform public.set_home_location(0, 181, null, null);
    raise exception 'FAIL longitude 181 accepted';
  exception when check_violation then
    if sqlerrm <> 'invalid_coordinates' then raise exception 'FAIL longitude 181 gave %', sqlerrm; end if;
  end;
  begin
    perform public.set_home_location(51.5, -0.1, repeat('x', 121), null);
    raise exception 'FAIL a 121-character label accepted';
  exception when check_violation then
    if sqlerrm <> 'label_too_long' then raise exception 'FAIL long label gave %', sqlerrm; end if;
  end;
  begin
    perform public.set_home_location(51.5, -0.1, null, 0::smallint);
    raise exception 'FAIL radius 0 accepted';
  exception when check_violation then
    if sqlerrm <> 'radius_out_of_range' then raise exception 'FAIL radius 0 gave %', sqlerrm; end if;
  end;
  -- Direct writes are refused.
  begin
    update public.profile_private set home_label = 'x' where user_id = auth.uid();
    raise exception 'FAIL direct update of home_label allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

do $$
declare
  v_ids uuid[];
begin
  select coalesce(array_agg(f.id), '{}') into v_ids
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days') f;
  if not current_setting('test.e_lon_near')::uuid = any (v_ids) then
    raise exception 'FAIL London user does not see the public event 3 km away';
  end if;
  if current_setting('test.e_lon_far')::uuid = any (v_ids) then
    raise exception 'FAIL London user sees the public event 40 km away';
  end if;
  if current_setting('test.e_atl_near')::uuid = any (v_ids) then
    raise exception 'FAIL London user sees an Atlanta event';
  end if;
  -- A device point still wins over the saved home.
  select coalesce(array_agg(f.id), '{}') into v_ids
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days', 33.749, -84.388) f;
  if not current_setting('test.e_atl_near')::uuid = any (v_ids)
     or current_setting('test.e_lon_near')::uuid = any (v_ids) then
    raise exception 'FAIL a device point does not override the home point';
  end if;
  -- Non-moderators read no collector rows.
  if exists (select 1 from public.collector_regions) then
    raise exception 'FAIL a non-moderator can read collector_regions';
  end if;
end $$;
reset role;

do $$
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_before')::bigint + 1 then
    raise exception 'FAIL saving a London home did not add exactly one collector region';
  end if;
  if (select count(*) from public.collector_regions r
       where extensions.ST_DWithin(r.point,
               extensions.ST_SetSRID(extensions.ST_MakePoint(-0.13, 51.51), 4326)::extensions.geography,
               r.radius_km * 1000.0)) <> 1 then
    raise exception 'FAIL the new region does not cover London';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- London user 2: onboards without a location, then saves one nearby
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.l2'), 'role', 'authenticated')::text, true);

do $$
declare
  v_pp  public.profile_private;
  v_res jsonb;
  v_ids uuid[];
begin
  perform public.complete_onboarding(
    'la2_' || substr(replace(current_setting('test.l2'), '-', ''), 1, 12),
    'Tester', date '1990-01-01', array[current_setting('test.hub_a')::uuid]);

  -- Another user's home point is not readable.
  if exists (select 1 from public.profile_private where user_id = current_setting('test.l1')::uuid) then
    raise exception 'FAIL another user''s profile_private (home_point) is readable';
  end if;
  if exists (select 1 from public.profile_private where user_id <> auth.uid()) then
    raise exception 'FAIL profile_private rows of other users are readable';
  end if;

  v_res := public.set_home_location(51.52, -0.10, '  Islington,   London ', null);
  select * into v_pp from public.profile_private where user_id = auth.uid();
  if v_pp.home_area_id is not null then
    raise exception 'FAIL set_home_location kept the home area';
  end if;
  if v_pp.home_label is distinct from 'Islington, London' then
    raise exception 'FAIL label not trimmed';
  end if;
  if (v_res ->> 'feed_radius_km')::integer <> v_pp.feed_radius_km then
    raise exception 'FAIL set_home_location returned a different radius';
  end if;

  select coalesce(array_agg(f.id), '{}') into v_ids
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days') f;
  if not current_setting('test.e_lon_near')::uuid = any (v_ids) then
    raise exception 'FAIL second London user does not see the nearby London event';
  end if;

  begin
    insert into public.collector_regions (point) values
      (extensions.ST_SetSRID(extensions.ST_MakePoint(0, 0), 4326)::extensions.geography);
    raise exception 'FAIL a client inserted a collector region';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

do $$
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_before')::bigint + 1 then
    raise exception 'FAIL a second nearby user added another collector region';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- No location: falls back to Atlanta
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.none'), 'role', 'authenticated')::text, true);

do $$
declare
  v_pp  public.profile_private;
  v_ids uuid[];
begin
  perform public.complete_onboarding(
    'la3_' || substr(replace(current_setting('test.none'), '-', ''), 1, 12),
    'Tester', date '1992-02-02', array[current_setting('test.hub_a')::uuid]);
  select * into v_pp from public.profile_private where user_id = auth.uid();
  if v_pp.home_area_id is distinct from (select id from public.areas where slug = 'atlanta') then
    raise exception 'FAIL no-location onboarding did not fall back to the Atlanta area';
  end if;
  if v_pp.home_point is not null then
    raise exception 'FAIL the Atlanta fallback saved a home point';
  end if;
  select coalesce(array_agg(f.id), '{}') into v_ids
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days') f;
  if not current_setting('test.e_atl_near')::uuid = any (v_ids)
     or current_setting('test.e_lon_near')::uuid = any (v_ids) then
    raise exception 'FAIL no-location user does not get the Atlanta feed';
  end if;
end $$;
reset role;

-- Neither a point nor an area: the Atlanta constant.
update public.profile_private set home_area_id = null, home_point = null
 where user_id = current_setting('test.none')::uuid;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.none'), 'role', 'authenticated')::text, true);
do $$
declare v_ids uuid[];
begin
  select coalesce(array_agg(f.id), '{}') into v_ids
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days') f;
  if not current_setting('test.e_atl_near')::uuid = any (v_ids) then
    raise exception 'FAIL a user with no home falls back to something other than Atlanta';
  end if;

  -- set_home_area still works and fills the home point from the area centre.
  perform public.set_home_area((select id from public.areas where slug = 'atlanta'));
  if not exists (select 1 from public.profile_private pp join public.areas a on a.id = pp.home_area_id
                  where pp.user_id = auth.uid() and a.slug = 'atlanta' and pp.home_point is not null
                    and extensions.ST_DWithin(pp.home_point, a.center, 1000)) then
    raise exception 'FAIL set_home_area did not fill home_point from the area centre';
  end if;
end $$;
reset role;

do $$
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_before')::bigint + 1 then
    raise exception 'FAIL an Atlanta home added a collector region (Atlanta is seeded)';
  end if;
end $$;

select 'location_anywhere: all assertions passed' as result;

rollback;
