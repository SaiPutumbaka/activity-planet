-- ============================================================================
-- Staging check for migration 20261208000100_place_files_fixes.sql (migration
-- 44). One transaction: sets up throwaway tiles and places, asserts with DO
-- blocks that raise on failure, then rolls everything back. Prints pass/fail
-- only (no user rows; the test places are invented).
-- Run as the staging_file of a staging_only migrate.yml run.
--
-- Tile T: Reykjavik, 222076 (lat 64.0 to 64.5, lng -22.0 to -21.5), with OSM
-- places A, B, C in the view (-21.95 to -21.85, 64.10 to 64.20) and E outside
-- it, last changed two hours ago; the "file" is built one hour ago.
-- Tile U: Ushuaia, Geoapify rows after the tile's OSM run.
-- ============================================================================
begin;

create or replace function pg_temp.pt(lng double precision, lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(lng, lat), 4326)::extensions.geography
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 40] then
    raise exception 'FAIL schema_version is older than 2.40';
  end if;
  if not has_function_privilege('anon', 'public.place_files_in_view(extensions.geometry,extensions.geometry)', 'execute')
     or not has_function_privilege('authenticated', 'public.place_files_in_view(extensions.geometry,extensions.geometry)', 'execute')
     or not (select p.prosecdef from pg_proc p where p.oid = 'public.place_files_in_view(extensions.geometry,extensions.geometry)'::regprocedure)
     or (select p.provolatile from pg_proc p where p.oid = 'public.place_files_in_view(extensions.geometry,extensions.geometry)'::regprocedure) <> 's' then
    raise exception 'FAIL place_files_in_view grants, security or volatility';
  end if;
  if has_function_privilege('anon', 'public.places_fill_supersede()', 'execute')
     or has_function_privilege('authenticated', 'public.places_fill_supersede()', 'execute')
     or not (select p.prosecdef from pg_proc p where p.oid = 'public.places_fill_supersede()'::regprocedure) then
    raise exception 'FAIL places_fill_supersede grants or security';
  end if;
  if exists (select 1 from public.place_tiles where id in (222076, public.place_tile_id(-54.80, -68.30))) then
    raise exception 'FAIL a test tile already exists on staging';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Setup: tile T with a published file built an hour ago
-- ---------------------------------------------------------------------------
do $$
declare
  v_rule smallint;
  r      jsonb;
