-- ============================================================================
-- Staging check for migration 20261220000100_notify_worker_fixes.sql
-- (migration 56). One transaction: throwaway accounts, two plans and
-- notifications, DO blocks that raise on failure, then ROLLBACK. Prints
-- pass/fail only (no user rows; the test accounts are invented). Before each
-- claim every pending row that is not a test account's is leased inside the
-- transaction, so the claim sees only the test rows however many real rows
-- are due (rolled back with the rest).
--
--   1 static: schema_version 2.52 or later; push_devices grants and policies.
--   2 push_devices: a member cannot insert or update rows directly (not even
--     another account's endpoint); register_push_device still works, and
--     select and delete of the member's own rows still work.
--   3 stale plans: hub_new_event on a moderated plan and rsvp_confirmed on a
--     cancelled plan are skipped; event_cancelled on the cancelled plan goes.
--   4 blocks: a broadcast queued before the block and one queued after it
--     both go, neither names the host; attendee_joined across the block is
--     dropped; a broadcast to someone who muted the host goes, named.
-- ============================================================================
begin;

-- Migration 77: the account-wide email budget must not hide the rows under test.
insert into public.meta (key, value) values ('email_daily_cap_total', '9999999'), ('email_monthly_cap_total', '9999999')
  on conflict (key) do update set value = excluded.value;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 52] then
    raise exception 'FAIL 1 schema_version is older than 2.52';
  end if;
  if has_table_privilege('authenticated', 'public.push_devices', 'insert')
     or has_table_privilege('authenticated', 'public.push_devices', 'update')
     or has_table_privilege('anon', 'public.push_devices', 'select')
     or not has_table_privilege('authenticated', 'public.push_devices', 'select')
     or not has_table_privilege('authenticated', 'public.push_devices', 'delete') then
    raise exception 'FAIL 1 push_devices grants';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'push_devices'
                                         and cmd in ('INSERT', 'UPDATE', 'ALL')) then
    raise exception 'FAIL 1 push_devices still has an insert or update policy';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['h', 'b', 'm', 'x', 'y'];
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'nwf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
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
  -- The daily email cap must not hide the rows under test.
  insert into public.meta (key, value) values ('notify_email_daily_cap', '99999')
  on conflict (key) do update set value = excluded.value;

  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  -- e1: stays live. e2: gets cancelled. e3: gets removed by moderators.
  for i in 1..3 loop
    insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
    values (v_hub, current_setting('test.h')::uuid, 'Notify fixes ' || i, now() + interval '2 days',
            now() + interval '2 days 2 hours', 'Riverside')
    returning id into v_e;
    perform set_config('test.e' || i, v_e::text, true);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2. push_devices: RPCs only
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_keys jsonb := jsonb_build_object(
    'p256dh', 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
    'auth', 'BTBZMqHH6r4Tts7J_aSIgg');
  v_tag  text := current_setting('test.tag');
  v_ep   text := 'https://fcm.googleapis.com/fcm/send/nwf-' || v_tag;
  v_id   uuid;
begin
  -- y registers a browser; x then tries to write rows directly.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.y'), 'role', 'authenticated')::text, true);
  v_id := public.register_push_device(jsonb_build_object('endpoint', v_ep, 'keys', v_keys));
  if v_id is null then raise exception 'FAIL 2 register_push_device returned nothing'; end if;
  perform set_config('test.ydev', v_id::text, true);

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  begin
    insert into public.push_devices (user_id, platform, subscription, token_hash)
    values (current_setting('test.x')::uuid, 'web', jsonb_build_object('endpoint', v_ep, 'keys', v_keys),
            encode(extensions.digest(v_ep, 'sha256'), 'hex'));
    raise exception 'FAIL 2 a direct insert into push_devices was allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.push_devices set revoked_at = null where user_id = current_setting('test.x')::uuid;
    raise exception 'FAIL 2 a direct update of push_devices was allowed';
  exception when insufficient_privilege then null;
  end;
  -- The RPC path still works, and the member reads and deletes their own rows.
  v_id := public.register_push_device(
    jsonb_build_object('endpoint', 'https://web.push.apple.com/nwf-' || v_tag, 'keys', v_keys));
  if not exists (select 1 from public.push_devices where id = v_id) then
    raise exception 'FAIL 2 the member cannot read their own device';
  end if;
  if exists (select 1 from public.push_devices where id = current_setting('test.ydev')::uuid) then
    raise exception 'FAIL 2 a member read another account''s device';
  end if;
  delete from public.push_devices where id = v_id;
  if exists (select 1 from public.push_devices where id = v_id) then
    raise exception 'FAIL 2 the member cannot delete their own device';
  end if;
