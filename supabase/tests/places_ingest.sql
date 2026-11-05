-- ============================================================================
-- Staging check for migration 20261123000100_places_ingest.sql (D-041, hub
-- map slice 4: ingest RPCs). One transaction with a fixture tile in the
-- Southern Ocean (no real places there), asserts with DO blocks that raise on
-- failure, then rolls everything back. Prints pass/fail only, never rows.
-- Run as the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.24 or later, place_tile_runs RLS and no user column,
--     the four RPCs callable by service_role only (and refused when an
--     authenticated user calls them), run columns not client-readable, the
--     collector secret exists and verifies.
--   2 Geoapify run: one row in, tile wanted -> filling. A moderator-style
--     correction locks its name; it gets a hub link and a venue.
--   3 OSM run 1 as service_role (the fixture batch, two numbered batches,
--     one retried): round trip of every field, bad rows skipped by reason,
--     the retried batch counted once, the osm_ref merge (lock, link and
--     venue move; the Geoapify row removed with merged_into), a margin row
--     not stamped, count_mismatch, finish (tile active, row_count),
--     run_finished, a second finish changes nothing.
--   4 Runs 2 to 5: a field update, locked fields kept, an identical
--     re-ingest updates nothing (content hash unchanged), closure after two
--     missed runs (not after one), a closed row reopens, a 'closed' lock
--     keeps a twice-missed row open, a member row in the tile untouched.
--   5 Edges: hidden rows are not rewritten, Geoapify for an element with an
--     OSM row is skipped, empty_run, tile_unknown, batch_too_large,
--     source_invalid.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_u    uuid := gen_random_uuid();
  v_tag  text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_t    integer := public.place_tile_id(-60.25, -150.25);
  v_k1   text;
  v_k2   text;
  v_r1   smallint;
  v_r2   smallint;
  v_hub  uuid;
  v_id   uuid;
begin
  if exists (select 1 from public.place_tiles where id = v_t) then
    raise exception 'setup: the fixture tile already exists';
  end if;
  if exists (select 1 from public.places where osm_ref like 'n90000000%' or osm_ref like 'w90000000%'
                                            or source_id in ('gx-test-1', 'gx-test-2')) then
    raise exception 'setup: fixture refs already exist';
  end if;
  select slug into v_k1 from public.place_kinds order by slug limit 1;
  select slug into v_k2 from public.place_kinds order by slug offset 1 limit 1;
  select id into v_r1 from public.place_rules order by id limit 1;
  select id into v_r2 from public.place_rules order by id offset 1 limit 1;
  select h.id into v_hub
    from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive order by h.slug limit 1;
  if v_k2 is null or v_r2 is null or v_hub is null then
    raise exception 'setup: no kinds, rules or hub';
  end if;

  insert into public.place_tiles (id, status) values (v_t, 'wanted');

  -- A venue owner (for the merge's venue move).
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'pin-' || v_tag || '@example.com', now(), now());
  insert into public.venues (name, location, created_by, is_public)
  values ('Ingest test hall', extensions.ST_SetSRID(extensions.ST_MakePoint(-150.21, -60.21), 4326)::extensions.geography,
          v_u, true)
  returning id into v_id;
  perform set_config('test.venue', v_id::text, true);

  -- A member place in the tile: the importer must never touch it.
  insert into public.places (source, name, kind, location, is_public, status, attribution)
  values ('user', 'Member spot', v_k1,
          extensions.ST_SetSRID(extensions.ST_MakePoint(-150.3, -60.3), 4326)::extensions.geography,
          true, 'active', 'Added by a member')
  returning id into v_id;
  perform set_config('test.user_place', v_id::text, true);

  perform set_config('test.t', v_t::text, true);
  perform set_config('test.k1', v_k1, true);
  perform set_config('test.k2', v_k2, true);
  perform set_config('test.r1', v_r1::text, true);
  perform set_config('test.r2', v_r2::text, true);
  perform set_config('test.hub', v_hub::text, true);
