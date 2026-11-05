-- ============================================================================
-- Staging check for migration 20261206000100_place_files.sql (D-042 slices 3
-- to 5). One transaction: sets up a throwaway tile with three OSM places,
-- asserts with DO blocks that raise on failure, then rolls everything back.
-- Prints pass/fail only (no user rows; the test places are invented).
-- Run as the staging_file of a staging_only migrate.yml run.
--
-- Tile T: Reykjavik, 222076 (lat 64.0 to 64.5, lng -22.0 to -21.5), which
-- must not exist on staging. Places A, B, C: OSM rows of one specific hub's
-- rule, last changed two hours ago; the "file" is built one hour ago.
-- ============================================================================
begin;

create or replace function pg_temp.pt(lng double precision, lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography
$$;

-- ---------------------------------------------------------------------------
-- 1. Static: version, columns, signatures, grants, security
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 38] then
    raise exception 'FAIL schema_version is older than 2.38';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'place_tiles'
         and column_name in ('file_path', 'file_sha256', 'file_bytes', 'file_count', 'file_rules_version',
                             'file_built_from', 'file_built_at', 'file_published_at')) <> 8 then
    raise exception 'FAIL place_tiles file columns';
  end if;
  if not exists (select 1 from public.meta where key = 'places_files' and value in ('on', 'off')) then
    raise exception 'FAIL meta places_files is missing';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'place_tiles' and data_type = 'uuid') then
    raise exception 'FAIL place_tiles has a uuid column';
  end if;
  if to_regprocedure('public.map_in_view(double precision,double precision,double precision,double precision,uuid[],text[],timestamptz,timestamptz,boolean,integer)') is not null
     or to_regprocedure('public.places_in_view(double precision,double precision,double precision,double precision,uuid[],boolean,text[],text,integer)') is not null then
    raise exception 'FAIL an old map_in_view or places_in_view signature is still there';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('map_in_view', 'places_in_view')) <> 2 then
    raise exception 'FAIL map_in_view or places_in_view has an overload';
  end if;
  foreach f in array array['public.place_files_queue(integer,boolean,integer[])',
                           'public.place_tile_file_page(integer,text,integer)',
                           'public.place_files_record(jsonb)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL grants of %', f;
    end if;
  end loop;
  foreach f in array array['public.place_files_in_view(extensions.geometry,extensions.geometry)',
                           'public.place_id_by_osm_ref(text)',
                           'public.map_in_view(double precision,double precision,double precision,double precision,uuid[],text[],timestamptz,timestamptz,boolean,integer,boolean)',
                           'public.places_in_view(double precision,double precision,double precision,double precision,uuid[],boolean,text[],text,integer,integer[],timestamptz)'] loop
    if not has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL grants of %', f;
    end if;
  end loop;
  if not (select p.prosecdef from pg_proc p where p.oid = 'public.place_files_in_view(extensions.geometry,extensions.geometry)'::regprocedure)
     or (select p.prosecdef from pg_proc p where p.oid = 'public.place_id_by_osm_ref(text)'::regprocedure)
     or (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'map_in_view')
     or (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'places_in_view')
     or (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'map_in_view') <> 's' then
    raise exception 'FAIL security or volatility of the read functions';
  end if;
  if exists (select 1 from public.place_tiles where id = 222076) then
    raise exception 'FAIL test tile 222076 already exists on staging';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_hub  uuid;
  v_rule smallint;
begin
  select h.id, r.rule_id into v_hub, v_rule
    from public.hubs h
    join public.hub_place_rules r on r.hub_id = h.id
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.place_mode = 'specific' and not c.is_sensitive
   order by h.slug, r.rule_id limit 1;
  if v_hub is null then raise exception 'FAIL no specific hub with a rule'; end if;
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.rule', v_rule::text, true);

  update public.meta set value = 'on' where key = 'places_files';
  insert into public.place_tiles (id, status, osm_run_at) values (222076, 'active', now() - interval '90 minutes');
  insert into public.places (source, source_id, osm_ref, name, kind, rule_ids, location, is_public, status,
                             attribution, updated_at)
  values ('osm', 'n9000000001', 'n9000000001', 'PF Alpha', 'court_field', array[v_rule], pg_temp.pt(-21.90, 64.14),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours'),
         ('osm', 'n9000000002', 'n9000000002', 'PF Bravo', 'court_field', array[v_rule], pg_temp.pt(-21.91, 64.15),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours'),
         ('osm', 'w9000000003', 'w9000000003', 'PF Charlie', 'court_field', array[v_rule], pg_temp.pt(-21.92, 64.13),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours');
  if (select count(*) from public.places where tile_id = 222076) <> 3 then
    raise exception 'FAIL setup places are not in tile 222076';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Queue and pages
-- ---------------------------------------------------------------------------
do $$
declare
  q  jsonb;
  p1 jsonb;
  p2 jsonb;
begin
  q := public.place_files_queue(500);
  if not exists (select 1 from jsonb_array_elements(q -> 'build') e where (e ->> 'id')::integer = 222076) then
    raise exception 'FAIL a tile with no file is not in the build queue';
  end if;
  if jsonb_array_length(q -> 'hubs') = 0
     or not exists (select 1 from jsonb_array_elements(q -> 'hubs') h
                     where h ->> 0 = current_setting('test.hub')
                       and (h -> 5) @> to_jsonb(current_setting('test.rule')::integer)) then
    raise exception 'FAIL the rules table misses the test hub';
  end if;
  if (q ->> 'rules_version')::integer < 1 then raise exception 'FAIL rules_version'; end if;
  q := public.place_files_queue(10, false, array[222076]);
  if jsonb_array_length(q -> 'build') <> 1 then raise exception 'FAIL named tiles queue'; end if;
  begin
    perform public.place_files_queue(10, false, array[300000]);
    raise exception 'FAIL a bad tile id was accepted';
  exception when check_violation then null;
  end;

  p1 := public.place_tile_file_page(222076, null, 2);
  if jsonb_array_length(p1 -> 'rows') <> 2 or p1 ->> 'next' <> 'n9000000002'
     or p1 -> 'rows' -> 0 ->> 0 <> 'n9000000001' or jsonb_array_length(p1 -> 'rows' -> 0) <> 11
     or (p1 -> 'rows' -> 0 ->> 1)::double precision <> -21.9 then
    raise exception 'FAIL first file page';
  end if;
  p2 := public.place_tile_file_page(222076, p1 ->> 'next', 2);
  if jsonb_array_length(p2 -> 'rows') <> 1 or p2 -> 'rows' -> 0 ->> 0 <> 'w9000000003'
     or p2 ->> 'next' is not null then
    raise exception 'FAIL last file page';
  end if;
  if (p1::text || p2::text) ~ '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' then
    raise exception 'FAIL a file page holds an id';
  end if;
  begin
    perform public.place_tile_file_page(222076, 'x; drop', 2);
    raise exception 'FAIL a bad cursor was accepted';
  exception when check_violation then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Record: a staging build is never offered; a published one is
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
begin
  -- Start from no rules file so the result does not depend on staging's state.
  delete from public.meta where key = 'places_rules_file';
  r := public.place_files_record(jsonb_build_object('published', false,
         'rules', jsonb_build_object('path', 'rules/v1.0123456789abcdef.json.gz', 'sha256', repeat('a', 64),
                                     'bytes', 1234, 'rules_version', 1),
         'tiles', jsonb_build_array(jsonb_build_object('id', 222076,
                    'path', 'places/v1/222076.00000000000000aa.json.gz', 'sha256', repeat('b', 64),
                    'bytes', 900, 'count', 3, 'rules_version', 1, 'built_from', now() - interval '1 hour'))));
  if (r ->> 'set')::integer <> 1 then raise exception 'FAIL staging record count'; end if;
  if (select file_published_at is not null or file_count <> 3 from public.place_tiles where id = 222076) then
    raise exception 'FAIL staging record fields';
  end if;
  if public.place_files_in_view(public.place_tile_bbox(222076), null) is not null then
    raise exception 'FAIL an unpublished build was offered';
  end if;

  r := public.place_files_record(jsonb_build_object('published', true,
         'rules', jsonb_build_object('path', 'rules/v1.0123456789abcdef.json.gz', 'sha256', repeat('a', 64),
                                     'bytes', 1234, 'rules_version', 1),
         'tiles', jsonb_build_array(jsonb_build_object('id', 222076,
                    'path', 'places/v1/222076.00000000000000aa.json.gz', 'sha256', repeat('b', 64),
                    'bytes', 900, 'count', 3, 'rules_version', 1, 'built_from', now() - interval '1 hour'))));
  if (select file_published_at is null from public.place_tiles where id = 222076) then
    raise exception 'FAIL published record';
  end if;
  -- A later staging build leaves the published file alone.
  r := public.place_files_record(jsonb_build_object('published', false,
         'rules', jsonb_build_object('path', 'rules/v1.fedcba9876543210.json.gz', 'sha256', repeat('c', 64),
                                     'bytes', 1, 'rules_version', 1),
         'tiles', jsonb_build_array(jsonb_build_object('id', 222076,
                    'path', 'places/v1/222076.00000000000000bb.json.gz', 'sha256', repeat('d', 64),
                    'bytes', 1, 'count', 1, 'rules_version', 1, 'built_from', now()))));
  if (r ->> 'set')::integer <> 0
     or (select file_path from public.place_tiles where id = 222076) <> 'places/v1/222076.00000000000000aa.json.gz'
     or (select value::jsonb ->> 'path' from public.meta where key = 'places_rules_file') <> 'rules/v1.0123456789abcdef.json.gz' then
    raise exception 'FAIL a staging build replaced a published file';
  end if;
  -- Validation
  begin
    perform public.place_files_record(jsonb_build_object('published', true,
      'tiles', jsonb_build_array(jsonb_build_object('id', 222076, 'path', 'places/v1/999.00000000000000aa.json.gz',
        'sha256', repeat('b', 64), 'bytes', 9, 'count', 3, 'rules_version', 1, 'built_from', now()))));
    raise exception 'FAIL a path for another tile was accepted';
  exception when check_violation then null;
  end;
  begin
    perform public.place_files_record(jsonb_build_object('published', true,
      'rules', jsonb_build_object('path', '../etc', 'sha256', repeat('a', 64), 'bytes', 1, 'rules_version', 1)));
    raise exception 'FAIL a bad rules path was accepted';
  exception when check_violation then null;
  end;
  if exists (select 1 from jsonb_array_elements(public.place_files_queue(500) -> 'build') e
              where (e ->> 'id')::integer = 222076) then
    raise exception 'FAIL a fresh file is still queued';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. map_in_view as anon: files on and off
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v   jsonb;
  hub uuid := current_setting('test.hub')::uuid;
begin
  -- Without p_files: exactly as before (eight elements, all three rows).
  v := public.map_in_view(-22.0, 64.1, -21.85, 64.2, array[hub], array['places']);
  if v -> 'place_files' <> 'null'::jsonb
     or (select count(*) from jsonb_array_elements(v -> 'places') e where e ->> 6 like 'PF %') <> 3
     or exists (select 1 from jsonb_array_elements(v -> 'places') e where jsonb_array_length(e) <> 8) then
    raise exception 'FAIL map_in_view without p_files';
  end if;
  -- With p_files: the tile's OSM rows come from the file.
  v := public.map_in_view(p_west => -22.0, p_south => 64.1, p_east => -21.85, p_north => 64.2,
                          p_hub_ids => array[hub], p_layers => array['places'], p_files => true);
  if v -> 'place_files' ->> 'rules' <> 'rules/v1.0123456789abcdef.json.gz'
     or v -> 'place_files' -> 'tiles' <> '[[222076, "places/v1/222076.00000000000000aa.json.gz", 3]]'::jsonb
     or (v -> 'place_files' ->> 'sel')::integer <> 1 or (v -> 'place_files' ->> 'all')::boolean
     or v -> 'place_files' ? 'since'
     or jsonb_array_length(v -> 'place_files' -> 'hidden') <> 0 then
    raise exception 'FAIL place_files in map_in_view';
  end if;
  if exists (select 1 from jsonb_array_elements(v -> 'places') e where e ->> 8 like '_900000000_') then
    raise exception 'FAIL file rows also came from the database';
  end if;
  -- Signed out with every specific hub: all is true.
  v := public.map_in_view(p_west => -22.0, p_south => 64.1, p_east => -21.85, p_north => 64.2,
                          p_layers => array['places'], p_files => true);
  if not (v -> 'place_files' ->> 'all')::boolean or (v -> 'place_files' ->> 'sel')::integer <> 0 then
    raise exception 'FAIL place_files all for every specific hub';
  end if;
  -- Too big a view: no files, zoom_in as before.
  v := public.map_in_view(p_west => -23.0, p_south => 64.0, p_east => -21.0, p_north => 64.5,
                          p_layers => array['places'], p_files => true);
  if v -> 'place_files' <> 'null'::jsonb or not (v ->> 'zoom_in')::boolean then
    raise exception 'FAIL zoom_in view with p_files';
  end if;
end $$;
reset role;

-- A moderator hides B and corrects C after the file was built.
update public.places set status = 'hidden' where osm_ref = 'n9000000002';
update public.places set name = 'PF Charlie Court', locked_fields = array['name'] where osm_ref = 'w9000000003';

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v   jsonb;
  hub uuid := current_setting('test.hub')::uuid;
begin
  v := public.map_in_view(p_west => -22.0, p_south => 64.1, p_east => -21.85, p_north => 64.2,
                          p_hub_ids => array[hub], p_layers => array['places'], p_files => true);
  if v -> 'place_files' -> 'hidden' <> '["n9000000002"]'::jsonb then
    raise exception 'FAIL hidden refs after the build';
  end if;
  if (select count(*) from jsonb_array_elements(v -> 'places') e where e ->> 8 like '_900000000_') <> 1
     or not exists (select 1 from jsonb_array_elements(v -> 'places') e
                     where e ->> 8 = 'w9000000003' and e ->> 6 = 'PF Charlie Court') then
    raise exception 'FAIL the corrected row is not in the overlay';
  end if;
  if public.place_id_by_osm_ref('n9000000001') is null or public.place_id_by_osm_ref('n9000000002') is not null
     or public.place_id_by_osm_ref('bad') is not null then
    raise exception 'FAIL place_id_by_osm_ref';
  end if;
end $$;
reset role;

-- The server switch off: everything from the database again.
update public.meta set value = 'off' where key = 'places_files';
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v jsonb;
begin
  v := public.map_in_view(p_west => -22.0, p_south => 64.1, p_east => -21.85, p_north => 64.2,
                          p_hub_ids => array[current_setting('test.hub')::uuid], p_layers => array['places'], p_files => true);
  if v -> 'place_files' <> 'null'::jsonb
     or (select count(*) from jsonb_array_elements(v -> 'places') e where e ->> 6 like 'PF %') <> 2 then
    raise exception 'FAIL the places_files switch';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 6. Rebuild after an OSM run, drop after 180 idle days, clear
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
begin
  update public.place_tiles set osm_run_at = now() where id = 222076;
  if not exists (select 1 from jsonb_array_elements(public.place_files_queue(500) -> 'build') e
                  where (e ->> 'id')::integer = 222076) then
    raise exception 'FAIL a tile with a newer OSM run is not queued';
  end if;
  update public.place_tiles set status = 'retired', idle_since = now() - interval '200 days' where id = 222076;
  if not (public.place_files_queue(500) -> 'drop') @> '[222076]'::jsonb then
    raise exception 'FAIL a long-idle tile file is not dropped';
  end if;
  r := public.place_files_record(jsonb_build_object('published', true,
         'tiles', jsonb_build_array(jsonb_build_object('id', 222076, 'clear', true))));
  if (r ->> 'cleared')::integer <> 1
     or (select file_path is not null or file_published_at is not null from public.place_tiles where id = 222076) then
    raise exception 'FAIL clear';
  end if;
end $$;

select 'place_files: all assertions passed' as result;
rollback;
