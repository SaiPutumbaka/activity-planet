-- ============================================================================
-- Timings for migration 20261124000100_places_read.sql (D-041, hub map slice
-- 6) on the Atlanta places (tiles 178030, 178031, 178751). One transaction
-- with one throwaway signed-in user, rolled back at the end. Prints only
-- timings, row counts, payload sizes and plan node names with their row
-- counts, never place names, ids or coordinates (the repo and its Action
-- logs are public). Run as the staging_file of a staging_only migrate.yml run.
--
-- Each scenario runs 33 times in this session: run 1 is reported as cold
-- (it includes planning), runs 2 and 3 warm up, and p50 / p95 / max are over
-- runs 4 to 33. Times are inside the database (clock_timestamp around the
-- call), so PostgREST and the network come on top.
--   anon_city     signed out, no hubs (every specific hub), a 0.2 x 0.15
--                 degree downtown view
--   anon_max      signed out, no hubs, the largest view that still returns
--                 places (1.0 x 1.5 degrees: all three tiles)
--   anon_max_1500 the same with the 1,500 cap
--   user_city     signed in with 5 joined hubs (the 5 specific hubs with the
--                 most Atlanta places), default layers
--   user_max      the same over 1.0 x 1.5 degrees
--   user_50_hubs  50 specific hubs passed, 1.0 x 1.5 degrees (most hub_idxs
--                 work per place)
--   user_generic  the generic hub with the most Atlanta places, alone, with
--                 generic set, city view
--   anon_search   places_in_view with the query 'park', 1.0 x 1.5 degrees
--   anon_zoomed   3 x 3 degrees: zoom_in, plans and shows only
--   anon_detail   place_detail of 20 Atlanta places, timed per call
-- Payload: raw = octet_length of the jsonb text; lz4 = its size compressed
-- by the database (pglz when lz4 is not available), a stand-in for gzip.
-- ============================================================================
begin;

create temp table perf_lines (n serial, line text);
create temp table perf_payload (scenario text, body text);

-- ---------------------------------------------------------------------------
-- Setup: one signed-in adult with the top hubs (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_u   uuid := gen_random_uuid();
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_box extensions.geometry := extensions.ST_MakeEnvelope(-85.0, 33.5, -84.0, 34.5, 4326);
  v_top uuid[];
  v_gen uuid;
  v_ids uuid[];
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'prdperf-' || v_tag || '@example.com', now(), now());
  update public.profile_private set birth_date = date '1990-05-05' where user_id = v_u;
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id = v_u;

  with counts as (
    select h.id, h.place_mode, count(*) as n
      from public.places p
      join public.hub_place_rules r on r.rule_id = any (p.rule_ids)
      join public.hubs h on h.id = r.hub_id and h.is_active
     where p.status = 'active' and p.is_public and p.geom operator(extensions.&&) v_box
     group by h.id, h.place_mode
  )
  select array(select c.id from counts c where c.place_mode = 'specific' order by c.n desc, c.id limit 50),
         (select c.id from counts c where c.place_mode = 'generic' order by c.n desc, c.id limit 1)
    into v_top, v_gen;
  if cardinality(v_top) < 50 or v_gen is null then
    raise exception 'setup: fewer than 50 specific hubs or no generic hub with Atlanta places';
  end if;
  insert into public.hub_members (hub_id, user_id, joined_at)
  select u.id, v_u, now() - (u.o || ' minutes')::interval from unnest(v_top[1:5]) with ordinality u(id, o);

  v_ids := array(select p.id from public.places p
                  where p.status = 'active' and p.is_public and p.geom operator(extensions.&&) v_box
                  order by p.id limit 20);
  perform set_config('perf.u', v_u::text, true);
  perform set_config('perf.top50', array_to_string(v_top, ','), true);
  perform set_config('perf.gen', v_gen::text, true);
  perform set_config('perf.ids', array_to_string(v_ids, ','), true);
  insert into perf_lines (line)
  select format('setup: atlanta active public places %s, published events in view next 7 days %s, top-5 hub places %s',
           (select count(*) from public.places p
             where p.status = 'active' and p.is_public and p.geom operator(extensions.&&) v_box),
           (select count(*) from public.events e
             where e.status = 'published' and e.starts_at < now() + interval '7 days' and e.ends_at > now()
               and e.approx_point is not null
               and (e.approx_point::extensions.geometry) operator(extensions.&&) v_box),
           (select count(distinct p.id) from public.places p
              join public.hub_place_rules r on r.rule_id = any (p.rule_ids)
             where r.hub_id = any (v_top[1:5]) and p.status = 'active' and p.is_public
               and p.geom operator(extensions.&&) v_box));
end $$;

-- Timing harness: runs one call 33 times and returns a summary as jsonb.
create function pg_temp.perf_run(p_name text, p_sql text)
returns jsonb language plpgsql as $$
declare
  t0    timestamptz;
  ms    double precision;
  cold  double precision;
  times double precision[] := '{}';
  r     jsonb;
  i     integer;
