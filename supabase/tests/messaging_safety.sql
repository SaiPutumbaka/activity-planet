-- ============================================================================
-- Staging check for migration 20261222000100_messaging.sql (migration 58),
-- part 2: groups, reports and evidence, moderators, blocks on requests, the
-- delivery worker and account deletion. One transaction, DO blocks that
-- raise on failure, ROLLBACK. Prints pass/fail only (invented accounts).
--
--   1 groups: create_group skips people without shared context and people
--     blocked with a member; roles; an owner leaving hands over.
--   2 reports: a member reports a message; evidence keeps the body and the
--     context the reporter could see; own message is own_item; a non-member
--     cannot report it.
--   3 moderators: mod_message_evidence (logged); the second-moderator rule
--     (a moderator in the DM, a moderator who reported); remove reads as
--     "moderator" with an empty body; restore brings it back.
--   4 blocks and requests: blocking the requester declines the request and
--     closes the DM.
--   5 worker: a message notice is not pushed once read in the chat, nor
--     while the chat is muted; it never goes by email.
--   6 account deletion: the pending request the person sent goes; DMs close;
--     their messages stay as "Deleted user" without the device key; the
--     group passes to the next admin; evidence stays; nothing of theirs is
--     left in conversation_members or message_requests.
-- ============================================================================
begin;

-- Migration 77: the account-wide email budget must not hide the rows under test.
insert into public.meta (key, value) values ('email_daily_cap_total', '9999999'), ('email_monthly_cap_total', '9999999')
  on conflict (key) do update set value = excluded.value;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create function pg_temp.backdate() returns void language sql security definer as $$
  update public.messages set created_at = created_at - interval '2 minutes'
   where author_id = any (string_to_array(current_setting('test.ids'), ',')::uuid[]);
$$;
create function pg_temp.send(p_conv uuid, p_body text) returns uuid language plpgsql as $$
declare
  v jsonb;
begin
  v := public.send_message(p_conv, gen_random_uuid(), p_body);
  perform pg_temp.backdate();
  return (v ->> 'id')::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  -- a, b, g, o, m2: on plan e1. c, z: strangers. m: moderator (on nothing).
  -- m2: moderator on e1. o: blocked by g.
  v_names text[] := array['a', 'b', 'c', 'g', 'o', 'z', 'm', 'm2'];
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  if public.project_url() is null then
    raise exception 'FAIL setup: meta.project_url is not set';
  end if;
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'msgs-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1994-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '5 days',
           avatar_url = public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
    v_ids := v_ids || v_id;
  end loop;
  perform set_config('test.ids', array_to_string(v_ids, ','), true);
  insert into public.user_roles (user_id, role) values (pg_temp.uid('m'), 'moderator'), (pg_temp.uid('m2'), 'moderator');

  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, pg_temp.uid('a'), 'Messaging safety plan', now() + interval '3 days', now() + interval '3 days 2 hours',
          'Park')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status)
  select v_e, u, 'going' from unnest(array[pg_temp.uid('b'), pg_temp.uid('g'), pg_temp.uid('o'), pg_temp.uid('m2')]) u;

  -- Migration 78: a shared plan counts for messaging once the RSVP is a day old.
  update public.rsvps set created_at = now() - interval '2 days' where event_id = v_e;
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('g'), pg_temp.uid('o'));
  insert into public.notification_prefs (user_id) values (pg_temp.uid('b')) on conflict do nothing;
  update public.notification_prefs set quiet_start = null, quiet_end = null where user_id = pg_temp.uid('b');
end $$;

-- ---------------------------------------------------------------------------
-- 1. Groups
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v   jsonb;
  v_g uuid;
