-- ============================================================================
-- Staging check for migration 20261227000100_collector_health_geocode.sql
-- (migration 63), the collector health panel and alerts
-- (docs/design/collector/COLLECTOR_COMPLETION.md 2.6). One transaction:
-- throwaway accounts and a test source on an invented host
-- (aptest-<tag>-*.org; nothing is fetched); asserts in DO blocks that raise on
-- failure, then rolls everything back. Prints pass/fail lines only.
--
--   1 Static: RLS and grants; mod_collector_health refuses a member.
--   2 collector_runs_record: a run is stored, a repeat updates it, text in
--     stats is refused.
--   3 A source not seen for 30 hours is stale.
--   4 Three runs that read nothing make a source failing; a good run clears it.
--   5 A job with no run for 27 hours is overdue.
--   6 Alerts: every moderator gets each alert once a UTC day (a second call
--     adds nothing), a member never; claim_pending_notifications sends no
--     email or push for them.
-- ============================================================================
begin;

-- Migration 77: the account-wide email budget must not hide the rows under test.
insert into public.meta (key, value) values ('email_daily_cap_total', '9999999'), ('email_monthly_cap_total', '9999999')
  on conflict (key) do update set value = excluded.value;

create temp table ch_lines (n serial, line text);
grant insert, select on ch_lines to anon, authenticated, service_role;
grant usage on sequence ch_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.src(p_tag text) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-health', 'kind', 'ics', 'url', 'https://aptest-' || p_tag || '-health.org/cal.ics',
    'name', 'Health test source', 'attribution', 'Listed from a test calendar.', 'lane', 'feed', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.items(p_tag text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'external_id', 'h1', 'title', 'Health test item ' || p_tag,
    'starts_at', to_char(date_trunc('hour', now()) + interval '4 days', 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://aptest-' || p_tag || '-health.org/e/1', 'location', 'Test hall'));
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  um uuid := gen_random_uuid();
  u1 uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'ch-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[um, u1]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (um, u1);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (um, u1);
  insert into public.user_roles (user_id, role) values (um, 'moderator');
  perform public.collector_ingest_events(pg_temp.src(v_tag), pg_temp.items(v_tag), true, true, 'ch-' || v_tag || '-0');
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.u1', u1::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.collector_job_runs'::regclass)
     or has_table_privilege('anon', 'public.collector_job_runs', 'select')
     or has_table_privilege('authenticated', 'public.collector_job_runs', 'insert')
     or has_function_privilege('authenticated', 'public.collector_runs_record(jsonb)', 'execute')
     or has_function_privilege('anon', 'public.mod_collector_health()', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_collector_health()', 'execute')
     or has_function_privilege('authenticated', 'public.collector_health_alerts()', 'execute')
     or has_function_privilege('authenticated', 'public.collector_health_snapshot()', 'execute')
     or has_function_privilege('authenticated', 'public.collector_denylist_remote()', 'execute') then
    raise exception 'FAIL 1 RLS or grants';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'collector-health-alerts') then
    raise exception 'FAIL 1 alerts job not scheduled';
  end if;
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.mod_collector_health();
    raise exception 'FAIL 1 a member read the health panel';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 member: %', sqlerrm; end if;
  end;
  if exists (select 1 from public.collector_job_runs) then
    raise exception 'FAIL 1 a member reads job runs';
  end if;
  execute 'reset role';
  insert into ch_lines (line) values ('1 static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. collector_runs_record
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
begin
  perform public.collector_runs_record(jsonb_build_object('job', 'ingest', 'run_id', 'ch-' || v_tag, 'outcome', 'partial',
                                                          'stats', jsonb_build_object('sources', 3, 'items', 10)));
  perform public.collector_runs_record(jsonb_build_object('job', 'ingest', 'run_id', 'ch-' || v_tag, 'outcome', 'ok',
                                                          'stats', jsonb_build_object('sources', 3, 'items', 12, 'mode', 'regions')));
  if (select count(*) from public.collector_job_runs where run_id = 'ch-' || v_tag) <> 1
     or (select outcome from public.collector_job_runs where run_id = 'ch-' || v_tag) <> 'ok' then
    raise exception 'FAIL 2 repeat run';
  end if;
  begin
    perform public.collector_runs_record(jsonb_build_object('job', 'ingest', 'run_id', 'ch2-' || v_tag, 'outcome', 'ok',
                                                            'stats', jsonb_build_object('host', 'https://example.org/x')));
    raise exception 'FAIL 2 text in stats accepted';
  exception when others then
    if sqlerrm <> 'run_invalid' then raise exception 'FAIL 2 run_invalid: %', sqlerrm; end if;
  end;
  begin
    perform public.collector_runs_record(jsonb_build_object('job', 'cleanup', 'run_id', 'ch3-' || v_tag, 'outcome', 'ok'));
    raise exception 'FAIL 2 an unknown job accepted';
  exception when others then
    if sqlerrm <> 'run_invalid' then raise exception 'FAIL 2 job: %', sqlerrm; end if;
  end;
  insert into ch_lines (line) values ('2 runs record: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3 and 4. Stale and failing sources
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_slug text := 'aptest-' || v_tag || '-health';
  h jsonb;
  i integer;
begin
  update public.feed_sources set collector_seen_at = now() - interval '30 hours' where slug = v_slug;
  h := public.collector_health_snapshot();
  if not exists (select 1 from jsonb_array_elements(h -> 'stale') x where x.value ->> 'slug' = v_slug and (x.value ->> 'hours')::int >= 29) then
    raise exception 'FAIL 3 the source is not stale';
  end if;
  insert into ch_lines (line) values ('3 stale: ok');

  for i in 1..3 loop
    perform public.collector_ingest_events(pg_temp.src(v_tag), '[]'::jsonb, false, true, 'ch-' || v_tag || '-f' || i);
  end loop;
  if (select collector_fail_streak from public.feed_sources where slug = v_slug) <> 3 then
    raise exception 'FAIL 4 streak is not 3';
  end if;
  h := public.collector_health_snapshot();
  if not exists (select 1 from jsonb_array_elements(h -> 'failing') x where x.value ->> 'slug' = v_slug and (x.value ->> 'streak')::int = 3)
     or exists (select 1 from jsonb_array_elements(h -> 'stale') x where x.value ->> 'slug' = v_slug) then
    raise exception 'FAIL 4 the source is not failing, or still stale after a run';
  end if;
  perform public.collector_ingest_events(pg_temp.src(v_tag), pg_temp.items(v_tag), true, true, 'ch-' || v_tag || '-g');
  if (select collector_fail_streak from public.feed_sources where slug = v_slug) <> 0
     or exists (select 1 from jsonb_array_elements(public.collector_health_snapshot() -> 'failing') x where x.value ->> 'slug' = v_slug) then
    raise exception 'FAIL 4 a good run did not clear the streak';
  end if;
  insert into ch_lines (line) values ('4 failing: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Overdue job
-- ---------------------------------------------------------------------------
do $$
declare
  h jsonb;
begin
  delete from public.collector_job_runs where job = 'places_files';
  insert into public.collector_job_runs (job, run_id, finished_at, outcome)
  values ('places_files', 'ch-overdue-' || current_setting('t.tag'), now() - interval '27 hours', 'ok');
  h := public.collector_health_snapshot();
  if not (h #>> '{jobs,places_files,overdue}')::boolean or (h #>> '{jobs,ingest,overdue}')::boolean then
    raise exception 'FAIL 5 overdue flags';
  end if;
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  h := public.mod_collector_health();
  execute 'reset role';
  if not (h #>> '{jobs,places_files,overdue}')::boolean or h -> 'geocoding' is null or h -> 'budgets' is null then
    raise exception 'FAIL 5 the moderator panel';
  end if;
  insert into ch_lines (line) values ('5 overdue job: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Alerts
-- ---------------------------------------------------------------------------
do $$
declare
  um uuid := current_setting('t.um')::uuid;
  u1 uuid := current_setting('t.u1')::uuid;
  n1 integer;
  n2 integer;
  v jsonb;
begin
  perform public.collector_health_alerts();
  select count(*) into n1 from public.notifications where user_id = um and kind = 'collector_alert';
  if n1 < 1 or not exists (select 1 from public.notifications where user_id = um and kind = 'collector_alert'
                                                              and payload ->> 'alert' = 'jobs_overdue') then
    raise exception 'FAIL 6 the moderator got no alert';
  end if;
  perform public.collector_health_alerts();
  select count(*) into n2 from public.notifications where user_id = um and kind = 'collector_alert';
  if n2 <> n1 then
    raise exception 'FAIL 6 a second call the same day added alerts';
  end if;
  if exists (select 1 from public.notifications where user_id = u1 and kind = 'collector_alert') then
    raise exception 'FAIL 6 a member got an alert';
  end if;
  if exists (select 1 from public.notifications where user_id = um and kind = 'collector_alert'
                                                and (email_status <> 'skipped' or push_status <> 'skipped')) then
    raise exception 'FAIL 6 an alert is queued for email or push';
  end if;
  -- Even a row marked pending by hand is never sent.
  update public.notifications set email_status = 'pending', push_status = 'pending'
   where user_id = um and kind = 'collector_alert';
  v := public.claim_pending_notifications(100);
  if exists (select 1 from jsonb_array_elements(v) x where x.value ->> 'kind' = 'collector_alert')
     or exists (select 1 from public.notifications where user_id = um and kind = 'collector_alert'
                                                  and (email_status = 'pending' or push_status = 'pending')) then
    raise exception 'FAIL 6 claim_pending_notifications sent an alert';
  end if;
  -- Direct enqueue to a member is dropped.
  if public.enqueue_notification(u1, 'collector_alert', 'collector_alert:test:' || u1::text) is not null then
    raise exception 'FAIL 6 an alert was queued for a member';
  end if;
  insert into ch_lines (line) values ('6 alerts: ok');
end $$;

select line as collector_health from (
  select 0 as n, 'collector_health: all assertions passed' as line
  union all
  select n, line from ch_lines) x
order by n;

rollback;