end $$;
reset role;

do $$
begin
  if (select revoked_at from public.push_devices where id = current_setting('test.ydev')::uuid) is not null then
    raise exception 'FAIL 2 y''s device was touched by x';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3 and 4. Queue, then change the plans and the blocks, then claim
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('test.tag');
  v_hub uuid := current_setting('test.hub')::uuid;
  v_e1  uuid := current_setting('test.e1')::uuid;
  v_e2  uuid := current_setting('test.e2')::uuid;
  v_e3  uuid := current_setting('test.e3')::uuid;
  v_h   uuid := current_setting('test.h')::uuid;
  v_b   uuid := current_setting('test.b')::uuid;
  v_m   uuid := current_setting('test.m')::uuid;
  v_x   uuid := current_setting('test.x')::uuid;
  v_id  uuid;
begin
  -- s1: hub_new_event to x about e3, which moderators then remove.
  v_id := public.enqueue_notification(v_x, 'hub_new_event', 'nwf:s1:' || v_tag, v_e3, v_hub, null, v_h,
                                      public.notification_event_payload(v_e3), true);
  perform set_config('test.s1', coalesce(v_id::text, ''), true);
  -- s2: rsvp_confirmed to x about e2, which the host then cancels.
  v_id := public.enqueue_notification(v_x, 'rsvp_confirmed', 'nwf:s2:' || v_tag, v_e2, v_hub, null, null,
                                      public.notification_event_payload(v_e2));
  perform set_config('test.s2', coalesce(v_id::text, ''), true);
  -- s3: waitlist_promoted to x about e3 (removed).
  v_id := public.enqueue_notification(v_x, 'waitlist_promoted', 'nwf:s3:' || v_tag, v_e3, v_hub, null, null,
                                      public.notification_event_payload(v_e3));
  perform set_config('test.s3', coalesce(v_id::text, ''), true);
  -- b1: broadcast from h to b, queued before b blocks h.
  v_id := public.enqueue_notification(v_b, 'broadcast', 'nwf:b1:' || v_tag, v_e1, v_hub, null, v_h,
                                      public.notification_event_payload(v_e1) || jsonb_build_object('body', 'Meet at the gate'));
  perform set_config('test.b1', coalesce(v_id::text, ''), true);
  -- j1: b joins h's plan (attendee_joined to h), queued before the block.
  v_id := public.enqueue_notification(v_h, 'attendee_joined', 'nwf:j1:' || v_tag, v_e1, v_hub, null, v_b,
                                      public.notification_event_payload(v_e1), true);
  perform set_config('test.j1', coalesce(v_id::text, ''), true);
  -- m1: broadcast from h to m, who muted h before it was queued.
  insert into public.mutes (muter_id, muted_id) values (v_m, v_h);
  v_id := public.enqueue_notification(v_m, 'broadcast', 'nwf:m1:' || v_tag, v_e1, v_hub, null, v_h,
                                      public.notification_event_payload(v_e1) || jsonb_build_object('body', 'Meet at the gate'));
  perform set_config('test.m1', coalesce(v_id::text, ''), true);

  insert into public.blocks (blocker_id, blocked_id) values (v_b, v_h);

  -- b2: broadcast from h to b, queued after the block.
  v_id := public.enqueue_notification(v_b, 'broadcast', 'nwf:b2:' || v_tag, v_e1, v_hub, null, v_h,
                                      public.notification_event_payload(v_e1) || jsonb_build_object('body', 'Meet at the gate'));
  perform set_config('test.b2', coalesce(v_id::text, ''), true);
  -- j2: attendee_joined across the block is not queued at all.
  v_id := public.enqueue_notification(v_h, 'attendee_joined', 'nwf:j2:' || v_tag, v_e1, v_hub, null, v_b,
                                      public.notification_event_payload(v_e1), true);
  if v_id is not null then raise exception 'FAIL 4 attendee_joined was queued across a block'; end if;

  update public.events set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host' where id = v_e2;
  update public.events set moderation_state = 'removed', moderated_at = now() where id = v_e3;
  -- c1: event_cancelled to x about e2: the news itself, still sent.
  v_id := public.enqueue_notification(v_x, 'event_cancelled', 'nwf:c1:' || v_tag, v_e2, v_hub, null, null,
                                      public.notification_event_payload(v_e2));
  perform set_config('test.c1', coalesce(v_id::text, ''), true);

  if '' in (current_setting('test.s1'), current_setting('test.s2'), current_setting('test.s3'),
            current_setting('test.b1'), current_setting('test.j1'), current_setting('test.m1'),
            current_setting('test.b2'), current_setting('test.c1')) then
    raise exception 'FAIL setup: enqueue wrote nothing';
  end if;