begin
  perform pg_temp.act('a');
  -- b, g share the plan with a; c does not. o shares it too, but g blocked o.
  v := public.create_group('Park crew', array[pg_temp.uid('b'), pg_temp.uid('g'), pg_temp.uid('c')]);
  v_g := (v ->> 'conversation_id')::uuid;
  perform set_config('test.group', v_g::text, true);
  if (v ->> 'added')::integer <> 2 or (v ->> 'skipped')::integer <> 1 then
    raise exception 'FAIL 1 create_group added % and skipped %', v ->> 'added', v ->> 'skipped';
  end if;
  v := public.add_group_members(v_g, array[pg_temp.uid('o')]);
  if (v ->> 'added')::integer <> 0 or (v ->> 'skipped')::integer <> 1 then
    raise exception 'FAIL 1 someone blocked by a member was added';
  end if;
  if exists (select 1 from public.conversation_members cm
              where cm.conversation_id = v_g and cm.user_id in (pg_temp.uid('c'), pg_temp.uid('o'))) then
    raise exception 'FAIL 1 a skipped person is in the group';
  end if;
  perform public.set_conversation_role(v_g, pg_temp.uid('g'), 'admin');
  perform pg_temp.send(v_g, 'Welcome to the group');
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.rename_group(%L, %L)', v_g, 'Mine now')) <> 'forbidden' then
    raise exception 'FAIL 1 a member renamed the group';
  end if;
  perform pg_temp.send(v_g, 'Thanks');
  perform pg_temp.act('c');
  if pg_temp.err(format('select * from public.get_messages(%L)', v_g)) <> 'not_found' then
    raise exception 'FAIL 1 a skipped person reads the group';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Reports and evidence
-- ---------------------------------------------------------------------------
do $$
declare
  v_dm  uuid;
  v_msg uuid;
  v     jsonb;
begin
  perform pg_temp.act('a');
  v_dm := (public.start_dm(pg_temp.uid('b')) ->> 'conversation_id')::uuid;
  perform set_config('test.dm_ab', v_dm::text, true);
  perform pg_temp.send(v_dm, 'context before');
  v_msg := pg_temp.send(v_dm, 'the reported line');
  perform set_config('test.msg', v_msg::text, true);
  perform pg_temp.send(v_dm, 'context after');
  if pg_temp.err(format('select public.report_content(%L, %L, %L)', 'message', v_msg, 'harassment')) <> 'own_item' then
    raise exception 'FAIL 2 reporting one''s own message was allowed';
  end if;
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.report_content(%L, %L, %L)', 'message', v_msg, 'harassment')) <> 'target_not_found' then
    raise exception 'FAIL 2 a non-member reported a message';
  end if;
  perform pg_temp.act('b');
  v := public.report_content('message', v_msg, 'harassment', 'Not okay');
  perform set_config('test.report', v ->> 'id', true);
  if (v ->> 'already')::boolean then raise exception 'FAIL 2 first report said already'; end if;
  -- The author deletes it afterwards; the evidence stays.
  perform pg_temp.act('a');
  perform public.delete_message(v_msg);
end $$;
reset role;
do $$
declare
  ev public.message_report_evidence%rowtype;
begin
  select * into ev from public.message_report_evidence where report_id = current_setting('test.report')::uuid;
  if not found or ev.body <> 'the reported line' or ev.author_id <> pg_temp.uid('a') or ev.conversation_kind <> 'dm' then
    raise exception 'FAIL 2 evidence missing or wrong';
  end if;
  if jsonb_array_length(ev.context) <> 2
     or not exists (select 1 from jsonb_array_elements(ev.context) x where x ->> 'body' = 'context after') then
    raise exception 'FAIL 2 evidence context is wrong (% items)', jsonb_array_length(ev.context);
  end if;
  if (select r.target_user_id from public.reports r where r.id = current_setting('test.report')::uuid) <> pg_temp.uid('a') then
    raise exception 'FAIL 2 the report does not name the author';
  end if;
end $$;
set local role authenticated;

-- A message deleted by its author can still be reported within 30 days.
do $$
begin
  perform pg_temp.act('b');
  if (public.report_content('message', current_setting('test.msg')::uuid, 'spam') ->> 'already') <> 'true' then
    raise exception 'FAIL 2 a repeat report was not already';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Moderators
-- ---------------------------------------------------------------------------
do $$
declare
  v       jsonb;
  v_dm2   uuid;
  v_msg2  uuid;