end $$;

create function pg_temp.r(p_sid text, p_name text, p_lat double precision, p_lng double precision,
                          p_extra jsonb default '{}')
returns jsonb language sql stable as $$
  select jsonb_build_object('source_id', p_sid, 'name', p_name, 'kind', current_setting('test.k1'),
                            'rule_ids', jsonb_build_array(current_setting('test.r1')::integer),
                            'lat', p_lat, 'lng', p_lng) || p_extra;
$$;

-- Content of the fixture rows (everything the importer may write except the run stamps).
create function pg_temp.content() returns text language sql stable as $$
  select md5(coalesce(string_agg(row(p.source, p.source_id, p.osm_ref, p.name, p.kind, p.rule_ids, p.lat, p.lng,
                                     p.address_text, p.locality, p.country, p.opening_hours, p.website, p.tags,
                                     p.status, p.locked_fields, p.attribution, p.merged_into, p.is_public)::text,
                                 '|' order by p.source, p.source_id), ''))
    from public.places p
   where p.tile_id = current_setting('test.t')::integer or p.source_id = 'n9000000006';
$$;

create function pg_temp.user_row() returns text language sql stable as $$
  select md5(row(p.*)::text) from public.places p where p.id = current_setting('test.user_place')::uuid;
$$;

do $$
begin
  perform set_config('test.user_hash', pg_temp.user_row(), true);
  -- Fixture batches.
  perform set_config('test.b_geo', jsonb_build_array(
    pg_temp.r('gx-test-1', 'Geo Court', -60.22, -150.22, '{"osm_ref": "n9000000003", "source": "geoapify"}')
  )::text, true);
  perform set_config('test.b1_good', jsonb_build_array(
    pg_temp.r('n9000000001', '  Court   A ', -60.24, -150.24, jsonb_build_object(
      'rule_ids', jsonb_build_array(current_setting('test.r2')::integer, current_setting('test.r1')::integer,
                                    current_setting('test.r1')::integer, 32000),
      'tags', jsonb_build_object('sport', 'basketball', 'hoops', 2, 'operator', 'Somebody', 'name:en', 'x'),
      'website', 'https://court-a.example', 'country', 'us', 'address_text', '1 Test Way',
      'locality', 'Testville', 'opening_hours', 'Mo-Su 06:00-22:00', 'osm_ref', 'n9000000001')),
    pg_temp.r('w9000000002', 'Park B', -60.26, -150.26, '{"website": "ftp://not-web"}'),
    pg_temp.r('n9000000004', 'Pitch C', -60.27, -150.27),
    pg_temp.r('n9000000005', 'Hall D', -60.28, -150.28),
    pg_temp.r('n9000000003', 'Court M from OSM', -60.221, -150.221),
    pg_temp.r('n9000000006', 'Margin E', -60.60, -150.25)          -- next tile south (the 2 km margin)
  )::text, true);
  perform set_config('test.b1_bad', jsonb_build_array(
    pg_temp.r('x1', 'Bad id', -60.3, -150.3),
    pg_temp.r('n9000000011', '   ', -60.3, -150.3),
    pg_temp.r('n9000000012', 'Bad kind', -60.3, -150.3, '{"kind": "no-such-kind"}'),
    pg_temp.r('n9000000013', 'No rules', -60.3, -150.3, '{"rule_ids": [32000]}'),
    pg_temp.r('n9000000014', 'Bad point', -60.3, -150.3, '{"lat": "-60.3"}'),
    pg_temp.r('n9000000015', 'Wrong source', -60.3, -150.3, '{"source": "geoapify"}'),
    to_jsonb(42)
  )::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 24] then
    raise exception 'FAIL schema_version is older than 2.24';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.place_tile_runs'::regclass) then
    raise exception 'FAIL RLS is off on place_tile_runs';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'place_tile_runs'
                and (data_type = 'uuid' or column_name ~ 'user|created_by|profile')) then
    raise exception 'FAIL place_tile_runs has a user column';
  end if;
  if has_table_privilege('anon', 'public.place_tile_runs', 'select')
     or has_table_privilege('authenticated', 'public.place_tile_runs', 'insert')
     or has_table_privilege('authenticated', 'public.place_tile_runs', 'update') then
    raise exception 'FAIL clients can write place_tile_runs or anon can read it';
  end if;
  if has_column_privilege('anon', 'public.places', 'last_run_id', 'select')
     or has_column_privilege('authenticated', 'public.places', 'missed_runs', 'select') then
    raise exception 'FAIL run columns are client-readable';
  end if;
  foreach f in array array['public.ingest_places(integer,text,jsonb,text,integer)',
                           'public.finish_place_tile(integer,text,integer,text)',
                           'public.place_tiles_queue(text[],integer)',
                           'public.collector_verify_secret(text)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL % is callable by clients', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL % is not callable by service_role', f;
    end if;
    if not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL % is not security definer', f;
    end if;
  end loop;
  if (select count(*) from vault.secrets where name = 'collector_secret') <> 1 then
    raise exception 'FAIL collector_secret missing';
  end if;
  if not public.collector_verify_secret((select ds.decrypted_secret from vault.decrypted_secrets ds
                                          where ds.name = 'collector_secret')) then
    raise exception 'FAIL collector_secret does not verify';
  end if;
  if public.collector_verify_secret(repeat('a', 64)) or public.collector_verify_secret('short')
     or public.collector_verify_secret(null)
     or public.collector_verify_secret((select ds.decrypted_secret from vault.decrypted_secrets ds
                                         where ds.name = 'import_feed_secret')) then
    raise exception 'FAIL a wrong secret verifies';
  end if;
end $$;

-- A signed-in user calling the RPCs directly is refused.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid(), 'role', 'authenticated')::text, true);
do $$
begin
  begin
    perform public.ingest_places(current_setting('test.t')::integer, 'x', '[]'::jsonb);
    raise exception 'FAIL authenticated called ingest_places';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.finish_place_tile(current_setting('test.t')::integer, 'x', 0);
    raise exception 'FAIL authenticated called finish_place_tile';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.place_tiles_queue();
    raise exception 'FAIL authenticated called place_tiles_queue';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 2. Geoapify run, then a locked correction, a hub link and a venue
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   integer := current_setting('test.t')::integer;
  v_res jsonb;
  v_id  uuid;