end $$;

do $$
declare
  v_out  jsonb;
  v_r    jsonb;
  n      public.notifications%rowtype;
begin
  -- Only the test accounts' rows are claimable.
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending')
     and user_id <> all (string_to_array(current_setting('test.ids'), ',')::uuid[]);
  v_out := public.claim_pending_notifications(100);

  -- 3. Stale plans.
  if exists (select 1 from jsonb_array_elements(v_out) x
              where x ->> 'id' in (current_setting('test.s1'), current_setting('test.s2'), current_setting('test.s3'))) then
    raise exception 'FAIL 3 a notice about a removed or cancelled plan was handed to the worker';
  end if;
  for n in select * from public.notifications
            where id in (current_setting('test.s1')::uuid, current_setting('test.s2')::uuid, current_setting('test.s3')::uuid) loop
    if n.email_status <> 'skipped' or n.push_status <> 'skipped' or n.last_error <> 'stale' then
      raise exception 'FAIL 3 a notice about a removed or cancelled plan was not skipped as stale';
    end if;
  end loop;
  if not exists (select 1 from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.c1')) then
    raise exception 'FAIL 3 event_cancelled on a cancelled plan was not sent';
  end if;

  -- 4. Blocks: both broadcast orderings go, unnamed.
  select x into v_r from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.b1');
  if v_r is null then raise exception 'FAIL 4 a broadcast queued before the block was dropped'; end if;
  if v_r -> 'actor_name' <> 'null'::jsonb then raise exception 'FAIL 4 a broadcast named a blocked sender'; end if;
  select x into v_r from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.b2');
  if v_r is null then raise exception 'FAIL 4 a broadcast queued after the block was dropped'; end if;
  if v_r -> 'actor_name' <> 'null'::jsonb then raise exception 'FAIL 4 a broadcast named a blocked sender'; end if;
  -- attendee_joined queued before the block is still dropped.
  if exists (select 1 from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.j1')) then
    raise exception 'FAIL 4 attendee_joined crossed a block';
  end if;
  select * into n from public.notifications where id = current_setting('test.j1')::uuid;
  if n.email_status <> 'skipped' or n.push_status <> 'skipped' or n.last_error <> 'blocked' then
    raise exception 'FAIL 4 attendee_joined across a block was not skipped';
  end if;
  -- A mute does not stop a broadcast, as at queueing.
  select x into v_r from jsonb_array_elements(v_out) x where x ->> 'id' = current_setting('test.m1');
  if v_r is null then raise exception 'FAIL 4 a broadcast to a muter was dropped'; end if;
  if v_r ->> 'actor_name' is distinct from 'Tester' then raise exception 'FAIL 4 a muted, unblocked sender lost their name'; end if;
end $$;

select 'notify_worker_fixes: PASS' as result;

rollback;
