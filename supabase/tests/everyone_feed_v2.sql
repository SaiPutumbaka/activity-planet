-- ============================================================================
-- Staging check for migrations 20261111000100_everyone_feed_v2.sql and
-- 20261111000200_feed_v2_review_fixes.sql.
-- One transaction: sets up throwaway users, events, a venue and a chapter,
-- asserts with DO blocks that raise on failure, then rolls everything back.
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_viewer uuid := gen_random_uuid();
  v_host   uuid := gen_random_uuid();
  v_young  uuid := gen_random_uuid();
  v_hub_21 uuid;
  v_hub_a  uuid;
  v_hub_b  uuid;
  v_t      timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_id     uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'feedv2-viewer-' || substr(v_viewer::text, 1, 8) || '@example.com', now(), now()),
         (v_host, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'feedv2-host-' || substr(v_host::text, 1, 8) || '@example.com', now(), now()),
         (v_young, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'feedv2-young-' || substr(v_young::text, 1, 8) || '@example.com', now(), now());

  -- A 20-year-old (under 21, over 18).
  update public.profile_private
     set birth_date = (current_date - interval '20 years 1 month')::date
   where user_id = v_young;

  select id into v_hub_a from public.hubs
   where is_active and min_age = 18 and scope = 'general' order by slug limit 1;
  select id into v_hub_b from public.hubs
   where is_active and min_age = 18 and scope = 'general' and id <> v_hub_a order by slug desc limit 1;
  if v_hub_a is null or v_hub_b is null then
    raise exception 'setup: need two general hubs on staging';
  end if;
  select id into v_hub_21 from public.hubs where is_active and min_age >= 21 order by slug limit 1;
  if v_hub_21 is null then
    raise exception 'setup: need an active 21+ hub on staging';
  end if;

  -- Area chapters: one on a 21+ hub, one on an 18+ hub.
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub_21, (select id from public.areas where slug = 'atlanta'),
          'feedv2-test-21-' || substr(replace(v_young::text, '-', ''), 1, 8), 'Test 21+ area chapter')
  returning id into v_id;
  perform set_config('test.ch_21', v_id::text, true);
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub_a, (select id from public.areas where slug = 'atlanta'),
          'feedv2-test-18-' || substr(replace(v_young::text, '-', ''), 1, 8), 'Test 18+ area chapter')
  returning id into v_id;
  perform set_config('test.ch_18', v_id::text, true);

  -- In the viewer's hub, five days out: a nearby event tomorrow must sort above it.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_a, v_host, 'Feed v2 hub later', v_t + interval '5 days', v_t + interval '5 days 2 hours', null)
  returning id into v_id;
  perform set_config('test.e_hub_later', v_id::text, true);

  -- Public event 3 km north of the Atlanta centre, in a hub the viewer never joins.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point, location_hint)
  values (v_hub_b, v_host, 'Feed v2 near', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.7760), 4326)::extensions.geography, 'Near')
  returning id into v_id;
  perform set_config('test.e_near', v_id::text, true);

  -- Public event about 40 km north: outside the 10 km default radius.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_b, v_host, 'Feed v2 far', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 34.1100), 4326)::extensions.geography)
  returning id into v_id;
  perform set_config('test.e_far', v_id::text, true);

  -- No point at all, in the viewer's hub: only the hub arm can bring it in.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_a, v_host, 'Feed v2 no point', v_t + interval '3 hours', v_t + interval '4 hours', null)
  returning id into v_id;
  perform set_config('test.e_nullpt', v_id::text, true);

  -- No point and not in the viewer's hubs: must not appear.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub_b, v_host, 'Feed v2 no point other hub', v_t, v_t + interval '1 hour', null)
  returning id into v_id;
  perform set_config('test.e_nullpt_other', v_id::text, true);

  -- Imported row, nearby and earliest: still sorts below every human-hosted row.
  insert into public.events (kind, hub_id, host_id, title, starts_at, ends_at, approx_point, external_url, source_name)
  values ('imported', v_hub_b, null, 'Feed v2 imported', v_t - interval '12 hours', v_t - interval '11 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.7500), 4326)::extensions.geography,
          'https://example.com/e/1', 'Test source')
  returning id into v_id;
  perform set_config('test.e_imported', v_id::text, true);

  -- Approved-only event about 15 km out: within radius + 8 km slack.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point, address_visibility)
  values (v_hub_b, v_host, 'Feed v2 approximate', v_t, v_t + interval '2 hours',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-84.3880, 33.8840), 4326)::extensions.geography,
          'approved_only')
  returning id into v_id;
  perform set_config('test.e_approx', v_id::text, true);

  perform set_config('test.viewer', v_viewer::text, true);
  perform set_config('test.young', v_young::text, true);
  perform set_config('test.hub_a', v_hub_a::text, true);
  perform set_config('test.hub_b', v_hub_b::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- Areas are readable logged out
-- ---------------------------------------------------------------------------
set local role anon;
do $$
declare n integer;
begin
  select count(*) into n from public.areas;
  if n < 13 then
    raise exception 'FAIL areas readable as anon: % rows', n;
  end if;
  if not exists (select 1 from public.areas where slug = 'atlanta' and kind = 'city' and parent_id is null) then
    raise exception 'FAIL atlanta area missing';
  end if;
  if exists (select 1 from public.areas where slug <> 'atlanta'
                and parent_id is distinct from (select id from public.areas where slug = 'atlanta')) then
    raise exception 'FAIL neighborhoods not parented to Atlanta';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- As the viewer
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.viewer'), 'role', 'authenticated')::text, true);

do $$
declare
  v_profile public.profiles;
  v_pp      public.profile_private;
  v_atl     public.areas;
begin
  select * into v_atl from public.areas where slug = 'atlanta';
  v_profile := public.complete_onboarding(
    'fv2_' || substr(replace(current_setting('test.viewer'), '-', ''), 1, 12),
    'Tester', date '1995-05-05', array[current_setting('test.hub_a')::uuid], null, null, null);
  select * into v_pp from public.profile_private where user_id = auth.uid();
  if v_pp.home_area_id is distinct from v_atl.id then
    raise exception 'FAIL complete_onboarding with null area did not set Atlanta (got %)', v_pp.home_area_id;
  end if;
  if v_pp.feed_radius_km <> v_atl.default_radius_km then
    raise exception 'FAIL first onboarding radius % is not the Atlanta default %', v_pp.feed_radius_km, v_atl.default_radius_km;
  end if;
  -- Other people's private rows (home area included) stay invisible.
  if exists (select 1 from public.profile_private where user_id <> auth.uid()) then
    raise exception 'FAIL profile_private rows of other users are readable';
  end if;
end $$;

do $$
declare
  r          record;
  v_ids      uuid[] := '{}';
  v_pos_imp  integer;
  v_pos_near integer;
  v_pos_hubl integer;
  i          integer := 0;
begin
  for r in
    select * from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days')
  loop
    i := i + 1;
    v_ids := v_ids || r.id;
    if r.id = current_setting('test.e_imported')::uuid then
      v_pos_imp := i;
      if not r.is_imported then raise exception 'FAIL imported row has is_imported false'; end if;
    end if;
    if r.id = current_setting('test.e_near')::uuid then
      v_pos_near := i;
      if r.matched_by <> 'nearby' then raise exception 'FAIL near event matched_by %', r.matched_by; end if;
      if r.distance_band <> '1-5 mi' then raise exception 'FAIL near event band %', r.distance_band; end if;
      if r.section not in ('today', 'this_week') then raise exception 'FAIL near event section %', r.section; end if;
    end if;
    if r.id = current_setting('test.e_hub_later')::uuid then
      v_pos_hubl := i;
    end if;
    if r.id = current_setting('test.e_nullpt')::uuid then
      if r.matched_by <> 'hub' then raise exception 'FAIL null-point event matched_by %', r.matched_by; end if;
      if r.distance_band is not null then raise exception 'FAIL null-point event has a band'; end if;
    end if;
    if r.id = current_setting('test.e_approx')::uuid and r.distance_band is distinct from 'approximate' then
      raise exception 'FAIL approved-only event band %', r.distance_band;
    end if;
  end loop;

  if not current_setting('test.e_near')::uuid = any (v_ids) then
    raise exception 'FAIL public event 3 km away is missing';
  end if;
  if current_setting('test.e_far')::uuid = any (v_ids) then
    raise exception 'FAIL public event 40 km away is included';
  end if;
  if not current_setting('test.e_nullpt')::uuid = any (v_ids) then
    raise exception 'FAIL hub-member event with no point is missing';
  end if;
  if current_setting('test.e_nullpt_other')::uuid = any (v_ids) then
    raise exception 'FAIL no-point event outside my hubs is included';
  end if;
  if not current_setting('test.e_approx')::uuid = any (v_ids) then
    raise exception 'FAIL approved-only event within radius + slack is missing';
  end if;
  if v_pos_imp is null then
    raise exception 'FAIL imported nearby event is missing';
  end if;
  if v_pos_imp < v_pos_near then
    raise exception 'FAIL imported row (%) sorts above a member row (%)', v_pos_imp, v_pos_near;
  end if;
  if v_pos_hubl is null then
    raise exception 'FAIL later hub event is missing';
  end if;
  if v_pos_hubl < v_pos_near then
    raise exception 'FAIL hub event five days out (%) sorts above a nearby event tomorrow (%)', v_pos_hubl, v_pos_near;
  end if;
  if v_pos_imp < v_pos_hubl then
    raise exception 'FAIL imported row (%) sorts above the later hub row (%)', v_pos_imp, v_pos_hubl;
  end if;

  -- A device point 40 km north brings the far event in and drops the near one.
  v_ids := array(select f.id from public.feed_events_v2(now() - interval '1 day', now() + interval '7 days',
                                                        34.1100, -84.3880) f);
  if not current_setting('test.e_far')::uuid = any (v_ids) or current_setting('test.e_near')::uuid = any (v_ids) then
    raise exception 'FAIL device point origin not applied';
  end if;
end $$;

do $$
declare
  v public.venues;
begin
  v := public.upsert_venue(jsonb_build_object(
    'name', 'Feed v2 test address', 'address_line1', '1 Test St', 'city', 'Atlanta',
    'postal_code', '30303', 'lat', 33.75, 'lng', -84.39,
    'place_id', 'feedv2-test-' || current_setting('test.viewer')));
  if v.is_public then
    raise exception 'FAIL upsert_venue with a place_id and no is_public made a public venue';
  end if;
end $$;

do $$
declare
  v       jsonb;
  v_mid   public.areas;
begin
  select * into v_mid from public.areas where slug = 'midtown';
  if v_mid.id is null then
    select * into v_mid from public.areas where slug <> 'atlanta' order by slug limit 1;
  end if;
  v := public.set_home_area(v_mid.id);
  if (v ->> 'feed_radius_km')::integer <> v_mid.default_radius_km then
    raise exception 'FAIL set_home_area without a radius kept % instead of the area default %',
      v ->> 'feed_radius_km', v_mid.default_radius_km;
  end if;
  v := public.set_home_area(v_mid.id, 25::smallint);
  if (v ->> 'feed_radius_km')::integer <> 25
     or (select home_area_id from public.profile_private where user_id = auth.uid()) is distinct from v_mid.id then
    raise exception 'FAIL set_home_area with a radius: %', v;
  end if;

  begin
    update public.profile_private set home_area_id = null where user_id = auth.uid();
    raise exception 'FAIL client can update profile_private.home_area_id';
  exception when insufficient_privilege then null;
  end;
end $$;

do $$
begin
  begin
    update public.profile_private set location_text = 'x' where user_id = auth.uid();
    raise exception 'FAIL client can still update profile_private.location_text';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- As a 20-year-old: area chapters follow the hub's age limit
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.young'), 'role', 'authenticated')::text, true);

do $$
begin
  if (select public.viewer_age()) >= 21 then
    raise exception 'setup: young user is %', (select public.viewer_age());
  end if;
  begin
    insert into public.chapter_members (chapter_id, user_id)
    values (current_setting('test.ch_21')::uuid, auth.uid());
    raise exception 'FAIL under-21 user joined the area chapter of a 21+ hub';
  exception when insufficient_privilege then null;
  end;
  insert into public.chapter_members (chapter_id, user_id)
  values (current_setting('test.ch_18')::uuid, auth.uid());
end $$;

reset role;

-- ---------------------------------------------------------------------------
-- Schema checks (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare v_bad text;
begin
  select string_agg(n, ', ') into v_bad
    from (
      select unnest(p.proargnames) as n, unnest(p.proargmodes) as m
        from pg_proc p
       where p.oid = 'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer)'::regprocedure
    ) a
   where m = 't'
     and (n ~ '(^|_)(lat|lng|latitude|longitude|point|origin)($|_)' or (n like '%distance%' and n <> 'distance_band'));
  if v_bad is not null then
    raise exception 'FAIL feed_events_v2 returns location columns: %', v_bad;
  end if;

  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (current_setting('test.hub_a')::uuid, (select id from public.areas where slug = 'old-fourth-ward'),
          'feedv2-test-' || substr(replace(current_setting('test.viewer'), '-', ''), 1, 10), 'Test area chapter');

  begin
    insert into public.hub_chapters (hub_id, slug, name)
    values (current_setting('test.hub_a')::uuid, 'feedv2-test-noowner', 'No owner chapter');
    raise exception 'FAIL chapter without org or area inserted';
  exception when check_violation then null;
  end;

  begin
    insert into public.hub_chapters (hub_id, org_id, area_id, slug, name)
    values (current_setting('test.hub_a')::uuid, (select id from public.organizations order by id limit 1),
            (select id from public.areas where slug = 'atlanta'), 'feedv2-test-twoowners', 'Two owners chapter');
    raise exception 'FAIL chapter with both org and area inserted';
  exception when check_violation then null;
  end;

  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles' and column_name = 'home_area_id') then
    raise exception 'FAIL profiles.home_area_id still exists (it is readable by every signed-in user)';
  end if;
  if exists (select 1 from public.profiles p join public.profile_private pp on pp.user_id = p.id
              where p.onboarding_completed_at is not null and p.deleted_at is null and pp.home_area_id is null) then
    raise exception 'FAIL an onboarded profile has no home area';
  end if;

  if (select value from public.meta where key = 'schema_version') <> '2.10' then
    raise exception 'FAIL schema_version is not 2.10';
  end if;
end $$;

select 'everyone_feed_v2: all assertions passed' as result;

rollback;