begin
  select r.rule_id into v_rule
    from public.hubs h
    join public.hub_place_rules r on r.hub_id = h.id
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.place_mode = 'specific' and not c.is_sensitive
   order by h.slug, r.rule_id limit 1;
  if v_rule is null then raise exception 'FAIL no specific hub with a rule'; end if;

  update public.meta set value = 'on' where key = 'places_files';
  delete from public.meta where key = 'places_rules_file';
  insert into public.place_tiles (id, status, osm_run_at) values (222076, 'active', now() - interval '90 minutes');
  insert into public.places (source, source_id, osm_ref, name, kind, rule_ids, location, is_public, status,
                             attribution, updated_at)
  values ('osm', 'n9000000001', 'n9000000001', 'PFX Alpha', 'court_field', array[v_rule], pg_temp.pt(-21.90, 64.14),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours'),
         ('osm', 'n9000000002', 'n9000000002', 'PFX Bravo', 'court_field', array[v_rule], pg_temp.pt(-21.91, 64.15),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours'),
         ('osm', 'w9000000003', 'w9000000003', 'PFX Charlie', 'court_field', array[v_rule], pg_temp.pt(-21.92, 64.13),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours'),
         ('osm', 'n9000000005', 'n9000000005', 'PFX Echo', 'court_field', array[v_rule], pg_temp.pt(-21.60, 64.45),
          true, 'active', '© OpenStreetMap contributors', now() - interval '2 hours');
  if (select count(*) from public.places where tile_id = 222076) <> 4 then
    raise exception 'FAIL setup places are not in tile 222076';
  end if;
  r := public.place_files_record(jsonb_build_object('published', true,
         'rules', jsonb_build_object('path', 'rules/v1.0123456789abcdef.json.gz', 'sha256', repeat('a', 64),
                                     'bytes', 1234, 'rules_version', 1),
         'tiles', jsonb_build_array(jsonb_build_object('id', 222076,
                    'path', 'places/v1/222076.00000000000000aa.json.gz', 'sha256', repeat('b', 64),
                    'bytes', 900, 'count', 4, 'rules_version', 1, 'built_from', now() - interval '1 hour'))));
  if (r ->> 'set')::integer <> 1 then raise exception 'FAIL setup record'; end if;
end $$;

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v jsonb := public.place_files_in_view(extensions.ST_MakeEnvelope(-21.95, 64.10, -21.85, 64.20, 4326), null);
begin
  if v is null or v -> 'tiles' <> '[[222076, "places/v1/222076.00000000000000aa.json.gz", 4]]'::jsonb
     or jsonb_array_length(v -> 'hidden') <> 0 then
    raise exception 'FAIL the file before any change';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. Changes after the build: all count as hidden
-- ---------------------------------------------------------------------------
-- A: an OSM refresh renames it (still active, no lock).
update public.places set name = 'PFX Alpha Court' where osm_ref = 'n9000000001';
-- B: a moderator moves it outside the view (location locked).
update public.places set location = pg_temp.pt(-21.60, 64.40), locked_fields = array['location']
 where osm_ref = 'n9000000002';
-- C: a moderator hides it.
update public.places set status = 'hidden' where osm_ref = 'w9000000003';
-- E: renamed, outside the view, no lock.
update public.places set name = 'PFX Echo Court' where osm_ref = 'n9000000005';

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v jsonb := public.place_files_in_view(extensions.ST_MakeEnvelope(-21.95, 64.10, -21.85, 64.20, 4326), null);
begin
  if not (v -> 'hidden') @> '["n9000000001"]'::jsonb then
    raise exception 'FAIL an active row changed after the build is not hidden';
  end if;
  if not (v -> 'hidden') @> '["n9000000002"]'::jsonb then
    raise exception 'FAIL a row moved out of the view is not hidden';
  end if;
  if not (v -> 'hidden') @> '["w9000000003"]'::jsonb then
    raise exception 'FAIL a hidden row is not hidden';
  end if;
  if (v -> 'hidden') @> '["n9000000005"]'::jsonb or jsonb_array_length(v -> 'hidden') <> 3 then
    raise exception 'FAIL hidden holds rows outside the view';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. A retired tile offers no file; idle does
-- ---------------------------------------------------------------------------
do $$
begin
  update public.place_tiles set status = 'retired' where id = 222076;
  if public.place_files_in_view(public.place_tile_bbox(222076), null) is not null then
    raise exception 'FAIL a retired tile still offers its file';
  end if;
  update public.place_tiles set status = 'idle', idle_since = now() where id = 222076;
  if public.place_files_in_view(public.place_tile_bbox(222076), null) is null then
    raise exception 'FAIL an idle tile does not offer its file';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. places_fill_supersede keeps a hidden, unmerged Geoapify row
-- ---------------------------------------------------------------------------
do $$
declare
  tu     integer := public.place_tile_id(-54.80, -68.30);
  v_kind text;
  v_osm  uuid;
  v_n    integer;
begin
  select k.slug into v_kind from public.place_kinds k order by k.slug limit 1;
  insert into public.place_tiles (id, status, demand, osm_run_at, geoapify_run_at)
  values (tu, 'active', 1, now(), now() - interval '1 day');
  insert into public.places (source, source_id, osm_ref, name, kind, location, is_public, status, attribution)
  values ('osm', 'w9000000011', 'w9000000011', 'PFX Osm', v_kind, pg_temp.pt(-68.30, -54.80), true, 'active',
          '© OpenStreetMap contributors')
  returning id into v_osm;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, merged_into)
  values ('geoapify', 'pfx-g-hidden', 'PFX Hidden', v_kind, pg_temp.pt(-68.31, -54.81), true, 'hidden',
          'Powered by Geoapify, © OpenStreetMap contributors', null),
         ('geoapify', 'pfx-g-removed', 'PFX Removed', v_kind, pg_temp.pt(-68.32, -54.82), true, 'removed',
          'Powered by Geoapify, © OpenStreetMap contributors', null),
         ('geoapify', 'pfx-g-merged', 'PFX Merged', v_kind, pg_temp.pt(-68.30, -54.80), true, 'removed',
          'Powered by Geoapify, © OpenStreetMap contributors', v_osm),
         ('geoapify', 'pfx-g-active', 'PFX Active', v_kind, pg_temp.pt(-68.33, -54.83), true, 'active',
          'Powered by Geoapify, © OpenStreetMap contributors', null);
  if (select count(*) from public.places where tile_id = tu and source = 'geoapify') <> 4 then
    raise exception 'FAIL setup Geoapify rows are not in the test tile';
  end if;

  v_n := public.places_fill_supersede();
  if not exists (select 1 from public.places where source = 'geoapify' and source_id = 'pfx-g-hidden') then
    raise exception 'FAIL a hidden, unmerged Geoapify row was deleted';
  end if;
  if not exists (select 1 from public.places where source = 'geoapify' and source_id = 'pfx-g-removed') then
    raise exception 'FAIL a removed, unmerged Geoapify row was deleted';
  end if;
  if exists (select 1 from public.places where source = 'geoapify' and source_id in ('pfx-g-merged', 'pfx-g-active')) then
    raise exception 'FAIL a merged or active Geoapify row was kept';
  end if;
  if v_n < 2 then
    raise exception 'FAIL supersede deleted fewer rows than expected';
  end if;
  if (select row_count from public.place_tiles where id = tu)
     <> (select count(*) from public.places where tile_id = tu and status = 'active' and is_public) then
    raise exception 'FAIL row_count not recomputed after supersede';
  end if;
end $$;

select 'place_files_fixes: all assertions passed' as result;
rollback;