begin
  v_res := public.ingest_places(v_t, 'test-g1', current_setting('test.b_geo')::jsonb, 'geoapify');
  if (v_res ->> 'inserted')::integer <> 1 then raise exception 'FAIL geoapify insert: %', v_res - 'skipped'; end if;
  v_res := public.finish_place_tile(v_t, 'test-g1', 1, 'geoapify');
  if (select status from public.place_tiles where id = v_t) <> 'filling'
     or (select geoapify_run_at from public.place_tiles where id = v_t) is null then
    raise exception 'FAIL a geoapify run did not move the tile to filling';
  end if;
  select id into v_id from public.places where source = 'geoapify' and source_id = 'gx-test-1';
  if (select attribution from public.places where id = v_id) not like 'Powered by Geoapify%' then
    raise exception 'FAIL geoapify attribution';
  end if;
  update public.places set name = 'Corrected Court', locked_fields = array['name'] where id = v_id;
  insert into public.place_hubs (place_id, hub_id, via) values (v_id, current_setting('test.hub')::uuid, 'moderator');
  update public.venues set place_ref = v_id where id = current_setting('test.venue')::uuid;
  perform set_config('test.geo', v_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. OSM run 1, as service_role
-- ---------------------------------------------------------------------------
set local role service_role;
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
do $$
declare
  v_t   integer := current_setting('test.t')::integer;
  v_res jsonb;
begin
  v_res := public.ingest_places(v_t, 'test-r1', current_setting('test.b1_good')::jsonb, 'osm', 0);
  if (v_res ->> 'received')::integer <> 6 or (v_res ->> 'inserted')::integer <> 5
     or (v_res ->> 'merged')::integer <> 1 or (v_res ->> 'updated')::integer <> 0 then
    raise exception 'FAIL run 1 batch 0 counts: %', v_res - 'skipped';
  end if;
  v_res := public.ingest_places(v_t, 'test-r1', current_setting('test.b1_bad')::jsonb, 'osm', 1);
  if (v_res ->> 'received')::integer <> 7 or (v_res ->> 'inserted')::integer <> 0
     or v_res -> 'skipped' <> '{"not_object": 1, "no_rules": 1, "kind_unknown": 1, "name_missing": 1,
                               "point_invalid": 1, "source_mismatch": 1, "source_id_invalid": 1}'::jsonb then
    raise exception 'FAIL run 1 bad rows: %', v_res;
  end if;
  -- The job retries batch 0 (a lost response): nothing changes and it counts once.
  v_res := public.ingest_places(v_t, 'test-r1', current_setting('test.b1_good')::jsonb, 'osm', 0);
  if (v_res ->> 'inserted')::integer <> 0 or (v_res ->> 'updated')::integer <> 0
     or (v_res ->> 'merged')::integer <> 0 or (v_res ->> 'unchanged')::integer <> 6
     or (v_res ->> 'run_received')::integer <> 13 then
    raise exception 'FAIL retried batch: %', v_res - 'skipped';
  end if;
  begin
    perform public.finish_place_tile(v_t, 'test-r1', 12);
    raise exception 'FAIL count_mismatch not raised';
  exception when check_violation then
    if sqlerrm <> 'count_mismatch' then raise; end if;
  end;
  v_res := public.finish_place_tile(v_t, 'test-r1', 13);
  if (v_res ->> 'seen')::integer <> 5 or (v_res ->> 'missed')::integer <> 0 or (v_res ->> 'closed')::integer <> 0
     or v_res ->> 'previous_seen' is not null or (v_res ->> 'active')::integer <> 5
     or (v_res ->> 'row_count')::integer <> 6 then
    raise exception 'FAIL finish run 1: %', v_res;
  end if;
  begin
    perform public.ingest_places(v_t, 'test-r1', current_setting('test.b1_good')::jsonb);
    raise exception 'FAIL run_finished not raised';
  exception when check_violation then
    if sqlerrm <> 'run_finished' then raise; end if;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- Round trip, merge, margin row, tile state.
