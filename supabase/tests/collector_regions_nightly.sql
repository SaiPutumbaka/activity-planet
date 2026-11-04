-- ============================================================================
-- Staging check for migration 20261209000100_collector_regions_nightly.sql
-- (migration 45). One transaction: adds throwaway collector regions (invented
-- points in the Southern Ocean and Iceland), asserts with DO blocks that raise
-- on failure, then rolls everything back. Prints pass/fail only, never region
-- points or counts of real regions.
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.41' then
    raise exception 'FAIL schema_version is not 2.41';
  end if;
  if has_function_privilege('anon', 'public.collector_regions_due(integer,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_regions_due(integer,boolean)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_regions_due(integer,boolean)', 'execute')
     or not (select p.prosecdef from pg_proc p where p.oid = 'public.collector_regions_due(integer,boolean)'::regprocedure) then
    raise exception 'FAIL collector_regions_due grants or security';
  end if;
  if has_function_privilege('anon', 'public.collector_regions_record(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_regions_record(jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_regions_record(jsonb)', 'execute') then
    raise exception 'FAIL collector_regions_record grants';
  end if;
  if (select count(*) from information_schema.columns
       where table_schema = 'public' and table_name = 'collector_regions'
         and column_name in ('timezone', 'last_collected_at', 'last_collect_sources', 'last_collect_items')) <> 4 then
    raise exception 'FAIL collector_regions columns';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Setup: three regions with a priority ahead of every real one
-- ---------------------------------------------------------------------------
create temp table t_ids (k text primary key, id uuid) on commit drop;

do $$
declare v uuid;
begin
  insert into public.collector_regions (point, radius_km, label, priority, home_count)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-150.0, -60.0), 4326)::extensions.geography, 25, null, 0, 3)
  returning id into v;
  insert into t_ids values ('a', v);
  insert into public.collector_regions (point, radius_km, label, priority, home_count)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-140.0, -61.0), 4326)::extensions.geography, 25, 'Test B', 0, 9)
  returning id into v;
  insert into t_ids values ('b', v);
  -- Collected today already: not due.
  insert into public.collector_regions (point, radius_km, label, priority, home_count, last_collected_at, timezone)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-21.9, 64.1), 4326)::extensions.geography, 25, null, 0, 1,
          date_trunc('day', now(), 'UTC'), 'Atlantic/Reykjavik')
  returning id into v;
  insert into t_ids values ('c', v);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Due list
-- ---------------------------------------------------------------------------
do $$
declare
  d jsonb := public.collector_regions_due(100, false);
  a jsonb;
  ids text[];
begin
  select array_agg(x->>'id' order by o) into ids from jsonb_array_elements(d) with ordinality as t(x, o);
  -- b (home_count 9) before a (home_count 3); both before every real region (priority 0).
  if ids[1] <> (select id::text from t_ids where k = 'b') or ids[2] <> (select id::text from t_ids where k = 'a') then
    raise exception 'FAIL due order';
  end if;
  if (select id::text from t_ids where k = 'c') = any (ids) then
    raise exception 'FAIL a region collected today is due';
  end if;
  select x into a from jsonb_array_elements(d) x where x->>'id' = (select id::text from t_ids where k = 'a');
  if (a->>'lat')::double precision <> -60 or (a->>'lng')::double precision <> -150
     or (a->>'radius_km')::int <> 25 or a ? 'home_count' or jsonb_typeof(a->'label') <> 'null'
     or jsonb_typeof(a->'timezone') <> 'null' then
    raise exception 'FAIL due entry shape';
  end if;
  if not exists (select 1 from jsonb_array_elements(public.collector_regions_due(100, true)) x
                  where x->>'id' = (select id::text from t_ids where k = 'c')) then
    raise exception 'FAIL p_all leaves out a collected region';
  end if;
  if jsonb_array_length(public.collector_regions_due(1, false)) <> 1
     or jsonb_array_length(public.collector_regions_due(1000, true)) > 100 then
    raise exception 'FAIL limit';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Record
-- ---------------------------------------------------------------------------
do $$
declare
  r jsonb;
  ra uuid := (select id from t_ids where k = 'a');
  rb uuid := (select id from t_ids where k = 'b');
  rc uuid := (select id from t_ids where k = 'c');
begin
  r := public.collector_regions_record(jsonb_build_array(
         jsonb_build_object('id', ra, 'sources', 2, 'items', 40, 'timezone', 'Pacific/Tahiti'),
         jsonb_build_object('id', rb, 'sources', 0, 'items', 0, 'timezone', 'Mars/Olympus'),
         jsonb_build_object('id', rc, 'sources', 1, 'items', 5, 'timezone', 'Europe/Berlin'),
         jsonb_build_object('id', gen_random_uuid(), 'sources', 0, 'items', 0)));
  if (r->>'updated')::int <> 3 or (r->>'unknown')::int <> 1 or (r->>'timezone_invalid')::int <> 1
     or (r->>'with_timezone')::int <> 2 then
    raise exception 'FAIL record counts';
  end if;
  if not exists (select 1 from public.collector_regions where id = ra and timezone = 'Pacific/Tahiti'
                   and last_collected_at = date_trunc('day', now(), 'UTC')
                   and last_collect_sources = 2 and last_collect_items = 40) then
    raise exception 'FAIL record a';
  end if;
  if not exists (select 1 from public.collector_regions where id = rb and timezone is null
                   and last_collected_at is not null and last_collect_items = 0) then
    raise exception 'FAIL record b (unknown zone must not be stored)';
  end if;
  if not exists (select 1 from public.collector_regions where id = rc and timezone = 'Atlantic/Reykjavik') then
    raise exception 'FAIL record c (a set zone must not be overwritten)';
  end if;
  if exists (select 1 from jsonb_array_elements(public.collector_regions_due(100, false)) x
              where (x->>'id')::uuid in (ra, rb, rc)) then
    raise exception 'FAIL recorded regions still due';
  end if;
  begin
    perform public.collector_regions_record('[{"id":"nope","sources":1,"items":1}]'::jsonb);
    raise exception 'FAIL bad id accepted';
  exception when others then
    if sqlerrm <> 'regions_invalid' then raise; end if;
  end;
  begin
    perform public.collector_regions_record(jsonb_build_array(jsonb_build_object('id', ra, 'sources', -1, 'items', 1)));
    raise exception 'FAIL negative count accepted';
  exception when others then
    if sqlerrm <> 'regions_invalid' then raise; end if;
  end;
  begin
    perform public.collector_regions_record('{}'::jsonb);
    raise exception 'FAIL object accepted';
  exception when others then
    if sqlerrm <> 'regions_invalid' then raise; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Members cannot call either function or read the new columns
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub":"00000000-0000-0000-0000-00000000c045","role":"authenticated"}', true) is not null as claims_set;
do $$
begin
  begin
    perform public.collector_regions_due(5, false);
    raise exception 'FAIL member called collector_regions_due';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.collector_regions_record('[]'::jsonb);
    raise exception 'FAIL member called collector_regions_record';
  exception when insufficient_privilege then null;
  end;
  if exists (select 1 from public.collector_regions) then
    raise exception 'FAIL member reads collector_regions';
  end if;
end $$;
reset role;

select 'PASS collector_regions_nightly' as result;

rollback;
