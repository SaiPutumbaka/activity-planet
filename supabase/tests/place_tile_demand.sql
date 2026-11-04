-- ============================================================================
-- Staging check for migration 20261204000100_place_tile_demand.sql (D-042
-- slice 1). One transaction: sets up throwaway users and tiles, asserts with
-- DO blocks that raise on failure, then rolls everything back. Prints
-- pass/fail only (no user rows, no tile ids with demand).
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_a   uuid := gen_random_uuid();   -- Leipzig tile centre, then its NE corner, then Lyon
  v_b   uuid := gen_random_uuid();   -- Leipzig tile centre
  v_c   uuid := gen_random_uuid();   -- Porto (a retired tile)
  v_d   uuid := gen_random_uuid();   -- Krakow (an idle tile with no OSM run)
  v_e   uuid := gen_random_uuid();   -- Reykjavik after both daily caps are reached
  v_hub uuid;
  t1    integer := public.place_tile_id(51.25, 12.25);
  v_ids integer[];
  v_p   extensions.geography;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'ptd-' || substr(u::text, 1, 8) || '@example.com', now(), now()
    from unnest(array[v_a, v_b, v_c, v_d, v_e]) as u;

  select id into v_hub from public.hubs
   where is_active and min_age = 18 and scope = 'general' order by slug limit 1;
  if v_hub is null then
    raise exception 'setup: need a general hub on staging';
  end if;

  v_ids := array[t1, t1 - 1, t1 + 1, t1 - 720, t1 + 720, t1 - 721, t1 - 719, t1 + 719, t1 + 721,
                 public.place_tile_id(45.76, 4.84), public.place_tile_id(41.25, -8.75),
                 public.place_tile_id(50.25, 19.75), public.place_tile_id(64.15, -21.94)];
  if exists (select 1 from public.place_tiles where id = any (v_ids)) then
    raise exception 'setup: a test tile already exists on staging';
  end if;
  foreach v_p in array array[
    extensions.ST_SetSRID(extensions.ST_MakePoint(-21.94, 64.15), 4326)::extensions.geography]
  loop
    if exists (select 1 from public.collector_regions r
                where extensions.ST_DWithin(r.point, v_p, r.radius_km * 1000.0)) then
      raise exception 'setup: a collector region already covers Reykjavik on staging';
    end if;
  end loop;

  -- Porto: retired after an OSM run; Krakow: idle with no OSM run.
  insert into public.place_tiles (id, status, demand, osm_run_at)
  values (public.place_tile_id(41.25, -8.75), 'retired', 3, now() - interval '200 days');
  insert into public.place_tiles (id, status, demand, idle_since)
  values (public.place_tile_id(50.25, 19.75), 'idle', 2, now() - interval '2 days');

  perform set_config('test.t1', t1::text, true);
  perform set_config('test.budget_before',
    coalesce((select used from public.collector_budget
               where day = (now() at time zone 'UTC')::date and source = 'place_tiles_new'), 0)::text, true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.c', v_c::text, true);
  perform set_config('test.d', v_d::text, true);
  perform set_config('test.e', v_e::text, true);
  perform set_config('test.hub', v_hub::text, true);
end $$;

-- Static checks (as the owner)
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.36' then
    raise exception 'FAIL schema_version is not 2.36';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profile_private'
                    and column_name = 'home_tile_noted_at') then
    raise exception 'FAIL profile_private.home_tile_noted_at missing';
  end if;
  if has_column_privilege('authenticated', 'public.profile_private', 'home_tile_noted_at', 'update') then
    raise exception 'FAIL clients can update home_tile_noted_at';
  end if;
  if has_function_privilege('authenticated',
       'public.place_tile_note_home(extensions.geography, extensions.geography)', 'execute')
     or has_function_privilege('anon',
       'public.place_tile_note_home(extensions.geography, extensions.geography)', 'execute')
     or has_function_privilege('service_role',
       'public.place_tile_note_home(extensions.geography, extensions.geography)', 'execute') then
    raise exception 'FAIL place_tile_note_home is callable from outside';
  end if;
  if has_function_privilege('authenticated', 'public.place_tiles_note_member_homes()', 'execute')
     or has_function_privilege('anon', 'public.place_tiles_note_member_homes()', 'execute') then
    raise exception 'FAIL clients can call place_tiles_note_member_homes';
  end if;
  if has_function_privilege('authenticated',
       'public.collector_note_home_point(extensions.geography, text, extensions.geography)', 'execute') then
    raise exception 'FAIL clients can call collector_note_home_point';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name in ('place_tiles', 'collector_budget', 'collector_regions')
                and data_type = 'uuid' and column_name <> 'id') then
    raise exception 'FAIL a demand table has a uuid column (user id)';
  end if;
  if exists (select 1 from public.place_tiles
              where created_at <> date_trunc('day', created_at, 'UTC')
                 or updated_at <> date_trunc('day', updated_at, 'UTC')) then
    raise exception 'FAIL a place tile time is not rounded to the day';
  end if;
  if exists (select 1 from pg_trigger where tgrelid = 'public.place_tiles'::regclass
              and tgname = 'place_tiles_set_updated_at') then
    raise exception 'FAIL the exact-time updated_at trigger is still on place_tiles';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'note-member-home-tiles' and schedule = '13 4 * * *') then
    raise exception 'FAIL note-member-home-tiles is not scheduled';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- A: onboarding at the Leipzig tile centre, then the NE corner of the same