begin
  perform pg_temp.act('m');
  v := public.mod_message_evidence(current_setting('test.report')::uuid);
  if v ->> 'body' <> 'the reported line' or jsonb_array_length(v -> 'context') <> 2 then
    raise exception 'FAIL 3 mod_message_evidence';
  end if;
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.mod_message_evidence(%L)', current_setting('test.report'))) <> 'forbidden' then
    raise exception 'FAIL 3 a member read evidence';
  end if;
  if pg_temp.err('select * from public.message_report_evidence') = 'ok' then
    raise exception 'FAIL 3 a member selected the evidence table';
  end if;

  -- m2 is in a DM with b: a report on b's message there is not m2's to act on.
  perform pg_temp.act('m2');
  v_dm2 := (public.start_dm(pg_temp.uid('b')) ->> 'conversation_id')::uuid;
  perform pg_temp.act('b');
  v_msg2 := pg_temp.send(v_dm2, 'to the moderator');
  perform set_config('test.msg2', v_msg2::text, true);
  perform pg_temp.act('m2');
  if pg_temp.err(format('select public.mod_moderate(%L, %L, %L)', 'message', v_msg2, 'remove')) <> 'own_item' then
    raise exception 'FAIL 3 a moderator acted on a message in their own DM';
  end if;
  v := public.report_content('message', v_msg2, 'spam');
  perform pg_temp.act('m');
  -- m acts: remove, then the members see it as removed by moderators.
  v := public.mod_moderate('message', v_msg2, 'remove', 'test');
  if v ->> 'state' <> 'removed' then raise exception 'FAIL 3 remove did not set removed'; end if;
  perform pg_temp.act('m2');
  if not exists (select 1 from public.get_messages(v_dm2) m where m.id = v_msg2 and m.deleted = 'moderator' and m.body = '') then
    raise exception 'FAIL 3 a removed message still shows';
  end if;
  perform pg_temp.act('m');
  perform public.mod_moderate('message', v_msg2, 'restore', 'test');
  perform pg_temp.act('b');
  if not exists (select 1 from public.get_messages(v_dm2) m where m.id = v_msg2 and m.deleted is null
                                                              and m.body = 'to the moderator') then
    raise exception 'FAIL 3 restore did not bring the message back';
  end if;
  -- A moderator who filed an open report on it does not act on it either.
  perform pg_temp.act('m2');
  perform public.report_content('message', v_msg2, 'spam');
  if pg_temp.err(format('select public.mod_moderate(%L, %L, %L)', 'message', v_msg2, 'hide')) <> 'own_item' then
    raise exception 'FAIL 3 a reporting moderator acted on the report';
  end if;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from public.admin_lookups l
                  where l.moderator_id = pg_temp.uid('m') and l.via = 'open' and l.target_user_id = pg_temp.uid('a')) then
    raise exception 'FAIL 3 evidence reads are not logged';
  end if;
end $$;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 4. Blocking a requester declines the request and closes the DM
-- ---------------------------------------------------------------------------
do $$
declare
  v_rq uuid;
begin
  perform pg_temp.act('z');
  v_rq := (public.start_dm(pg_temp.uid('c')) ->> 'conversation_id')::uuid;
  perform set_config('test.rq_zc', v_rq::text, true);
  perform public.send_message(v_rq, gen_random_uuid(), 'hello there');
  perform pg_temp.act('c');
  perform public.block_user(pg_temp.uid('z'));
  if exists (select 1 from public.chat_list('requests') l where l.conversation_id = v_rq) then
    raise exception 'FAIL 4 a blocked requester''s request is still listed';
  end if;
end $$;
reset role;
do $$
begin
  if (select r.status from public.message_requests r where r.conversation_id = current_setting('test.rq_zc')::uuid) <> 'declined'
     or (select c.closed_at from public.conversations c where c.id = current_setting('test.rq_zc')::uuid) is null then
    raise exception 'FAIL 4 block did not decline the request and close the DM';
  end if;
  if exists (select 1 from public.notifications n
              where n.user_id = pg_temp.uid('c') and n.kind = 'message_request' and n.email_status <> 'skipped') then
    raise exception 'FAIL 4 a request notification is set to email';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Worker: read in the chat, or muted, means no push
-- ---------------------------------------------------------------------------
do $$
declare
  v_out jsonb;
  v_dm  uuid := current_setting('test.dm_ab')::uuid;
  v_g   uuid := current_setting('test.group')::uuid;
  v_n1  uuid;
  v_n2  uuid;