do $$
declare
  v_t  integer := current_setting('test.t')::integer;
  v_p  public.places%rowtype;
  v_m  uuid;
  v_h  text := pg_temp.content();
  v_res jsonb;
begin
  -- Finishing the same run again returns the stored result and changes nothing.
  v_res := public.finish_place_tile(v_t, 'test-r1', 13);
  if not coalesce((v_res ->> 'already_finished')::boolean, false) or (v_res ->> 'seen')::integer <> 5
     or pg_temp.content() <> v_h then
    raise exception 'FAIL a second finish changed something';
  end if;
  select * into v_p from public.places where source = 'osm' and source_id = 'n9000000001';
  if v_p.name <> 'Court A' or v_p.kind <> current_setting('test.k1') or v_p.osm_ref <> 'n9000000001'
     or v_p.rule_ids <> array[least(current_setting('test.r1')::smallint, current_setting('test.r2')::smallint),
                              greatest(current_setting('test.r1')::smallint, current_setting('test.r2')::smallint)]
     or abs(v_p.lat - (-60.24)) > 1e-9 or abs(v_p.lng - (-150.24)) > 1e-9 or v_p.tile_id <> v_t
     or v_p.tags <> '{"sport": "basketball", "hoops": "2"}'::jsonb
     or v_p.website <> 'https://court-a.example' or v_p.country <> 'US' or v_p.address_text <> '1 Test Way'
     or v_p.locality <> 'Testville' or v_p.opening_hours <> 'Mo-Su 06:00-22:00'
     or v_p.attribution <> '© OpenStreetMap contributors' or v_p.license <> 'ODbL-1.0'
     or v_p.status <> 'active' or not v_p.is_public or v_p.created_by is not null
     or v_p.last_run_id <> 'test-r1' or v_p.missed_runs <> 0 or v_p.locked_fields <> '{}' then
    raise exception 'FAIL round trip of row A';
  end if;
  if (select website from public.places where source_id = 'w9000000002') is not null then
    raise exception 'FAIL a non-http website was kept';
  end if;
  if exists (select 1 from public.places where source_id like 'n900000001%' or source_id = 'x1') then
    raise exception 'FAIL a bad row was stored';
  end if;

  -- osm_ref merge.
  select id into v_m from public.places where source = 'osm' and source_id = 'n9000000003';
  if v_m is null then raise exception 'FAIL merged OSM row missing'; end if;
  select * into v_p from public.places where id = v_m;
  if v_p.name <> 'Corrected Court' or v_p.locked_fields <> array['name'] or v_p.osm_ref <> 'n9000000003'
     or abs(v_p.lat - (-60.221)) > 1e-9 or v_p.status <> 'active' then
    raise exception 'FAIL merge did not keep the lock or take the OSM point';
  end if;
  select * into v_p from public.places where id = current_setting('test.geo')::uuid;
  if v_p.status <> 'removed' or v_p.merged_into is distinct from v_m then
    raise exception 'FAIL the geoapify row was not retired into the OSM row';
  end if;
  if not exists (select 1 from public.place_hubs where place_id = v_m and hub_id = current_setting('test.hub')::uuid
                                                  and via = 'moderator')
     or exists (select 1 from public.place_hubs where place_id = current_setting('test.geo')::uuid) then
    raise exception 'FAIL the hub link did not move';
  end if;
  if (select place_ref from public.venues where id = current_setting('test.venue')::uuid) is distinct from v_m then
    raise exception 'FAIL the venue did not move';
  end if;

  -- Margin row: stored, in its own tile, not stamped with this run.
  select * into v_p from public.places where source_id = 'n9000000006';
  if v_p.id is null or v_p.tile_id = v_t or v_p.last_run_id is not null then
    raise exception 'FAIL margin row handling';
  end if;

  if (select status from public.place_tiles where id = v_t) <> 'active'
     or (select osm_run_at from public.place_tiles where id = v_t) is null
     or (select row_count from public.place_tiles where id = v_t) <> 6 then
    raise exception 'FAIL tile state after run 1';
  end if;
  if (select count(*) from public.place_tile_runs where tile_id = v_t and finished_at is not null) <> 2 then
    raise exception 'FAIL run log';
  end if;
  if pg_temp.user_row() <> current_setting('test.user_hash') then
    raise exception 'FAIL the member row changed';
  end if;

  -- A moderator-approved correction on D: name and closed status locked.
  update public.places set name = 'Hall D (corrected)', locked_fields = array['name', 'closed']
   where source = 'osm' and source_id = 'n9000000005';
