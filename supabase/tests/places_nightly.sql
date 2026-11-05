-- ============================================================================
-- Staging check for migration 20261205000100_places_nightly.sql (D-042
-- slice 2). One transaction: sets up throwaway tiles, asserts with DO blocks
-- that raise on failure, then rolls everything back. Prints pass/fail only
-- (no user rows, no demand counts).
-- Run as the staging_file of a staging_only migrate.yml run.
--
-- Tiles (none may exist on staging): A Nairobi (wanted), B Wellington
-- (wanted), C Montevideo (filling), D Dakar (active, OSM run 2 days ago).
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static: version, column, constraint, trigger, grants, security
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 37] then
    raise exception 'FAIL schema_version is older than 2.37';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'place_tiles' and column_name = 'queue_reason') then
    raise exception 'FAIL place_tiles.queue_reason is missing';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'place_tiles_clear_queue_reason'
                    and tgrelid = 'public.place_tiles'::regclass) then
    raise exception 'FAIL the clear-reason trigger is missing';
  end if;
  if has_function_privilege('authenticated', 'public.place_tiles_set_queue_reasons(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.place_tiles_set_queue_reasons(jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.place_tiles_set_queue_reasons(jsonb)', 'execute') then
    raise exception 'FAIL place_tiles_set_queue_reasons grants';
  end if;
  if has_function_privilege('authenticated', 'public.place_tiles_queue(text[],integer)', 'execute')
     or has_function_privilege('anon', 'public.place_tiles_queue(text[],integer)', 'execute')
     or not has_function_privilege('service_role', 'public.place_tiles_queue(text[],integer)', 'execute') then
    raise exception 'FAIL place_tiles_queue grants';
  end if;
  if not has_function_privilege('anon', 'public.place_tiles_mapping_reason_in_view(extensions.geometry,extensions.geometry)', 'execute')
     or not has_function_privilege('authenticated', 'public.place_tiles_mapping_reason_in_view(extensions.geometry,extensions.geometry)', 'execute') then
    raise exception 'FAIL place_tiles_mapping_reason_in_view grants';
  end if;
  if not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'place_tiles_mapping_reason_in_view')
     or (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'map_in_view')
     or (select p.provolatile from pg_proc p join pg_namespace n on n.oid = p.pronamespace
          where n.nspname = 'public' and p.proname = 'map_in_view') <> 's' then
    raise exception 'FAIL security or volatility of the read functions';
  end if;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.place_tiles'::regclass)
     or has_table_privilege('anon', 'public.place_tiles', 'select')
     or has_column_privilege('authenticated', 'public.place_tiles', 'queue_reason', 'update') then
    raise exception 'FAIL place_tiles access (RLS, anon read, member update)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_ids integer[] := array[public.place_tile_id(-1.25, 36.75), public.place_tile_id(-41.25, 174.75),
                           public.place_tile_id(-34.75, -56.25), public.place_tile_id(14.75, -17.25)];
begin
  if exists (select 1 from public.place_tiles where id = any (v_ids)) then
    raise exception 'setup: a test tile already exists on staging';
  end if;
  insert into public.place_tiles (id, status, demand) values
    (v_ids[1], 'wanted', 3), (v_ids[2], 'wanted', 1), (v_ids[3], 'filling', 0);
  insert into public.place_tiles (id, status, demand, osm_run_at) values
    (v_ids[4], 'active', 5, now() - interval '2 days');
end $$;

-- ---------------------------------------------------------------------------
-- 3. place_tiles_set_queue_reasons and the constraint
-- ---------------------------------------------------------------------------
do $$
declare
  a integer := public.place_tile_id(-1.25, 36.75);
  b integer := public.place_tile_id(-41.25, 174.75);
  c integer := public.place_tile_id(-34.75, -56.25);
  d integer := public.place_tile_id(14.75, -17.25);
  v_r jsonb;
  v_ok boolean;
