-- ============================================================================
-- Staging check for migration 20261211000100_discovery_probe.sql (migration
-- 47, D-042 slice 8: the discovery probe and its Atlanta gate). One
-- transaction: collector regions in the Southern Ocean and candidates on
-- invented hosts (aptest-<tag>-*.org; nothing is fetched), asserts in DO
-- blocks that raise on failure, then rolls everything back. Prints pass/fail
-- lines only, never ids, URLs, hosts or points.
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 Static: version, grants and security of the new functions, RLS and no
--     user column on source_discovery_gates, moderator-only reads.
--   2 Gate: gate_invalid inputs write nothing; passed is computed here (a
--     caller's "passed" is ignored); a repeated run_id is ignored; status
--     open only for the hash of a passing run within 30 days.
--   3 Probe queue: closed until the gate passes; then the source_candidates_due
--     rules (locked, unapproved, denylisted, EU automatic candidates and
--     candidates without a region left out), at most p_per_region a region,
--     less the probes recorded today (probe- run ids only).
--   4 Regions: regions_due lists a never-built region, record stamps it and
--     it leaves the list; regions_invalid.
-- ============================================================================
begin;

create temp table dp_lines (n serial, line text);

create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 43] then
    raise exception 'FAIL schema_version is older than 2.43';
  end if;
  foreach f in array array['public.source_discovery_gate_record(jsonb)', 'public.source_discovery_gate_open(text)',
                           'public.source_discovery_gate_status(text)',
                           'public.source_discovery_probe_queue(text,uuid[],integer,integer)',
                           'public.source_discovery_regions_due(integer)', 'public.source_discovery_regions_record(jsonb)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute')
       or not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL grants or security of %', f;
    end if;
  end loop;
  if not (select c.relrowsecurity from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relname = 'source_discovery_gates') then
    raise exception 'FAIL RLS off on source_discovery_gates';
  end if;
  if has_table_privilege('authenticated', 'public.source_discovery_gates', 'insert')
     or has_table_privilege('authenticated', 'public.source_discovery_gates', 'update')
     or has_table_privilege('anon', 'public.source_discovery_gates', 'select') then
    raise exception 'FAIL client write or anon read on source_discovery_gates';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'source_discovery_gates'
                and (column_name like '%user%' or column_name like '%by')) then
    raise exception 'FAIL a user column on source_discovery_gates';
  end if;
  insert into dp_lines (line) values ('static: ok');
end $$;

