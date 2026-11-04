-- ============================================================================
-- Staging check for migration 20261210000100_source_discovery.sql (migration
-- 46, D-042 slice 7: discovered sources and "Suggest a calendar"). One
-- transaction: throwaway members, a collector region in the Southern Ocean
-- and candidates on invented hosts (aptest-<tag>-*.org; nothing is fetched),
-- asserts in DO blocks that raise on failure, then rolls everything back.
-- Prints pass/fail lines only, never ids, URLs, hosts or points.
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 Static: version, grants, RLS, no user-id column on the new tables, the
--     denylist rows.
--   2 source_url_check: the D-040 URL rules.
--   3 suggest_calendar: anon and not-onboarded refused; bad and denylisted
--     URLs refused and not counted; a new host is a pending member candidate
--     in the member's region with no user id; the same host again (www.) is
--     already_known; 5 a day (rate_limited).
--   4 Moderation: only moderators read candidates and decide; approve,
--     reject, item_not_pending.
--   5 source_candidates_due: unapproved suggestions, locked and rejected
--     rows, and EU automatic candidates (while eu_discovery is off) are left
--     out; approved suggestions and EU suggestions are in.
--   6 source_candidates_record: probation after one good day (feed_sources
--     row off), a second good run the same day does not enable, a repeat run
--     id is ignored, enabled after a good run on a second day (row on);
--     collector_sources_for_regions lists it as a seed; error rate, empty
--     runs (paused, weekly retry), blocked, robots, denylisted (locked),
--     results_invalid writes nothing.
--   7 collector_ingest_events with p_enable leaves discovered rows as the
--     lifecycle set them and creates a new disc- row off.
--   8 Account deletion removes the member's suggestion rate rows; the
--     candidate stays, with no link to anyone.
-- ============================================================================
begin;

create temp table sd_lines (n serial, line text);
grant insert, select on sd_lines to anon, authenticated;
grant usage on sequence sd_lines_n_seq to anon, authenticated;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

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
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.42' then
    raise exception 'FAIL schema_version is not 2.42';
  end if;
  if coalesce((select value from public.meta where key = 'eu_discovery'), '') not in ('off', 'on') then
    raise exception 'FAIL meta.eu_discovery missing';
  end if;
  foreach f in array array['public.source_candidates_add(jsonb)', 'public.source_candidates_due(integer,uuid[])',
                           'public.source_candidates_record(jsonb)', 'public.collector_sources_for_regions(uuid[])',
                           'public.source_url_check(text)', 'public.collector_host_denied(text)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute')
       or not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then
      raise exception 'FAIL grants or security of %', f;
    end if;
  end loop;
  foreach f in array array['public.suggest_calendar(text)', 'public.mod_review_source_candidate(uuid,boolean,text)'] loop
    if has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL grants of %', f;
    end if;
  end loop;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relname in ('source_candidates', 'source_probe_results', 'collector_denylist')
                and not c.relrowsecurity) then
    raise exception 'FAIL RLS off on a new table';
  end if;
  if has_table_privilege('authenticated', 'public.source_candidates', 'insert')
     or has_table_privilege('authenticated', 'public.source_candidates', 'update')
     or has_table_privilege('anon', 'public.source_candidates', 'select')
     or has_table_privilege('authenticated', 'public.source_probe_results', 'insert')
     or has_table_privilege('authenticated', 'public.collector_denylist', 'insert') then
    raise exception 'FAIL client write or anon read on a new table';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name in ('source_candidates', 'source_probe_results')
                and (column_name like '%user%' or column_name like '%by')) then
    raise exception 'FAIL a user column on a discovery table';
  end if;
  if (select count(*) from public.collector_denylist) < 22 then
    raise exception 'FAIL denylist rows';
  end if;
  if (select count(*) from information_schema.columns where table_schema = 'public' and table_name = 'feed_sources'
        and column_name in ('discovery_status', 'candidate_id')) <> 2 then
    raise exception 'FAIL feed_sources columns';
  end if;
  insert into sd_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. source_url_check
