-- ============================================================================
-- Staging check for migration 20261221000100_feed_distance.sql (migration 57):
-- feed_events_v2 is distance-based for every member (D-040, PLAN.md 4.3).
-- A hub member far away no longer sees a plan from another city; plans with
-- no point stand at the chapter area or the host's home area, and are left
-- out when there is none.
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
  v_tag     text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_host    uuid := gen_random_uuid();   -- lives in the Atlanta area
  v_nohome  uuid := gen_random_uuid();   -- host with no home at all
  v_lhost   uuid := gen_random_uuid();   -- host with a London home point only
  v_london  uuid := gen_random_uuid();   -- hub member in London
  v_atl     uuid := gen_random_uuid();   -- hub member in Atlanta
  v_atl2    uuid := gen_random_uuid();   -- Atlanta member outside the hub
  v_hub     uuid;
  v_area    uuid := (select id from public.areas where slug = 'atlanta');
  v_lon_pt  extensions.geography :=
    extensions.ST_SetSRID(extensions.ST_MakePoint(-0.13, 51.53), 4326)::extensions.geography;
  v_t       timestamptz := now() + interval '2 hours';
  v_id      uuid;
begin
  if v_area is null then raise exception 'setup: no atlanta area'; end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'fdist-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_host, v_nohome, v_lhost, v_london, v_atl, v_atl2]) as u;
  update public.profile_private set birth_date = date '1991-03-03'
   where user_id in (v_host, v_nohome, v_lhost, v_london, v_atl, v_atl2);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_host, v_nohome, v_lhost, v_london, v_atl, v_atl2);

  update public.profile_private set home_area_id = v_area, home_point = null, feed_radius_km = 10
   where user_id in (v_host, v_atl, v_atl2);
  update public.profile_private set home_area_id = null, home_point = null where user_id = v_nohome;
  update public.profile_private set home_area_id = null, home_point = v_lon_pt, feed_radius_km = 10
   where user_id in (v_lhost, v_london);

  select h.id into v_hub
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
   order by h.slug
   limit 1;
  if v_hub is null then raise exception 'setup: no general hub'; end if;
  insert into public.hub_members (user_id, hub_id)
  values (v_london, v_hub), (v_atl, v_hub), (v_host, v_hub), (v_nohome, v_hub), (v_lhost, v_hub)
  on conflict do nothing;

  -- A plan with a point 3 km north of the Atlanta centre.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, v_host, 'Feed distance Atlanta point', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.7760), 4326)::extensions.geography)
  returning id into v_id;
  perform set_config('test.e_pt', v_id::text, true);

  -- A plan with only a described location, by the Atlanta host.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point, location_hint)
  values (v_hub, v_host, 'Feed distance Atlanta described', v_t, v_t + interval '2 hours', null, 'The park')
  returning id into v_id;
  perform set_config('test.e_desc', v_id::text, true);

  -- A plan with no point by a host with no home: nowhere to place it.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, v_nohome, 'Feed distance no place', v_t, v_t + interval '2 hours', null)
  returning id into v_id;
  perform set_config('test.e_nohome', v_id::text, true);

  -- A plan with no point by a host whose home is a London point.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, v_lhost, 'Feed distance London described', v_t, v_t + interval '2 hours', null)
  returning id into v_id;
  perform set_config('test.e_lon', v_id::text, true);

  perform set_config('test.london', v_london::text, true);
  perform set_config('test.atl', v_atl::text, true);
  perform set_config('test.atl2', v_atl2::text, true);
  perform set_config('test.nohome', v_nohome::text, true);
end $$;

-- Static checks (as the owner)
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 53] then
    raise exception 'FAIL schema_version is older than 2.53';
  end if;
  if to_regprocedure('public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text)') is null then
    raise exception 'FAIL feed_events_v2 signature changed';
  end if;
  if (select prosecdef from pg_proc where oid = 'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text)'::regprocedure) then
    raise exception 'FAIL feed_events_v2 became security definer';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.feed_event_area(uuid)'::regprocedure)
     or not exists (select 1 from pg_proc where oid = 'public.feed_event_area(uuid)'::regprocedure
                       and proconfig @> array['search_path=""']) then
    raise exception 'FAIL feed_event_area is not security definer with an empty search_path';
  end if;
  if has_function_privilege('anon', 'public.feed_event_area(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.feed_event_area(uuid)', 'execute') then
    raise exception 'FAIL feed_event_area grants';
  end if;
end $$;

-- A helper (created inside this transaction and rolled back with it): the test
-- events the caller's feed returns, with their bands.
create function public.fdist_test_feed(p_radius integer default null,
                                       p_lat double precision default null,
                                       p_lng double precision default null)
