-- ============================================================================
-- Staging check for migration 20261129000100_places_lifecycle_odbl.sql
-- (D-041, hub map slices 10 groundwork, 14 and 15). One transaction, asserts
-- in DO blocks that raise on failure, rolled back at the end. Prints
-- pass/fail lines and counts only, never names, ids or points (the repo and
-- its Action logs are public). Run as the staging_file of a staging_only
-- migrate.yml run. The fixture tiles sit in the Southern Ocean (lng -140 to
-- -137, lat -62 to -61.5, tiles 40400 to 40405), where no real data is.
--
-- Checks:
--   * version 2.31, grants (no client reaches the lifecycle, export, dump or
--     sync functions; anon cannot open the health panel; anyone can ask
--     shows_available), the retire-place-tiles cron job;
--   * retire_place_tiles: last_member_at on a tile with an active member's
--     home (the day, not the time); a member last seen 100 days ago does not
--     count; 90 days without a member idles a tile, keep tiles never; a new
--     tile has its grace period; an idle tile with a member wakes; a retired
--     tile with a member is wanted; 7 days idle retires a tile: plain OSM and
--     Geoapify rows go, corrected rows, moderator-linked rows and member rows
--     stay; place_ops_runs records the run and the size check; a second run
--     changes nothing;
--   * places_odbl_page: only public active rows, exactly the export keys,
--     never an id or a member; paging by cursor;
--   * record_place_dump and its errors; mod_place_health for moderators only,
--     with tile entries that hold no member field; place_ops_runs is
--     moderator-read only;
--   * listing_kind: ticketmaster and seatgeek sources are shows; an imported
--     show is a show (also when a plan source links to it), and a plan again
--     when its show import goes; a source switching kind re-files its
--     events; feed_events_v2 keeps shows out by default and lists them for
--     p_listing_kind show (listing_kind_invalid otherwise); map_in_view has
--     the show in shows, not plans; shows_available.
-- ============================================================================
begin;

