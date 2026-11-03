-- ============================================================================
-- Staging check for migration 20261114000100_notifications.sql.
-- One transaction: throwaway users and events; DO blocks raise on failure;
-- ROLLBACK at the end. Prints only pass/fail, never user rows.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner): host h, attendees a and b (b has email
-- off), w (will be waitlisted), i (interested), stranger s. Event 1 starts in
-- 20 hours with capacity 3 (the host's auto-RSVP takes one seat).
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['h', 'a', 'b', 'w', 'i', 's'];
  v_id    uuid;
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ntf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  update public.notification_prefs set email_enabled = false where user_id = current_setting('test.b')::uuid;

  select h.id into v_hub from public.hubs h
   where h.is_active and h.min_age = 18 and h.scope = 'general'
   order by h.slug limit 1;
  if v_hub is null then
    raise exception 'setup: need a general hub on staging';
  end if;
  perform set_config('test.hub', v_hub::text, true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, capacity, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Notifications test run', now() + interval '20 hours',
          now() + interval '22 hours', 3, 'Midtown')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. RSVPs: confirmations, attendee_joined batching, no duplicates
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e uuid := current_setting('test.e1')::uuid;
  r   public.rsvps;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  if r.status <> 'going' then raise exception 'FAIL 1 a not going'; end if;
  r := public.set_rsvp(v_e, 'going');            -- repeat: no change
  r := public.set_rsvp(v_e, 'cancelled');
  r := public.set_rsvp(v_e, 'going');            -- rejoin: still one row each

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  if r.status <> 'going' then raise exception 'FAIL 1 b not going'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.w'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'going');
  if r.status <> 'waitlisted' then raise exception 'FAIL 1 w not waitlisted'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.i'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e, 'interested');
end $$;

reset role;
do $$
declare
  v_e uuid := current_setting('test.e1')::uuid;
  n   integer;
  x   public.notifications;
begin
  select count(*) into n from public.notifications
   where user_id = current_setting('test.a')::uuid and kind = 'rsvp_confirmed' and event_id = v_e;
  if n <> 1 then raise exception 'FAIL 1 a has % rsvp_confirmed rows', n; end if;

  select count(*) into n from public.notifications
   where user_id = current_setting('test.h')::uuid and kind = 'attendee_joined' and event_id = v_e;
  if n <> 1 then raise exception 'FAIL 1 host has % attendee_joined rows', n; end if;
  select * into x from public.notifications
   where user_id = current_setting('test.h')::uuid and kind = 'attendee_joined' and event_id = v_e;
  if (x.payload ->> 'count')::integer <> 2 then
    raise exception 'FAIL 1 attendee_joined count is %', x.payload ->> 'count';
  end if;
  if x.payload ? 'location_text' or x.payload ->> 'title' <> 'Notifications test run' then
    raise exception 'FAIL 1 payload shape';
  end if;

  select count(*) into n from public.notifications
   where user_id = current_setting('test.w')::uuid and kind = 'rsvp_confirmed' and payload ->> 'status' = 'waitlisted';
  if n <> 1 then raise exception 'FAIL 1 waitlisted confirmation'; end if;
  if exists (select 1 from public.notifications where user_id = current_setting('test.i')::uuid) then
    raise exception 'FAIL 1 interested got a notification';
  end if;

  -- 2. Opted out of email: skipped, push pending, in-app recorded.
  select * into x from public.notifications
   where user_id = current_setting('test.b')::uuid and kind = 'rsvp_confirmed' and event_id = v_e;
  if x.id is null then raise exception 'FAIL 2 b has no in-app row'; end if;
  if x.email_status <> 'skipped' or x.push_status <> 'pending' then
    raise exception 'FAIL 2 b channels %/%', x.email_status, x.push_status;
  end if;
  select * into x from public.notifications
   where user_id = current_setting('test.a')::uuid and kind = 'rsvp_confirmed' and event_id = v_e;
  if x.email_status <> 'pending' or x.push_status <> 'pending' then
    raise exception 'FAIL 2 a channels %/%', x.email_status, x.push_status;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. RLS and column grants
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_a uuid := current_setting('test.a')::uuid;
  n   integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.s'), 'role', 'authenticated')::text, true);
  select count(*) into n from public.notifications where user_id = v_a;
  if n <> 0 then raise exception 'FAIL 3 stranger reads % rows', n; end if;
  update public.notifications set read_at = now() where user_id = v_a;
  get diagnostics n = row_count;
  if n <> 0 then raise exception 'FAIL 3 stranger updated % rows', n; end if;
  if public.unread_notification_count() <> 0 then raise exception 'FAIL 3 stranger unread count'; end if;
  if public.mark_notifications_read(null) <> 0 then raise exception 'FAIL 3 stranger marked rows'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  select count(*) into n from public.notifications where user_id = v_a;
  if n <> 1 then raise exception 'FAIL 3 owner reads % rows', n; end if;
  begin
    update public.notifications set payload = '{}'::jsonb where user_id = v_a;
    raise exception 'FAIL 3 owner updated payload';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.notifications set email_status = 'sent' where user_id = v_a;
    raise exception 'FAIL 3 owner updated email_status';
  exception when insufficient_privilege then null;
  end;
  update public.notifications set seen_at = now() where user_id = v_a;
  get diagnostics n = row_count;
  if n <> 1 then raise exception 'FAIL 3 owner seen_at update'; end if;
  if public.unread_notification_count() <> 1 then raise exception 'FAIL 3 unread count before'; end if;
  if public.mark_notifications_read(null) <> 1 then raise exception 'FAIL 3 mark read'; end if;
  if public.unread_notification_count() <> 0 then raise exception 'FAIL 3 unread count after'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. broadcast_to_event: stranger refused, cap of 3
-- ---------------------------------------------------------------------------
do $$
declare
  v_e uuid := current_setting('test.e1')::uuid;
  j   jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.s'), 'role', 'authenticated')::text, true);
  begin
    perform public.broadcast_to_event(v_e, 'Hello');
    raise exception 'FAIL 4 stranger broadcast';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 4 stranger: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  begin
    perform public.broadcast_to_event(v_e, '   ');
    raise exception 'FAIL 4 empty body';
  exception when others then
    if sqlerrm <> 'body_length' then raise exception 'FAIL 4 empty body: %', sqlerrm; end if;
  end;
  for k in 1..3 loop
    j := public.broadcast_to_event(v_e, 'Bring water, message ' || k);
    if (j ->> 'recipients')::integer <> 3 then
      raise exception 'FAIL 4 broadcast % reached %', k, j ->> 'recipients';
    end if;
  end loop;
  begin
    perform public.broadcast_to_event(v_e, 'One too many');
    raise exception 'FAIL 4 fourth broadcast';
  exception when others then
    if sqlerrm <> 'broadcast_limit' then raise exception 'FAIL 4 cap: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 5. enqueue_due_reminders: 2-hour reminder, check-in prompt, idempotent
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_h  uuid := current_setting('test.h')::uuid;
  v_a  uuid := current_setting('test.a')::uuid;
  v_e2 uuid;
  v_e3 uuid;
  n1   integer;
  n2   integer;
  c1   integer;
  c2   integer;
begin
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (current_setting('test.hub')::uuid, v_h, 'Notifications soon run', now() + interval '90 minutes',
          now() + interval '3 hours', 'Midtown')
  returning id into v_e2;
  insert into public.rsvps (event_id, user_id, status, created_at, updated_at)
  values (v_e2, v_a, 'going', now() - interval '1 day', now() - interval '1 day');

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (current_setting('test.hub')::uuid, v_h, 'Notifications past run', now() - interval '3 hours',
          now() - interval '1 hour', 'Midtown')
  returning id into v_e3;
  insert into public.rsvps (event_id, user_id, status) values (v_e3, v_a, 'going');

  n1 := public.enqueue_due_reminders();
  select count(*) into c1 from public.notifications;
  n2 := public.enqueue_due_reminders();
  select count(*) into c2 from public.notifications;
  if c1 <> c2 or n2 <> 0 then raise exception 'FAIL 5 not idempotent (%, %)', n1, n2; end if;

  if not exists (select 1 from public.notifications where user_id = v_a and event_id = v_e2 and kind = 'event_reminder_2h') then
    raise exception 'FAIL 5 no 2h reminder';
  end if;
  if exists (select 1 from public.notifications where user_id = v_h and event_id = v_e2 and kind = 'event_reminder_2h') then
    raise exception 'FAIL 5 host reminded right after creating';
  end if;
  if (select count(*) from public.notifications where user_id = v_a and event_id = v_e3 and kind = 'checkin_prompt') <> 1 then
    raise exception 'FAIL 5 check-in prompt';
  end if;
  if exists (select 1 from public.notifications where user_id = v_h and event_id = v_e3 and kind = 'checkin_prompt') then
    raise exception 'FAIL 5 host got a check-in prompt';
  end if;
  if exists (select 1 from public.notifications where event_id = current_setting('test.e1')::uuid
              and kind = 'event_reminder_day') then
    raise exception 'FAIL 5 day reminder for a fresh RSVP';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. cancel_event fans out to going, waitlisted and interested
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  perform public.cancel_event(current_setting('test.e1')::uuid, 'Rain');
  perform public.cancel_event(current_setting('test.e1')::uuid, 'Rain');   -- idempotent
end $$;
reset role;
do $$
declare
  v_e uuid := current_setting('test.e1')::uuid;
  v_got uuid[];
  v_want uuid[] := array[current_setting('test.a')::uuid, current_setting('test.b')::uuid,
                         current_setting('test.w')::uuid, current_setting('test.i')::uuid];
begin
  select array_agg(user_id order by user_id) into v_got
    from public.notifications where event_id = v_e and kind = 'event_cancelled';
  if v_got is distinct from (select array_agg(u order by u) from unnest(v_want) u) then
    raise exception 'FAIL 6 cancel recipients (% rows)', coalesce(array_length(v_got, 1), 0);
  end if;
  if exists (select 1 from public.notifications where event_id = v_e and kind = 'event_cancelled'
              and payload ->> 'reason' is distinct from 'Rain') then
    raise exception 'FAIL 6 cancel reason';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. cron jobs, schema version
-- ---------------------------------------------------------------------------
do $$
declare
  v_missing text;
begin
  select string_agg(j, ', ') into v_missing
    from unnest(array['notifications-reminders', 'refresh-hub-stats', 'materialize-event-series',
                      'purge-read-notifications', 'purge-account-deletions']) j
   where not exists (select 1 from cron.job c where c.jobname = j);
  if v_missing is not null then raise exception 'FAIL 7 missing cron jobs: %', v_missing; end if;
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 14] then
    raise exception 'FAIL 7 schema_version is older than 2.14';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion removes the caller's notifications
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.notifications where user_id = current_setting('test.a')::uuid) then
    raise exception 'FAIL 8 notifications survive deletion';
  end if;
  if exists (select 1 from public.notifications where actor_id in (current_setting('test.a')::uuid, current_setting('test.h')::uuid)) then
    raise exception 'FAIL 8 actor_id survives deletion';
  end if;
  if exists (select 1 from public.event_broadcasts where sender_id = current_setting('test.h')::uuid) then
    raise exception 'FAIL 8 broadcast sender survives deletion';
  end if;
end $$;

select 'notifications: all assertions passed' as result;

rollback;