begin
  v_r := public.place_tiles_set_queue_reasons(jsonb_build_object(
           a::text, 'budget', b::text, 'extract_too_big', c::text, 'size_cap', d::text, 'budget'));
  if (v_r ->> 'set')::integer <> 3 or (v_r ->> 'unchanged')::integer <> 1 or (v_r ->> 'tiles')::integer <> 4 then
    raise exception 'FAIL set_queue_reasons counts: %', v_r;
  end if;
  if (select queue_reason from public.place_tiles where id = d) is not null then
    raise exception 'FAIL an active tile got a queue reason';
  end if;
  if (select queue_reason from public.place_tiles where id = c) is distinct from 'size_cap' then
    raise exception 'FAIL a filling tile did not get its reason';
  end if;
  -- The same call again changes nothing.
  v_r := public.place_tiles_set_queue_reasons(jsonb_build_object(a::text, 'budget'));
  if (v_r ->> 'unchanged')::integer <> 1 then
    raise exception 'FAIL a repeated reason was counted as a change';
  end if;

  foreach v_r in array array['[]'::jsonb, '{"abc": "budget"}'::jsonb, '{"1": "nope"}'::jsonb,
                             '{"259200": "budget"}'::jsonb, '{"1": 3}'::jsonb] loop
    v_ok := false;
    begin
      perform public.place_tiles_set_queue_reasons(v_r);
    exception when check_violation then v_ok := true;
    end;
    if not v_ok then
      raise exception 'FAIL set_queue_reasons accepted bad input';
    end if;
  end loop;

  v_ok := false;
  begin
    update public.place_tiles set queue_reason = 'tired' where id = a;
  exception when check_violation then v_ok := true;
  end;
  if not v_ok then
    raise exception 'FAIL the queue_reason constraint accepted an unknown reason';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. place_tiles_queue: filling is queued, no-run tiles first, reason shown
-- ---------------------------------------------------------------------------
do $$
declare
  c integer := public.place_tile_id(-34.75, -56.25);
  d integer := public.place_tile_id(14.75, -17.25);
  v_q jsonb := public.place_tiles_queue(array['wanted'], 100);
  v_e jsonb;
begin
  select e into v_e from jsonb_array_elements(v_q) e where (e ->> 'id')::integer = c;
  if v_e is null then
    raise exception 'FAIL a filling tile is not in the wanted queue';
  end if;
  if v_e ->> 'queue_reason' is distinct from 'size_cap' then
    raise exception 'FAIL the queue does not carry queue_reason';
  end if;
  if exists (select 1 from jsonb_array_elements(v_q) e where (e ->> 'id')::integer = d) then
    raise exception 'FAIL an active tile is in the wanted queue';
  end if;
  -- With refresh: tiles without an OSM run come before refreshes, whatever the demand.
  update public.place_tiles set osm_run_at = now() - interval '8 days' where id = d;
  v_q := public.place_tiles_queue(array['wanted', 'refresh'], 100);
  if exists (
       select 1
         from jsonb_array_elements(v_q) with ordinality x(e, o)
         join jsonb_array_elements(v_q) with ordinality y(e, o) on y.o > x.o
        where x.e ->> 'osm_run_at' is not null and y.e ->> 'osm_run_at' is null) then
    raise exception 'FAIL a refresh is ordered before a tile with no OSM run';
  end if;
  if not exists (select 1 from jsonb_array_elements(v_q) e where (e ->> 'id')::integer = d) then
    raise exception 'FAIL a due refresh is missing from the queue';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. place_tiles_mapping_reason_in_view
-- ---------------------------------------------------------------------------
do $$
declare
  a integer := public.place_tile_id(-1.25, 36.75);
  b integer := public.place_tile_id(-41.25, 174.75);
  c integer := public.place_tile_id(-34.75, -56.25);
  d integer := public.place_tile_id(14.75, -17.25);
  ea extensions.geometry := public.place_tile_bbox(a);
  eb extensions.geometry := public.place_tile_bbox(b);
  ec extensions.geometry := public.place_tile_bbox(c);
  ed extensions.geometry := public.place_tile_bbox(d);
