-- ============================================================================
-- Staging check for migration 20261120000100_location_region_limits.sql.
-- One transaction: sets up throwaway users, asserts with DO blocks that raise
-- on failure, then rolls everything back. Prints pass/fail only.
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_a   uuid := gen_random_uuid();   -- Nairobi in onboarding, then Lima, then Nairobi again
  v_b   uuid := gen_random_uuid();   -- onboards without a location, then saves Lima
  v_c   uuid := gen_random_uuid();   -- saves Reykjavik after the daily cap is reached
  v_hub uuid;
  v_p   extensions.geography;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'locrl-' || substr(u::text, 1, 8) || '@example.com', now(), now()
    from unnest(array[v_a, v_b, v_c]) as u;

  select id into v_hub from public.hubs
   where is_active and min_age = 18 and scope = 'general' order by slug limit 1;
  if v_hub is null then
    raise exception 'setup: need a general hub on staging';
  end if;

  foreach v_p in array array[
    extensions.ST_SetSRID(extensions.ST_MakePoint(36.82, -1.29), 4326)::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(-77.04, -12.05), 4326)::extensions.geography,
    extensions.ST_SetSRID(extensions.ST_MakePoint(-21.94, 64.15), 4326)::extensions.geography]
  loop
    if exists (select 1 from public.collector_regions r
                where extensions.ST_DWithin(r.point, v_p, r.radius_km * 1000.0)) then
      raise exception 'setup: a collector region already covers a test city on staging';
    end if;
  end loop;
  perform set_config('test.regions_before', (select count(*) from public.collector_regions)::text, true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.c', v_c::text, true);
  perform set_config('test.hub', v_hub::text, true);
end $$;

-- Static checks (as the owner)
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.21' then
    raise exception 'FAIL schema_version is not 2.21';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'profile_private'
         and column_name in ('home_region_noted_at', 'home_count_noted_at')) <> 2 then
    raise exception 'FAIL profile_private stamp columns missing';
  end if;
  if has_column_privilege('authenticated', 'public.profile_private', 'home_region_noted_at', 'update')
     or has_column_privilege('authenticated', 'public.profile_private', 'home_count_noted_at', 'update') then
    raise exception 'FAIL clients can update the region stamps';
  end if;
  if has_function_privilege('authenticated',
       'public.collector_note_home_point(extensions.geography, text, extensions.geography)', 'execute') then
    raise exception 'FAIL clients can call collector_note_home_point';
  end if;
  if exists (select 1 from public.collector_regions where first_user_at is not null and label is not null) then
    raise exception 'FAIL a user-added region keeps a label';
  end if;
  if exists (select 1 from public.collector_regions
              where first_user_at <> date_trunc('day', first_user_at, 'UTC')
                 or created_at <> date_trunc('day', created_at, 'UTC')
                 or updated_at <> date_trunc('day', updated_at, 'UTC')) then
    raise exception 'FAIL a collector region time is not rounded to the day';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'complete_onboarding') <> 1 then
    raise exception 'FAIL complete_onboarding has more than one overload';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- User A: Nairobi in onboarding adds a region; Lima the same day does not;
-- moving back to Nairobi does not bump the count again.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);

do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'lrl_' || substr(replace(current_setting('test.a'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1993-03-03',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => -1.2921,
    p_lng        => 36.8219,
    p_label      => '12 Elm St, my flat');
  perform public.set_home_location(-12.0464, -77.0428, 'Lima flat 4');
  perform public.set_home_location(-1.2921, 36.8219, 'back home');
  perform public.set_home_location(-12.0464, -77.0428, 'Lima again');
end $$;
reset role;

do $$
declare
  v_r public.collector_regions;
  v_nairobi extensions.geography :=
    extensions.ST_SetSRID(extensions.ST_MakePoint(36.82, -1.29), 4326)::extensions.geography;
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_before')::bigint + 1 then
    raise exception 'FAIL one person added more than one region in a day';
  end if;
  select * into v_r from public.collector_regions r
   where extensions.ST_DWithin(r.point, v_nairobi, r.radius_km * 1000.0);
  if not found then
    raise exception 'FAIL the first save did not add a region';
  end if;
  if v_r.label is not null then
    raise exception 'FAIL a new region stores the person''s label';
  end if;
  if v_r.first_user_at <> date_trunc('day', now(), 'UTC')
     or v_r.created_at <> date_trunc('day', now(), 'UTC')
     or v_r.updated_at <> date_trunc('day', v_r.updated_at, 'UTC') then
    raise exception 'FAIL a new region keeps an exact time';
  end if;
  if v_r.home_count <> 1 then
    raise exception 'FAIL moving back and forth grew home_count';
  end if;
  if exists (select 1 from public.collector_regions r
              where extensions.ST_DWithin(r.point,
                      extensions.ST_SetSRID(extensions.ST_MakePoint(-77.04, -12.05), 4326)::extensions.geography,
                      r.radius_km * 1000.0)) then
    raise exception 'FAIL a second region was added the same day';
  end if;
  if (select home_region_noted_at from public.profile_private where user_id = current_setting('test.a')::uuid) is null then
    raise exception 'FAIL home_region_noted_at not stamped';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- User B: onboards without a location, then saves Lima: a region is added
-- (the limit is per person).
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);

do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'lrl_' || substr(replace(current_setting('test.b'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1990-01-01',
    p_hub_ids    => array[current_setting('test.hub')::uuid]);
  perform public.set_home_location(-12.0464, -77.0428, 'Lima');
end $$;
reset role;

do $$
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_before')::bigint + 2 then
    raise exception 'FAIL a second person could not add a region';
  end if;
  if exists (select 1 from public.collector_regions where first_user_at is not null and label is not null) then
    raise exception 'FAIL a user-added region stores a label';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Daily cap: fill today's quota with ocean rows, then user C adds nothing.
-- ---------------------------------------------------------------------------
do $$
declare
  v_n integer;
begin
  select count(*) into v_n from public.collector_regions
   where first_user_at is not null and created_at >= date_trunc('day', now(), 'UTC');
  insert into public.collector_regions (point, radius_km, first_user_at, priority, home_count)
  select extensions.ST_SetSRID(extensions.ST_MakePoint(-150.0, -75.0 + i * 0.5), 4326)::extensions.geography,
         25, now(), 10, 1
    from generate_series(1, greatest(0, 100 - v_n)) as i;
  perform set_config('test.regions_capped', (select count(*) from public.collector_regions)::text, true);
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);

do $$
begin
  perform public.complete_onboarding(
    p_handle     => 'lrl_' || substr(replace(current_setting('test.c'), '-', ''), 1, 12),
    p_first_name => 'Tester',
    p_birth_date => date '1991-02-02',
    p_hub_ids    => array[current_setting('test.hub')::uuid],
    p_lat        => 64.1466,
    p_lng        => -21.9426,
    p_label      => 'Reykjavik');
  if (select home_point from public.profile_private where user_id = auth.uid()) is null then
    raise exception 'FAIL the home point was not saved when the cap was reached';
  end if;
end $$;
reset role;

do $$
begin
  if (select count(*) from public.collector_regions) <> current_setting('test.regions_capped')::bigint then
    raise exception 'FAIL a region was added past the daily cap';
  end if;
end $$;

select 'location_region_limits: all assertions passed' as result;

rollback;