create temp table plc_lines (n serial, line text);
grant insert, select on plc_lines to anon, authenticated;
grant usage on sequence plc_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- 0. Version, grants, cron
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.31' then
    raise exception 'FAIL schema_version is not 2.31';
  end if;
  foreach f in array array[
      'public.retire_place_tiles()', 'public.place_size_status()',
      'public.places_odbl_page(uuid, integer)',
      'public.record_place_dump(text, integer, bigint, text, boolean, jsonb)',
      'public.event_listing_kind_sync(uuid)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL a client can execute %', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL service_role cannot execute %', f;
    end if;
  end loop;
  foreach f in array array['public.feed_sources_listing_kind_default()', 'public.feed_sources_listing_kind_sync()',
                           'public.event_imports_listing_kind()'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL a client can execute trigger function %', f;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.mod_place_health()', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_place_health()', 'execute') then
    raise exception 'FAIL mod_place_health grants';
  end if;
  if not has_function_privilege('anon', 'public.shows_available()', 'execute')
     or not has_function_privilege('authenticated', 'public.shows_available()', 'execute') then
    raise exception 'FAIL shows_available grants';
  end if;
  if has_table_privilege('anon', 'public.places_odbl_export', 'select')
     or has_table_privilege('authenticated', 'public.places_odbl_export', 'select') then
    raise exception 'FAIL a client can read places_odbl_export';
  end if;
  if has_table_privilege('anon', 'public.place_ops_runs', 'select')
     or has_table_privilege('authenticated', 'public.place_ops_runs', 'insert') then
    raise exception 'FAIL place_ops_runs grants';
  end if;
  if has_function_privilege('anon',
       'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text)', 'execute')
     or not has_function_privilege('authenticated',
       'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text)', 'execute') then
    raise exception 'FAIL feed_events_v2 grants';
  end if;
  if to_regprocedure('public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text)') is not null then
    raise exception 'FAIL the old feed_events_v2 signature is still there';
  end if;
  if to_regclass('cron.job') is not null then
    if not exists (select 1 from cron.job where jobname = 'retire-place-tiles' and schedule = '23 4 * * *') then
      raise exception 'FAIL retire-place-tiles is not scheduled';
    end if;
    insert into plc_lines (line) values ('version, grants and cron: ok');
  else
    insert into plc_lines (line) values ('version and grants: ok (no pg_cron here)');
  end if;
  if exists (select 1 from public.feed_sources where kind in ('ticketmaster', 'seatgeek') and listing_kind <> 'show') then
    raise exception 'FAIL a ticketed source is not a show source';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  ua uuid := gen_random_uuid();   -- active member, home in tile 40401
  us uuid := gen_random_uuid();   -- stale member (seen 100 days ago), home in tile 40400
  ub uuid := gen_random_uuid();   -- active member, home in tile 40403 (idle, wakes)
  ur uuid := gen_random_uuid();   -- active member, home in tile 40404 (retired, wanted)
  um uuid := gen_random_uuid();   -- moderator
  v_hub uuid;
  v_id uuid;
begin
  if exists (select 1 from public.place_tiles where id between 40400 and 40405)
     or exists (select 1 from public.places
                 where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-140, -62, -137, -61.5, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'plc-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[ua, us, ub, ur, um]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (ua, us, ub, ur, um);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (ua, us, ub, ur, um);
  insert into public.user_roles (user_id, role) values (um, 'moderator');
  update public.profile_private set home_point = pg_temp.pt(-139.25, -61.75), last_seen_at = now() where user_id = ua;
  update public.profile_private set home_point = pg_temp.pt(-139.75, -61.75), last_seen_at = now() - interval '100 days' where user_id = us;
  update public.profile_private set home_point = pg_temp.pt(-138.25, -61.75), last_seen_at = now() - interval '2 days' where user_id = ub;
  update public.profile_private set home_point = pg_temp.pt(-137.75, -61.75), last_seen_at = now() - interval '89 days' where user_id = ur;
  if (select count(distinct public.place_tile_id_of(home_point)) from public.profile_private
       where user_id in (ua, us, ub, ur)) <> 4
     or public.place_tile_id_of(pg_temp.pt(-139.75, -61.75)) <> 40400 then
    raise exception 'setup: fixture tiles are not what the test expects';
  end if;

  -- 40400 stale: active, OSM run 100 days ago, only a stale member.
  -- 40401 member:  active, OSM run 200 days ago, an active member.
  -- 40402 keep:    active, OSM run 200 days ago, keep.
  -- 40403 idle:    idle a day, OSM run, an active member (wakes).
  -- 40404 retired: retired, no OSM run, an active member (wanted).
  -- 40405 fresh:   filling, created now, no member (grace).
  insert into public.place_tiles (id, status, osm_run_at, created_at, keep, idle_since) values
    (40400, 'active',  now() - interval '100 days', now() - interval '120 days', false, null),
    (40401, 'active',  now() - interval '200 days', now() - interval '220 days', false, null),
    (40402, 'active',  now() - interval '200 days', now() - interval '220 days', true,  null),
    (40403, 'idle',    now() - interval '130 days', now() - interval '220 days', false, now() - interval '1 day'),
    (40404, 'retired', null,                        now() - interval '220 days', false, null),
    (40405, 'filling', null,                        now(),                       false, null);

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific'
   order by h.slug limit 1;

  -- Tile 40400's rows: plain OSM (goes), plain Geoapify (goes), corrected OSM
  -- (stays), moderator-linked OSM (stays), a member's public place (stays).
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-plc-plain-' || v_tag, 'PLC Plain', 'park', pg_temp.pt(-139.90, -61.80), true, 'active',
          '© OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.p_plain', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('geoapify', 'test-plc-geo-' || v_tag, 'PLC Geo', 'cafe', pg_temp.pt(-139.91, -61.80), true, 'active',
          'Powered by Geoapify, © OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.p_geo', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, locked_fields)
  values ('osm', 'test-plc-locked-' || v_tag, 'PLC Locked', 'park', pg_temp.pt(-139.92, -61.80), true, 'active',
          '© OpenStreetMap contributors', array['name']) returning id into v_id;
  perform set_config('test.p_locked', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-plc-linked-' || v_tag, 'PLC Linked', 'court_field', pg_temp.pt(-139.93, -61.80), true, 'active',
          '© OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.p_linked', v_id::text, true);
  insert into public.place_hubs (place_id, hub_id, via) values (v_id, v_hub, 'moderator');
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'PLC Member Spot', 'court_field', pg_temp.pt(-139.94, -61.80), true, 'active', um,
          'Added by an Activity Planet member') returning id into v_id;
  perform set_config('test.p_member', v_id::text, true);

  -- Tile 40401's rows for the export: public OSM, public member place, a
  -- private pin, a pending place, a hidden import.
  insert into public.places (source, source_id, osm_ref, name, kind, location, is_public, status, attribution, website, opening_hours, tags)
  values ('osm', 'test-plc-odbl-' || v_tag, null, 'PLC Export Court', 'court_field', pg_temp.pt(-139.10, -61.70), true, 'active',
          '© OpenStreetMap contributors', 'https://example.com/court', 'Mo-Fr 08:00-20:00', '{"sport":"basketball"}');
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'PLC Export Member', 'court_field', pg_temp.pt(-139.11, -61.70), true, 'active', um,
          'Added by an Activity Planet member');
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'PLC Export Private', 'court_field', pg_temp.pt(-139.12, -61.70), false, 'active', ua,
          'Added by an Activity Planet member');
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'PLC Export Pending', 'court_field', pg_temp.pt(-139.13, -61.70), true, 'pending', ua,
          'Added by an Activity Planet member');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-plc-hidden-' || v_tag, 'PLC Export Hidden', 'park', pg_temp.pt(-139.14, -61.70), true, 'hidden',
          '© OpenStreetMap contributors');

  perform set_config('test.ua', ua::text, true);
  perform set_config('test.um', um::text, true);
  perform set_config('test.tag', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. retire_place_tiles: first run
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  t record;
  v_runs integer := (select count(*) from public.place_ops_runs);
begin
  r := public.retire_place_tiles();
  if r is null or not (r ? 'retired' and r ? 'idled' and r ? 'deleted_rows' and r ? 'size_level') then
    raise exception 'FAIL retire_place_tiles result shape';
  end if;

  select * into t from public.place_tiles where id = 40400;
  if t.status <> 'idle' or t.idle_since is null or t.last_member_at is not null then
    raise exception 'FAIL a tile with only a stale member did not go idle (status %)', t.status;
  end if;
  select * into t from public.place_tiles where id = 40401;
  if t.status <> 'active' or t.last_member_at is distinct from date_trunc('day', now()) then
    raise exception 'FAIL a tile with an active member was idled or not stamped with the day';
  end if;
  select * into t from public.place_tiles where id = 40402;
  if t.status <> 'active' then
    raise exception 'FAIL a keep tile was idled';
  end if;
  select * into t from public.place_tiles where id = 40403;
  if t.status <> 'active' or t.idle_since is not null then
    raise exception 'FAIL an idle tile whose member came back did not wake';
  end if;
  select * into t from public.place_tiles where id = 40404;
  if t.status <> 'wanted' then
    raise exception 'FAIL a retired tile with a member is not wanted';
  end if;
  select * into t from public.place_tiles where id = 40405;
  if t.status <> 'filling' then
    raise exception 'FAIL a new tile lost its grace period';
  end if;
  if (select count(*) from public.places where tile_id = 40400) <> 5 then
    raise exception 'FAIL idling deleted rows';
  end if;
  if (select count(*) from public.place_ops_runs) < v_runs + 2
     or not exists (select 1 from public.place_ops_runs where job = 'size' and stats ? 'places_bytes' and stats ? 'level')
     or not exists (select 1 from public.place_ops_runs where job = 'retire' and stats ? 'member_tiles') then
    raise exception 'FAIL the run or the size check was not recorded';
  end if;
  insert into plc_lines (line) values ('lifecycle run 1 (stamp, idle, keep, wake, wanted, grace): ok');
  insert into plc_lines (line) values ('size level now: ' || (public.place_size_status() ->> 'level'));
end $$;

-- ---------------------------------------------------------------------------
-- 3. retire_place_tiles: 7 days idle retires the tile
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  t record;
begin
  update public.place_tiles set idle_since = now() - interval '8 days' where id = 40400;
  r := public.retire_place_tiles();
  select * into t from public.place_tiles where id = 40400;
  if t.status <> 'retired' or t.idle_since is not null then
    raise exception 'FAIL a tile idle for 8 days was not retired';
  end if;
  if exists (select 1 from public.places where id in (current_setting('test.p_plain')::uuid, current_setting('test.p_geo')::uuid)) then
    raise exception 'FAIL retirement kept a plain OSM or Geoapify row';
  end if;
  if (select count(*) from public.places where id in (current_setting('test.p_locked')::uuid,
        current_setting('test.p_linked')::uuid, current_setting('test.p_member')::uuid)) <> 3 then
    raise exception 'FAIL retirement deleted a corrected, linked or member row';
  end if;
  if t.row_count <> 2 then
    raise exception 'FAIL the retired tile''s row_count is % (2 imported rows stay)', t.row_count;
  end if;
  if (r ->> 'retired')::integer < 1 or (r ->> 'deleted_rows')::integer < 2 then
    raise exception 'FAIL the run did not count the retirement';
  end if;
  -- A second run changes nothing for the fixture.
  r := public.retire_place_tiles();
  if (select string_agg(id || ':' || status, ',' order by id) from public.place_tiles where id between 40400 and 40405)
     <> '40400:retired,40401:active,40402:active,40403:active,40404:wanted,40405:filling' then
    raise exception 'FAIL a second run changed the fixture tiles';
  end if;
  insert into plc_lines (line) values ('lifecycle run 2 (retire, kept rows, idempotent): ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. The ODbL export page
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  v_after uuid := null;
  v_rows jsonb := '[]'::jsonb;
  v_pages integer := 0;
  v_total integer := 0;
  x jsonb;
  v_keys text[] := array['kind', 'lat', 'lng', 'name', 'osm_ref', 'source', 'tags', 'website', 'opening_hours'];
begin
  r := public.places_odbl_page(null, 2);
  if jsonb_array_length(r -> 'rows') <> 2 or r ->> 'next' is null then
    raise exception 'FAIL a page of 2 did not give 2 rows and a cursor';
  end if;
  loop
    r := public.places_odbl_page(v_after, 5000);
    v_pages := v_pages + 1;
    v_total := v_total + jsonb_array_length(r -> 'rows');
    for x in select value from jsonb_array_elements(r -> 'rows') loop
      if (select array_agg(k order by k) from jsonb_object_keys(x) k) <> (select array_agg(k order by k) from unnest(v_keys) k) then
        raise exception 'FAIL an export row has other keys';
      end if;
      if x ->> 'name' like 'PLC Export %' then
        v_rows := v_rows || x;
      end if;
    end loop;
    exit when r ->> 'next' is null or v_pages > 200;
    v_after := (r ->> 'next')::uuid;
  end loop;
  if v_total <> (select count(*) from public.places where is_public and status = 'active' and merged_into is null) then
    raise exception 'FAIL the pages do not add up to the public active places';
  end if;
  if (select array_agg(e ->> 'name' order by e ->> 'name') from jsonb_array_elements(v_rows) e)
     <> array['PLC Export Court', 'PLC Export Member'] then
    raise exception 'FAIL the export holds a private, pending or hidden place, or misses a public one';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_rows) e
                  where e ->> 'name' = 'PLC Export Court' and e ->> 'source' = 'osm'
                    and e ->> 'website' = 'https://example.com/court' and e -> 'tags' ->> 'sport' = 'basketball'
                    and (e ->> 'lat')::double precision between -61.71 and -61.69) then
    raise exception 'FAIL the export row lost its facts';
  end if;
  if r::text ~ current_setting('test.um') or r::text ~ current_setting('test.ua') then
    raise exception 'FAIL the export carries a member id';
  end if;
  insert into plc_lines (line) values ('odbl export: ok (' || v_total || ' rows in ' || v_pages || ' pages of 5000)');

  perform pg_temp.as_user(current_setting('test.um')::uuid);
  execute 'set local role authenticated';
  if pg_temp.try('select public.places_odbl_page(null, 10)') !~ 'permission denied' then
    execute 'reset role';
    raise exception 'FAIL a moderator can call places_odbl_page';
  end if;
  if pg_temp.try('select count(*) from public.places_odbl_export') !~ 'permission denied' then
    execute 'reset role';
    raise exception 'FAIL a signed-in user can read places_odbl_export';
  end if;
  execute 'reset role';