end $$;

-- ---------------------------------------------------------------------------
-- 4. Runs 2 to 5: updates, locks, idempotent re-ingest, closure, reopen
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   integer := current_setting('test.t')::integer;
  v_r2  jsonb := jsonb_build_array(
                   pg_temp.r('n9000000001', 'Court A Renamed', -60.24, -150.24),
                   pg_temp.r('w9000000002', 'Park B', -60.26, -150.26),
                   pg_temp.r('n9000000005', 'Hall D new OSM name', -60.28, -150.28),
                   pg_temp.r('n9000000003', 'Court M from OSM', -60.221, -150.221));   -- C missing
  v_r4  jsonb := jsonb_build_array(
                   pg_temp.r('n9000000001', 'Court A Renamed', -60.24, -150.24),
                   pg_temp.r('w9000000002', 'Park B', -60.26, -150.26),
                   pg_temp.r('n9000000004', 'Pitch C', -60.27, -150.27),
                   pg_temp.r('n9000000003', 'Court M from OSM', -60.221, -150.221));   -- D missing
  v_res jsonb;
  v_h   text;
begin
  -- Run 2: A changes (its extra fields go, its name changes), D's locked name stays, C missed once.
  v_res := public.ingest_places(v_t, 'test-r2', v_r2);
  if (v_res ->> 'inserted')::integer <> 0 or (v_res ->> 'updated')::integer <> 1
     or (v_res ->> 'unchanged')::integer <> 3 then
    raise exception 'FAIL run 2 counts: %', v_res - 'skipped';
  end if;
  if (select name from public.places where source_id = 'n9000000001') <> 'Court A Renamed'
     or (select website from public.places where source_id = 'n9000000001') is not null then
    raise exception 'FAIL run 2 did not update A';
  end if;
  if (select name from public.places where source_id = 'n9000000005') <> 'Hall D (corrected)'
     or (select name from public.places where source_id = 'n9000000003') <> 'Corrected Court' then
    raise exception 'FAIL a locked name was overwritten';
  end if;
  v_res := public.finish_place_tile(v_t, 'test-r2', 4);
  if (v_res ->> 'previous_seen')::integer <> 5 or (v_res ->> 'seen')::integer <> 4
     or (v_res ->> 'missed')::integer <> 1 or (v_res ->> 'closed')::integer <> 0
     or (select status from public.places where source_id = 'n9000000004') <> 'active'
     or (select missed_runs from public.places where source_id = 'n9000000004') <> 1 then
    raise exception 'FAIL one miss must not close: %', v_res;
  end if;

  -- Run 3: the identical batch again. Nothing changes but the stamps; C is missed twice and closes.
  v_h := pg_temp.content();
  v_res := public.ingest_places(v_t, 'test-r3', v_r2);
  if (v_res ->> 'inserted')::integer <> 0 or (v_res ->> 'updated')::integer <> 0
     or (v_res ->> 'merged')::integer <> 0 or (v_res ->> 'unchanged')::integer <> 4 then
    raise exception 'FAIL identical re-ingest changed rows: %', v_res - 'skipped';
  end if;
  if pg_temp.content() <> v_h then
    raise exception 'FAIL identical re-ingest changed content';
  end if;
  v_res := public.finish_place_tile(v_t, 'test-r3', 4);
  if (v_res ->> 'closed')::integer <> 1 or (v_res ->> 'active')::integer <> 4
     or (select status from public.places where source_id = 'n9000000004') <> 'closed' then
    raise exception 'FAIL two misses did not close C: %', v_res;
  end if;

  -- Run 4: C is back (reopens); D is missed once.
  v_res := public.ingest_places(v_t, 'test-r4', v_r4);
  if (v_res ->> 'reopened')::integer <> 1 or (v_res ->> 'updated')::integer <> 1
     or (select status from public.places where source_id = 'n9000000004') <> 'active'
     or (select missed_runs from public.places where source_id = 'n9000000004') <> 0 then
    raise exception 'FAIL a closed row did not reopen: %', v_res - 'skipped';
  end if;
  v_res := public.finish_place_tile(v_t, 'test-r4', 4);
  if (v_res ->> 'missed')::integer <> 1 or (v_res ->> 'closed')::integer <> 0 then
    raise exception 'FAIL run 4 finish: %', v_res;
  end if;

  -- Run 5: D missed a second time, but its open status is locked.
  v_res := public.ingest_places(v_t, 'test-r5', v_r4);
  v_res := public.finish_place_tile(v_t, 'test-r5', 4);
  if (v_res ->> 'closed')::integer <> 0
     or (select status from public.places where source_id = 'n9000000005') <> 'active'
     or (select missed_runs from public.places where source_id = 'n9000000005') <> 2
     or (select name from public.places where source_id = 'n9000000005') <> 'Hall D (corrected)' then
    raise exception 'FAIL a closed lock did not hold: %', v_res;
  end if;

  if pg_temp.user_row() <> current_setting('test.user_hash') then
    raise exception 'FAIL the member row changed after five runs';
  end if;
  if (select status from public.places where id = current_setting('test.geo')::uuid) <> 'removed' then
    raise exception 'FAIL the merged geoapify row came back';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Edges
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   integer := current_setting('test.t')::integer;
  v_res jsonb;
  v_big jsonb;
