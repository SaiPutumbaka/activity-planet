-- ============================================================================
-- Staging check for migration 20261227000100_collector_health_geocode.sql
-- (migration 63), discovery-queue tuning (docs/design/collector/
-- COLLECTOR_COMPLETION.md 2.9). One transaction: candidates on invented hosts
-- (aptest-<tag>-*.org; nothing is fetched) in a collector region in the
-- Southern Ocean, and a gate row for a made-up probe hash; asserts in DO
-- blocks that raise on failure, then rolls everything back. Prints pass/fail
-- lines only.
--
--   1 Static: the view is security invoker, grants.
--   2 source_kind_yield counts probed and good candidates by kind and origin;
--     source_kind_learned_yield is null under 30 probes.
--   3 source_candidates_record keeps the platform on a rejection.
--   4 A second empty probe of a kind under 5% learned yield waits 180 days;
--     a kind without a learned yield waits 30.
--   5 The probe queue orders by score, then Wikidata first, then fewest probes.
--   6 collector_discovery_yield and collector_denylist_remote answer counts and names only.
-- ============================================================================
begin;

create temp table dt_lines (n serial, line text);
grant insert, select on dt_lines to anon, authenticated, service_role;
grant usage on sequence dt_lines_n_seq to anon, authenticated, service_role;

do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_r uuid;
  i integer;