begin
  if public.place_tiles_mapping_reason_in_view(ea, ea) is distinct from 'budget'
     or public.place_tiles_mapping_reason_in_view(eb, eb) is distinct from 'extract_too_big'
     or public.place_tiles_mapping_reason_in_view(ec, ec) is distinct from 'size_cap' then
    raise exception 'FAIL mapping reason per tile';
  end if;
  if public.place_tiles_mapping_reason_in_view(ea, eb) is distinct from 'budget'
     or public.place_tiles_mapping_reason_in_view(eb, ec) is distinct from 'size_cap' then
    raise exception 'FAIL the mildest reason does not win';
  end if;
  if public.place_tiles_mapping_reason_in_view(ed, ed) is not null then
    raise exception 'FAIL an active tile gave a mapping reason';
  end if;
  perform public.place_tiles_set_queue_reasons(jsonb_build_object(a::text, null));
  if public.place_tiles_mapping_reason_in_view(ea, eb) is not null then
    raise exception 'FAIL a tile due tonight did not clear the reason';
  end if;
  if not public.place_tiles_mapping_in_view(ea, ea) then
    raise exception 'FAIL the cleared tile is no longer mapping';
  end if;
  -- The trigger: leaving wanted clears the reason.
  update public.place_tiles set status = 'active', osm_run_at = now() where id = b;
  if (select queue_reason from public.place_tiles where id = b) is not null then
    raise exception 'FAIL an active tile kept its queue reason';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. map_in_view carries mapping_reason (as anon and as a member)
-- ---------------------------------------------------------------------------
set local role anon;
do $$
declare
  v jsonb;
begin
  -- Montevideo tile (filling, size_cap): a 0.3 x 0.3 view inside it.
  v := public.map_in_view(-56.4, -34.9, -56.1, -34.6, null, array['places']);
  if not coalesce((v ->> 'mapping')::boolean, false) or v ->> 'mapping_reason' is distinct from 'size_cap' then
    raise exception 'FAIL map_in_view mapping_reason for a queued tile';
  end if;
  -- Nairobi tile (wanted, due tonight): mapping, no reason.
  v := public.map_in_view(36.6, -1.4, 36.9, -1.1, null, array['places']);
  if not coalesce((v ->> 'mapping')::boolean, false) or v -> 'mapping_reason' <> 'null'::jsonb then
    raise exception 'FAIL map_in_view for a tile due tonight';
  end if;
  -- Dakar tile (active): not mapping, no reason.
  v := public.map_in_view(-17.4, 14.6, -17.1, 14.9, null, array['places']);
  if coalesce((v ->> 'mapping')::boolean, false) or v ->> 'mapping_reason' is not null then
    raise exception 'FAIL map_in_view for an active tile';
  end if;
  -- Places layer off: never a reason.
  v := public.map_in_view(-56.4, -34.9, -56.1, -34.6, null, array['plans']);
  if coalesce((v ->> 'mapping')::boolean, false) or v ->> 'mapping_reason' is not null then
    raise exception 'FAIL map_in_view gave a reason without the places layer';
  end if;
  -- The reply never carries a tile id or demand.
  v := public.map_in_view(-56.4, -34.9, -56.1, -34.6, null, array['places']);
  if v ? 'demand' or v ? 'tiles' or v ? 'queue_reason' then
    raise exception 'FAIL map_in_view leaked tile fields';
  end if;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
do $$
declare
  v jsonb;
  v_ok boolean := false;
begin
  v := public.map_in_view(-56.4, -34.9, -56.1, -34.6, null, array['places']);
  if v ->> 'mapping_reason' is distinct from 'size_cap' then
    raise exception 'FAIL map_in_view mapping_reason as a member';
  end if;
  begin
    perform public.place_tiles_set_queue_reasons('{}'::jsonb);
  exception when insufficient_privilege then v_ok := true;
  end;
  if not v_ok then
    raise exception 'FAIL a member could set queue reasons';
  end if;
end $$;
reset role;

select 'places_nightly: all assertions passed' as result;

rollback;