-- tile, then Lyon (within 24 hours).
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);

do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'ptd_' || substr(replace(current_setting('test.a'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1993-03-03',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => 51.25,
    p_lng        => 12.25,
    p_label      => 'Leipzig');
  if (select count(*) from public.place_tiles) <> 0 then
    raise exception 'FAIL a member can read place_tiles';
  end if;
end $$;
reset role;

do $$
declare
  t1 integer := current_setting('test.t1')::integer;
  v  public.place_tiles;
begin
  select * into v from public.place_tiles where id = t1;
  if not found then
    raise exception 'FAIL onboarding with a home did not add its tile';
  end if;
  if v.status <> 'wanted' or v.demand <> 1 then
    raise exception 'FAIL a new home tile is not wanted with demand 1';
  end if;
  if v.last_member_at <> date_trunc('day', now(), 'UTC')
     or v.created_at <> date_trunc('day', now(), 'UTC')
     or v.updated_at <> date_trunc('day', v.updated_at, 'UTC') then
    raise exception 'FAIL a new tile keeps an exact time';
  end if;
  if exists (select 1 from public.place_tiles
              where id in (t1 - 1, t1 + 1, t1 - 720, t1 + 720, t1 - 721, t1 - 719, t1 + 719, t1 + 721)) then
    raise exception 'FAIL a home 17 km from every edge added a neighbour';
  end if;
  if (select home_tile_noted_at from public.profile_private where user_id = current_setting('test.a')::uuid) is null then
    raise exception 'FAIL home_tile_noted_at not stamped';
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.set_home_location(51.49, 12.49, 'Leipzig north-east');
end $$;
reset role;

do $$
declare
  t1 integer := current_setting('test.t1')::integer;
begin
  if (select demand from public.place_tiles where id = t1) <> 1 then
    raise exception 'FAIL a move inside the same tile counted again';
  end if;
  if (select count(*) from public.place_tiles
       where id in (t1 + 1, t1 + 720, t1 + 721) and status = 'wanted' and demand = 0) <> 3 then
    raise exception 'FAIL a home within 10 km of the north and east edges did not add those neighbours with demand 0';
  end if;
  if exists (select 1 from public.place_tiles where id in (t1 - 1, t1 - 720, t1 - 721, t1 - 719, t1 + 719)) then
    raise exception 'FAIL a neighbour more than 10 km away was added';
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.set_home_location(45.76, 4.84, 'Lyon');
end $$;
reset role;

do $$
begin
  if (select demand from public.place_tiles where id = public.place_tile_id(45.76, 4.84) and status = 'wanted') <> 0 then
    raise exception 'FAIL a second move within 24 hours did not add the tile with demand 0';
  end if;
  if (select demand from public.place_tiles where id = current_setting('test.t1')::integer) <> 1 then
    raise exception 'FAIL leaving a tile changed its demand';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- B: a second member in the Leipzig tile bumps its demand.
-- C: Porto's retired tile becomes wanted. D: Krakow's idle tile wakes.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'ptd_' || substr(replace(current_setting('test.b'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1990-01-01',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => 51.25,
    p_lng        => 12.25);
end $$;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'ptd_' || substr(replace(current_setting('test.c'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1991-01-01',
    p_hub_ids    => array[current_setting('test.hub')::uuid]);
  perform public.set_home_location(41.25, -8.75, 'Porto');
end $$;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.d'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'ptd_' || substr(replace(current_setting('test.d'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1992-01-01',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => 50.25,
    p_lng        => 19.75);
end $$;
reset role;

do $$
declare
  v public.place_tiles;
begin
  if (select demand from public.place_tiles where id = current_setting('test.t1')::integer) <> 2 then
    raise exception 'FAIL a second member did not bump the tile demand';
  end if;
  select * into v from public.place_tiles where id = public.place_tile_id(41.25, -8.75);
  if v.status <> 'wanted' or v.demand <> 4 or v.idle_since is not null
     or v.last_member_at <> date_trunc('day', now(), 'UTC') then
    raise exception 'FAIL a retired home tile did not become wanted with demand + 1';
  end if;
  select * into v from public.place_tiles where id = public.place_tile_id(50.25, 19.75);
  if v.status <> 'filling' or v.demand <> 3 or v.idle_since is not null then
    raise exception 'FAIL an idle home tile with no OSM run did not wake as filling';
  end if;
  if (select used from public.collector_budget
       where day = (now() at time zone 'UTC')::date and source = 'place_tiles_new')
     <> current_setting('test.budget_before')::integer + 5 then
    raise exception 'FAIL the daily new-tile count is not the 5 rows added';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Daily caps: 50 new tiles and 10 new event regions; E then adds neither,
-- but the home is saved. The nightly job adds the tile once there is room.
-- ---------------------------------------------------------------------------
do $$
declare
  v_n integer;
begin
  insert into public.collector_budget (day, source, used)
  values ((now() at time zone 'UTC')::date, 'place_tiles_new', 50)
  on conflict (day, source) do update set used = 50;

  select count(*) into v_n from public.collector_regions
   where first_user_at is not null and created_at >= date_trunc('day', now(), 'UTC');
  if v_n > 10 then
    raise exception 'FAIL more than 10 user regions were added today';
  end if;
  insert into public.collector_regions (point, radius_km, first_user_at, priority, home_count)
  select extensions.ST_SetSRID(extensions.ST_MakePoint(-150.0, -75.0 + i * 0.5), 4326)::extensions.geography,
         25, now(), 10, 1
    from generate_series(1, greatest(0, 10 - v_n)) as i;
  perform set_config('test.regions_capped', (select count(*) from public.collector_regions)::text, true);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.e'), 'role', 'authenticated')::text, true);
do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'ptd_' || substr(replace(current_setting('test.e'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1989-01-01',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => 64.15,
    p_lng        => -21.94,
    p_label      => 'Reykjavik');
  if (select home_point from public.profile_private where user_id = auth.uid()) is null then
    raise exception 'FAIL the home point was not saved when the caps were reached';
  end if;
end $$;
reset role;

do $$
declare
  v_r jsonb;
begin
  if exists (select 1 from public.place_tiles where id = public.place_tile_id(64.15, -21.94)) then
    raise exception 'FAIL a tile was added past the 50-a-day cap';
  end if;
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_capped')::bigint then
    raise exception 'FAIL a region was added past the 10-a-day cap';
  end if;
  if (select home_tile_noted_at from public.profile_private where user_id = current_setting('test.e')::uuid) is not null then
    raise exception 'FAIL a capped home was stamped as counted';
  end if;

  update public.profile_private set last_seen_at = now() where user_id = current_setting('test.e')::uuid;
  v_r := public.place_tiles_note_member_homes();
  if (v_r ->> 'added')::integer <> 0 or (v_r ->> 'missing')::integer < 1 then
    raise exception 'FAIL the nightly job ignored the cap or missed the capped home';
  end if;

  update public.collector_budget set used = 0
   where day = (now() at time zone 'UTC')::date and source = 'place_tiles_new';
  v_r := public.place_tiles_note_member_homes();
  if (v_r ->> 'added')::integer < 1 then
    raise exception 'FAIL the nightly job did not add the missing tile';
  end if;
  if not exists (select 1 from public.place_tiles
                  where id = public.place_tile_id(64.15, -21.94) and status = 'wanted' and demand >= 1
                    and created_at = date_trunc('day', now(), 'UTC')) then
    raise exception 'FAIL the capped home''s tile was not added wanted by the nightly job';
  end if;
  if (select used from public.collector_budget
       where day = (now() at time zone 'UTC')::date and source = 'place_tiles_new') <> (v_r ->> 'added')::integer then
    raise exception 'FAIL the nightly job did not count its rows in the budget';
  end if;
  v_r := public.place_tiles_note_member_homes();
  if (v_r ->> 'added')::integer <> 0 then
    raise exception 'FAIL the nightly job added a tile twice';
  end if;
end $$;

select 'place_tile_demand: all assertions passed' as result;

rollback;