begin
  -- A hidden row (moderation) is never rewritten or reopened.
  update public.places set status = 'hidden' where source_id = 'w9000000002';
  v_res := public.ingest_places(v_t, 'test-r6', jsonb_build_array(pg_temp.r('w9000000002', 'Park B again', -60.26, -150.26)));
  if coalesce((v_res -> 'skipped' ->> 'moderated')::integer, 0) <> 1
     or (select status from public.places where source_id = 'w9000000002') <> 'hidden'
     or (select name from public.places where source_id = 'w9000000002') <> 'Park B' then
    raise exception 'FAIL a hidden row was rewritten: %', v_res;
  end if;
  v_res := public.finish_place_tile(v_t, 'test-r6', 1);
  if (v_res ->> 'closed')::integer <> 0 then
    raise exception 'FAIL run 6 closed a row seen in run 5: %', v_res;
  end if;

  -- Geoapify for an element that already has an OSM row adds nothing.
  v_res := public.ingest_places(v_t, 'test-g2', jsonb_build_array(
             pg_temp.r('gx-test-2', 'Geo dup', -60.24, -150.24, '{"osm_ref": "n9000000001"}')), 'geoapify');
  if coalesce((v_res -> 'skipped' ->> 'osm_row_exists')::integer, 0) <> 1
     or exists (select 1 from public.places where source_id = 'gx-test-2') then
    raise exception 'FAIL geoapify duplicated an OSM element: %', v_res;
  end if;

  begin
    perform public.finish_place_tile(v_t, 'test-empty', 0);
    raise exception 'FAIL empty_run not raised';
  exception when check_violation then
    if sqlerrm <> 'empty_run' then raise; end if;
  end;
  begin
    perform public.ingest_places(v_t + 1, 'test-x', '[]'::jsonb);
    raise exception 'FAIL tile_unknown not raised';
  exception when no_data_found then
    if sqlerrm <> 'tile_unknown' then raise; end if;
  end;
  select jsonb_agg(to_jsonb(g)) into v_big from generate_series(1, 2001) as g;
  begin
    perform public.ingest_places(v_t, 'test-x', v_big);
    raise exception 'FAIL batch_too_large not raised';
  exception when check_violation then
    if sqlerrm <> 'batch_too_large' then raise; end if;
  end;
  begin
    perform public.ingest_places(v_t, 'test-x', '[]'::jsonb, 'user');
    raise exception 'FAIL source_invalid not raised';
  exception when check_violation then
    if sqlerrm <> 'source_invalid' then raise; end if;
  end;

  -- The tiles queue sees the fixture tile only as a refresh candidate when it is due.
  if exists (select 1 from jsonb_array_elements(public.place_tiles_queue(array['refresh'], 100)) e
              where (e ->> 'id')::integer = v_t) then
    raise exception 'FAIL a freshly run tile is due a refresh';
  end if;
  update public.place_tiles set osm_run_at = now() - interval '7 days' where id = v_t;
  if not exists (select 1 from jsonb_array_elements(public.place_tiles_queue(array['refresh'], 100)) e
                  where (e ->> 'id')::integer = v_t and (e ->> 'west')::double precision = -150.5
                    and (e ->> 'north')::double precision = -60.0) then
    raise exception 'FAIL the tiles queue missed a due tile or its box';
  end if;
end $$;

select 'places_ingest: all assertions passed' as result;

rollback;
