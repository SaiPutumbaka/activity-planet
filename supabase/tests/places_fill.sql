-- ============================================================================
-- Staging check for migration 20261207000100_places_fill.sql (D-042 slice 9,
-- Geoapify quick fill). One transaction: sets up throwaway tiles and rows,
-- asserts with DO blocks that raise on failure, then rolls everything back
-- (so the pg_net requests the triggers queue are never sent). Prints
-- pass/fail only (no user rows, no secrets).
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- Baseline of queued pg_net requests, before any test tile exists.
do $$
begin
  perform set_config('test.queue0', (select count(*) from net.http_request_queue)::text, true);
  perform set_config('test.budget0',
    coalesce((select used from public.collector_budget
               where day = (now() at time zone 'utc')::date and source = 'geoapify_places'), 0)::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  ta integer := public.place_tile_id(39.47, -0.38);    -- Valencia: fillable, top demand
  tb integer := public.place_tile_id(60.39, 5.32);     -- Bergen: has an OSM run
  tc integer := public.place_tile_id(35.01, 135.77);   -- Kyoto: already Geoapify-filled
  td integer := public.place_tile_id(-33.45, -70.66);  -- Santiago: demand 0 (a neighbour)
  te integer := public.place_tile_id(-1.29, 36.82);    -- Nairobi: claimed 5 minutes ago
  tf integer := public.place_tile_id(19.43, -99.13);   -- Mexico City: claim expired
begin
  if exists (select 1 from public.place_tiles where id in (ta, tb, tc, td, te, tf)) then
    raise exception 'setup: a test tile already exists on staging';
  end if;
  if public.project_url() is null then
    raise exception 'setup: meta.project_url is not set on staging';
  end if;
  insert into public.place_tiles (id, status, demand) values (ta, 'wanted', 100000);
  insert into public.place_tiles (id, status, demand, osm_run_at) values (tb, 'wanted', 99999, now());
  insert into public.place_tiles (id, status, demand, geoapify_run_at) values (tc, 'filling', 99998, now());
  insert into public.place_tiles (id, status, demand) values (td, 'wanted', 0);
  insert into public.place_tiles (id, status, demand, geoapify_claimed_at)
  values (te, 'wanted', 99997, now() - interval '5 minutes');
  insert into public.place_tiles (id, status, demand, geoapify_claimed_at)
  values (tf, 'wanted', 99996, now() - interval '1 hour');
  perform set_config('test.ta', ta::text, true);
  perform set_config('test.tb', tb::text, true);
  perform set_config('test.tc', tc::text, true);
  perform set_config('test.td', td::text, true);
  perform set_config('test.te', te::text, true);
  perform set_config('test.tf', tf::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
  r text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.39' then
    raise exception 'FAIL schema_version is not 2.39';
  end if;
  if not exists (select 1 from information_schema.columns where table_schema = 'public'
                    and table_name = 'place_tiles' and column_name = 'geoapify_claimed_at') then
    raise exception 'FAIL place_tiles.geoapify_claimed_at missing';
  end if;
  foreach f in array array['public.places_fill_plan(integer)', 'public.places_fill_spend(integer)',
                           'public.places_fill_release(integer)', 'public.places_fill_supersede()',
                           'public.places_fill_dispatch(text,boolean)', 'public.places_fill_tick()',
                           'public.place_tiles_fill_ping()'] loop
    foreach r in array array['anon', 'authenticated'] loop
      if has_function_privilege(r, f, 'execute') then
        raise exception 'FAIL % can execute %', r, f;
      end if;
    end loop;
  end loop;
  foreach f in array array['public.places_fill_plan(integer)', 'public.places_fill_spend(integer)',
                           'public.places_fill_release(integer)'] loop
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL service_role cannot execute %', f;
    end if;
  end loop;
  if not exists (select 1 from cron.job where jobname = 'places-fill'
                    and schedule = '7,22,37,52 * * * *' and command = 'select public.places_fill_tick()') then
    raise exception 'FAIL cron job places-fill missing or wrong';
  end if;
  if (select count(*) from pg_trigger where tgrelid = 'public.place_tiles'::regclass
        and tgname in ('place_tiles_fill_ping_insert', 'place_tiles_fill_ping_update')) <> 2 then
    raise exception 'FAIL fill ping triggers missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- The ping: one pg_net request for the whole transaction, to places-fill
-- ---------------------------------------------------------------------------
do $$
begin
  if current_setting('ap.places_fill_pinged', true) is distinct from '1' then
    raise exception 'FAIL a fillable tile insert did not ping';
  end if;
  if (select count(*) from net.http_request_queue) <> current_setting('test.queue0')::bigint + 1 then
    raise exception 'FAIL expected exactly one queued request after six tile inserts';
  end if;
  if not exists (select 1 from net.http_request_queue q
                  where q.url = public.project_url() || '/functions/v1/places-fill' and q.method = 'POST'
                    and q.headers ? 'x-collector-secret') then
    raise exception 'FAIL the queued request is not a places-fill POST with the collector secret';
  end if;
  -- A demand bump in the same transaction adds nothing.
  update public.place_tiles set demand = demand + 1 where id = current_setting('test.te')::integer;
  if (select count(*) from net.http_request_queue) <> current_setting('test.queue0')::bigint + 1 then
    raise exception 'FAIL a second ping in the same transaction';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Plan (as service_role): which tiles, in what order, claimed
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_p   jsonb;
  v_ids integer[];
  ta    integer := current_setting('test.ta')::integer;
  tf    integer := current_setting('test.tf')::integer;
begin
  v_p := public.places_fill_plan(5);
  select array_agg((t ->> 'id')::integer order by o) into v_ids
    from jsonb_array_elements(v_p -> 'tiles') with ordinality as x(t, o);
  if v_ids[1] is distinct from ta then
    raise exception 'FAIL the highest-demand fillable tile is not first';
  end if;
  if not tf = any (v_ids) then
    raise exception 'FAIL a tile with an expired claim was not offered';
  end if;
  if v_ids && array[current_setting('test.tb')::integer, current_setting('test.tc')::integer,
                    current_setting('test.td')::integer, current_setting('test.te')::integer] then
    raise exception 'FAIL an OSM-run, Geoapify-filled, demand-0 or freshly claimed tile was offered';
  end if;
  if (v_p -> 'tiles' -> 0 -> 'bbox') <> '[-0.5, 39.0, 0.0, 39.5]'::jsonb then
    raise exception 'FAIL bbox of the Valencia tile: %', v_p -> 'tiles' -> 0 -> 'bbox';
  end if;
  if jsonb_array_length(v_p -> 'categories') < 20 or jsonb_array_length(v_p -> 'rules') < 100
     or jsonb_array_length(v_p -> 'kinds') < 10 then
    raise exception 'FAIL plan lacks categories, rules or kinds';
  end if;
  if (v_p -> 'budget' ->> 'cap')::integer <> 500 then
    raise exception 'FAIL budget cap is not 500';
  end if;
  if (select geoapify_claimed_at from public.place_tiles where id = ta) is null then
    raise exception 'FAIL the tile was not claimed';
  end if;
  -- Claimed now, so a second run does not take it.
  if exists (select 1 from jsonb_array_elements(public.places_fill_plan(5) -> 'tiles') t
              where (t ->> 'id')::integer = ta) then
    raise exception 'FAIL a claimed tile was offered twice';
  end if;
  if not public.places_fill_release(ta) or (select geoapify_claimed_at from public.place_tiles where id = ta) is not null then
    raise exception 'FAIL release did not drop the claim';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Budget: 500 credits a day, never more
-- ---------------------------------------------------------------------------
do $$
declare
  v_left integer;
begin
  insert into public.collector_budget (day, source, used)
  values ((now() at time zone 'utc')::date, 'geoapify_places', 490)
  on conflict (day, source) do update set used = 490;
  v_left := public.places_fill_spend(5);
  if v_left <> 5 then raise exception 'FAIL spend left % (expected 5)', v_left; end if;
  v_left := public.places_fill_spend(5);
  if v_left <> 0 then raise exception 'FAIL spend left % (expected 0)', v_left; end if;
  if public.places_fill_spend(5) is not null then
    raise exception 'FAIL spend past the cap was not refused';
  end if;
  if (select used from public.collector_budget
       where day = (now() at time zone 'utc')::date and source = 'geoapify_places') <> 500 then
    raise exception 'FAIL a refused spend changed the budget';
  end if;
  begin
    perform public.places_fill_spend(0);
    raise exception 'FAIL spend of 0 credits accepted';
  exception when check_violation then null;
  end;
  if jsonb_array_length(public.places_fill_plan(5) -> 'tiles') <> 0 then
    raise exception 'FAIL plan offered tiles with no budget left';
  end if;
  update public.collector_budget set used = 0
   where day = (now() at time zone 'utc')::date and source = 'geoapify_places';
end $$;
reset role;

-- Dispatch: nothing without budget unless forced (as the owner).
do $$
begin
  update public.collector_budget set used = 498
   where day = (now() at time zone 'utc')::date and source = 'geoapify_places';
  if public.places_fill_dispatch('test', false) is not null then
    raise exception 'FAIL dispatch sent with no budget left';
  end if;
  if public.places_fill_dispatch('test', true) is null then
    raise exception 'FAIL forced dispatch sent nothing';
  end if;
  update public.collector_budget set used = 0
   where day = (now() at time zone 'utc')::date and source = 'geoapify_places';
end $$;

-- ---------------------------------------------------------------------------
-- Fill, then the OSM run supersedes the Geoapify rows (as service_role)
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  ta    integer := current_setting('test.ta')::integer;
  v_rule smallint;
  v_kind text;
  v_r   jsonb;
  v_n   integer;
begin
  select r.id, r.kind into v_rule, v_kind from public.place_rules r
   where r.osm_key = 'leisure' and r.osm_value = 'pitch' and r.extra = '{}'::jsonb order by r.id limit 1;
  if v_rule is null then
    select r.id, r.kind into v_rule, v_kind from public.place_rules r order by r.id limit 1;
  end if;

  v_r := public.ingest_places(ta, 'geoapify-test-1', jsonb_build_array(
    jsonb_build_object('source_id', 'pft-g1', 'osm_ref', 'w990000001', 'name', 'Test Court One',
                       'kind', v_kind, 'rule_ids', jsonb_build_array(v_rule), 'lat', 39.20, 'lng', -0.30),
    jsonb_build_object('source_id', 'pft-g2', 'osm_ref', 'w990000002', 'name', 'Test Court Two',
                       'kind', v_kind, 'rule_ids', jsonb_build_array(v_rule), 'lat', 39.21, 'lng', -0.31),
    jsonb_build_object('source_id', 'pft-g3', 'name', 'Test Court Three',
                       'kind', v_kind, 'rule_ids', jsonb_build_array(v_rule), 'lat', 39.22, 'lng', -0.32)),
    'geoapify', 0);
  if (v_r ->> 'inserted')::integer <> 3 then
    raise exception 'FAIL geoapify ingest inserted % rows', v_r ->> 'inserted';
  end if;
  perform public.finish_place_tile(ta, 'geoapify-test-1', 3, 'geoapify');
  if (select status from public.place_tiles where id = ta) <> 'filling'
     or (select geoapify_run_at from public.place_tiles where id = ta) is null then
    raise exception 'FAIL the tile is not filling after the Geoapify run';
  end if;
  if exists (select 1 from jsonb_array_elements(public.places_fill_plan(5) -> 'tiles') t
              where (t ->> 'id')::integer = ta) then
    raise exception 'FAIL a Geoapify-filled tile was offered again';
  end if;
  if (select attribution from public.places where source = 'geoapify' and source_id = 'pft-g1')
     not like 'Powered by Geoapify%' then
    raise exception 'FAIL Geoapify rows lack the Powered by Geoapify attribution';
  end if;
end $$;
reset role;

do $$
declare
  ta integer := current_setting('test.ta')::integer;
  v_n integer;
begin
  -- No OSM run yet: nothing is superseded.
  perform public.places_fill_supersede();
  if (select count(*) from public.places where source = 'geoapify' and tile_id = ta and source_id like 'pft-%') <> 3 then
    raise exception 'FAIL Geoapify rows deleted before the OSM run';
  end if;

  -- A moderator correction on row three keeps it.
  update public.places set locked_fields = array['name'] where source = 'geoapify' and source_id = 'pft-g3';

  -- The nightly OSM run sees element w990000001 (merges row one) and one new element.
  perform public.ingest_places(ta, 'osm-test-1', jsonb_build_array(
    jsonb_build_object('source_id', 'w990000001', 'name', 'Test Court One', 'kind',
                       (select kind from public.places where source_id = 'pft-g1'),
                       'rule_ids', (select to_jsonb(rule_ids) from public.places where source_id = 'pft-g1'),
                       'lat', 39.20, 'lng', -0.30),
    jsonb_build_object('source_id', 'w990000009', 'name', 'Test Court Nine', 'kind',
                       (select kind from public.places where source_id = 'pft-g1'),
                       'rule_ids', (select to_jsonb(rule_ids) from public.places where source_id = 'pft-g1'),
                       'lat', 39.25, 'lng', -0.35)), 'osm', 0);
  perform public.finish_place_tile(ta, 'osm-test-1', 2, 'osm');
  if (select status from public.place_tiles where id = ta) <> 'active' then
    raise exception 'FAIL the tile is not active after the OSM run';
  end if;
  if (select status from public.places where source = 'geoapify' and source_id = 'pft-g1') <> 'removed' then
    raise exception 'FAIL the OSM row did not merge the Geoapify row with its osm_ref';
  end if;

  v_n := public.places_fill_supersede();
  if v_n < 2 then
    raise exception 'FAIL supersede deleted % rows (expected the merged and the unmatched row)', v_n;
  end if;
  if exists (select 1 from public.places where source = 'geoapify' and source_id in ('pft-g1', 'pft-g2')) then
    raise exception 'FAIL superseded Geoapify rows were kept';
  end if;
  if not exists (select 1 from public.places where source = 'geoapify' and source_id = 'pft-g3') then
    raise exception 'FAIL a corrected Geoapify row was deleted';
  end if;
  if (select row_count from public.place_tiles where id = ta)
     <> (select count(*) from public.places where tile_id = ta and status = 'active' and is_public) then
    raise exception 'FAIL row_count not recomputed after supersede';
  end if;
  if (public.places_fill_tick() ->> 'superseded')::integer <> 0 then
    raise exception 'FAIL the tick superseded rows twice';
  end if;
end $$;

select 'places_fill: all assertions passed' as result;

rollback;
