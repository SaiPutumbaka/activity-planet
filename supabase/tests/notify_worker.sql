-- ============================================================================
-- Staging check for migration 20261219000100_notify_worker.sql (migration 55).
-- One transaction: sets up throwaway accounts, a plan and notifications,
-- asserts with DO blocks that raise on failure, then rolls everything back.
-- Prints pass/fail only (no user rows; the test accounts are invented).
-- Every other pending row on staging is leased inside the transaction, at
-- setup and again right before each claim (rows queued for real members
-- during the test, or more than 100 due rows, cannot crowd out the test
-- rows), so the claims see only the test rows (rolled back with the rest).
--
--   1 static: schema_version 2.51 or later, grants, the cron job.
--   2 register_push_device: allowed hosts only, upsert, the endpoint moves
--     to the account that registered it last.
--   3 claim: what goes out (address, unsubscribe token, devices), what is
--     skipped (block, prefs turned off, unconfirmed address, expired), push
--     deferred by quiet hours set after the row was queued.
--   4 a second overlapping claim takes nothing already claimed.
--   5 complete: sent, retry back to pending, a gone device revoked; next
--     claim skips push with no device left.
--   6 daily email cap.
--   7 signed unsubscribe: anon with the token turns email off; a bad or
--     tampered token is refused.
-- ============================================================================
begin;