returns table (id uuid, band text, matched text) language sql as $$
  select f.id, f.distance_band, f.matched_by
    from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days',
                               p_lat, p_lng, p_radius, p_limit => 200) f
   where f.id in (current_setting('test.e_pt')::uuid, current_setting('test.e_desc')::uuid,
                  current_setting('test.e_nohome')::uuid, current_setting('test.e_lon')::uuid);
$$;
grant execute on function public.fdist_test_feed(integer, double precision, double precision) to authenticated;

-- ---------------------------------------------------------------------------
-- The London hub member: none of the Atlanta plans, even at 50 km
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.london'), 'role', 'authenticated')::text, true);

do $$
declare r integer;
begin
  for r in select unnest(array[10, 25, 50]) loop
    if exists (select 1 from public.fdist_test_feed(r) f
                where f.id in (current_setting('test.e_pt')::uuid, current_setting('test.e_desc')::uuid)) then
      raise exception 'FAIL London hub member sees an Atlanta plan at % km', r;
    end if;
    if exists (select 1 from public.fdist_test_feed(r) f where f.id = current_setting('test.e_nohome')::uuid) then
      raise exception 'FAIL London hub member sees a plan with no place at % km', r;
    end if;
  end loop;
  -- The London host's described plan stands at the host's home (to 0.1 degree): nearby.
  if not exists (select 1 from public.fdist_test_feed(25) f
                  where f.id = current_setting('test.e_lon')::uuid and f.band = 'approximate') then
    raise exception 'FAIL London hub member does not see the nearby described London plan';
  end if;
  -- The area is coarse (0.1 degree), never the host's saved point.
  if (select round(extensions.ST_X(a::extensions.geometry)::numeric, 6) <> -0.1
          or round(extensions.ST_Y(a::extensions.geometry)::numeric, 6) <> 51.5
        from public.feed_event_area(current_setting('test.e_lon')::uuid) a) then
    raise exception 'FAIL feed_event_area does not round the host home point to 0.1 degree';
  end if;
  -- A device point in Atlanta brings the Atlanta plans in.
  if (select count(*) from public.fdist_test_feed(10, 33.749, -84.388) f
       where f.id in (current_setting('test.e_pt')::uuid, current_setting('test.e_desc')::uuid)) <> 2 then
    raise exception 'FAIL an Atlanta device point does not bring the Atlanta plans in';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The Atlanta hub member: the nearby plans, not the London one or the unplaced one
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.atl'), 'role', 'authenticated')::text, true);

do $$
begin
  if not exists (select 1 from public.fdist_test_feed() f
                  where f.id = current_setting('test.e_pt')::uuid and f.band = '1-5 mi' and f.matched = 'hub') then
    raise exception 'FAIL Atlanta hub member does not see the nearby plan with a point';
  end if;
  if not exists (select 1 from public.fdist_test_feed() f
                  where f.id = current_setting('test.e_desc')::uuid and f.band = 'approximate' and f.matched = 'hub') then
    raise exception 'FAIL Atlanta hub member does not see the nearby described plan';
  end if;
  if exists (select 1 from public.fdist_test_feed(50) f
              where f.id in (current_setting('test.e_lon')::uuid, current_setting('test.e_nohome')::uuid)) then
    raise exception 'FAIL Atlanta hub member sees a London or unplaced plan';
  end if;
  -- A device point in London drops the Atlanta plans.
  if exists (select 1 from public.fdist_test_feed(50, 51.53, -0.13) f
              where f.id in (current_setting('test.e_pt')::uuid, current_setting('test.e_desc')::uuid)) then
    raise exception 'FAIL a London device point still shows the Atlanta plans';
  end if;
  if public.feed_event_area(current_setting('test.e_pt')::uuid) is not null then
    raise exception 'FAIL feed_event_area places a plan that has a point';
  end if;
  if public.feed_event_area(current_setting('test.e_nohome')::uuid) is not null then
    raise exception 'FAIL feed_event_area places a plan whose host has no home';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- An Atlanta member outside the hub: the public nearby plans still show
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.atl2'), 'role', 'authenticated')::text, true);

do $$
begin
  if (select count(*) from public.fdist_test_feed() f
       where f.matched = 'nearby'
         and f.id in (current_setting('test.e_pt')::uuid, current_setting('test.e_desc')::uuid)) <> 2 then
    raise exception 'FAIL Atlanta member outside the hub does not see the nearby public plans';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The host with no home still sees their own plan
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.nohome'), 'role', 'authenticated')::text, true);

do $$
begin
  if not exists (select 1 from public.fdist_test_feed() f where f.id = current_setting('test.e_nohome')::uuid) then
    raise exception 'FAIL the host does not see their own plan with no place';
  end if;
end $$;

reset role;

select 'feed_distance: all assertions passed' as result;

rollback;