begin
  for i in 1..33 loop
    t0 := clock_timestamp();
    execute p_sql into r;
    ms := extract(epoch from clock_timestamp() - t0) * 1000;
    if i = 1 then cold := ms; elsif i > 3 then times := times || ms; end if;
  end loop;
  return jsonb_build_object(
    'scenario', p_name,
    'cold_ms', round(cold::numeric, 1),
    'p50_ms', (select round(percentile_cont(0.5) within group (order by t)::numeric, 1) from unnest(times) t),
    'p95_ms', (select round(percentile_cont(0.95) within group (order by t)::numeric, 1) from unnest(times) t),
    'max_ms', (select round(max(t)::numeric, 1) from unnest(times) t),
    'places', case when jsonb_typeof(r -> 'places') = 'array' then jsonb_array_length(r -> 'places') end,
    'plans', case when jsonb_typeof(r -> 'plans') = 'array' then jsonb_array_length(r -> 'plans') end,
    'shows', case when jsonb_typeof(r -> 'shows') = 'array' then jsonb_array_length(r -> 'shows') end,
    'cells', case when jsonb_typeof(r -> 'cells') = 'array' then jsonb_array_length(r -> 'cells') end,
    'hubs', case when jsonb_typeof(r -> 'hubs') = 'array' then jsonb_array_length(r -> 'hubs') end,
    'zoom_in', r -> 'zoom_in',
    'truncated', r -> 'truncated',
    'raw_bytes', octet_length(r::text),
    'body', r::text);
end $$;
grant execute on function pg_temp.perf_run(text, text) to anon, authenticated;

-- Plan summary: node type (and index) with actual rows and time, no filters.
create function pg_temp.perf_plan(p_name text, p_sql text)
returns jsonb language plpgsql as $$
declare
  v_plan jsonb;
begin
  execute 'explain (analyze, buffers, format json) ' || p_sql into v_plan;
  return jsonb_build_object(
    'scenario', p_name,
    'planning_ms', round((v_plan -> 0 ->> 'Planning Time')::numeric, 2),
    'execution_ms', round((v_plan -> 0 ->> 'Execution Time')::numeric, 2),
    'nodes', (with recursive n(node, depth) as (
                select v_plan -> 0 -> 'Plan', 0
                union all
                select c.value, n.depth + 1 from n cross join lateral jsonb_array_elements(coalesce(n.node -> 'Plans', '[]')) c
              )
              select jsonb_agg(repeat('  ', n.depth) || (n.node ->> 'Node Type')
                               || coalesce(' on ' || (n.node ->> 'Relation Name'), '')
                               || coalesce(' using ' || (n.node ->> 'Index Name'), '')
                               || ' rows=' || coalesce(n.node ->> 'Actual Rows', '?')
                               || ' loops=' || coalesce(n.node ->> 'Actual Loops', '?')
                               || ' ms=' || coalesce(n.node ->> 'Actual Total Time', '?'))
                from n));
end $$;
grant execute on function pg_temp.perf_plan(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Signed out
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v_out jsonb := '[]';
  v_ids text := current_setting('perf.ids');
  r     jsonb;
  v_rules smallint[];
begin
  v_out := v_out || pg_temp.perf_run('anon_city', 'select public.map_in_view(-84.50, 33.70, -84.30, 33.85)');
  v_out := v_out || pg_temp.perf_run('anon_max', 'select public.map_in_view(-85.0, 33.5, -83.5, 34.5)');
  v_out := v_out || pg_temp.perf_run('anon_max_1500',
    'select public.map_in_view(-85.0, 33.5, -83.5, 34.5, null, array[''places'',''plans'',''shows''], null, null, false, 1500)');
  v_out := v_out || pg_temp.perf_run('anon_search',
    'select public.places_in_view(-85.0, 33.5, -83.5, 34.5, null, false, null, ''park'')');
  v_out := v_out || pg_temp.perf_run('anon_zoomed', 'select public.map_in_view(-86.0, 32.5, -83.0, 35.5)');
  v_out := v_out || pg_temp.perf_run('anon_detail',
    format('select public.place_detail((%L::uuid[])[1 + (floor(random() * 20))::integer])', '{' || v_ids || '}'));
  perform set_config('perf.anon', v_out::text, true);

  -- Plans: the whole RPC (one Result node: plpgsql hides the inner plans),
  -- then its places and events queries with the same inputs.
  v_out := '[]';
  v_out := v_out || pg_temp.perf_plan('anon_max rpc', 'select public.map_in_view(-85.0, 33.5, -83.5, 34.5)');
  -- The rules branch of places_in_view as the 5-hub user runs it (the KNN
  -- read through the GiST index), with that user's rule set.
  v_rules := array(select distinct r.rule_id from public.hub_place_rules r
                    where r.hub_id = any ((string_to_array(current_setting('perf.top50'), ',')::uuid[])[1:5]));
  v_out := v_out || pg_temp.perf_plan('user_max places rules branch', format($q$
    select count(*) from (
      select p.id, p.geom operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-84.25, 34.0), 4326) as d
        from public.places p
       where p.status = 'active' and p.is_public and p.rule_ids && %L::smallint[]
         and p.geom operator(extensions.&&) extensions.ST_MakeEnvelope(-85.0, 33.5, -83.5, 34.5, 4326)
       order by p.geom operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-84.25, 34.0), 4326)
       limit 801) x$q$, v_rules));
  v_out := v_out || pg_temp.perf_plan('user_city places rules branch', format($q$
    select count(*) from (
      select p.id, p.geom operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-84.40, 33.775), 4326) as d
        from public.places p
       where p.status = 'active' and p.is_public and p.rule_ids && %L::smallint[]
         and p.geom operator(extensions.&&) extensions.ST_MakeEnvelope(-84.50, 33.70, -84.30, 33.85, 4326)
       order by p.geom operator(extensions.<->) extensions.ST_SetSRID(extensions.ST_MakePoint(-84.40, 33.775), 4326)
       limit 801) x$q$, v_rules));
  v_out := v_out || pg_temp.perf_plan('anon_max events core', $q$
    select count(*) from public.events e join public.hubs h on h.id = e.hub_id
     where e.status = 'published' and e.starts_at < now() + interval '7 days' and e.ends_at > now()
       and e.approx_point is not null
       and (e.approx_point::extensions.geometry) operator(extensions.&&)
           extensions.ST_MakeEnvelope(-85.0, 33.5, -83.5, 34.5, 4326)$q$);
  perform set_config('perf.plans', v_out::text, true);
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- Signed in
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('perf.u'), 'role', 'authenticated')::text, true);
do $$
declare
  v_out jsonb := '[]';
  v_top text := '{' || current_setting('perf.top50') || '}';
