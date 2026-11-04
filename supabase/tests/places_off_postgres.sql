-- ============================================================================
-- Staging check for migration 20261213000100_places_off_postgres.sql
-- (migration 49, D-042 slice 11). One transaction, asserts in DO blocks that
-- raise on failure, rolled back at the end. Prints pass/fail lines only, never
-- names, ids or points (the repo and its Action logs are public). The fixture
-- sits in the Southern Ocean, where no real data is; the "published file" is
-- recorded with invented hashes (nothing is fetched).
--   1 Static: schema_version 2.45; grants and security of the new functions;
--     the checks table has RLS and no client privileges; the job exists.
--   2 Files: place_file_of_tile and place_file_at (anon) answer for the
--     published tile, null with the switch off, null for an unpublished tile.
--   3 place_from_file: refusals (sha256 not current, outside the tile, kind,
--     rules, ref); a good row is source osm, active, public, no user id; a
--     second call answers the same id; a hidden row answers null.
--   4 Venue matching: a public plan at a public venue with no row nearby
--     makes a meeting spot; the venue is queued with its tile's file; a
--     recorded match makes the OSM row, links the venue to it and drops the
--     spot; a recorded "no match" keeps the spot; neither is queued again for
--     the same files; a new file version queues the unmatched one again; a
--     private venue is never queued; a refused match only counts.
--   5 RLS: a signed-in member cannot read the checks table or call the
--     service functions.
-- ============================================================================
begin;

create temp table pop_lines (n serial, line text);
grant insert, select on pop_lines to anon, authenticated;
grant usage on sequence pop_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

create function pg_temp.spot(p_venue uuid) returns uuid language sql stable as $$
  select p.id from public.places p where p.source = 'venue' and p.source_id = p_venue::text;
$$;

create function pg_temp.queued(p_venue uuid) returns jsonb language sql stable as $$
  select e.value from jsonb_array_elements(public.place_match_queue(200) -> 'venues') as e(value)
   where e.value ->> 'venue_id' = p_venue::text;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.45' then
    raise exception 'FAIL schema_version is not 2.45';
  end if;
  if coalesce((select value from public.meta where key = 'places_base_url'), '') !~ '^https://' then
    raise exception 'FAIL places_base_url is not set';
  end if;
  foreach f in array array['public.place_file_of_tile(integer)', 'public.place_from_file(integer,text,jsonb)',
                           'public.place_match_queue(integer)', 'public.place_match_record(jsonb)',
                           'public.place_match_dispatch(boolean)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL % is executable by a client role', f;
    end if;
    if not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL % is not security definer', f;
    end if;
  end loop;
  if not has_function_privilege('anon', 'public.place_file_at(double precision,double precision)', 'execute')
     or not has_function_privilege('authenticated', 'public.place_file_at(double precision,double precision)', 'execute')
     or (select p.provolatile from pg_proc p
          where p.oid = 'public.place_file_at(double precision,double precision)'::regprocedure) <> 's' then
    raise exception 'FAIL place_file_at grants or volatility';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.place_venue_file_checks'::regclass)
     or has_table_privilege('anon', 'public.place_venue_file_checks', 'select')
     or has_table_privilege('authenticated', 'public.place_venue_file_checks', 'select')
     or has_table_privilege('authenticated', 'public.place_venue_file_checks', 'insert') then
    raise exception 'FAIL place_venue_file_checks RLS or privileges';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'place_venue_file_checks'
                and column_name in ('user_id', 'created_by')) then
    raise exception 'FAIL place_venue_file_checks has a user column';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'place-match') then
    raise exception 'FAIL place-match is not scheduled';
  end if;
  insert into pop_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_h    uuid := gen_random_uuid();
  v_u    uuid := gen_random_uuid();
  v_tag  text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_a    uuid;
  v_rule smallint;
  v_t    integer := public.place_tile_id(-61.23, -140.23);
  v_t2   integer := public.place_tile_id(-61.23, -139.23);
  v1 uuid; v2 uuid; v3 uuid;
  e1 uuid;
  r  jsonb;