end $$;

-- ---------------------------------------------------------------------------
-- 5. record_place_dump, mod_place_health, place_ops_runs RLS
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  x jsonb;
  v_n integer;
begin
  r := public.record_place_dump('2026-11', 123, 4567, repeat('ab', 32), false, '{"osm": 120, "user": 3}');
  if r ->> 'month' <> '2026-11' or (r ->> 'published')::boolean then
    raise exception 'FAIL record_place_dump result';
  end if;
  if pg_temp.try($q$select public.record_place_dump('2026-13', 1, 1, repeat('ab', 32), false)$q$) <> 'month_invalid'
     or pg_temp.try($q$select public.record_place_dump('2026-11', 1, 1, 'nope', false)$q$) <> 'sha256_invalid'
     or pg_temp.try($q$select public.record_place_dump('2026-11', -1, 1, repeat('ab', 32), false)$q$) <> 'count_invalid' then
    raise exception 'FAIL record_place_dump errors';
  end if;

  perform pg_temp.as_user(current_setting('test.ua')::uuid);
  execute 'set local role authenticated';
  if pg_temp.try('select public.mod_place_health()') <> 'forbidden' then
    execute 'reset role';
    raise exception 'FAIL a member opened the health panel';
  end if;
  select count(*) into v_n from public.place_ops_runs;
  if v_n <> 0 then
    execute 'reset role';
    raise exception 'FAIL a member reads place_ops_runs';
  end if;
  execute 'reset role';

  perform pg_temp.as_user(null);
  execute 'set local role anon';
  if pg_temp.try('select public.mod_place_health()') !~ 'permission denied' then
    execute 'reset role';
    raise exception 'FAIL anon reached mod_place_health';
  end if;
  execute 'reset role';

  perform pg_temp.as_user(current_setting('test.um')::uuid);
  execute 'set local role authenticated';
  r := public.mod_place_health();
  select count(*) into v_n from public.place_ops_runs;
  execute 'reset role';
  if v_n = 0 then
    raise exception 'FAIL a moderator cannot read place_ops_runs';
  end if;
  if not (r ? 'tiles' and r ? 'rows' and r ? 'size' and r ? 'runs' and r ? 'budget' and r ? 'budget_caps') then
    raise exception 'FAIL health panel keys';
  end if;
  if (r -> 'tiles' -> 'by_status' ->> 'retired')::integer < 1 or (r -> 'tiles' ->> 'total')::integer < 6 then
    raise exception 'FAIL health panel tile counts';
  end if;
  if r -> 'runs' -> 'dump' -> 'stats' ->> 'month' <> '2026-11'
     or r -> 'runs' -> 'retire' -> 'stats' is null or r -> 'runs' -> 'size' -> 'stats' ->> 'level' is null then
    raise exception 'FAIL health panel runs';
  end if;
  for x in select value from jsonb_array_elements(r -> 'tiles' -> 'list') loop
    if (select array_agg(k order by k) from jsonb_object_keys(x) k) <>
       array['demand', 'geoapify_run_at', 'id', 'idle_since', 'keep', 'last_member_at', 'osm_run_at', 'rows', 'south', 'status', 'west'] then
      raise exception 'FAIL a tile entry has other keys';
    end if;
  end loop;
  if r::text ~ current_setting('test.ua') or r::text ~ current_setting('test.um') then
    raise exception 'FAIL the health panel carries a member id';
  end if;
  insert into plc_lines (line) values ('dump record, health panel and run log access: ok');
  insert into plc_lines (line) values ('cron jobs listed: ' || jsonb_array_length(r -> 'runs' -> 'cron'));