begin
  v_out := v_out || pg_temp.perf_run('user_city', 'select public.map_in_view(-84.50, 33.70, -84.30, 33.85)');
  v_out := v_out || pg_temp.perf_run('user_max', 'select public.map_in_view(-85.0, 33.5, -83.5, 34.5)');
  v_out := v_out || pg_temp.perf_run('user_50_hubs',
    format('select public.map_in_view(-85.0, 33.5, -83.5, 34.5, %L::uuid[])', v_top));
  v_out := v_out || pg_temp.perf_run('user_generic',
    format('select public.map_in_view(-84.50, 33.70, -84.30, 33.85, array[%L::uuid], array[''places''], null, null, true)',
           current_setting('perf.gen')));
  perform set_config('perf.user', v_out::text, true);
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- Report (as the owner): sizes compressed by the database, then one line per
-- scenario and plan node.
-- ---------------------------------------------------------------------------
do $$
begin
  begin
    execute 'alter table perf_payload alter column body set compression lz4';
    perform set_config('perf.codec', 'lz4', true);
  exception when others then
    perform set_config('perf.codec', 'pglz', true);
  end;
  alter table perf_payload alter column body set storage main;
end $$;
insert into perf_payload (scenario, body)
select x.value ->> 'scenario', x.value ->> 'body'
  from jsonb_array_elements(current_setting('perf.anon')::jsonb || current_setting('perf.user')::jsonb) x;

insert into perf_lines (line)
select format('%s: p50 %s ms, p95 %s ms, max %s ms, cold %s ms | places %s plans %s shows %s cells %s hubs %s | zoom_in %s truncated %s | raw %s B, %s %s B, %s B per 1000 features',
         x.value ->> 'scenario', x.value ->> 'p50_ms', x.value ->> 'p95_ms', x.value ->> 'max_ms', x.value ->> 'cold_ms',
         coalesce(x.value ->> 'places', '-'), coalesce(x.value ->> 'plans', '-'), coalesce(x.value ->> 'shows', '-'),
         coalesce(x.value ->> 'cells', '-'), coalesce(x.value ->> 'hubs', '-'),
         x.value ->> 'zoom_in', x.value ->> 'truncated', x.value ->> 'raw_bytes',
         current_setting('perf.codec'), pg_column_size(pp.body),
         case when coalesce((x.value ->> 'places')::integer, 0) + coalesce((x.value ->> 'plans')::integer, 0)
                   + coalesce((x.value ->> 'shows')::integer, 0) > 0
              then round(1000.0 * pg_column_size(pp.body) / (coalesce((x.value ->> 'places')::integer, 0)
                   + coalesce((x.value ->> 'plans')::integer, 0) + coalesce((x.value ->> 'shows')::integer, 0)))::text
              else '-' end)
  from jsonb_array_elements(current_setting('perf.anon')::jsonb || current_setting('perf.user')::jsonb) with ordinality x(value, o)
  join perf_payload pp on pp.scenario = x.value ->> 'scenario'
 order by x.o;

insert into perf_lines (line)
select format('plan %s: planning %s ms, execution %s ms', x.value ->> 'scenario', x.value ->> 'planning_ms',
              x.value ->> 'execution_ms')
       || coalesce(E'\n' || (select string_agg('    ' || l.value, E'\n') from jsonb_array_elements_text(x.value -> 'nodes') l), '')
  from jsonb_array_elements(current_setting('perf.plans')::jsonb) with ordinality x(value, o)
 order by x.o;

select line as places_read_perf from perf_lines order by n;

rollback;