begin
  if exists (select 1 from public.place_tiles where id in (v_t, v_t2))
     or exists (select 1 from public.places
                 where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-141, -62, -139, -60, 4326))
     or exists (select 1 from public.venues
                 where location is not null
                   and (location::extensions.geometry) operator(extensions.&&)
                       extensions.ST_MakeEnvelope(-141, -62, -139, -60, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'pop-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_h, v_u]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (v_h, v_u);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_h, v_u);

  select h.id, r.rule_id into v_a, v_rule
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
    join public.hub_place_rules r on r.hub_id = h.id
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and coalesce(h.min_age, 0) < 21
   order by h.slug, r.rule_id limit 1;
  if v_a is null then raise exception 'setup: no specific hub with a rule'; end if;

  -- Tile T has a published file; tile T2 has a built file that was never published.
  update public.meta set value = 'on' where key = 'places_files';
  delete from public.meta where key = 'places_rules_file';
  insert into public.place_tiles (id, status, osm_run_at)
  values (v_t, 'active', now() - interval '2 hours'), (v_t2, 'active', now() - interval '2 hours');
  r := public.place_files_record(jsonb_build_object('published', true,
         'rules', jsonb_build_object('path', 'rules/v1.0123456789abcdef.json.gz', 'sha256', repeat('a', 64),
                                     'bytes', 1234, 'rules_version', 1),
         'tiles', jsonb_build_array(jsonb_build_object('id', v_t,
                    'path', 'places/v1/' || v_t || '.00000000000000aa.json.gz', 'sha256', repeat('b', 64),
                    'bytes', 900, 'count', 3, 'rules_version', 1, 'built_from', now() - interval '1 hour'))));
  if (r ->> 'set')::integer <> 1 then raise exception 'setup: record published'; end if;
  r := public.place_files_record(jsonb_build_object('published', false,
         'tiles', jsonb_build_array(jsonb_build_object('id', v_t2,
                    'path', 'places/v1/' || v_t2 || '.00000000000000bb.json.gz', 'sha256', repeat('c', 64),
                    'bytes', 900, 'count', 3, 'rules_version', 1, 'built_from', now() - interval '1 hour'))));

  -- V1: a public court with a public plan, no row nearby (the court is only in the file).
  insert into public.venues (name, location, is_public, created_by)
  values ('POP Court Alpha', pg_temp.pt(-140.2302, -61.2301), true, v_h) returning id into v1;
  -- V2: a public hall with a public plan; the file has nothing like it.
  insert into public.venues (name, address_line1, city, location, is_public, created_by)
  values ('POP Corner Hall', '1 Fixture Way', 'Nowhere', pg_temp.pt(-140.3000, -61.3000), true, v_h) returning id into v2;
  -- V3: a private venue with a public plan's address hidden: never queued.
  insert into public.venues (name, location, is_public, created_by)
  values ('POP Home', pg_temp.pt(-140.3500, -61.3500), false, v_h) returning id into v3;

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'POP plan at the court', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-140.2302, -61.2301)) returning id into e1;
  insert into public.event_addresses (event_id, venue_id) values (e1, v1);
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'POP plan at the hall', now() + interval '2 days', now() + interval '2 days 2 hours', 'Here',
          pg_temp.pt(-140.3, -61.3)) returning id into e1;
  insert into public.event_addresses (event_id, venue_id) values (e1, v2);
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'POP plan at home', now() + interval '2 days', now() + interval '2 days 2 hours', 'Here',
          pg_temp.pt(-140.35, -61.35)) returning id into e1;
  insert into public.event_addresses (event_id, venue_id) values (e1, v3);

  perform set_config('test.u', v_u::text, true);
  perform set_config('test.rule', v_rule::text, true);
  perform set_config('test.t', v_t::text, true);
  perform set_config('test.t2', v_t2::text, true);
  perform set_config('test.v1', v1::text, true);
  perform set_config('test.v2', v2::text, true);
  perform set_config('test.v3', v3::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Files
-- ---------------------------------------------------------------------------
do $$
declare
  v_t  integer := current_setting('test.t')::integer;
  v_t2 integer := current_setting('test.t2')::integer;
  f    jsonb := public.place_file_of_tile(current_setting('test.t')::integer);
begin
  if f is null or f ->> 'sha256' <> repeat('b', 64) or (f ->> 'tile')::integer <> v_t
     or f ->> 'path' <> 'places/v1/' || v_t || '.00000000000000aa.json.gz' or f ->> 'base' !~ '^https://' then
    raise exception 'FAIL place_file_of_tile for the published tile';
  end if;
  if public.place_file_of_tile(v_t2) is not null then
    raise exception 'FAIL place_file_of_tile offers an unpublished file';
  end if;
  update public.meta set value = 'off' where key = 'places_files';
  if public.place_file_of_tile(v_t) is not null then
    raise exception 'FAIL place_file_of_tile with the switch off';
  end if;
  update public.meta set value = 'on' where key = 'places_files';
  insert into pop_lines (line) values ('files: ok');
end $$;

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v jsonb := public.place_file_at(-61.2301, -140.2302);
begin
  if v is null or (v ->> 'tile')::integer <> current_setting('test.t')::integer or v ? 'sha256'
     or v ->> 'path' !~ '^places/v1/' then
    raise exception 'FAIL place_file_at as anon';
  end if;
  if public.place_file_at(-61.2301, -139.2302) is not null or public.place_file_at(95, 0) is not null then
    raise exception 'FAIL place_file_at for an unpublished tile or a bad point';
  end if;
  insert into pop_lines (line) values ('file at (anon): ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. place_from_file
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   integer := current_setting('test.t')::integer;
  v_r   smallint := current_setting('test.rule')::smallint;
  good  jsonb;
  v_id  uuid;
  v_id2 uuid;
  p     public.places%rowtype;
  f     text;
  bad   jsonb;
begin
  good := jsonb_build_object('osm_ref', 'n9100000009', 'lng', -140.2600, 'lat', -61.2600, 'kind', 'court_field',
                             'name', '  POP   Spare Court ', 'rule_ids', jsonb_build_array(v_r, 32000),
                             'address_text', '9 Fixture Way', 'locality', 'Nowhere', 'opening_hours', 'Mo-Su 08:00-20:00',
                             'website', 'https://example.org/court', 'tags', jsonb_build_object('sport', 'tennis', 'secret', 'x'));
  begin
    perform public.place_from_file(v_t, repeat('c', 64), good);
    raise exception 'FAIL a stale sha256 was accepted';
  exception when check_violation then
    if sqlerrm <> 'file_not_current' then raise exception 'FAIL stale sha256 error %', sqlerrm; end if;
  end;
  foreach f in array array['outside', 'kind', 'rules', 'ref', 'name'] loop
    bad := case f
      when 'outside' then good || jsonb_build_object('lng', -139.26)
      when 'kind' then good || jsonb_build_object('kind', 'no_such_kind')
      when 'rules' then good || jsonb_build_object('rule_ids', jsonb_build_array(32000))
      when 'ref' then good || jsonb_build_object('osm_ref', 'x1')
      else good || jsonb_build_object('name', '  ') end;
    begin
      perform public.place_from_file(v_t, repeat('b', 64), bad);
      raise exception 'FAIL a bad row (%) was accepted', f;
    exception when check_violation then
      null;
    end;
  end loop;

  v_id := public.place_from_file(v_t, repeat('b', 64), good);
  select * into p from public.places where id = v_id;
  if p.id is null or p.source <> 'osm' or p.source_id <> 'n9100000009' or p.osm_ref <> 'n9100000009'
     or p.status <> 'active' or not p.is_public or p.created_by is not null or p.tile_id <> v_t
     or p.name <> 'POP Spare Court' or p.rule_ids <> array[v_r] or p.tags <> '{"sport": "tennis"}'::jsonb
     or p.website <> 'https://example.org/court' or p.attribution <> '© OpenStreetMap contributors' then
    raise exception 'FAIL the row made from a file';
  end if;
  v_id2 := public.place_from_file(v_t, repeat('b', 64), good || jsonb_build_object('name', 'Other'));
  if v_id2 is distinct from v_id or (select name from public.places where id = v_id) <> 'POP Spare Court' then
    raise exception 'FAIL a second call did not answer the same row unchanged';
  end if;
  update public.places set status = 'hidden' where id = v_id;
  if public.place_from_file(v_t, repeat('b', 64), good) is not null then
    raise exception 'FAIL a hidden row was answered';
  end if;
  insert into pop_lines (line) values ('place_from_file: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Venue matching
-- ---------------------------------------------------------------------------
do $$
declare
  v_t  integer := current_setting('test.t')::integer;
  v1   uuid := current_setting('test.v1')::uuid;
  v2   uuid := current_setting('test.v2')::uuid;
  v3   uuid := current_setting('test.v3')::uuid;
  v_r  smallint := current_setting('test.rule')::smallint;
  q1   jsonb;
  q2   jsonb;
  res  jsonb;
  s1   uuid;
  v_pl uuid;
  p    public.places%rowtype;
begin
  s1 := pg_temp.spot(v1);
  if s1 is null or pg_temp.spot(v2) is null then
    raise exception 'FAIL the plans did not make meeting spots';
  end if;
  if (select place_ref from public.venues where id = v1) is distinct from s1 then
    raise exception 'FAIL the venue is not on its meeting spot';
  end if;
  q1 := pg_temp.queued(v1);
  q2 := pg_temp.queued(v2);
  if q1 is null or q2 is null then
    raise exception 'FAIL a public venue on a meeting spot is not queued';
  end if;
  if pg_temp.queued(v3) is not null then
    raise exception 'FAIL a private venue is queued';
  end if;
  if q1 -> 'files' <> jsonb_build_array(jsonb_build_object('tile', v_t,
       'path', 'places/v1/' || v_t || '.00000000000000aa.json.gz', 'sha256', repeat('b', 64)))
     or q1 ->> 'key' <> md5(repeat('b', 64)) or q1 ->> 'name' <> 'POP Court Alpha' then
    raise exception 'FAIL the queue entry';
  end if;
  if (public.place_match_queue(200) ->> 'base') !~ '^https://' then
    raise exception 'FAIL the queue base url';
  end if;

  res := public.place_match_record(jsonb_build_array(
    jsonb_build_object('venue_id', v1, 'key', q1 ->> 'key', 'match', jsonb_build_object(
      'tile', v_t, 'sha256', repeat('b', 64), 'row', jsonb_build_object(
        'osm_ref', 'w9100000001', 'lng', -140.2300, 'lat', -61.2300, 'kind', 'court_field',
        'name', 'POP Court Alpha', 'rule_ids', jsonb_build_array(v_r)))),
    jsonb_build_object('venue_id', v2, 'key', q2 ->> 'key', 'match', null),
    jsonb_build_object('venue_id', v3, 'key', q2 ->> 'key', 'match', null),
    jsonb_build_object('venue_id', 'nope', 'key', q2 ->> 'key')));
  if (res ->> 'checked')::integer <> 2 or (res ->> 'rows')::integer <> 1 or (res ->> 'linked')::integer <> 1
     or (res ->> 'skipped')::integer <> 2 or (res ->> 'refused')::integer <> 0 then
    raise exception 'FAIL place_match_record counts %', res;
  end if;
  select v.place_ref into v_pl from public.venues v where v.id = v1;
  select * into p from public.places where id = v_pl;
  if p.id is null or p.source <> 'osm' or p.osm_ref <> 'w9100000001' or p.status <> 'active' or not p.is_public then
    raise exception 'FAIL the matched venue is not linked to the file place';
  end if;
  if pg_temp.spot(v1) is not null then
    raise exception 'FAIL the matched venue kept its own meeting spot';
  end if;
  if not exists (select 1 from public.place_hubs ph where ph.place_id = v_pl and ph.via = 'events') then
    raise exception 'FAIL the file place did not get the plan''s hub link';
  end if;
  if pg_temp.spot(v2) is null or (select place_ref from public.venues where id = v2) is distinct from pg_temp.spot(v2) then
    raise exception 'FAIL an unmatched venue lost its meeting spot';
  end if;
  if pg_temp.queued(v1) is not null or pg_temp.queued(v2) is not null then
    raise exception 'FAIL a checked venue is queued again for the same files';
  end if;
  if exists (select 1 from public.place_venue_file_checks where venue_id = v3) then
    raise exception 'FAIL a private venue got a check row';
  end if;

  -- A new file version queues the unmatched venue again (the matched one has its place).
  perform public.place_files_record(jsonb_build_object('published', true,
         'tiles', jsonb_build_array(jsonb_build_object('id', v_t,
                    'path', 'places/v1/' || v_t || '.00000000000000cc.json.gz', 'sha256', repeat('d', 64),
                    'bytes', 900, 'count', 4, 'rules_version', 1, 'built_from', now()))));
  if pg_temp.queued(v2) is null or pg_temp.queued(v2) ->> 'key' <> md5(repeat('d', 64)) then
    raise exception 'FAIL a new file version did not queue the unmatched venue';
  end if;
  if pg_temp.queued(v1) is not null then
    raise exception 'FAIL a matched venue is queued';
  end if;

  -- A match against the old file is refused and only counted.
  res := public.place_match_record(jsonb_build_array(
    jsonb_build_object('venue_id', v2, 'key', md5(repeat('d', 64)), 'match', jsonb_build_object(
      'tile', v_t, 'sha256', repeat('b', 64), 'row', jsonb_build_object(
        'osm_ref', 'n9100000002', 'lng', -140.3000, 'lat', -61.3000, 'kind', 'court_field',
        'name', 'POP Corner Hall', 'rule_ids', jsonb_build_array(v_r))))));
  if (res ->> 'refused')::integer <> 1 or (res ->> 'rows')::integer <> 0
     or exists (select 1 from public.places where osm_ref = 'n9100000002') then
    raise exception 'FAIL a match against a replaced file was not refused %', res;
  end if;
  insert into pop_lines (line) values ('venue matching: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. A signed-in member
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
do $$
begin
  begin
    perform 1 from public.place_venue_file_checks limit 1;
    raise exception 'FAIL a member read the checks table';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform public.place_match_queue(1);
    raise exception 'FAIL a member read the match queue';
  exception when insufficient_privilege then
    null;
  end;
  begin
    perform public.place_from_file(1, repeat('b', 64), '{}'::jsonb);
    raise exception 'FAIL a member called place_from_file';
  exception when insufficient_privilege then
    null;
  end;
  if public.place_file_at(-61.2301, -140.2302) is null then
    raise exception 'FAIL place_file_at as a member';
  end if;
  insert into pop_lines (line) values ('member: ok');
end $$;
reset role;

select 'places_off_postgres: ' || case when count(*) = 6 then 'all assertions passed'
                                       else count(*) || ' of 6 sections passed' end as result
  from pop_lines
union all
select line from (select line from pop_lines order by n) x;

rollback;