-- ---------------------------------------------------------------------------
do $$
declare
  c record;
  v jsonb;
begin
  for c in select * from (values
      ('http://Www.Aptest-Lib.org/events#top', 'ok', 'https://www.aptest-lib.org/events'),
      ('webcal://cal.aptest-city.gov/feed.ics?c=1', 'ok', 'https://cal.aptest-city.gov/feed.ics?c=1'),
      ('https://aptest-x.org', 'ok', 'https://aptest-x.org/'),
      ('https://aptest-x.org:443?y=1', 'ok', 'https://aptest-x.org/?y=1'),
      ('', 'url_invalid', null),
      ('not a url', 'url_invalid', null),
      ('ftp://aptest-x.org/', 'url_not_https', null),
      ('https://me:pw@aptest-x.org/', 'url_has_credentials', null),
      ('https://aptest-x.org:8443/', 'url_port', null),
      ('https://10.1.2.3/', 'url_private_host', null),
      ('https://[::1]/', 'url_private_host', null),
      ('https://localhost/', 'url_private_host', null),
      ('https://intranet/', 'url_private_host', null),
      ('https://printer.local/', 'url_private_host', null),
      ('https://svc.internal/', 'url_private_host', null),
      ('https://www.facebook.com/events/1', 'url_denylisted', null),
      ('https://m.facebook.com/x', 'url_denylisted', null),
      ('https://www.eventbrite.co.uk/e/1', 'url_denylisted', null),
      ('https://www.meetup.com/g/', 'url_denylisted', null),
      ('https://notfacebook.com/', 'ok', 'https://notfacebook.com/'),
      ('https://aptest-' || repeat('x', 500) || '.org/', 'url_too_long', null)) t(u, want, url) loop
    v := public.source_url_check(c.u);
    if c.want = 'ok' then
      if not (v ->> 'ok')::boolean or v ->> 'url' <> c.url then
        raise exception 'FAIL source_url_check accepted case % gave %', c.want, v ->> 'error';
      end if;
    elsif (v ->> 'ok')::boolean or v ->> 'error' <> c.want then
      raise exception 'FAIL source_url_check case % gave %', c.want, coalesce(v ->> 'error', 'ok');
    end if;
  end loop;
  if public.source_url_check('https://WWW.Aptest-Lib.org/a') ->> 'host' <> 'aptest-lib.org' then
    raise exception 'FAIL dedupe host';
  end if;
  insert into sd_lines (line) values ('source_url_check: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- member with a home in the test region
  u2 uuid := gen_random_uuid();   -- member, no home
  u3 uuid := gen_random_uuid();   -- not onboarded
  um uuid := gen_random_uuid();   -- moderator
  v_r uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'sd-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2, u3, um]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2, u3, um);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (u1, u2, um);
  insert into public.user_roles (user_id, role) values (um, 'moderator');

  insert into public.collector_regions (point, radius_km, label, priority)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-125.0, -63.0), 4326)::extensions.geography, 25, null, 100)
  returning id into v_r;
  update public.profile_private
     set home_point = extensions.ST_SetSRID(extensions.ST_MakePoint(-125.05, -63.05), 4326)::extensions.geography
   where user_id = u1;

  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.u3', u3::text, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.r', v_r::text, true);
  perform set_config('t.tag', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. suggest_calendar
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  u1 uuid := current_setting('t.u1')::uuid;
  v jsonb;
  e text;
  i integer;
begin
  perform pg_temp.as_user(null);
  execute 'set local role anon';
  e := pg_temp.try($q$select public.suggest_calendar('https://aptest-anon.org/')$q$);
  execute 'reset role';
  if e not like '%permission denied%' then
    raise exception 'FAIL anon can suggest';
  end if;

  perform pg_temp.as_user(current_setting('t.u3')::uuid);
  execute 'set local role authenticated';
  e := pg_temp.try($q$select public.suggest_calendar('https://aptest-x.org/')$q$);
  execute 'reset role';
  if e <> 'onboarding_required' then
    raise exception 'FAIL not onboarded: %', e;
  end if;

  perform pg_temp.as_user(u1);
  execute 'set local role authenticated';
  e := pg_temp.try($q$select public.suggest_calendar('https://www.facebook.com/aptest/events')$q$);
  if e <> 'url_denylisted' then
    execute 'reset role';
    raise exception 'FAIL denylisted suggestion: %', e;
  end if;
  e := pg_temp.try($q$select public.suggest_calendar('https://localhost:8080/admin')$q$);
  if e <> 'url_port' and e <> 'url_private_host' then
    execute 'reset role';
    raise exception 'FAIL private suggestion: %', e;
  end if;
  v := public.suggest_calendar('http://www.aptest-' || v_tag || '-arts.org/calendar#june');
  if v ->> 'status' <> 'received' then
    execute 'reset role';
    raise exception 'FAIL first suggestion status';
  end if;
  v := public.suggest_calendar('https://aptest-' || v_tag || '-arts.org/other');
  if v ->> 'status' <> 'already_known' then
    execute 'reset role';
    raise exception 'FAIL same host is not already_known';
  end if;
  -- Members cannot read the candidates.
  if exists (select 1 from public.source_candidates) then
    execute 'reset role';
    raise exception 'FAIL a member reads source_candidates';
  end if;
  for i in 3..5 loop
    perform public.suggest_calendar('https://aptest-' || v_tag || '-s' || i || '.org/events');
  end loop;
  e := pg_temp.try(format('select public.suggest_calendar(%L)', 'https://aptest-' || v_tag || '-s6.org/events'));
  execute 'reset role';
  if e <> 'rate_limited' then
    raise exception 'FAIL sixth suggestion: %', e;
  end if;

  if (select count(*) from public.place_rate_log where user_id = u1 and kind = 'calendar') <> 5 then
    raise exception 'FAIL rate rows (refused URLs must not count)';
  end if;
  select to_jsonb(c) into v from public.source_candidates c where c.host = 'aptest-' || v_tag || '-arts.org';
  if v is null or v ->> 'origin' <> 'member' or v ->> 'review_status' <> 'pending' or v ->> 'status' <> 'discovered'
     or (v ->> 'suggest_count')::int <> 2 or v ->> 'region_id' <> current_setting('t.r')
     or v ->> 'url' <> 'https://www.aptest-' || v_tag || '-arts.org/calendar' then
    raise exception 'FAIL member candidate row';
  end if;
  if exists (select 1 from public.source_candidates where host = 'aptest-' || v_tag || '-s6.org') then
    raise exception 'FAIL a rate-limited suggestion was stored';
  end if;

  -- No home: no region.
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  perform public.suggest_calendar('https://aptest-' || v_tag || '-nohome.org/');
  execute 'reset role';
  if (select region_id from public.source_candidates where host = 'aptest-' || v_tag || '-nohome.org') is not null then
    raise exception 'FAIL region without a home';
  end if;
  insert into sd_lines (line) values ('suggest_calendar: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Moderation
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_arts uuid := (select id from public.source_candidates where host = 'aptest-' || v_tag || '-arts.org');
  v_s3 uuid := (select id from public.source_candidates where host = 'aptest-' || v_tag || '-s3.org');
  e text;
  n integer;
begin
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  e := pg_temp.try(format('select public.mod_review_source_candidate(%L, true)', v_arts));
  execute 'reset role';
  if e <> 'forbidden' then
    raise exception 'FAIL a member decided a suggestion: %', e;
  end if;

  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  select count(*) into n from public.source_candidates where review_status = 'pending' and host like 'aptest-' || v_tag || '-%';
  perform public.mod_review_source_candidate(v_arts, true);
  perform public.mod_review_source_candidate(v_s3, false, 'Not a calendar');
  e := pg_temp.try(format('select public.mod_review_source_candidate(%L, false)', v_arts));
  execute 'reset role';
  if n <> 5 then
    raise exception 'FAIL moderator queue count %', n;
  end if;
  if e <> 'item_not_pending' then
    raise exception 'FAIL second decision: %', e;
  end if;
  if (select review_status from public.source_candidates where id = v_arts) <> 'approved'
     or (select status || '/' || review_status || '/' || coalesce(retry_after::text, 'never')
           from public.source_candidates where id = v_s3) <> 'rejected/rejected/never' then
    raise exception 'FAIL moderation result';
  end if;
  insert into sd_lines (line) values ('moderation: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. source_candidates_due and source_candidates_add
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_r uuid := current_setting('t.r')::uuid;
  v jsonb;
  hosts text[];
begin
  v := public.source_candidates_add(jsonb_build_array(
    jsonb_build_object('url', 'https://aptest-' || v_tag || '-library.org/events', 'origin', 'osm', 'region_id', v_r,
                       'name', 'APTest Library', 'place_kind', 'library', 'country', 'US', 'score', 70),
    jsonb_build_object('url', 'https://aptest-' || v_tag || '-museum.de/', 'origin', 'wikidata', 'region_id', v_r,
                       'wikidata_id', 'Q1', 'country', 'DE', 'score', 60),
    jsonb_build_object('url', 'https://www.instagram.com/aptest', 'origin', 'osm'),
    jsonb_build_object('url', 'https://aptest-' || v_tag || '-library.org/other', 'origin', 'osm', 'score', 90),
    jsonb_build_object('url', 'https://aptest-' || v_tag || '-member.org/', 'origin', 'member'),
    '"junk"'::jsonb));
  if v <> '{"added": 2, "known": 1, "denied": 1, "invalid": 2}'::jsonb then
    raise exception 'FAIL source_candidates_add counts %', v;
  end if;
  if (select score from public.source_candidates where host = 'aptest-' || v_tag || '-library.org') <> 90 then
    raise exception 'FAIL known host keeps the higher score';
  end if;
  -- A member suggestion from Germany, approved.
  insert into public.source_candidates (host, url, region_id, origin, review_status, country)
  values ('aptest-' || v_tag || '-verein.de', 'https://aptest-' || v_tag || '-verein.de/termine', v_r, 'member', 'approved', 'DE');

  update public.meta set value = 'off' where key = 'eu_discovery';
  select array_agg(x ->> 'host') into hosts from jsonb_array_elements(public.source_candidates_due(500, array[v_r])) x;
  if not ('aptest-' || v_tag || '-library.org' = any (hosts)) or not ('aptest-' || v_tag || '-arts.org' = any (hosts))
     or not ('aptest-' || v_tag || '-verein.de' = any (hosts)) then
    raise exception 'FAIL due misses an allowed candidate';
  end if;
  if 'aptest-' || v_tag || '-museum.de' = any (hosts) or 'aptest-' || v_tag || '-s4.org' = any (hosts)
     or 'aptest-' || v_tag || '-s3.org' = any (hosts) then
    raise exception 'FAIL due lists an EU automatic, unapproved or rejected candidate';
  end if;
  if (select (x ->> 'host') from jsonb_array_elements(public.source_candidates_due(500, array[v_r])) with ordinality t(x, o) order by o limit 1)
     <> 'aptest-' || v_tag || '-library.org' then
    raise exception 'FAIL due order by score';
  end if;
  update public.meta set value = 'on' where key = 'eu_discovery';
  select array_agg(x ->> 'host') into hosts from jsonb_array_elements(public.source_candidates_due(500, array[v_r])) x;
  if not ('aptest-' || v_tag || '-museum.de' = any (hosts)) then
    raise exception 'FAIL eu_discovery on does not open the EU';
  end if;
  update public.meta set value = 'off' where key = 'eu_discovery';
  insert into sd_lines (line) values ('candidates due and add: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Lifecycle
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_r uuid := current_setting('t.r')::uuid;
  v_lib uuid := (select id from public.source_candidates where host = 'aptest-' || v_tag || '-library.org');
  v_arts uuid := (select id from public.source_candidates where host = 'aptest-' || v_tag || '-arts.org');
  v_s4 uuid := (select id from public.source_candidates where host = 'aptest-' || v_tag || '-s4.org');
  v_den uuid;
  v jsonb;
  c record;
  f record;
  good jsonb := jsonb_build_object('outcome', 'ok', 'kind', 'ics', 'url', 'https://aptest-' || v_tag || '-library.org/events.ics',
                                   'platform', 'ics', 'items', 12, 'in_region', 9, 'requests', 3, 'errors', 0, 'complete', true);
  e text;
begin
  -- Day 1: probation, row off.
  v := public.source_candidates_record(pg_temp.res(v_lib, 'run-a-' || v_tag, good));
  select * into c from public.source_candidates where id = v_lib;
  select * into f from public.feed_sources where candidate_id = v_lib;
  if c.status <> 'probation' or c.ok_days <> 1 or (v ->> 'probation')::int <> 1
     or f.slug <> public.source_candidate_slug(v_lib) or f.enabled or f.discovery_status <> 'probation'
     or not f.collector or f.kind <> 'ics' or f.lane <> 'feed' or f.attribution not like 'Events from APTest Library (%)' then
    raise exception 'FAIL day one';
  end if;
  -- Same day again: still one day. Same run again: repeat.
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-b-' || v_tag, good));
  v := public.source_candidates_record(pg_temp.res(v_lib, 'run-b-' || v_tag, good));
  select * into c from public.source_candidates where id = v_lib;
  if c.status <> 'probation' or c.ok_days <> 1 or c.ok_runs <> 2 or (v ->> 'repeat')::int <> 1 then
    raise exception 'FAIL two runs on one day enabled the source or the repeat counted';
  end if;
  -- Probation sources are already collected (to earn the second day), as seeds.
  v := public.collector_sources_for_regions(array[v_r]);
  if not exists (select 1 from jsonb_array_elements(v) x
                  where x ->> 'candidate_id' = v_lib::text and x #>> '{seed,id}' = public.source_candidate_slug(v_lib)
                    and (x #>> '{seed,enabled}')::boolean and not (x #>> '{seed,verified}')::boolean
                    and x #>> '{seed,kind}' = 'ics') then
    raise exception 'FAIL probation seed';
  end if;
  -- A run with 30% errors is not a good run.
  update public.source_candidates set last_ok_on = last_ok_on - 1 where id = v_lib;
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-c-' || v_tag, good || '{"requests": 10, "errors": 3}'));
  if (select status || '/' || ok_days from public.source_candidates where id = v_lib) <> 'probation/1' then
    raise exception 'FAIL error rate';
  end if;
  -- A partial read is not either.
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-c2-' || v_tag, good || '{"complete": false}'));
  -- Day 2: enabled, row on.
  v := public.source_candidates_record(pg_temp.res(v_lib, 'run-d-' || v_tag, good));
  select * into c from public.source_candidates where id = v_lib;
  select * into f from public.feed_sources where candidate_id = v_lib;
  if c.status <> 'enabled' or c.ok_days <> 2 or not f.enabled or f.discovery_status <> 'enabled' or (v ->> 'enabled')::int <> 1 then
    raise exception 'FAIL day two';
  end if;
  v := public.collector_sources_for_regions(array[v_r]);
  if not exists (select 1 from jsonb_array_elements(v) x
                  where x ->> 'candidate_id' = v_lib::text and (x #>> '{seed,verified}')::boolean) then
    raise exception 'FAIL enabled seed';
  end if;
  if exists (select 1 from jsonb_array_elements(v) x where x ->> 'candidate_id' = v_arts::text) then
    raise exception 'FAIL a discovered candidate is a seed before its probe';
  end if;

  -- Three empty runs: paused, row off, out of the seeds until the weekly retry.
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-e1-' || v_tag, '{"outcome": "empty", "items": 0}'));
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-e2-' || v_tag, '{"outcome": "ok", "items": 4, "in_region": 0}'));
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-e3-' || v_tag, '{"outcome": "no_feed"}'));
  select * into c from public.source_candidates where id = v_lib;
  if c.status <> 'paused' or c.retry_after < now() + interval '6 days' or c.ok_days <> 2
     or (select enabled from public.feed_sources where candidate_id = v_lib) then
    raise exception 'FAIL three empty runs';
  end if;
  if exists (select 1 from jsonb_array_elements(public.collector_sources_for_regions(array[v_r])) x where x ->> 'candidate_id' = v_lib::text) then
    raise exception 'FAIL a paused source is a seed before its retry';
  end if;
  update public.source_candidates set retry_after = now() - interval '1 minute' where id = v_lib;
  if not exists (select 1 from jsonb_array_elements(public.collector_sources_for_regions(array[v_r])) x where x ->> 'candidate_id' = v_lib::text) then
    raise exception 'FAIL a paused source is not retried';
  end if;
  -- A good run brings it straight back (it already had two days).
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-f-' || v_tag, good));
  if (select status from public.source_candidates where id = v_lib) <> 'enabled'
     or not (select enabled from public.feed_sources where candidate_id = v_lib) then
    raise exception 'FAIL retry after pause';
  end if;

  -- Blocked: rejected at once, never retried, good days reset.
  perform public.source_candidates_record(pg_temp.res(v_lib, 'run-g-' || v_tag, '{"outcome": "blocked"}'));
  select * into c from public.source_candidates where id = v_lib;
  if c.status <> 'rejected' or c.retry_after is not null or c.ok_days <> 0
     or (select enabled::text || discovery_status from public.feed_sources where candidate_id = v_lib) <> 'falserejected' then
    raise exception 'FAIL blocked';
  end if;

  -- An approved member suggestion: probe finds nothing, rejected with a retry.
  perform public.source_candidates_record(pg_temp.res(v_arts, 'run-h-' || v_tag, '{"outcome": "robots"}'));
  if (select status || '/' || reason from public.source_candidates where id = v_arts) <> 'rejected/robots'
     or (select retry_after from public.source_candidates where id = v_arts) < now() + interval '29 days' then
    raise exception 'FAIL robots';
  end if;
  -- An unapproved suggestion takes no results.
  v := public.source_candidates_record(pg_temp.res(v_s4, 'run-i-' || v_tag, good));
  if (v ->> 'skipped')::int <> 1 or (select status from public.source_candidates where id = v_s4) <> 'discovered' then
    raise exception 'FAIL an unapproved suggestion was recorded';
  end if;

  -- A host that is denylisted (as after a later terms change): rejected and locked.
  insert into public.source_candidates (host, url, region_id, origin)
  values ('aptest-' || v_tag || '.fb.com', 'https://aptest-' || v_tag || '.fb.com/', v_r, 'osm') returning id into v_den;
  perform public.source_candidates_record(pg_temp.res(v_den, 'run-j-' || v_tag, good));
  if (select status || '/' || locked from public.source_candidates where id = v_den) <> 'rejected/true'
     or exists (select 1 from public.feed_sources where candidate_id = v_den) then
    raise exception 'FAIL denylisted host';
  end if;

  -- One bad entry: nothing is written.
  e := pg_temp.try(format('select public.source_candidates_record(%L::jsonb)',
         (pg_temp.res(v_s4, 'run-k-' || v_tag, '{"outcome": "ok"}') || '[{"candidate_id": "x", "run_id": "r", "outcome": "ok"}]'::jsonb)::text));
  if e <> 'results_invalid' or exists (select 1 from public.source_probe_results where run_id = 'run-k-' || v_tag) then
    raise exception 'FAIL results_invalid';
  end if;
  if (select count(*) from public.source_probe_results where candidate_id = v_lib) <> 10 then
    raise exception 'FAIL probe result rows';
  end if;
  -- The constraint behind the two-days rule.
  e := pg_temp.try(format('update public.source_candidates set status = %L, ok_days = 1 where id = %L', 'enabled', v_arts));
  if e not like '%source_candidates_enabled_two_days%' and e not like '%source_candidates_live_has_feed%' then
    raise exception 'FAIL the table allows enabled without two days: %', e;
  end if;
  insert into sd_lines (line) values ('lifecycle: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 7. collector_ingest_events and discovered rows
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_r uuid := current_setting('t.r')::uuid;
  v_id uuid;
  v_slug text;
  v jsonb;
begin
  insert into public.source_candidates (host, url, region_id, origin, name)
  values ('aptest-' || v_tag || '-hall.org', 'https://aptest-' || v_tag || '-hall.org/', v_r, 'osm', 'APTest Hall') returning id into v_id;
  perform public.source_candidates_record(pg_temp.res(v_id, 'run-l-' || v_tag,
    jsonb_build_object('outcome', 'ok', 'kind', 'rss', 'url', 'https://aptest-' || v_tag || '-hall.org/feed', 'items', 2, 'in_region', 2)));
  v_slug := public.source_candidate_slug(v_id);
  v := public.collector_ingest_events(
    jsonb_build_object('slug', v_slug, 'kind', 'rss', 'url', 'https://aptest-' || v_tag || '-hall.org/feed', 'name', 'APTest Hall',
                       'attribution', 'Events from APTest Hall (aptest-hall.org)', 'lane', 'feed', 'enabled', true),
    '[]'::jsonb, false, true, 'run-m-' || v_tag, null);
  if (v ->> 'enabled')::boolean or (select enabled from public.feed_sources where slug = v_slug) then
    raise exception 'FAIL p_enable switched on a probation source';
  end if;
  -- A disc- slug the lifecycle never made starts off.
  v := public.collector_ingest_events(
    jsonb_build_object('slug', 'disc-000000' || substr(v_tag, 1, 6), 'kind', 'rss', 'url', 'https://aptest-' || v_tag || '-other.org/feed',
                       'name', 'APTest Other', 'attribution', 'Events from APTest Other (aptest-other.org)', 'lane', 'feed', 'enabled', true),
    '[]'::jsonb, false, true, 'run-n-' || v_tag, null);
  if (v ->> 'enabled')::boolean or not (v ->> 'created')::boolean then
    raise exception 'FAIL a new disc- row was switched on';
  end if;
  -- Day two: enabled by the lifecycle; p_enable keeps it on.
  update public.source_candidates set last_ok_on = last_ok_on - 1 where id = v_id;
  perform public.source_candidates_record(pg_temp.res(v_id, 'run-o-' || v_tag,
    '{"outcome": "ok", "items": 2, "in_region": 2}'::jsonb));
  v := public.collector_ingest_events(
    jsonb_build_object('slug', v_slug, 'kind', 'rss', 'url', 'https://aptest-' || v_tag || '-hall.org/feed', 'name', 'APTest Hall',
                       'attribution', 'Events from APTest Hall (aptest-hall.org)', 'lane', 'feed', 'enabled', true),
    '[]'::jsonb, false, true, 'run-p-' || v_tag, null);
  if not (v ->> 'enabled')::boolean then
    raise exception 'FAIL p_enable switched off an enabled discovered source';
  end if;
  insert into sd_lines (line) values ('collector_ingest_events: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  v_tag text := current_setting('t.tag');
begin
  perform pg_temp.as_user(u1);
  execute 'set local role authenticated';
  perform public.request_account_deletion('test');
  execute 'reset role';
  if exists (select 1 from public.place_rate_log where user_id = u1) then
    raise exception 'FAIL deletion kept the suggestion rate rows';
  end if;
  if not exists (select 1 from public.source_candidates where host = 'aptest-' || v_tag || '-s5.org') then
    raise exception 'FAIL deletion removed a suggested calendar';
  end if;
  insert into sd_lines (line) values ('account deletion: ok');
end $$;

select line as source_discovery from (
  select 0 as n, 'source_discovery: all assertions passed' as line
  union all
  select n, line from sd_lines) x
order by n;

rollback;
