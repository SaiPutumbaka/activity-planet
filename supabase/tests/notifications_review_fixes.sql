-- ============================================================================
-- Staging check for migration 20261114000200_notifications_review_fixes.sql
-- (regression test for the migration 18 review). One transaction: throwaway
-- users and events; DO blocks raise on failure; ROLLBACK at the end. Prints
-- only pass/fail, never user rows.
--   1 update_event: T1 -> T2 -> T1 -> T2 tells a going attendee three times;
--     an edit that changes neither time nor place tells nobody.
--   2 attendee_joined: a, b, then a leaves and rejoins counts 2; the payload
--     holds no raw user id.
--   3 reminders: an RSVP made long ago and approved by the host inside the
--     window still gets the day-before reminder; a fresh join does not.
--   4 pg_cron job purge-cron-run-details exists; schema_version 2.15 or later.
-- ============================================================================
begin;

do $$
declare
  v_names text[] := array['h', 'a', 'b', 'c'];
  v_id    uuid;
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ntfr-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  select h.id into v_hub from public.hubs h
   where h.is_active and h.min_age = 18 and h.scope = 'general'
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  insert into public.hub_members (user_id, hub_id) values (current_setting('test.h')::uuid, v_hub)
    on conflict do nothing;
  perform set_config('test.hub', v_hub::text, true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Review fixes run', date_trunc('hour', now()) + interval '3 days',
          date_trunc('hour', now()) + interval '3 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e', v_e::text, true);

  -- Event 2 starts in 20 hours (inside the day-before window).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Review fixes soon run', now() + interval '20 hours',
          now() + interval '22 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e2', v_e::text, true);
  -- c RSVPed two days ago (no confirmation row inside the window).
  insert into public.rsvps (event_id, user_id, status, created_at, updated_at)
  values (v_e, current_setting('test.c')::uuid, 'going', now() - interval '2 days', now() - interval '2 days');
end $$;

-- ---------------------------------------------------------------------------
-- 1 and 2: joins, a leave and rejoin, three moves and a no-op edit
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e  uuid := current_setting('test.e')::uuid;
  v_t1 timestamptz;
  r    public.rsvps;
  e    public.events;
begin
  -- Migration 22: events are read through RLS for a signed-in adult, so read as the host.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  select starts_at into v_t1 from public.events where id = v_e;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'cancelled');
  r := public.set_rsvp(v_e, 'going');
  -- a joins event 2 now (fresh RSVP inside the window).
  r := public.set_rsvp(current_setting('test.e2')::uuid, 'going');

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  e := public.update_event(v_e, jsonb_build_object('location_text', 'Review park', 'starts_at', v_t1 + interval '1 hour', 'ends_at', v_t1 + interval '3 hours'));
  e := public.update_event(v_e, jsonb_build_object('location_text', 'Review park', 'starts_at', v_t1, 'ends_at', v_t1 + interval '2 hours'));
  e := public.update_event(v_e, jsonb_build_object('location_text', 'Review park', 'starts_at', v_t1 + interval '1 hour', 'ends_at', v_t1 + interval '3 hours'));
  e := public.update_event(v_e, jsonb_build_object('title', 'Review fixes run again'));
  -- The host approves c on event 2 inside the window.
  r := public.approve_rsvp(current_setting('test.e2')::uuid, current_setting('test.c')::uuid, true);
end $$;
reset role;

do $$
declare
  n integer;
  x public.notifications;
begin
  select count(*) into n from public.notifications
   where user_id = current_setting('test.a')::uuid and kind = 'event_updated';
  if n <> 3 then raise exception 'FAIL 1 three moves gave % event_updated rows', n; end if;

  select * into x from public.notifications
   where user_id = current_setting('test.h')::uuid and kind = 'attendee_joined'
     and event_id = current_setting('test.e')::uuid;
  if not found then raise exception 'FAIL 2 no attendee_joined row'; end if;
  if (x.payload ->> 'count')::integer is distinct from 2 then
    raise exception 'FAIL 2 two joiners counted as %', coalesce(x.payload ->> 'count', 'null');
  end if;
  if jsonb_array_length(x.payload -> 'joiners') <> 2 then raise exception 'FAIL 2 joiners set size'; end if;
  if position(current_setting('test.a') in x.payload::text) > 0
     or position(current_setting('test.b') in x.payload::text) > 0 then
    raise exception 'FAIL 2 payload carries a raw user id';
  end if;

  perform public.enqueue_due_reminders();
  if not exists (select 1 from public.notifications where user_id = current_setting('test.c')::uuid
                  and event_id = current_setting('test.e2')::uuid and kind = 'event_reminder_day') then
    raise exception 'FAIL 3 approval inside the window skipped the day-before reminder';
  end if;
  if exists (select 1 from public.notifications where user_id = current_setting('test.a')::uuid
              and event_id = current_setting('test.e2')::uuid and kind = 'event_reminder_day') then
    raise exception 'FAIL 3 fresh join got a day-before reminder';
  end if;
  if exists (select 1 from public.notifications where user_id = current_setting('test.h')::uuid
              and event_id = current_setting('test.e2')::uuid and kind = 'event_reminder_day') then
    raise exception 'FAIL 3 host reminded right after creating';
  end if;

  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'purge-cron-run-details') then
    raise exception 'FAIL 4 purge-cron-run-details not scheduled';
  end if;
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 15] then
    raise exception 'FAIL 4 schema_version is too old';
  end if;
end $$;

select 'notifications_review_fixes: PASS' as result;

rollback;