-- Migration 77: the account-wide email budget must not hide the rows under test.
-- Staging's notify_email_daily_cap is 5 since migration 77; section 6 sets its own.
insert into public.meta (key, value) values ('email_daily_cap_total', '9999999'), ('email_monthly_cap_total', '9999999'),
                                            ('notify_email_daily_cap', '99999')
  on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 51] then
    raise exception 'FAIL 1 schema_version is older than 2.51';
  end if;
  if has_function_privilege('authenticated', 'public.claim_pending_notifications(integer)', 'execute')
     or has_function_privilege('anon', 'public.claim_pending_notifications(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.claim_pending_notifications(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.complete_notification_delivery(jsonb,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.notify_worker_verify_secret(text)', 'execute')
     or has_function_privilege('authenticated', 'public.notification_unsubscribe_token(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.notify_worker_dispatch(boolean)', 'execute')
     or has_function_privilege('service_role', 'public.notify_vault_secret(text)', 'execute')
     or has_function_privilege('anon', 'public.register_push_device(jsonb,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.register_push_device(jsonb,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.unregister_push_device(text)', 'execute')
     or not has_function_privilege('anon', 'public.unsubscribe_email_with_token(text)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if has_table_privilege('authenticated', 'public.notification_email_days', 'select')
     or has_table_privilege('anon', 'public.notification_email_days', 'select')
     or has_column_privilege('authenticated', 'public.notifications', 'claimed_at', 'update') then
    raise exception 'FAIL 1 table grants';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'send-notifications' and schedule = '*/2 * * * *') then
    raise exception 'FAIL 1 cron job send-notifications missing';
  end if;
  if public.notify_worker_verify_secret('not-the-secret-not-the-secret-not-the-secret') then
    raise exception 'FAIL 1 a wrong worker secret verified';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['a', 'b', 'h', 'r', 'q', 'c', 'k'];
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  -- Lease every real pending row so only the test rows are claimable.
  update public.notifications set claimed_at = now()
   where email_status = 'pending' or push_status = 'pending';

  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'nw-' || v_names[i] || '-' || v_tag || '@example.com',
            case when v_names[i] = 'c' then null else now() end, now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
    v_ids := v_ids || v_id;
  end loop;
  perform set_config('test.ids', array_to_string(v_ids, ','), true);
  perform set_config('test.tag', v_tag, true);

  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Notify worker run', now() + interval '2 days',
          now() + interval '2 days 2 hours', 'Riverside')
  returning id into v_e;
  perform set_config('test.e', v_e::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. register_push_device
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_keys jsonb := jsonb_build_object(
    'p256dh', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
    'auth', 'BTBZMqHH6r4Tts7J_aSIgg');
  v_tag  text := current_setting('test.tag');
  v_id   uuid;
  v_id2  uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  begin
    perform public.register_push_device(jsonb_build_object('endpoint', 'https://evil.example.com/' || v_tag, 'keys', v_keys));
    raise exception 'FAIL 2 an unknown push host was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.register_push_device(jsonb_build_object('endpoint', 'https://fcm.googleapis.com/fcm/send/' || v_tag));
    raise exception 'FAIL 2 a subscription without keys was accepted';
  exception when sqlstate '22023' then null;
  end;
  v_id := public.register_push_device(
    jsonb_build_object('endpoint', 'https://fcm.googleapis.com/fcm/send/nw1-' || v_tag, 'keys', v_keys), 'test agent');
  v_id2 := public.register_push_device(
    jsonb_build_object('endpoint', 'https://fcm.googleapis.com/fcm/send/nw1-' || v_tag, 'keys', v_keys), 'test agent');
  if v_id is null or v_id <> v_id2 then
    raise exception 'FAIL 2 registering the same endpoint twice made two rows';
  end if;
  perform set_config('test.dev', v_id::text, true);
  -- A second endpoint on a, then the same browser signs in as k.
  v_id := public.register_push_device(
    jsonb_build_object('endpoint', 'https://web.push.apple.com/nw2-' || v_tag, 'keys', v_keys));
  perform set_config('test.dev2', v_id::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.k'), 'role', 'authenticated')::text, true);
  v_id := public.register_push_device(
    jsonb_build_object('endpoint', 'https://web.push.apple.com/nw2-' || v_tag, 'keys', v_keys));
  if public.unregister_push_device('https://web.push.apple.com/nw2-' || v_tag) is not true then
    raise exception 'FAIL 2 unregister did not find the live device';
  end if;
end $$;
reset role;

do $$
begin
  if (select revoked_at from public.push_devices where id = current_setting('test.dev2')::uuid) is null then
    raise exception 'FAIL 2 the endpoint stayed live on the previous account';
  end if;
  if exists (select 1 from public.push_devices where user_id = current_setting('test.k')::uuid and revoked_at is null) then
    raise exception 'FAIL 2 unregister left the device live';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Claim: what goes, what is skipped, what waits
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('test.tag');
  v_e   uuid := current_setting('test.e')::uuid;
  v_hub uuid := current_setting('test.hub')::uuid;
  v_id  uuid;
  v_now time := (now() at time zone 'UTC')::time;
begin
  -- n1: a confirmation to a (confirmed address, one live device).
  v_id := public.enqueue_notification(current_setting('test.a')::uuid, 'rsvp_confirmed', 'nw:n1:' || v_tag,
                                      v_e, v_hub, null, null, public.notification_event_payload(v_e));
  perform set_config('test.n1', v_id::text, true);
  -- n2: b joined h's plan, then h blocks b.
  v_id := public.enqueue_notification(current_setting('test.h')::uuid, 'attendee_joined', 'nw:n2:' || v_tag,
                                      v_e, v_hub, null, current_setting('test.b')::uuid,
                                      public.notification_event_payload(v_e), true);
  perform set_config('test.n2', v_id::text, true);
  insert into public.blocks (blocker_id, blocked_id) values (current_setting('test.h')::uuid, current_setting('test.b')::uuid);
  -- n3: a reminder to r, who then turns reminders off.
  v_id := public.enqueue_notification(current_setting('test.r')::uuid, 'event_reminder_day', 'nw:n3:' || v_tag,
                                      v_e, v_hub, null, null, public.notification_event_payload(v_e));
  perform set_config('test.n3', v_id::text, true);
  update public.notification_prefs set event_reminders = false where user_id = current_setting('test.r')::uuid;
  -- n4: an update to q, who then sets quiet hours around now (Etc/UTC; is_valid_timezone wants Area/Name).
  v_id := public.enqueue_notification(current_setting('test.q')::uuid, 'event_updated', 'nw:n4:' || v_tag,
                                      v_e, v_hub, null, null, public.notification_event_payload(v_e));
  perform set_config('test.n4', v_id::text, true);
  update public.notification_prefs
     set timezone = 'Etc/UTC', quiet_start = v_now - interval '1 hour', quiet_end = v_now + interval '1 hour'
   where user_id = current_setting('test.q')::uuid;
  -- n5: to c, whose address is not confirmed.
  v_id := public.enqueue_notification(current_setting('test.c')::uuid, 'rsvp_confirmed', 'nw:n5:' || v_tag,
                                      v_e, v_hub, null, null, public.notification_event_payload(v_e));
  perform set_config('test.n5', v_id::text, true);
  -- n6: three days old.
  insert into public.notifications (user_id, kind, event_id, dedupe_key, created_at)
  values (current_setting('test.a')::uuid, 'rsvp_confirmed', v_e, 'nw:n6:' || v_tag, now() - interval '3 days')
  returning id into v_id;
  perform set_config('test.n6', v_id::text, true);
  if current_setting('test.n1') = '' or current_setting('test.n2') = '' or current_setting('test.n4') = '' then
    raise exception 'FAIL setup: enqueue wrote nothing';
  end if;
end $$;

do $$
declare
  v_out jsonb;
  v_n1  jsonb;
  v_n4  jsonb;
  n     public.notifications%rowtype;
begin
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending')
     and user_id <> all (string_to_array(current_setting('test.ids'), ',')::uuid[]);
  v_out := public.claim_pending_notifications(100);
  select x into v_n1 from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.n1');
  select x into v_n4 from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.n4');
  if v_n1 is null then raise exception 'FAIL 3 n1 was not claimed'; end if;
  if v_n1 #>> '{email,to}' is null or v_n1 #>> '{email,unsubscribe_token}' !~ '^[0-9a-f-]{36}\.[0-9a-f]{64}$' then
    raise exception 'FAIL 3 n1 has no address or unsubscribe token';
  end if;
  if jsonb_array_length(v_n1 -> 'push') <> 1 or v_n1 #>> '{push,0,device_id}' <> current_setting('test.dev') then
    raise exception 'FAIL 3 n1 does not carry exactly the live device';
  end if;
  if v_n1 -> 'payload' ? 'joiners' or v_n1 #>> '{payload,location_hint}' <> 'Riverside' then
    raise exception 'FAIL 3 n1 payload';
  end if;
  if v_n4 is null or v_n4 -> 'email' = 'null'::jsonb or v_n4 -> 'push' <> 'null'::jsonb then
    raise exception 'FAIL 3 n4 should go by email now and wait for push';
  end if;
  if exists (select 1 from jsonb_array_elements(v_out) x
              where x ->> 'id' in (current_setting('test.n2'), current_setting('test.n3'),
                                   current_setting('test.n5'), current_setting('test.n6'))) then
    raise exception 'FAIL 3 a skipped row was handed to the worker';
  end if;

  select * into n from public.notifications where id = current_setting('test.n1')::uuid;
  if n.claimed_at is null or n.attempts <> 1 then raise exception 'FAIL 3 n1 lease'; end if;
  select * into n from public.notifications where id = current_setting('test.n2')::uuid;
  if n.email_status <> 'skipped' or n.push_status <> 'skipped' or n.last_error <> 'blocked' then
    raise exception 'FAIL 3 a notice crossed a block';
  end if;
  select * into n from public.notifications where id = current_setting('test.n3')::uuid;
  if n.email_status <> 'skipped' or n.push_status <> 'skipped' then
    raise exception 'FAIL 3 prefs turned off after queueing were ignored';
  end if;
  select * into n from public.notifications where id = current_setting('test.n4')::uuid;
  if n.push_status <> 'pending' or n.push_after is null or n.push_after <= now() then
    raise exception 'FAIL 3 quiet hours did not hold the push';
  end if;
  select * into n from public.notifications where id = current_setting('test.n5')::uuid;
  if n.email_status <> 'skipped' or n.push_status <> 'skipped' then
    raise exception 'FAIL 3 an unconfirmed address or a person without devices was not skipped';
  end if;
  select * into n from public.notifications where id = current_setting('test.n6')::uuid;
  if n.email_status <> 'skipped' or n.push_status <> 'skipped' or n.last_error <> 'expired' then
    raise exception 'FAIL 3 an old row was not expired';
  end if;

  -- 4. An overlapping run gets nothing already claimed.
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending')
     and user_id <> all (string_to_array(current_setting('test.ids'), ',')::uuid[]);
  v_out := public.claim_pending_notifications(100);
  if exists (select 1 from jsonb_array_elements(v_out) x
              where x ->> 'id' in (current_setting('test.n1'), current_setting('test.n4'))) then
    raise exception 'FAIL 4 a claimed row was claimed twice';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Complete
-- ---------------------------------------------------------------------------
do $$
declare
  n     public.notifications%rowtype;
  v_out jsonb;
begin
  if public.complete_notification_delivery(
       jsonb_build_array(jsonb_build_object('id', current_setting('test.n1'), 'email', 'sent', 'push', 'retry', 'error', 'push_retry'),
                         jsonb_build_object('id', 'not-a-uuid', 'email', 'sent')),
       jsonb_build_object('gone', jsonb_build_array(current_setting('test.dev')), 'failed', 'x')) <> 1 then
    raise exception 'FAIL 5 complete did not report one row';
  end if;
  select * into n from public.notifications where id = current_setting('test.n1')::uuid;
  if n.email_status <> 'sent' or n.email_sent_at is null or n.push_status <> 'pending' or n.claimed_at is not null then
    raise exception 'FAIL 5 n1 outcome';
  end if;
  if (select revoked_at from public.push_devices where id = current_setting('test.dev')::uuid) is null then
    raise exception 'FAIL 5 a gone device stayed live';
  end if;
  -- Push is due again, but a has no live device now.
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending')
     and user_id <> all (string_to_array(current_setting('test.ids'), ',')::uuid[]);
  v_out := public.claim_pending_notifications(100);
  select * into n from public.notifications where id = current_setting('test.n1')::uuid;
  if n.push_status <> 'skipped' or n.email_status <> 'sent' then
    raise exception 'FAIL 5 push without devices was not skipped';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Daily email cap
-- ---------------------------------------------------------------------------
do $$
declare
  v_e   uuid := current_setting('test.e')::uuid;
  v_id  uuid;
  v_out jsonb;
  n     public.notifications%rowtype;
begin
  insert into public.meta (key, value)
  values ('notify_email_daily_cap',
          coalesce((select reserved from public.notification_email_days where day = (now() at time zone 'UTC')::date), 0)::text)
  on conflict (key) do update set value = excluded.value;
  v_id := public.enqueue_notification(current_setting('test.k')::uuid, 'rsvp_confirmed', 'nw:n7:' || current_setting('test.tag'),
                                      v_e, null, null, null, public.notification_event_payload(v_e));
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending')
     and user_id <> all (string_to_array(current_setting('test.ids'), ',')::uuid[]);
  v_out := public.claim_pending_notifications(100);
  select * into n from public.notifications where id = v_id;
  if n.email_status <> 'skipped' or n.last_error <> 'daily_cap' then
    raise exception 'FAIL 6 the daily cap did not hold';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Signed unsubscribe
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('test.token', public.notification_unsubscribe_token(current_setting('test.a')::uuid), true);
  if current_setting('test.token') !~ '^[0-9a-f-]{36}\.[0-9a-f]{64}$' then
    raise exception 'FAIL 7 token shape';
  end if;
  -- A pending email for a, skipped by the unsubscribe.
  perform set_config('test.n8', public.enqueue_notification(current_setting('test.a')::uuid, 'rsvp_confirmed',
                     'nw:n8:' || current_setting('test.tag'), current_setting('test.e')::uuid)::text, true);
end $$;

set local role anon;
do $$
declare
  v_t text := current_setting('test.token');
begin
  begin
    perform public.unsubscribe_email_with_token(left(v_t, 100) || case when right(v_t, 1) = '0' then '1' else '0' end);
    raise exception 'FAIL 7 a tampered token was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.unsubscribe_email_with_token(current_setting('test.b') || '.' || split_part(v_t, '.', 2));
    raise exception 'FAIL 7 another person''s signature was accepted';
  exception when sqlstate '22023' then null;
  end;
  begin
    perform public.unsubscribe_email_with_token('garbage');
    raise exception 'FAIL 7 garbage was accepted';
  exception when sqlstate '22023' then null;
  end;
  if (public.unsubscribe_email_with_token(v_t) ->> 'ok') <> 'true'
     or (public.unsubscribe_email_with_token(v_t) ->> 'ok') <> 'true' then
    raise exception 'FAIL 7 a valid token was refused';
  end if;
end $$;
reset role;

do $$
begin
  if (select email_enabled from public.notification_prefs where user_id = current_setting('test.a')::uuid) then
    raise exception 'FAIL 7 email stayed on';
  end if;
  if (select push_enabled from public.notification_prefs where user_id = current_setting('test.a')::uuid) is not true then
    raise exception 'FAIL 7 unsubscribe from email touched push';
  end if;
  if (select email_status from public.notifications where id = current_setting('test.n8')::uuid) <> 'skipped' then
    raise exception 'FAIL 7 a pending email survived the unsubscribe';
  end if;
end $$;

select 'notify_worker: PASS' as result;

rollback;