begin
  insert into public.collector_regions (point, radius_km, label, priority, timezone)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-124.0, -64.0), 4326)::extensions.geography, 25, null, 100, 'Antarctica/Palmer')
  returning id into v_r;
  -- 30 probed candidates of a low-yield kind (1 good), 4 of a fresh kind.
  for i in 1..30 loop
    insert into public.source_candidates (host, url, region_id, origin, place_kind, status, last_probe_at, feed_url, feed_kind, ok_days)
    values ('aptest-' || v_tag || '-low' || i || '.org', 'https://aptest-' || v_tag || '-low' || i || '.org/',
            v_r, 'osm', 'aptlow' || v_tag, case when i = 1 then 'probation' else 'rejected' end, now() - interval '40 days',
            case when i = 1 then 'https://aptest-' || v_tag || '-low1.org/cal.ics' end, case when i = 1 then 'ics' end,
            case when i = 1 then 1 else 0 end);
  end loop;
  for i in 1..4 loop
    insert into public.source_candidates (host, url, region_id, origin, place_kind, status, last_probe_at)
    values ('aptest-' || v_tag || '-new' || i || '.org', 'https://aptest-' || v_tag || '-new' || i || '.org/',
            v_r, case when i <= 2 then 'wikidata' else 'osm' end, 'aptnew' || v_tag,
            'discovered', case when i = 1 then now() - interval '40 days' end);
  end loop;
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.r', v_r::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1 and 2. View and learned yield
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
begin
  if not exists (select 1 from pg_class c where c.oid = 'public.source_kind_yield'::regclass
                    and c.reloptions @> array['security_invoker=true'])
     or has_table_privilege('anon', 'public.source_kind_yield', 'select')
     or has_function_privilege('authenticated', 'public.collector_discovery_yield()', 'execute')
     or has_function_privilege('authenticated', 'public.source_kind_learned_yield(text)', 'execute') then
    raise exception 'FAIL 1 view or grants';
  end if;
  insert into dt_lines (line) values ('1 static: ok');
  if (select probed || '/' || good from public.source_kind_yield where place_kind = 'aptlow' || v_tag and origin = 'osm') <> '30/1'
     or (select sum(probed) || '/' || sum(waiting) from public.source_kind_yield where place_kind = 'aptnew' || v_tag) <> '1/4' then
    raise exception 'FAIL 2 yield view counts';
  end if;
  if public.source_kind_learned_yield('aptlow' || v_tag) is distinct from (1::numeric / 30)
     or public.source_kind_learned_yield('aptnew' || v_tag) is not null then
    raise exception 'FAIL 2 learned yield';
  end if;
  insert into dt_lines (line) values ('2 yield: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3 and 4. Platform kept on rejection; the 180-day wait
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
  c_low uuid;
  c_new uuid;
  c_plat uuid;
begin
  select id into c_low from public.source_candidates where host = 'aptest-' || v_tag || '-low2.org';
  update public.source_candidates set reason = 'no_events_in_region', retry_after = now() - interval '1 day' where id = c_low;
  select id into c_new from public.source_candidates where host = 'aptest-' || v_tag || '-new3.org';
  update public.source_candidates set status = 'rejected', reason = 'no_events_in_region', retry_after = now() - interval '1 day'
   where id = c_new;
  select id into c_plat from public.source_candidates where host = 'aptest-' || v_tag || '-new4.org';
  perform public.source_candidates_record(jsonb_build_array(
    jsonb_build_object('candidate_id', c_low, 'run_id', 'probe-dt-' || v_tag, 'outcome', 'empty', 'items', 0, 'in_region', 0),
    jsonb_build_object('candidate_id', c_new, 'run_id', 'probe-dt-' || v_tag, 'outcome', 'empty', 'items', 0, 'in_region', 0),
    jsonb_build_object('candidate_id', c_plat, 'run_id', 'probe-dt-' || v_tag, 'outcome', 'robots', 'platform', 'the_events_calendar')));
  if (select status || ':' || coalesce(platform, '-') from public.source_candidates where id = c_plat) <> 'rejected:the_events_calendar' then
    raise exception 'FAIL 3 the platform was not kept on a rejection';
  end if;
  insert into dt_lines (line) values ('3 platform kept: ok');
  if (select retry_after from public.source_candidates where id = c_low) < now() + interval '170 days' then
    raise exception 'FAIL 4 a low-yield kind did not wait 180 days';
  end if;
  if (select retry_after from public.source_candidates where id = c_new) > now() + interval '40 days' then
    raise exception 'FAIL 4 a kind without a learned yield waits longer than 30 days';
  end if;
  insert into dt_lines (line) values ('4 180-day wait: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 5. Probe queue order
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_r uuid := current_setting('t.r')::uuid;
  v_hash text := substr(md5('dt-' || v_tag), 1, 16) || substr(md5('dt2-' || v_tag), 1, 16);
  v jsonb;
  v_hosts text[];
begin
  insert into public.source_discovery_gates (run_id, probe_hash, region, expected, required, found, passed)
  values ('dt-' || v_tag, v_hash, 'atl', 9, 6, 9, true);
  -- Same score: the two Wikidata candidates first, the one with fewer probes before the other.
  update public.source_candidates set score = 30 where host in ('aptest-' || v_tag || '-new1.org', 'aptest-' || v_tag || '-new2.org');
  update public.source_candidates set score = 30, status = 'discovered', reason = null, retry_after = null
   where host = 'aptest-' || v_tag || '-new3.org';
  update public.source_candidates set error_runs = 2 where host = 'aptest-' || v_tag || '-new1.org';
  v := public.source_discovery_probe_queue(v_hash, array[v_r], 150, 500);
  v_hosts := array(select x.value ->> 'host' from jsonb_array_elements(v) with ordinality x(value, o)
                    where x.value ->> 'host' like 'aptest-' || v_tag || '-new%' order by x.o);
  if v_hosts[1:3] <> array['aptest-' || v_tag || '-new2.org', 'aptest-' || v_tag || '-new1.org', 'aptest-' || v_tag || '-new3.org'] then
    raise exception 'FAIL 5 queue order %', array_length(v_hosts, 1);
  end if;
  insert into dt_lines (line) values ('5 queue order: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Yield and remote denylist answers
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  y jsonb := public.collector_discovery_yield();
  d jsonb;
begin
  if (y #>> array['kinds', 'aptlow' || v_tag, 'probed'])::int <> 30
     or y #> '{origins,wikidata}' is null
     or (y #>> '{platforms,the_events_calendar,probed}') is null then
    raise exception 'FAIL 6 collector_discovery_yield';
  end if;
  insert into public.collector_denylist (name, match, reason) values ('aptest-' || v_tag || '-gone.org', 'domain', 'owner request RM-TEST0000');
  d := public.collector_denylist_remote();
  if not exists (select 1 from jsonb_array_elements(d -> 'entries') x
                  where x.value ->> 'name' = 'aptest-' || v_tag || '-gone.org' and x.value ->> 'match' = 'domain' and not x.value ? 'reason')
     or exists (select 1 from jsonb_array_elements(d -> 'entries') x where x.value ->> 'name' = 'facebook.com') then
    raise exception 'FAIL 6 collector_denylist_remote';
  end if;
  insert into dt_lines (line) values ('6 yield and remote denylist: ok');
end $$;

select line as discovery_tuning from (
  select 0 as n, 'discovery_tuning: all assertions passed' as line
  union all
  select n, line from dt_lines) x
order by n;

rollback;