-- A non-moderator member reads no gate rows (RLS), whatever exists on staging.
do $$
declare
  v_n integer;
  v_uid uuid := gen_random_uuid();
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  select count(*) into v_n from public.source_discovery_gates;
  execute 'reset role';
  if v_n <> 0 then
    raise exception 'FAIL a member read gate rows';
  end if;
  insert into dp_lines (line) values ('rls: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Gate
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag  text := substr(md5(random()::text), 1, 10);
  v_hash text := md5('aptest-pass-' || v_tag);
  v_bad  text := md5('aptest-fail-' || v_tag);
  v jsonb;
  v_n integer;
begin
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.hash', v_hash, true);
  -- Migration 50: at most 2 gate runs in 24 hours. Staging's own recent runs are removed for
  -- this transaction only (rolled back), so the two runs below are not refused.
  delete from public.source_discovery_gates where created_at > now() - interval '24 hours';
  select count(*) into v_n from public.source_discovery_gates;
  if pg_temp.try($q$select public.source_discovery_gate_record('[]'::jsonb)$q$) not like '%gate_invalid%'
     or pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$,
          jsonb_build_object('run_id', 'gate-x-' || v_tag, 'probe_hash', 'nothex', 'region', 'atl',
                             'expected', 9, 'required', 6, 'found', 7)::text)) not like '%gate_invalid%'
     or pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$,
          jsonb_build_object('run_id', 'gate-y-' || v_tag, 'probe_hash', v_hash, 'region', 'atl',
                             'expected', 9, 'required', 6, 'found', 10)::text)) not like '%gate_invalid%'
     or pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$,
          jsonb_build_object('run_id', 'gate-z-' || v_tag, 'probe_hash', v_hash, 'region', 'atl',
                             'expected', 9, 'required', 6, 'found', 7, 'found_sites', jsonb_build_array('not a host'))::text)) not like '%gate_invalid%'
     or pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$,
          jsonb_build_object('run_id', 'gate-w-' || v_tag, 'probe_hash', v_hash, 'region', 'atl',
                             'expected', 9, 'required', 6, 'found', 7, 'counts', jsonb_build_object('Bad Key', 1))::text)) not like '%gate_invalid%' then
    raise exception 'FAIL gate_invalid inputs';
  end if;
  if (select count(*) from public.source_discovery_gates) <> v_n then
    raise exception 'FAIL an invalid gate run was stored';
  end if;

  -- A failing run, even with a caller's passed: true, does not open the gate.
  v := public.source_discovery_gate_record(jsonb_build_object(
         'run_id', 'gate-f-' || v_tag, 'probe_hash', v_bad, 'region', 'atl', 'expected', 9, 'required', 6,
         'found', 5, 'passed', true, 'found_sites', jsonb_build_array('aptest-' || v_tag || '-a.org'),
         'counts', jsonb_build_object('candidates', 400, 'probed', 150)));
  if (v ->> 'passed')::boolean or not (v ->> 'recorded')::boolean or public.source_discovery_gate_open(v_bad) then
    raise exception 'FAIL a failing gate run opened the gate %', v;
  end if;
  if public.source_discovery_gate_open(v_hash) then
    raise exception 'FAIL the gate was open before any run';
  end if;
  v := public.source_discovery_gate_record(jsonb_build_object(
         'run_id', 'gate-p-' || v_tag, 'probe_hash', upper(v_hash), 'region', 'atl', 'expected', 9, 'required', 6,
         'found', 6, 'found_sites', jsonb_build_array('aptest-' || v_tag || '-a.org', 'aptest-' || v_tag || '-a.org')));
  if not (v ->> 'passed')::boolean or not public.source_discovery_gate_open(v_hash) then
    raise exception 'FAIL a passing gate run did not open the gate %', v;
  end if;
  if (select cardinality(g.found_sites) from public.source_discovery_gates g where g.run_id = 'gate-p-' || v_tag) <> 1 then
    raise exception 'FAIL found_sites not deduplicated';
  end if;
  v := public.source_discovery_gate_record(jsonb_build_object(
         'run_id', 'gate-p-' || v_tag, 'probe_hash', v_hash, 'region', 'atl', 'expected', 9, 'required', 6, 'found', 0));
  if (v ->> 'recorded')::boolean or not (v ->> 'repeat')::boolean
     or (select g.found from public.source_discovery_gates g where g.run_id = 'gate-p-' || v_tag) <> 6 then
    raise exception 'FAIL a repeated gate run_id was not ignored';
  end if;
  v := public.source_discovery_gate_status(v_hash);
  if not (v ->> 'open')::boolean or (v #>> '{last,found}')::int <> 6 then
    raise exception 'FAIL gate status %', v;
  end if;
  -- Older than 30 days: closed again.
  update public.source_discovery_gates set created_at = now() - interval '31 days' where run_id = 'gate-p-' || v_tag;
  if public.source_discovery_gate_open(v_hash) or (public.source_discovery_gate_status(v_hash) ->> 'open')::boolean then
    raise exception 'FAIL a gate run over 30 days old kept the gate open';
  end if;
  update public.source_discovery_gates set created_at = now() where run_id = 'gate-p-' || v_tag;
  insert into dp_lines (line) values ('gate: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Probe queue
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag  text := current_setting('t.tag');
  v_hash text := current_setting('t.hash');
  v_r    uuid;
  v_r2   uuid;
  v_c    uuid;
  v      jsonb;
  i      integer;
begin
  insert into public.collector_regions (point, radius_km, label, priority)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(100.1, -60.1), 4326)::extensions.geography, 25, 'APTest probe A', 999)
  returning id into v_r;
  insert into public.collector_regions (point, radius_km, label, priority)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(110.1, -60.1), 4326)::extensions.geography, 25, 'APTest probe B', 999)
  returning id into v_r2;
  perform set_config('t.r', v_r::text, true);

  if pg_temp.try(format('select public.source_discovery_probe_queue(%L, null, 150, 500)', md5('closed' || v_tag)))
       not like '%discovery_gate_closed%' then
    raise exception 'FAIL the probe queue was open without a passing gate';
  end if;

  -- Five probe-able candidates in region A, scores 50..54; one in region B.
  for i in 0..4 loop
    insert into public.source_candidates (host, url, region_id, origin, score)
    values ('aptest-' || v_tag || '-q' || i || '.org', 'https://aptest-' || v_tag || '-q' || i || '.org/', v_r, 'osm', 50 + i);
  end loop;
  insert into public.source_candidates (host, url, region_id, origin, score)
  values ('aptest-' || v_tag || '-b.org', 'https://aptest-' || v_tag || '-b.org/', v_r2, 'osm', 10);
  -- Left out: locked, pending member suggestion, EU automatic, no region, not discovered.
  insert into public.source_candidates (host, url, region_id, origin, score, locked)
  values ('aptest-' || v_tag || '-locked.org', 'https://aptest-' || v_tag || '-locked.org/', v_r, 'osm', 99, true);
  insert into public.source_candidates (host, url, region_id, origin, review_status, score)
  values ('aptest-' || v_tag || '-member.org', 'https://aptest-' || v_tag || '-member.org/', v_r, 'member', 'pending', 99);
  insert into public.source_candidates (host, url, region_id, origin, country, score)
  values ('aptest-' || v_tag || '-eu.org', 'https://aptest-' || v_tag || '-eu.org/', v_r, 'wikidata', 'DE', 99);
  insert into public.source_candidates (host, url, region_id, origin, score)
  values ('aptest-' || v_tag || '-noregion.org', 'https://aptest-' || v_tag || '-noregion.org/', null, 'osm', 99);
  insert into public.source_candidates (host, url, region_id, origin, score, status, feed_kind, feed_url, ok_days, last_ok_on)
  values ('aptest-' || v_tag || '-live.org', 'https://aptest-' || v_tag || '-live.org/', v_r, 'osm', 99, 'probation', 'rss',
          'https://aptest-' || v_tag || '-live.org/feed', 1, current_date);

  v := public.source_discovery_probe_queue(v_hash, array[v_r, v_r2], 150, 500);
  if jsonb_array_length(v) <> 6 then
    raise exception 'FAIL probe queue size %', jsonb_array_length(v);
  end if;
  if exists (select 1 from jsonb_array_elements(v) e
              where e.value ->> 'host' ~ '-(locked|member|eu|noregion|live)\.org$') then
    raise exception 'FAIL the probe queue offered a candidate it must leave out';
  end if;
  -- Round-robin: each region's best candidate comes before any region's second.
  if (v -> 0 ->> 'score')::int <> 54 or (v -> 1 ->> 'region_id')::uuid <> v_r2 then
    raise exception 'FAIL probe queue order';
  end if;
  -- Per region cap.
  v := public.source_discovery_probe_queue(v_hash, array[v_r], 3, 500);
  if jsonb_array_length(v) <> 3 or (v -> 2 ->> 'score')::int <> 52 then
    raise exception 'FAIL per-region cap %', jsonb_array_length(v);
  end if;
  -- Probes recorded today count against the cap; a nightly-run result does not.
  select id into v_c from public.source_candidates where host = 'aptest-' || v_tag || '-q4.org';
  perform public.source_candidates_record(jsonb_build_array(jsonb_build_object(
    'candidate_id', v_c, 'run_id', 'probe-t1-' || v_tag, 'outcome', 'error', 'requests', 3, 'errors', 1)));
  select id into v_c from public.source_candidates where host = 'aptest-' || v_tag || '-live.org';
  perform public.source_candidates_record(jsonb_build_array(jsonb_build_object(
    'candidate_id', v_c, 'run_id', 'gh-t2-' || v_tag, 'outcome', 'ok', 'items', 1, 'in_region', 1)));
  v := public.source_discovery_probe_queue(v_hash, array[v_r], 3, 500);
  if jsonb_array_length(v) <> 2 then
    raise exception 'FAIL probes today not counted against the cap (%)', jsonb_array_length(v);
  end if;
  -- The EU gate opens with meta.eu_discovery on (and only then).
  update public.meta set value = 'on' where key = 'eu_discovery';
  v := public.source_discovery_probe_queue(v_hash, array[v_r], 150, 500);
  if not exists (select 1 from jsonb_array_elements(v) e where e.value ->> 'host' like '%-eu.org') then
    raise exception 'FAIL eu_discovery on did not offer the EU candidate';
  end if;
  update public.meta set value = 'off' where key = 'eu_discovery';
  insert into dp_lines (line) values ('probe queue: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Regions
-- ---------------------------------------------------------------------------
do $$
declare
  v_r uuid := current_setting('t.r')::uuid;
  v   jsonb;
begin
  -- Priority 999 sorts last; ask for every due region.
  v := public.source_discovery_regions_due(100);
  if not exists (select 1 from jsonb_array_elements(v) e where (e.value ->> 'id')::uuid = v_r) then
    raise exception 'FAIL a never-built region is not due';
  end if;
  if exists (select 1 from jsonb_array_elements(v) e where e.value ? 'home_count') then
    raise exception 'FAIL regions_due returns home_count';
  end if;
  v := public.source_discovery_regions_record(jsonb_build_array(v_r::text, gen_random_uuid()::text));
  if (v ->> 'updated')::int <> 1 or (v ->> 'unknown')::int <> 1 then
    raise exception 'FAIL regions_record counts %', v;
  end if;
  if exists (select 1 from jsonb_array_elements(public.source_discovery_regions_due(100)) e where (e.value ->> 'id')::uuid = v_r) then
    raise exception 'FAIL a just-built region is still due';
  end if;
  if pg_temp.try($q$select public.source_discovery_regions_record('["x"]'::jsonb)$q$) not like '%regions_invalid%' then
    raise exception 'FAIL regions_invalid';
  end if;
  insert into dp_lines (line) values ('regions: ok');
end $$;

select line as discovery_probe from (
  select 0 as n, 'discovery_probe: all assertions passed' as line
  union all
  select n, line from dp_lines) x
order by n;

rollback;