end $$;

-- ---------------------------------------------------------------------------
-- 6. Shows and games groundwork
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('test.tag');
  v_start timestamptz := date_trunc('minute', now()) + interval '2 days 3 hours 7 minutes';
  r jsonb;
  v_show uuid;
  v_plan uuid;
  v_ids uuid[];
  v_feed text := 'select coalesce(array_agg(id), ''{}'') from public.feed_events_v2(%L::timestamptz, %L::timestamptz, 33.757, -84.396, 10, null, false, 200, null%s)';
begin
  insert into public.feed_sources (slug, kind, url, name, listing_kind)
  values ('plc-tm-' || v_tag, 'ticketmaster', 'https://app.ticketmaster.com/discovery/v2/events.json', 'PLC Tickets', 'plan'),
         ('plc-ics-' || v_tag, 'ics', 'https://example.com/plc.ics', 'PLC Calendar', 'plan');
  if (select listing_kind from public.feed_sources where slug = 'plc-tm-' || v_tag) <> 'show'
     or (select listing_kind from public.feed_sources where slug = 'plc-ics-' || v_tag) <> 'plan' then
    raise exception 'FAIL a ticketmaster source is not a show source, or an ics source is not a plan source';
  end if;
  update public.feed_sources set listing_kind = 'plan' where slug = 'plc-tm-' || v_tag;
  if (select listing_kind from public.feed_sources where slug = 'plc-tm-' || v_tag) <> 'show' then
    raise exception 'FAIL a ticketmaster source was turned into a plan source';
  end if;

  r := public.import_upsert_batch('plc-tm-' || v_tag, jsonb_build_array(jsonb_build_object(
         'external_id', 'plc-1', 'title', 'PLC Arena Night', 'starts_at', v_start,
         'url', 'https://example.com/plc/1', 'lat', 33.757, 'lng', -84.396, 'is_free', false)));
  r := public.import_upsert_batch('plc-ics-' || v_tag, jsonb_build_array(
         jsonb_build_object('external_id', 'plc-2', 'title', 'PLC Arena Night', 'starts_at', v_start,
                            'url', 'https://example.com/plc/2', 'lat', 33.757, 'lng', -84.396),
         jsonb_build_object('external_id', 'plc-3', 'title', 'PLC Park Meetup', 'starts_at', v_start,
                            'url', 'https://example.com/plc/3', 'lat', 33.757, 'lng', -84.396)));
  select ei.event_id into v_show from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'plc-tm-' || v_tag and ei.external_id = 'plc-1';
  select ei.event_id into v_plan from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'plc-ics-' || v_tag and ei.external_id = 'plc-3';
  if v_show is null or v_plan is null then
    raise exception 'FAIL the importer made no events (%)', r;
  end if;
  if (select ei.event_id from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
       where fs.slug = 'plc-ics-' || v_tag and ei.external_id = 'plc-2') is distinct from v_show then
    raise exception 'FAIL the plan source''s copy of the show was not deduplicated onto it';
  end if;
  if (select listing_kind from public.events where id = v_show) <> 'show'
     or (select listing_kind from public.events where id = v_plan) <> 'plan' then
    raise exception 'FAIL imported events are not filed by their sources';
  end if;
  if not public.shows_available() then
    raise exception 'FAIL shows_available is false with a published show';
  end if;

  -- The feed: plans by default, shows on request.
  perform pg_temp.as_user(current_setting('test.ua')::uuid);
  execute 'set local role authenticated';
  execute format(v_feed, v_start - interval '1 minute', v_start + interval '1 minute', '') into v_ids;
  if v_show = any (v_ids) or not v_plan = any (v_ids) then
    execute 'reset role';
    raise exception 'FAIL the default feed holds the show or misses the plan';
  end if;
  execute format(v_feed, v_start - interval '1 minute', v_start + interval '1 minute', ', ''show''') into v_ids;
  if not v_show = any (v_ids) or v_plan = any (v_ids) then
    execute 'reset role';
    raise exception 'FAIL the shows feed misses the show or holds the plan';
  end if;
  if pg_temp.try(format(v_feed, v_start - interval '1 minute', v_start + interval '1 minute', ', ''bogus''')) <> 'listing_kind_invalid' then
    execute 'reset role';
    raise exception 'FAIL p_listing_kind is not checked';
  end if;
  execute 'reset role';

  -- The map: the show is in shows, never in plans (signed out).
  perform pg_temp.as_user(null);
  execute 'set local role anon';
  r := public.map_in_view(-84.40, 33.75, -84.39, 33.76, null, array['plans', 'shows'],
                          v_start - interval '1 minute', v_start + interval '1 minute');
  if not exists (select 1 from jsonb_array_elements(r -> 'shows') x where x ->> 0 = v_show::text)
     or exists (select 1 from jsonb_array_elements(r -> 'plans') x where x ->> 0 = v_show::text)
     or not exists (select 1 from jsonb_array_elements(r -> 'plans') x where x ->> 0 = v_plan::text) then
    execute 'reset role';
    raise exception 'FAIL map_in_view does not keep the show in its own layer';
  end if;
  if not public.shows_available() then
    execute 'reset role';
    raise exception 'FAIL shows_available is false for anon';
  end if;
  execute 'reset role';

  -- The show source drops it: the plan source's copy keeps the event, now a plan.
  update public.event_imports ei set removed_at = now()
    from public.feed_sources fs where fs.id = ei.source_id and fs.slug = 'plc-tm-' || v_tag;
  if (select listing_kind from public.events where id = v_show) <> 'plan' then
    raise exception 'FAIL an event with no show source left is still a show';
  end if;
  -- A source switching kind re-files its events.
  update public.feed_sources set listing_kind = 'show' where slug = 'plc-ics-' || v_tag;
  if (select listing_kind from public.events where id = v_plan) <> 'show' then
    raise exception 'FAIL a source turned show did not re-file its events';
  end if;
  update public.feed_sources set listing_kind = 'plan' where slug = 'plc-ics-' || v_tag;
  if (select listing_kind from public.events where id = v_plan) <> 'plan' then
    raise exception 'FAIL a source turned back to plan did not re-file its events';
  end if;
  insert into plc_lines (line) values ('shows and games groundwork (sources, importer, dedupe, feed, map, shows_available): ok');
end $$;

select line as places_lifecycle from (
  select 0 as n, 'places_lifecycle: all assertions passed' as line
  union all
  select n, line from plc_lines) x
order by n;

rollback;
