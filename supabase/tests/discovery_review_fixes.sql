-- ============================================================================
-- Staging check for migration 20261214000100_discovery_review_fixes.sql
-- (migration 50: review fixes for D-042 slices 7 to 11). One transaction:
-- test members, collector regions in the Southern Ocean, candidates on
-- invented hosts (aptest-<tag>-*.org; nothing is fetched) and test ticketing
-- sources, asserts in DO blocks that raise on failure, then rolls everything
-- back. Prints pass/fail lines only, never ids, URLs, hosts or points.
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 Static: version, grants and security of the new functions, the
--     prune-place-rate-log job, the error_since column.
--   2 Lifecycle: a live source pauses after 3 error runs (weekly retry, its
--     feed_sources row off), a good run resets the errors, and 30 days of
--     errors reject it.
--   3 Privacy: member candidates keep their times to the hour; rate rows
--     older than a day are pruned.
--   4 Gate: required below 6 is refused, at most 2 runs in 24 hours
--     (gate_rate_limited, a repeat still answers), runs_24h in the status, a
--     run stored with a lower required does not open the gate.
--   5 EU gate: in a Europe/ region, automatic candidates need their own
--     country (CH in, DE out, none out); none is fine in a Pacific region;
--     a region without a zone needs one too; member suggestions are in.
--   6 Ticketing sweep: ticketing-only events ended (or cancelled as no
--     longer listed) over 7 days ago are deleted with their import rows; one
--     with an RSVP is blanked; a shared or upcoming one is untouched.
--   7 place_file_request_take: onboarded active members only, 60 an hour.
-- ============================================================================
begin;

create temp table rf_lines (n serial, line text);

create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

