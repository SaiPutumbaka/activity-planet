-- ============================================================================
-- Review probe for migration 18 (notifications). One transaction; ROLLBACK.
-- Prints only verdicts and job-level counts, never user rows.
--   P1 update_event: moving an event T1 -> T2 -> T1 -> T2 should tell going
--      attendees three times.
--   P2 attendee_joined: joins by a, b, then a leaves and rejoins, should
--      count 2 distinct joiners.
--   P3 pg_cron health: run and failure counts per migration-18 job.
-- ============================================================================
begin;

do $$
declare
  v_names text[] := array['h', 'a', 'b'];
  v_id    uuid;
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ntfp-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  select h.id into v_hub from public.hubs h
   where h.is_active and h.min_age = 18 and h.scope = 'general'
   order by h.slug limit 1;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Probe run', date_trunc('hour', now()) + interval '3 days',
          date_trunc('hour', now()) + interval '3 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e', v_e::text, true);
end $$;

set local role authenticated;
do $$
declare
  v_e  uuid := current_setting('test.e')::uuid;
  v_t1 timestamptz;
  r    public.rsvps;
  e    public.events;
begin
  select starts_at into v_t1 from public.events where id = v_e;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'cancelled');
  r := public.set_rsvp(v_e, 'going');

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  e := public.update_event(v_e, jsonb_build_object('starts_at', v_t1 + interval '1 hour', 'ends_at', v_t1 + interval '3 hours'));
  e := public.update_event(v_e, jsonb_build_object('starts_at', v_t1, 'ends_at', v_t1 + interval '2 hours'));
  e := public.update_event(v_e, jsonb_build_object('starts_at', v_t1 + interval '1 hour', 'ends_at', v_t1 + interval '3 hours'));
end $$;
reset role;

do $$
declare
  n integer;
  c integer;
begin
  select count(*) into n from public.notifications
   where user_id = current_setting('test.a')::uuid and kind = 'event_updated';
  perform set_config('test.p1', case when n = 3 then 'P1 ok' else 'P1 BUG: 3 moves, ' || n || ' event_updated rows' end, true);
  select (payload ->> 'count')::integer into c from public.notifications
   where user_id = current_setting('test.h')::uuid and kind = 'attendee_joined';
  perform set_config('test.p2', case when c = 2 then 'P2 ok' else 'P2 BUG: 2 joiners counted as ' || coalesce(c::text, 'null') end, true);
end $$;

select current_setting('test.p1') as result
union all select current_setting('test.p2')
union all
select 'P3 ' || j.jobname || ': runs=' || count(d.runid) || ' failed=' || count(*) filter (where d.status = 'failed')
       || coalesce(' last_error=' || left(max(d.return_message) filter (where d.status = 'failed'), 160), '')
  from cron.job j left join cron.job_run_details d on d.jobid = j.jobid
 where j.jobname in ('notifications-reminders', 'refresh-hub-stats', 'materialize-event-series',
                     'purge-read-notifications', 'purge-account-deletions')
 group by j.jobname;

rollback;