begin
  select n.id into v_n1 from public.notifications n
   where n.user_id = pg_temp.uid('b') and n.kind = 'message' and n.payload ->> 'conversation_id' = v_dm::text;
  select n.id into v_n2 from public.notifications n
   where n.user_id = pg_temp.uid('b') and n.kind = 'message' and n.payload ->> 'conversation_id' = v_g::text;
  if v_n1 is null or v_n2 is null then raise exception 'FAIL 5 no message notifications queued'; end if;
  -- Read the DM in the chat (stamps last_read_seq, not read_at, to test the seq rule).
  update public.conversation_members cm set last_read_seq = c.last_seq
    from public.conversations c
   where c.id = v_dm and cm.conversation_id = v_dm and cm.user_id = pg_temp.uid('b');
  -- Mute the group now.
  update public.conversation_members set muted_until = 'infinity'
   where conversation_id = v_g and user_id = pg_temp.uid('b');
  update public.notifications set claimed_at = now()
   where (email_status = 'pending' or push_status = 'pending') and id not in (v_n1, v_n2);
  v_out := public.claim_pending_notifications(100);
  if exists (select 1 from jsonb_array_elements(v_out) x where (x ->> 'id')::uuid in (v_n1, v_n2)) then
    raise exception 'FAIL 5 a read or muted chat notice was handed to the worker';
  end if;
  if exists (select 1 from public.notifications n
              where n.id in (v_n1, v_n2) and (n.push_status <> 'skipped' or n.email_status <> 'skipped'
                                              or n.last_error <> 'stale')) then
    raise exception 'FAIL 5 a read or muted chat notice was not skipped';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_rq uuid;
begin
  -- a has a pending request out to c, a DM with b, owns the group (g is admin).
  perform pg_temp.act('a');
  v_rq := (public.start_dm(pg_temp.uid('c')) ->> 'conversation_id')::uuid;
  perform set_config('test.rq_ac', v_rq::text, true);
  perform public.send_message(v_rq, gen_random_uuid(), 'hi c');
  perform public.request_account_deletion('test');
end $$;
reset role;
do $$
declare
  v_dm uuid := current_setting('test.dm_ab')::uuid;
  v_g  uuid := current_setting('test.group')::uuid;
begin
  if exists (select 1 from public.conversations where id = current_setting('test.rq_ac')::uuid) then
    raise exception 'FAIL 6 the pending request the person sent was kept';
  end if;
  if exists (select 1 from public.conversation_members where user_id = pg_temp.uid('a'))
     or exists (select 1 from public.message_requests where from_user = pg_temp.uid('a') or to_user = pg_temp.uid('a')) then
    raise exception 'FAIL 6 member or request rows of the deleted account remain';
  end if;
  if (select closed_at from public.conversations where id = v_dm) is null then
    raise exception 'FAIL 6 the DM was not closed';
  end if;
  if exists (select 1 from public.messages where author_id = pg_temp.uid('a') and (client_id is not null or deleted_body is not null)) then
    raise exception 'FAIL 6 device keys or kept deleted text remain';
  end if;
  if (select role from public.conversation_members where conversation_id = v_g and user_id = pg_temp.uid('g')) <> 'owner' then
    raise exception 'FAIL 6 the group did not pass to the admin';
  end if;
  if not exists (select 1 from public.message_report_evidence where report_id = current_setting('test.report')::uuid) then
    raise exception 'FAIL 6 evidence was deleted with the account';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v_dm uuid := current_setting('test.dm_ab')::uuid;
begin
  perform pg_temp.act('b');
  if not exists (select 1 from public.get_messages(v_dm) m
                  where m.author ->> 'first_name' = 'Deleted user' and m.body = 'context before') then
    raise exception 'FAIL 6 the deleted person''s messages are not kept as Deleted user';
  end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'still there?')) <> 'conversation_closed' then
    raise exception 'FAIL 6 the DM with a deleted account still takes messages';
  end if;
  if not exists (select 1 from public.get_messages(current_setting('test.group')::uuid) m
                  where m.author ->> 'first_name' = 'Deleted user') then
    raise exception 'FAIL 6 the group lost the deleted person''s messages';
  end if;
end $$;

select 'messaging_safety: PASS' as result;

rollback;