create function pg_temp.res(p_cand uuid, p_run text, p_extra jsonb) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object('candidate_id', p_cand, 'run_id', p_run) || p_extra);
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- onboarded member
  u2 uuid := gen_random_uuid();   -- not onboarded
  v_rn uuid;
  v_rz uuid;
  v_rx uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'rf-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id = u1;

  insert into public.collector_regions (point, radius_km, label, priority, timezone)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-131.0, -62.0), 4326)::extensions.geography, 25, 'APTest RF N', 999, 'Pacific/Auckland')
  returning id into v_rn;
  insert into public.collector_regions (point, radius_km, label, priority, timezone)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-133.0, -62.0), 4326)::extensions.geography, 25, 'APTest RF Z', 999, 'Europe/Zurich')
  returning id into v_rz;
  insert into public.collector_regions (point, radius_km, label, priority)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-135.0, -62.0), 4326)::extensions.geography, 25, 'APTest RF X', 999)
  returning id into v_rx;

  perform set_config('t.tag', v_tag, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.rn', v_rn::text, true);
  perform set_config('t.rz', v_rz::text, true);
  perform set_config('t.rx', v_rx::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.46' then
    raise exception 'FAIL schema_version is not 2.46';
  end if;
  foreach f in array array['public.place_rate_log_prune()', 'public.source_discovery_gate_min_required()',
                           'public.source_discovery_allowed(text,text,uuid)', 'public.place_file_request_take(uuid)',
                           'public.source_candidates_record(jsonb)', 'public.source_candidates_due(integer,uuid[])',
                           'public.source_discovery_probe_queue(text,uuid[],integer,integer)',
                           'public.source_discovery_gate_record(jsonb)', 'public.source_discovery_gate_open(text)',
                           'public.source_discovery_gate_status(text)', 'public.collector_api_shows_sweep()'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute')
       or not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL grants or security of %', f;
    end if;
  end loop;
  if has_function_privilege('authenticated', 'public.source_discovery_zone_needs_country(text)', 'execute')
     or has_function_privilege('anon', 'public.source_candidates_member_hour()', 'execute') then
    raise exception 'FAIL client execute on an internal function';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'prune-place-rate-log') then
    raise exception 'FAIL prune-place-rate-log is not scheduled';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'source_candidates' and column_name = 'error_since') then
    raise exception 'FAIL source_candidates.error_since is missing';
  end if;
  if public.source_discovery_gate_min_required() <> 6 then
    raise exception 'FAIL the gate floor is not 6';
  end if;
  insert into rf_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Lifecycle: live sources that keep failing
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_r   uuid := current_setting('t.rn')::uuid;
  v_c   uuid;
  v_row public.source_candidates%rowtype;
  i     integer;
begin
  insert into public.source_candidates (host, url, region_id, origin, score, status, feed_kind, feed_url, ok_days, last_ok_on)
  values ('aptest-' || v_tag || '-live.org', 'https://aptest-' || v_tag || '-live.org/', v_r, 'osm', 50, 'enabled', 'rss',
          'https://aptest-' || v_tag || '-live.org/feed', 2, current_date - 1)
  returning id into v_c;

  for i in 1..2 loop
    perform public.source_candidates_record(pg_temp.res(v_c, 'gh-e' || i || '-' || v_tag, '{"outcome": "error", "requests": 3, "errors": 3}'));
  end loop;
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.status <> 'enabled' or v_row.error_runs <> 2 or v_row.error_since <> (now() at time zone 'UTC')::date then
    raise exception 'FAIL two error runs changed a live source too early';
  end if;
  perform public.source_candidates_record(pg_temp.res(v_c, 'gh-e3-' || v_tag, '{"outcome": "error", "requests": 3, "errors": 3}'));
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.status <> 'paused' or v_row.reason <> 'error_runs'
     or v_row.retry_after < now() + interval '6 days' or v_row.retry_after > now() + interval '8 days' then
    raise exception 'FAIL 3 error runs did not pause a live source for a week';
  end if;
  if exists (select 1 from public.feed_sources f where f.candidate_id = v_c and f.enabled) then
    raise exception 'FAIL a paused source is still switched on';
  end if;

  -- A good run on its weekly retry: enabled again, errors reset.
  perform public.source_candidates_record(pg_temp.res(v_c, 'gh-ok-' || v_tag, '{"outcome": "ok", "items": 2, "in_region": 2, "requests": 2, "errors": 0}'));
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.status <> 'enabled' or v_row.error_runs <> 0 or v_row.error_since is not null then
    raise exception 'FAIL a good run did not reset the errors';
  end if;

  -- 30 days of errors: rejected, retry in 30 days, row off.
  update public.source_candidates set error_runs = 1, error_since = current_date - 31 where id = v_c;
  perform public.source_candidates_record(pg_temp.res(v_c, 'gh-e30-' || v_tag, '{"outcome": "error", "requests": 3, "errors": 3}'));
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.status <> 'rejected' or v_row.reason <> 'errors_30_days'
     or v_row.retry_after < now() + interval '29 days' then
    raise exception 'FAIL 30 days of errors did not reject a live source';
  end if;
  if exists (select 1 from public.feed_sources f where f.candidate_id = v_c and f.enabled) then
    raise exception 'FAIL a rejected source is still switched on';
  end if;
  insert into rf_lines (line) values ('lifecycle errors: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Privacy: hour-rounded member times, pruned rate rows
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  u1    uuid := current_setting('t.u1')::uuid;
  v_c   uuid;
  v_row public.source_candidates%rowtype;
  v_n   integer;
begin
  insert into public.source_candidates (host, url, origin, review_status, suggest_count)
  values ('aptest-' || v_tag || '-sugg.org', 'https://aptest-' || v_tag || '-sugg.org/', 'member', 'pending', 1)
  returning id into v_c;
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.created_at <> date_trunc('hour', v_row.created_at) or v_row.updated_at <> date_trunc('hour', v_row.updated_at)
     or v_row.status_at <> date_trunc('hour', v_row.status_at) then
    raise exception 'FAIL a member candidate kept an exact time';
  end if;
  update public.source_candidates set suggest_count = suggest_count + 1 where id = v_c;
  select * into v_row from public.source_candidates where id = v_c;
  if v_row.updated_at <> date_trunc('hour', v_row.updated_at) then
    raise exception 'FAIL a counted suggestion kept an exact time';
  end if;
  -- An automatic candidate keeps its exact time.
  insert into public.source_candidates (host, url, origin)
  values ('aptest-' || v_tag || '-auto.org', 'https://aptest-' || v_tag || '-auto.org/', 'osm')
  returning id into v_c;
  if (select created_at from public.source_candidates where id = v_c) <> now() then
    raise exception 'FAIL an automatic candidate time was rounded';
  end if;

  insert into public.place_rate_log (user_id, kind, created_at)
  values (u1, 'calendar', now() - interval '2 days'), (u1, 'add', now() - interval '25 hours'), (u1, 'calendar', now());
  perform public.place_rate_log_prune();
  select count(*) into v_n from public.place_rate_log where user_id = u1;
  if v_n <> 1 then
    raise exception 'FAIL rate rows older than a day were kept (or a fresh one dropped)';
  end if;
  delete from public.place_rate_log where user_id = u1;
  insert into rf_lines (line) values ('privacy: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Gate floor and runs a day
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  h1    text := md5('rf-pass-' || v_tag);
  h2    text := md5('rf-fail-' || v_tag);
  h3    text := md5('rf-low-' || v_tag);
  v     jsonb;
begin
  -- Only this transaction's runs count (rolled back below).
  delete from public.source_discovery_gates where created_at > now() - interval '24 hours';

  if pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$, jsonb_build_object(
       'run_id', 'gate-low-' || v_tag, 'probe_hash', h3, 'region', 'atl', 'expected', 9, 'required', 1, 'found', 1)))
       not like '%gate_invalid%' then
    raise exception 'FAIL a gate run with required 1 was taken';
  end if;
  if pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$, jsonb_build_object(
       'run_id', 'gate-low2-' || v_tag, 'probe_hash', h3, 'region', 'atl', 'expected', 5, 'required', 5, 'found', 5)))
       not like '%gate_invalid%' then
    raise exception 'FAIL a gate run with expected and required 5 was taken';
  end if;

  v := public.source_discovery_gate_record(jsonb_build_object(
    'run_id', 'gate-p-' || v_tag, 'probe_hash', h1, 'region', 'atl', 'expected', 9, 'required', 6, 'found', 6));
  if not (v ->> 'passed')::boolean or not public.source_discovery_gate_open(h1) then
    raise exception 'FAIL a passing gate run at the floor did not open the gate';
  end if;
  v := public.source_discovery_gate_record(jsonb_build_object(
    'run_id', 'gate-f-' || v_tag, 'probe_hash', h2, 'region', 'atl', 'expected', 9, 'required', 6, 'found', 2));
  if (v ->> 'passed')::boolean or not (v ->> 'recorded')::boolean then
    raise exception 'FAIL the second gate run of the day';
  end if;
  if pg_temp.try(format($q$select public.source_discovery_gate_record(%L::jsonb)$q$, jsonb_build_object(
       'run_id', 'gate-3-' || v_tag, 'probe_hash', h2, 'region', 'atl', 'expected', 9, 'required', 6, 'found', 9)))
       not like '%gate_rate_limited%' then
    raise exception 'FAIL a third gate run in 24 hours was taken';
  end if;
  v := public.source_discovery_gate_record(jsonb_build_object(
    'run_id', 'gate-p-' || v_tag, 'probe_hash', h1, 'region', 'atl', 'expected', 9, 'required', 6, 'found', 6));
  if not (v ->> 'repeat')::boolean then
    raise exception 'FAIL a repeated run id did not answer as a repeat';
  end if;
  v := public.source_discovery_gate_status(h1);
  if (v ->> 'runs_24h')::int <> 2 or (v ->> 'max_runs_24h')::int <> 2 or not (v ->> 'open')::boolean then
    raise exception 'FAIL gate status runs_24h';
  end if;

  -- A run stored with a required below the floor never opens the gate.
  insert into public.source_discovery_gates (run_id, probe_hash, region, expected, required, found, passed)
  values ('gate-direct-' || v_tag, h3, 'atl', 9, 1, 1, true);
  if public.source_discovery_gate_open(h3) then
    raise exception 'FAIL a run below the floor opened the gate';
  end if;
  perform set_config('t.hash', h1, true);
  insert into rf_lines (line) values ('gate floor and daily runs: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. EU gate across a border
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_rn  uuid := current_setting('t.rn')::uuid;
  v_rz  uuid := current_setting('t.rz')::uuid;
  v_rx  uuid := current_setting('t.rx')::uuid;
  v     jsonb;
  v_got text[];
  v_want text[];
begin
  if coalesce((select value from public.meta where key = 'eu_discovery'), 'off') <> 'off' then
    raise exception 'FAIL setup: eu_discovery is on';
  end if;
  insert into public.source_candidates (host, url, region_id, origin, country, score)
  values ('aptest-' || v_tag || '-z-none.org', 'https://aptest-' || v_tag || '-z-none.org/', v_rz, 'osm', null, 90),
         ('aptest-' || v_tag || '-z-ch.org', 'https://aptest-' || v_tag || '-z-ch.org/', v_rz, 'osm', 'CH', 90),
         ('aptest-' || v_tag || '-z-de.org', 'https://aptest-' || v_tag || '-z-de.org/', v_rz, 'wikidata', 'DE', 90),
         ('aptest-' || v_tag || '-n-none.org', 'https://aptest-' || v_tag || '-n-none.org/', v_rn, 'osm', null, 90),
         ('aptest-' || v_tag || '-x-none.org', 'https://aptest-' || v_tag || '-x-none.org/', v_rx, 'osm', null, 90);
  insert into public.source_candidates (host, url, region_id, origin, review_status, score)
  values ('aptest-' || v_tag || '-z-member.org', 'https://aptest-' || v_tag || '-z-member.org/', v_rz, 'member', 'approved', 90);
  v_want := array['aptest-' || v_tag || '-n-none.org', 'aptest-' || v_tag || '-z-ch.org', 'aptest-' || v_tag || '-z-member.org'];

  v := public.source_candidates_due(500, array[v_rn, v_rz, v_rx]);
  select array_agg(e.value ->> 'host' order by e.value ->> 'host') into v_got
    from jsonb_array_elements(v) e where e.value ->> 'host' like 'aptest-' || v_tag || '-%';
  if v_got is distinct from v_want then
    raise exception 'FAIL source_candidates_due EU gate across a border (% candidates)', coalesce(cardinality(v_got), 0);
  end if;
  v := public.source_discovery_probe_queue(current_setting('t.hash'), array[v_rn, v_rz, v_rx], 150, 500);
  select array_agg(e.value ->> 'host' order by e.value ->> 'host') into v_got
    from jsonb_array_elements(v) e where e.value ->> 'host' like 'aptest-' || v_tag || '-%';
  if v_got is distinct from v_want then
    raise exception 'FAIL probe queue EU gate across a border (% candidates)', coalesce(cardinality(v_got), 0);
  end if;
  if public.source_discovery_allowed('osm', null, null) or not public.source_discovery_allowed('member', null, null) then
    raise exception 'FAIL source_discovery_allowed without a region';
  end if;
  insert into rf_lines (line) values ('eu gate across a border: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Ticketing-only events keep no text
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_tag    text := current_setting('t.tag');
  u1       uuid := current_setting('t.u1')::uuid;
  v_region jsonb := jsonb_build_object('lat', -61.4, 'lng', -151.4, 'radius_km', 50,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_tm     jsonb;
  v_cal    jsonb;
  v_res    jsonb;
  v_old    uuid;
  v_gone   uuid;
  v_rsvp   uuid;
  v_shared uuid;
  v_new    uuid;
begin
  if exists (select 1 from public.feed_sources where slug in ('ticketmaster-test-rf', 'test-rf-cal')) then
    raise exception 'setup: test sources already exist';
  end if;
  v_tm := jsonb_build_object('slug', 'ticketmaster-test-rf', 'kind', 'ticketmaster',
    'url', 'https://app.ticketmaster.com/discovery/v2/events.json', 'name', 'Ticketmaster',
    'attribution', 'Event data from the Ticketmaster Discovery API (ticketmaster.com).',
    'homepage_url', 'https://www.ticketmaster.com/', 'lane', 'api', 'enabled', true,
    'hubs', '[]'::jsonb, 'region', v_region);
  v_cal := jsonb_build_object('slug', 'test-rf-cal', 'kind', 'ics', 'url', 'https://hall.example.org/rf.ics',
    'name', 'Test Hall calendar', 'attribution', 'Listed from the Test Hall public calendar (hall.example.org).',
    'lane', 'feed', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_cal, jsonb_build_array(
    jsonb_build_object('external_id', 'hall-shared', 'title', 'Zzr Hall Night ' || v_tag, 'starts_at', v_t + interval '1 day',
      'url', 'https://hall.example.org/e/night', 'lat', -61.41, 'lng', -151.41)), true, true);
  if (v_res->>'inserted')::int <> 1 then raise exception 'FAIL calendar setup'; end if;
  v_res := public.collector_ingest_events(v_tm, jsonb_build_array(
    jsonb_build_object('external_id', 'tm-old', 'title', 'Zzr Old Concert ' || v_tag, 'starts_at', v_t,
      'url', 'https://www.ticketmaster.com/event/RFOLD', 'lat', -61.41, 'lng', -151.41),
    jsonb_build_object('external_id', 'tm-gone', 'title', 'Zzr Gone Match ' || v_tag, 'starts_at', v_t + interval '1 hour',
      'url', 'https://www.ticketmaster.com/event/RFGONE', 'lat', -61.41, 'lng', -151.41),
    jsonb_build_object('external_id', 'tm-rsvp', 'title', 'Zzr Kept Show ' || v_tag, 'starts_at', v_t + interval '2 hours',
      'url', 'https://www.ticketmaster.com/event/RFRSVP', 'lat', -61.41, 'lng', -151.41, 'price_text', 'From 40'),
    jsonb_build_object('external_id', 'tm-shared', 'title', 'Zzr Hall Night ' || v_tag, 'starts_at', v_t + interval '1 day',
      'url', 'https://www.ticketmaster.com/event/RFSHARED', 'lat', -61.41, 'lng', -151.41),
    jsonb_build_object('external_id', 'tm-new', 'title', 'Zzr New Concert ' || v_tag, 'starts_at', v_t + interval '3 hours',
      'url', 'https://www.ticketmaster.com/event/RFNEW', 'lat', -61.41, 'lng', -151.41)), true, true);
  if (v_res->>'inserted')::int <> 4 or (v_res->>'linked_duplicates')::int <> 1 then
    raise exception 'FAIL ticketmaster setup';
  end if;
  select ei.event_id into v_old from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-rf' and ei.external_id = 'tm-old';
  select ei.event_id into v_gone from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-rf' and ei.external_id = 'tm-gone';
  select ei.event_id into v_rsvp from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-rf' and ei.external_id = 'tm-rsvp';
  select ei.event_id into v_shared from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-rf-cal' and ei.external_id = 'hall-shared';
  select ei.event_id into v_new from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-rf' and ei.external_id = 'tm-new';

  update public.events
     set starts_at = now() - interval '10 days', ends_at = now() - interval '10 days' + interval '2 hours',
         description = 'Doors at seven.'
   where id in (v_old, v_rsvp, v_shared);
  update public.events
     set status = 'cancelled', cancelled_at = now() - interval '8 days', cancel_reason = 'No longer listed by the source.'
   where id = v_gone;
  insert into public.rsvps (event_id, user_id, status) values (v_rsvp, u1, 'going');

  v_res := public.collector_api_shows_sweep();
  if (v_res ->> 'events_deleted')::int < 2 or (v_res ->> 'events_blanked')::int < 1 then
    raise exception 'FAIL sweep counts';
  end if;
  if exists (select 1 from public.events where id in (v_old, v_gone))
     or exists (select 1 from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
                 where fs.slug = 'ticketmaster-test-rf' and ei.external_id in ('tm-old', 'tm-gone')) then
    raise exception 'FAIL an old ticketing-only event (or its import row) was kept';
  end if;
  if not exists (select 1 from public.events where id = v_rsvp and description = '' and cover_url is null and price_text is null) then
    raise exception 'FAIL an old ticketing-only event with an RSVP was not blanked';
  end if;
  if not exists (select 1 from public.events where id = v_shared and description = 'Doors at seven.') then
    raise exception 'FAIL an event another source lists was touched';
  end if;
  if not exists (select 1 from public.events where id = v_new and status = 'published') then
    raise exception 'FAIL an upcoming ticketing event was touched';
  end if;
  insert into rf_lines (line) values ('ticketing sweep: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 7. place_file_request_take
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  u2 uuid := current_setting('t.u2')::uuid;
  v  jsonb;
begin
  if (public.place_file_request_take(u2) ->> 'error') is distinct from 'onboarding_required'
     or (public.place_file_request_take(gen_random_uuid()) ->> 'error') is distinct from 'onboarding_required'
     or (public.place_file_request_take(null) ->> 'error') is distinct from 'onboarding_required' then
    raise exception 'FAIL a member who is not onboarded got a place-files call';
  end if;
  v := public.place_file_request_take(u1);
  if not (v ->> 'ok')::boolean then
    raise exception 'FAIL an onboarded member was refused';
  end if;
  insert into public.place_rate_log (user_id, kind) select u1, 'file' from generate_series(1, 59);
  if (public.place_file_request_take(u1) ->> 'error') is distinct from 'rate_limited' then
    raise exception 'FAIL the 61st call in an hour was allowed';
  end if;
  update public.profiles set status = 'suspended' where id = u1;
  delete from public.place_rate_log where user_id = u1;
  if (public.place_file_request_take(u1) ->> 'error') is distinct from 'onboarding_required' then
    raise exception 'FAIL a suspended member got a place-files call';
  end if;
  insert into rf_lines (line) values ('place-files limit: ok');
end $$;

select line as discovery_review_fixes from (
  select 0 as n, 'discovery_review_fixes: all assertions passed' as line
  union all
  select n, line from rf_lines) x
order by n;

rollback;
