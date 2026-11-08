-- ============================================================================
-- Staging check for migration 20261222000100_messaging.sql (migration 58,
-- messaging slice 1). One transaction: throwaway accounts, a plan, a hub, DO
-- blocks that raise on failure, then ROLLBACK. Prints pass/fail only (no user
-- rows; the accounts are invented). Reports, moderation, account deletion
-- and the delivery worker are in messaging_safety.sql.
--
--   1 static: schema_version 2.54 or later; no client grants on messages,
--     evidence or strikes; private helpers out of anon's reach; chat images
--     off; the chat buckets are private.
--   2 membership: shared context opens a DM; a non-member reads nothing
--     (table, RPC, realtime.messages with realtime.topic set) and nobody
--     sends on conv: topics directly (migration 59); the owner's user topic only; a removed RSVP and a room
--     admin's removal lose the event chat; a sensitive hub has no chat; an
--     imported plan has no chat.
--   3 requests: no context gives a request; one text message only (second
--     message, link, image refused); a 23-hour account cannot request; no
--     photo cannot request or send; decline is silent to the requester and
--     a new request is request_cooldown; the request shows under Requests.
--   4 blocks: a block closes the DM both ways, start_dm says user_not_found,
--     each side's messages vanish from the other in a shared event chat,
--     the member row is hidden.
--   5 sending: idempotent client_id; keyset pages without gaps or repeats;
--     per-conversation rate limit, the per-minute limit and hub slow mode;
--     a hub member under 24 hours; images_disabled while off.
--   6 filter: shortener refused everywhere; links allowed in an open DM;
--     message_filtered for a slur (leetspeak) and a request-only term only in
--     a request; three refusals start a cooldown and file a report.
--   7 unread, mute and soft delete: unread counts and mark read (with the
--     notification marked read); mute stops notifications and the badge;
--     quiet hours hold the push; message notifications stay out of
--     unread_notification_count; author delete and room admin delete.
-- ============================================================================
begin;

-- Migration 74 turns meta.chat_images on; this file checks the paths with it off (rolled back).
update public.meta set value = 'off' where key = 'chat_images';

-- ---------------------------------------------------------------------------
-- Helpers (this session only)
-- ---------------------------------------------------------------------------
create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
-- The error message of a statement, or 'ok'.
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- Moves every test message two minutes back, so the per-second and
-- per-minute limits do not hit the next send (now() is fixed in a transaction).
create function pg_temp.backdate() returns void language sql security definer as $$
  update public.messages set created_at = created_at - interval '2 minutes'
   where author_id = any (string_to_array(current_setting('test.ids'), ',')::uuid[]);
$$;
-- has_link as stored (messages has no client grant).
create function pg_temp.has_link(p_id uuid) returns boolean language sql security definer as $$
  select m.has_link from public.messages m where m.id = p_id;
$$;
create function pg_temp.send(p_conv uuid, p_body text) returns jsonb language plpgsql as $$
declare
  v jsonb;
begin
  v := public.send_message(p_conv, gen_random_uuid(), p_body);
  perform pg_temp.backdate();
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 54] then
    raise exception 'FAIL 1 schema_version is older than 2.54';
  end if;
  if has_table_privilege('authenticated', 'public.messages', 'select')
     or has_table_privilege('authenticated', 'public.messages', 'insert')
     or has_table_privilege('authenticated', 'public.message_report_evidence', 'select')
     or has_table_privilege('authenticated', 'public.chat_filter_strikes', 'select')
     or has_table_privilege('authenticated', 'public.conversations', 'insert')
     or has_table_privilege('authenticated', 'public.conversation_members', 'update')
     or has_table_privilege('anon', 'public.conversations', 'select')
     or has_column_privilege('authenticated', 'public.message_requests', 'status', 'select')
     or not has_column_privilege('authenticated', 'public.conversation_members', 'user_id', 'select') then
    raise exception 'FAIL 1 message table grants';
  end if;
  if has_function_privilege('anon', 'public.send_message(uuid,uuid,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.send_message(uuid,uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.purge_messaging()', 'execute')
     or has_function_privilege('authenticated', 'public.chat_image_classified(text,text,text,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'private.chat_role(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'private.chat_shared_context(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'private.chat_can_read(uuid)', 'execute')
     or has_function_privilege('anon', 'private.chat_can_read(uuid)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if exists (select 1 from storage.buckets where id in ('chat-images', 'chat-evidence') and public)
     or (select count(*) from storage.buckets where id in ('chat-images', 'chat-evidence')) <> 2 then
    raise exception 'FAIL 1 chat buckets missing or public';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages'
                                             and policyname = 'chat_topics_read') then
    raise exception 'FAIL 1 realtime.messages read policy missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- a, b: share plan e1. c, d: strangers. n: 23-hour account. p: no photo.
  -- x: not on anything. k: on e1, later blocks a. y: on e1, removed by the host.
  -- f: filter tests (on e1). h: hosts e1. s: hub member under 24 hours.
  v_names text[] := array['a', 'b', 'c', 'd', 'n', 'p', 'x', 'k', 'y', 'f', 'h', 's'];
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_hub   uuid;
  v_sens  uuid;
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
            'msg-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = case when v_names[i] = 'n' then now() - interval '23 hours' else now() - interval '3 days' end,
           avatar_url = case when v_names[i] = 'p' then null
                             else public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg' end
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
    v_ids := v_ids || v_id;
  end loop;
  perform set_config('test.ids', array_to_string(v_ids, ','), true);

  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.sens', coalesce(v_sens::text, ''), true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, pg_temp.uid('h'), 'Messaging test plan', now() + interval '2 days', now() + interval '2 days 2 hours',
          'Riverside')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status)
  select v_e, u, 'going' from unnest(array[pg_temp.uid('a'), pg_temp.uid('b'), pg_temp.uid('k'), pg_temp.uid('y'),
                                           pg_temp.uid('f'), pg_temp.uid('p')]) u;
  -- a, b and s in the hub; a and b for days, s for an hour.
  insert into public.hub_members (user_id, hub_id, joined_at)
  values (pg_temp.uid('a'), v_hub, now() - interval '3 days'), (pg_temp.uid('b'), v_hub, now() - interval '3 days'),
         (pg_temp.uid('s'), v_hub, now() - interval '1 hour')
  on conflict do nothing;
  update public.hub_members set joined_at = now() - interval '3 days'
   where hub_id = v_hub and user_id in (pg_temp.uid('a'), pg_temp.uid('b'));
  update public.hub_members set joined_at = now() - interval '1 hour'
   where hub_id = v_hub and user_id = pg_temp.uid('s');
  -- Notifications at any hour for b, unless a test sets quiet hours.
  insert into public.notification_prefs (user_id) values (pg_temp.uid('b')) on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Membership
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v    jsonb;
  v_dm uuid;
  v_ev uuid;
  v_n  integer;
begin
  -- Shared plan: the DM opens.
  perform pg_temp.act('a');
  v := public.start_dm(pg_temp.uid('b'));
  if v ->> 'state' <> 'open' then raise exception 'FAIL 2 shared context did not open the DM'; end if;
  v_dm := (v ->> 'conversation_id')::uuid;
  perform set_config('test.dm_ab', v_dm::text, true);
  v := pg_temp.send(v_dm, 'Hi from the plan');
  if v ->> 'seq' <> '1' then raise exception 'FAIL 2 first message did not get seq 1'; end if;

  -- The plan's chat.
  v_ev := (public.open_event_chat(pg_temp.uid('e1'::text)::uuid) ->> 'conversation_id')::uuid;
  perform set_config('test.ev', v_ev::text, true);
  perform pg_temp.send(v_ev, 'See you there');

  perform pg_temp.act('b');
  if (select count(*) from public.get_messages(v_dm)) <> 1 then raise exception 'FAIL 2 b does not read the DM'; end if;
  if (select count(*) from public.get_messages(v_ev)) <> 1 then raise exception 'FAIL 2 b does not read the plan chat'; end if;
  if not exists (select 1 from public.conversations where id = v_ev) then
    raise exception 'FAIL 2 b cannot select the plan chat row';
  end if;

  -- x is on nothing: no table row, no RPC, no member rows.
  perform pg_temp.act('x');
  if exists (select 1 from public.conversations where id in (v_dm, v_ev)) then
    raise exception 'FAIL 2 a non-member selected a conversation';
  end if;
  if exists (select 1 from public.conversation_members where conversation_id in (v_dm, v_ev)) then
    raise exception 'FAIL 2 a non-member selected member rows';
  end if;
  if pg_temp.err(format('select * from public.get_messages(%L)', v_dm)) <> 'not_found'
     or pg_temp.err(format('select * from public.get_messages(%L)', v_ev)) <> 'not_found' then
    raise exception 'FAIL 2 a non-member read messages';
  end if;
  if pg_temp.err(format('select public.open_event_chat(%L)', current_setting('test.e1'))) <> 'forbidden' then
    raise exception 'FAIL 2 a non-member opened the plan chat';
  end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_ev, 'hello')) <> 'forbidden' then
    raise exception 'FAIL 2 a non-member posted in the plan chat';
  end if;
end $$;

-- Realtime: the signals the trigger wrote are readable only by members.
do $$
declare
  v_ev uuid := current_setting('test.ev')::uuid;
begin
  perform pg_temp.act('x');
  perform set_config('realtime.topic', 'conv:' || v_ev, true);
  if exists (select 1 from realtime.messages where topic = 'conv:' || v_ev) then
    raise exception 'FAIL 2 a non-member reads the conversation topic';
  end if;
  if pg_temp.err(format($q$insert into realtime.messages (topic, extension, event, payload, private)
                          values (%L, 'broadcast', 'typing', '{}', true)$q$, 'conv:' || v_ev)) = 'ok' then
    raise exception 'FAIL 2 a non-member sent on the conversation topic';
  end if;
  perform set_config('realtime.topic', 'user:' || current_setting('test.b') || ':chats', true);
  if exists (select 1 from realtime.messages where topic = 'user:' || current_setting('test.b') || ':chats') then
    raise exception 'FAIL 2 someone else reads a personal topic';
  end if;

  perform pg_temp.act('b');
  perform set_config('realtime.topic', 'conv:' || v_ev, true);
  if not exists (select 1 from realtime.messages where topic = 'conv:' || v_ev and event = 'msg') then
    raise exception 'FAIL 2 a member cannot read the conversation topic';
  end if;
  if exists (select 1 from realtime.messages where topic = 'conv:' || v_ev and payload ? 'body') then
    raise exception 'FAIL 2 a signal carries a body';
  end if;
  -- Migration 59: members do not send on conv: topics either; typing goes through chat_typing.
  if pg_temp.err(format($q$insert into realtime.messages (topic, extension, event, payload, private)
                          values (%L, 'broadcast', 'typing', '{}', true)$q$, 'conv:' || v_ev)) = 'ok' then
    raise exception 'FAIL 2 a member sent on the conversation topic directly';
  end if;
  perform set_config('realtime.topic', 'user:' || current_setting('test.b') || ':chats', true);
  if not exists (select 1 from realtime.messages where topic = 'user:' || current_setting('test.b') || ':chats') then
    raise exception 'FAIL 2 the owner cannot read their personal topic';
  end if;
  perform set_config('realtime.topic', '', true);
end $$;

do $$
declare
  v_ev uuid := current_setting('test.ev')::uuid;
begin
  -- y is going, then the host removes y from the room.
  perform pg_temp.act('y');
  if (select count(*) from public.get_messages(v_ev)) < 1 then raise exception 'FAIL 2 y cannot read the plan chat'; end if;
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.remove_conversation_member(%L, %L)', v_ev, current_setting('test.y'))) <> 'forbidden' then
    raise exception 'FAIL 2 a member removed someone from the plan chat';
  end if;
  perform pg_temp.act('h');
  perform public.remove_conversation_member(v_ev, pg_temp.uid('y'));
  perform pg_temp.act('y');
  if pg_temp.err(format('select * from public.get_messages(%L)', v_ev)) <> 'not_found'
     or pg_temp.err(format('select public.open_event_chat(%L)', current_setting('test.e1'))) <> 'forbidden' then
    raise exception 'FAIL 2 a removed member still reads the plan chat';
  end if;
  -- A sensitive hub has no chat.
  if current_setting('test.sens') <> ''
     and pg_temp.err(format('select public.open_hub_chat(%L)', current_setting('test.sens'))) <> 'chat_unavailable' then
    raise exception 'FAIL 2 a sensitive hub has a chat';
  end if;
end $$;
reset role;

-- k's RSVP is taken away (removed by the host): k loses the plan chat; it comes back after.
update public.rsvps set status = 'cancelled', removed_at = now(), removed_by = pg_temp.uid('h'), removed_reason = 'test'
 where event_id = pg_temp.uid('e1') and user_id = pg_temp.uid('k');
set local role authenticated;
do $$
begin
  perform pg_temp.act('k');
  if pg_temp.err(format('select * from public.get_messages(%L)', current_setting('test.ev'))) <> 'not_found' then
    raise exception 'FAIL 2 a removed RSVP still reads the plan chat';
  end if;
end $$;
reset role;
update public.rsvps set status = 'going', removed_at = null, removed_by = null, removed_reason = null
 where event_id = pg_temp.uid('e1') and user_id = pg_temp.uid('k');
-- An imported plan has no chat.
do $$
declare
  v_e uuid;
begin
  select e.id into v_e from public.events e where e.kind = 'imported' limit 1;
  perform set_config('test.imported', coalesce(v_e::text, ''), true);
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('a');
  if current_setting('test.imported') <> ''
     and pg_temp.err(format('select public.open_event_chat(%L)', current_setting('test.imported'))) <> 'chat_unavailable' then
    raise exception 'FAIL 2 an imported plan has a chat';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Message requests
-- ---------------------------------------------------------------------------
do $$
declare
  v    jsonb;
  v_rq uuid;
begin
  perform pg_temp.act('a');
  v := public.start_dm(pg_temp.uid('c'));
  if v ->> 'state' <> 'request' then raise exception 'FAIL 3 no shared context did not give a request'; end if;
  v_rq := (v ->> 'conversation_id')::uuid;
  perform set_config('test.rq_ac', v_rq::text, true);
  -- A link or an image in a request is refused (images are off, so that answer comes first).
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_rq, 'see www.example.com')) <> 'link_not_allowed' then
    raise exception 'FAIL 3 a link was allowed in a request';
  end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L, %L)', v_rq, '',
                        current_setting('test.a') || '/' || v_rq || '/' || gen_random_uuid() || '.jpg')) <> 'images_disabled' then
    raise exception 'FAIL 3 an image was not refused while chat images are off';
  end if;
  -- (Not backdated: the one-message rule counts from the request's time.)
  v := public.send_message(v_rq, gen_random_uuid(), 'Hi, I saw your post about the climbing gym');
  if v ->> 'id' is null then raise exception 'FAIL 3 the first request message was refused'; end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_rq, 'Hello?')) <> 'request_pending' then
    raise exception 'FAIL 3 a second message before acceptance was allowed';
  end if;
  if (public.start_dm(pg_temp.uid('c')) ->> 'state') <> 'request_pending' then
    raise exception 'FAIL 3 start_dm did not say request_pending';
  end if;
  -- The requester sees it in Chats as sent.
  if (select l.request from public.chat_list() l where l.conversation_id = v_rq) is distinct from 'sent' then
    raise exception 'FAIL 3 the requester does not see the request as sent';
  end if;

  -- The recipient sees it under Requests, not in Chats.
  perform pg_temp.act('c');
  if not exists (select 1 from public.chat_list('requests') l where l.conversation_id = v_rq) then
    raise exception 'FAIL 3 the request is not under Requests';
  end if;
  if exists (select 1 from public.chat_list('chats') l where l.conversation_id = v_rq) then
    raise exception 'FAIL 3 the request is in the main list';
  end if;
  if ((public.chat_unread_total()) ->> 'requests')::integer < 1 then
    raise exception 'FAIL 3 the request is not counted on the badge';
  end if;
  perform public.respond_message_request(v_rq, 'decline');

  -- Silent decline; a new request inside 30 days is request_cooldown.
  perform pg_temp.act('a');
  if (select l.request from public.chat_list() l where l.conversation_id = v_rq) is distinct from 'sent' then
    raise exception 'FAIL 3 the decline was visible to the requester';
  end if;
end $$;
do $$
begin
  if pg_temp.err('select status from public.message_requests limit 1') = 'ok' then
    raise exception 'FAIL 3 the requester can read the request status';
  end if;
  if pg_temp.err(format('select public.start_dm(%L)', current_setting('test.c'))) <> 'request_cooldown' then
    raise exception 'FAIL 3 a declined requester could ask again at once';
  end if;
  -- A 23-hour account cannot start a request; a profile without a photo cannot request or send.
  perform pg_temp.act('n');
  if pg_temp.err(format('select public.start_dm(%L)', current_setting('test.c'))) <> 'account_too_new' then
    raise exception 'FAIL 3 a 23-hour account sent a request';
  end if;
  perform pg_temp.act('p');
  if pg_temp.err(format('select public.start_dm(%L)', current_setting('test.c'))) <> 'photo_required' then
    raise exception 'FAIL 3 an account without a photo sent a request';
  end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', current_setting('test.ev'), 'hi')) <> 'photo_required' then
    raise exception 'FAIL 3 an account without a photo posted in the plan chat';
  end if;
  -- Reading needs no photo.
  if (select count(*) from public.get_messages(current_setting('test.ev')::uuid)) < 1 then
    raise exception 'FAIL 3 an account without a photo cannot read the plan chat';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Blocks
-- ---------------------------------------------------------------------------
do $$
declare
  v_dm uuid;
  v_ev uuid := current_setting('test.ev')::uuid;
begin
  perform pg_temp.act('k');
  v_dm := (public.start_dm(pg_temp.uid('a')) ->> 'conversation_id')::uuid;
  perform set_config('test.dm_ak', v_dm::text, true);
  perform pg_temp.send(v_dm, 'k to a');
  perform pg_temp.send(v_ev, 'k in the plan chat');
  perform public.block_user(pg_temp.uid('a'));
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'again')) <> 'conversation_closed' then
    raise exception 'FAIL 4 the blocker can still send in the DM';
  end if;
  if exists (select 1 from public.get_messages(v_ev) m where (m.author ->> 'id')::uuid = pg_temp.uid('a')) then
    raise exception 'FAIL 4 the blocker still sees the blocked person''s plan chat messages';
  end if;

  perform pg_temp.act('a');
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'hey')) <> 'conversation_closed' then
    raise exception 'FAIL 4 the blocked person can still send in the DM';
  end if;
  if pg_temp.err(format('select public.start_dm(%L)', current_setting('test.k'))) <> 'user_not_found' then
    raise exception 'FAIL 4 start_dm across a block did not say user_not_found';
  end if;
  if exists (select 1 from public.get_messages(v_ev) m where (m.author ->> 'id')::uuid = pg_temp.uid('k'))
     or exists (select 1 from public.get_messages(v_dm) m where not m.mine) then
    raise exception 'FAIL 4 the blocked person still sees the blocker''s messages';
  end if;
  if exists (select 1 from public.conversation_members where conversation_id = v_dm and user_id = pg_temp.uid('k')) then
    raise exception 'FAIL 4 the blocker''s member row is visible';
  end if;
  if exists (select 1 from public.chat_list() l where l.conversation_id = v_dm) then
    raise exception 'FAIL 4 the DM is still listed across the block';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Sending
-- ---------------------------------------------------------------------------
do $$
declare
  v_dm   uuid := current_setting('test.dm_ab')::uuid;
  v_cid  uuid := gen_random_uuid();
  v1     jsonb;
  v2     jsonb;
  v_seqs bigint[] := '{}';
  v_page bigint[];
  v_cur  bigint;
  v_hub  uuid;
begin
  perform pg_temp.act('a');
  -- Idempotent retry.
  v1 := public.send_message(v_dm, v_cid, 'once');
  v2 := public.send_message(v_dm, v_cid, 'once');
  perform pg_temp.backdate();
  if v1 ->> 'id' <> v2 ->> 'id' or (v2 ->> 'duplicate')::boolean is not true or (v1 ->> 'duplicate')::boolean then
    raise exception 'FAIL 5 a retry with the same client_id did not return the same row';
  end if;
  if (select count(*) from public.get_messages(v_dm, null, null, 100) m where m.client_id = v_cid) <> 1 then
    raise exception 'FAIL 5 a retry wrote a second row';
  end if;
  -- Per-conversation limit: two sends in the same second.
  perform public.send_message(v_dm, gen_random_uuid(), 'quick one');
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'quick two')) <> 'rate_limited' then
    raise exception 'FAIL 5 two messages in one second were allowed';
  end if;
  perform pg_temp.backdate();
  for i in 1..6 loop
    perform pg_temp.send(v_dm, 'page ' || i);
  end loop;
  -- Keyset pages of 3: every seq once, no gaps.
  v_cur := null;
  loop
    select array_agg(m.seq order by m.seq desc) into v_page from public.get_messages(v_dm, v_cur, null, 3) m;
    exit when v_page is null;
    v_seqs := v_seqs || v_page;
    v_cur := v_page[array_length(v_page, 1)];
  end loop;
  if (select count(distinct s) from unnest(v_seqs) s) <> cardinality(v_seqs)
     or (select max(s) - min(s) + 1 from unnest(v_seqs) s) <> cardinality(v_seqs)
     or (select min(s) from unnest(v_seqs) s) <> 1 then
    raise exception 'FAIL 5 keyset pages have gaps or repeats';
  end if;
  -- after_seq returns what follows, without gaps.
  if (select array_agg(m.seq order by m.seq) from public.get_messages(v_dm, null, 2, 3) m) <> array[3, 4, 5]::bigint[] then
    raise exception 'FAIL 5 after_seq did not return the next messages';
  end if;
  -- images_disabled while off, in an open DM too.
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L, %L)', v_dm, '',
                        current_setting('test.a') || '/' || v_dm || '/' || gen_random_uuid() || '.jpg')) <> 'images_disabled' then
    raise exception 'FAIL 5 images were not disabled';
  end if;

  -- Hub chat: slow mode, and a member under 24 hours cannot post.
  v_hub := (public.open_hub_chat(current_setting('test.hub')::uuid) ->> 'conversation_id')::uuid;
  perform set_config('test.hubchat', v_hub::text, true);
  perform public.send_message(v_hub, gen_random_uuid(), 'hub hello');
end $$;
reset role;
update public.messages set created_at = created_at - interval '5 seconds'
 where conversation_id = current_setting('test.hubchat')::uuid;
set local role authenticated;
do $$
declare
  v_hub uuid := current_setting('test.hubchat')::uuid;
begin
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_hub, 'too soon')) <> 'slow_mode' then
    raise exception 'FAIL 5 hub slow mode did not apply';
  end if;
  perform pg_temp.act('s');
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_hub, 'new here')) <> 'account_too_new' then
    raise exception 'FAIL 5 a hub member under 24 hours posted';
  end if;
  if (select count(*) from public.get_messages(v_hub)) < 1 then
    raise exception 'FAIL 5 a new hub member cannot read the hub chat';
  end if;
end $$;
reset role;
-- Thirty messages in the last minute (written directly, in a throwaway group).
do $$
declare
  v_g uuid;
begin
  insert into public.conversations (kind, title, created_by) values ('group', 'Limit test', pg_temp.uid('a'))
  returning id into v_g;
  insert into public.messages (conversation_id, seq, author_id, body, created_at)
  select v_g, i, pg_temp.uid('a'), 'x', now() - interval '20 seconds' from generate_series(1, 30) i;
  perform set_config('test.limitgroup', v_g::text, true);
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', current_setting('test.dm_ab'), 'one more')) <> 'rate_limited' then
    raise exception 'FAIL 5 the per-minute limit did not apply';
  end if;
end $$;
reset role;
delete from public.conversations where id = current_setting('test.limitgroup')::uuid;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 6. Filter
-- ---------------------------------------------------------------------------
do $$
declare
  v_dm uuid;
  v_rq uuid;
  v    jsonb;
begin
  perform pg_temp.act('f');
  v_dm := (public.start_dm(pg_temp.uid('b')) ->> 'conversation_id')::uuid;
  perform set_config('test.dm_fb', v_dm::text, true);
  -- Shorteners: refused even in an open DM.
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'look: bit.ly/abc123')) <> 'link_not_allowed' then
    raise exception 'FAIL 6 a shortener was allowed';
  end if;
  -- Plain links are fine in an open DM from an older account; email and phone are not links.
  v := pg_temp.send(v_dm, 'tickets at https://example.org/tickets');
  if v ->> 'id' is null then raise exception 'FAIL 6 a link was refused in an open DM'; end if;
  if not pg_temp.has_link((v ->> 'id')::uuid) then
    raise exception 'FAIL 6 has_link not set';
  end if;
  v := pg_temp.send(v_dm, 'mail me at sam@example.com or call 404.555.0100');
  if pg_temp.has_link((v ->> 'id')::uuid) then
    raise exception 'FAIL 6 an email address or phone number counted as a link';
  end if;
  -- A request-only term is fine here, refused in a request.
  v := pg_temp.send(v_dm, 'I can pay you back on cashapp');
  if v ->> 'id' is null then raise exception 'FAIL 6 a request-only term was refused outside a request'; end if;
  v_rq := (public.start_dm(pg_temp.uid('d')) ->> 'conversation_id')::uuid;
  v := pg_temp.send(v_rq, 'hey send me your cashapp');
  if v ->> 'error' is distinct from 'message_filtered' then
    raise exception 'FAIL 6 a request-only term passed in a request';
  end if;
  -- A slur in leetspeak with stretched letters.
  v := pg_temp.send(v_dm, 'you f4gggg0t');
  if v ->> 'error' is distinct from 'message_filtered' then
    raise exception 'FAIL 6 a slur passed the filter';
  end if;
  -- Ordinary swearing is fine.
  v := pg_temp.send(v_dm, 'damn that was a hell of a hike');
  if v ->> 'id' is null then raise exception 'FAIL 6 ordinary profanity was refused'; end if;
  -- Third refusal within the hour: cooldown and an automatic report.
  v := pg_temp.send(v_dm, 'n1gger');
  if v ->> 'error' is distinct from 'message_filtered' then raise exception 'FAIL 6 third refusal'; end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_dm, 'ok sorry')) <> 'rate_limited' then
    raise exception 'FAIL 6 three refusals did not start the cooldown';
  end if;
end $$;
reset role;
do $$
begin
  if not exists (select 1 from public.reports r
                  where r.target_kind = 'profile' and r.target_id = pg_temp.uid('f') and r.reporter_id is null
                    and r.status = 'open') then
    raise exception 'FAIL 6 three refusals did not file an automatic report';
  end if;
end $$;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 7. Unread, mute, quiet hours, soft delete
-- ---------------------------------------------------------------------------
do $$
declare
  v_dm   uuid := current_setting('test.dm_ab')::uuid;
  v_n    integer;
  v_seq  bigint;
  v_note integer;
begin
  perform pg_temp.act('b');
  select l.unread into v_n from public.chat_list() l where l.conversation_id = v_dm;
  if coalesce(v_n, 0) < 5 then raise exception 'FAIL 7 unread count is wrong'; end if;
  if ((public.chat_unread_total()) ->> 'chats')::integer < 1 then raise exception 'FAIL 7 badge does not count the DM'; end if;
  if not exists (select 1 from public.notifications n
                  where n.user_id = pg_temp.uid('b') and n.kind = 'message'
                    and n.payload ->> 'conversation_id' = v_dm::text and n.read_at is null) then
    raise exception 'FAIL 7 no message notification for b';
  end if;
  if exists (select 1 from public.notifications n
              where n.user_id = pg_temp.uid('b') and n.kind = 'message' and n.email_status <> 'skipped') then
    raise exception 'FAIL 7 a message notification is set to email';
  end if;
  if exists (select 1 from public.notifications n
              where n.user_id = pg_temp.uid('b') and n.kind = 'message' and n.payload::text like '%page 1%') then
    raise exception 'FAIL 7 a notification carries message text';
  end if;
  -- Message notifications have their own badge.
  if public.unread_notification_count() <> (select count(*) from public.notifications n
                                             where n.user_id = pg_temp.uid('b') and n.read_at is null
                                               and n.kind::text not in ('message', 'message_request')) then
    raise exception 'FAIL 7 unread_notification_count counts chat notices';
  end if;
  select c.last_seq into v_seq from public.conversations c where c.id = v_dm;
  perform public.mark_conversation_read(v_dm, v_seq);
  if (select l.unread from public.chat_list() l where l.conversation_id = v_dm) <> 0 then
    raise exception 'FAIL 7 mark read left unread messages';
  end if;
  if exists (select 1 from public.notifications n
              where n.user_id = pg_temp.uid('b') and n.kind = 'message'
                and n.payload ->> 'conversation_id' = v_dm::text and n.read_at is null) then
    raise exception 'FAIL 7 mark read left the notification unread';
  end if;
  -- Never lowered.
  perform public.mark_conversation_read(v_dm, 1);
  if (public.conversation_info(v_dm) ->> 'last_read_seq')::bigint <> v_seq then
    raise exception 'FAIL 7 mark read lowered last_read_seq';
  end if;

  -- Mute: no notification, not on the badge.
  perform public.mute_conversation(v_dm, 'infinity');
  v_n := ((public.chat_unread_total()) ->> 'chats')::integer;
  select count(*) into v_note from public.notifications n where n.user_id = pg_temp.uid('b') and n.kind = 'message';
  perform pg_temp.act('a');
  perform pg_temp.send(v_dm, 'while muted');
  perform pg_temp.act('b');
  if (select count(*) from public.notifications n where n.user_id = pg_temp.uid('b') and n.kind = 'message'
                                                    and n.payload ->> 'conversation_id' = v_dm::text
                                                    and n.read_at is null) > 0 then
    raise exception 'FAIL 7 a muted conversation notified';
  end if;
  if not (select l.muted from public.chat_list() l where l.conversation_id = v_dm) then
    raise exception 'FAIL 7 chat_list does not show the mute';
  end if;
  if ((public.chat_unread_total()) ->> 'chats')::integer <> v_n
     or (select l.unread from public.chat_list() l where l.conversation_id = v_dm) <> 1 then
    raise exception 'FAIL 7 a muted conversation is on the badge';
  end if;
  perform public.mute_conversation(v_dm, null);
end $$;
reset role;
-- Quiet hours for b all day: the next push waits.
update public.notification_prefs set quiet_start = '00:00', quiet_end = '23:59', timezone = 'UTC'
 where user_id = pg_temp.uid('b');
delete from public.notifications where user_id = pg_temp.uid('b') and kind = 'message';
set local role authenticated;
do $$
declare
  v_dm  uuid := current_setting('test.dm_ab')::uuid;
  v_msg uuid;
  v_ev  uuid := current_setting('test.ev')::uuid;
begin
  perform pg_temp.act('a');
  perform pg_temp.send(v_dm, 'after the mute');
  perform pg_temp.act('b');
  if not exists (select 1 from public.notifications n
                  where n.user_id = pg_temp.uid('b') and n.kind = 'message' and n.push_after is not null) then
    raise exception 'FAIL 7 quiet hours did not hold the push';
  end if;

  -- Author delete.
  perform pg_temp.act('a');
  select m.id into v_msg from public.get_messages(v_dm) m where m.mine limit 1;
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.delete_message(%L)', v_msg)) <> 'forbidden' then
    raise exception 'FAIL 7 someone deleted another person''s DM message';
  end if;
  perform pg_temp.act('a');
  perform public.delete_message(v_msg);
  perform pg_temp.act('b');
  if not exists (select 1 from public.get_messages(v_dm) m where m.id = v_msg and m.deleted = 'author' and m.body = '') then
    raise exception 'FAIL 7 an author delete did not leave an empty deleted row';
  end if;
  if (select l.last_message ->> 'preview' from public.chat_list() l where l.conversation_id = v_dm) <> 'Message deleted' then
    raise exception 'FAIL 7 the preview shows a deleted message';
  end if;

  -- Room admin delete in the plan chat.
  perform pg_temp.act('a');
  select m.id into v_msg from public.get_messages(v_ev) m where m.mine limit 1;
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.delete_message(%L)', v_msg)) <> 'forbidden' then
    raise exception 'FAIL 7 a member deleted someone else''s plan chat message';
  end if;
  perform pg_temp.act('h');
  perform public.delete_message(v_msg);
  perform pg_temp.act('b');
  if not exists (select 1 from public.get_messages(v_ev) m where m.id = v_msg and m.deleted = 'room_admin') then
    raise exception 'FAIL 7 a room admin delete did not show';
  end if;
  perform set_config('test.admindel', v_msg::text, true);
end $$;
reset role;
do $$
begin
  if not exists (select 1 from public.moderation_actions ma
                  where ma.target_kind = 'message' and ma.target_id = current_setting('test.admindel')::uuid
                    and ma.note = 'room_admin' and ma.moderator_id = pg_temp.uid('h')) then
    raise exception 'FAIL 7 a room admin delete was not logged';
  end if;
  if not exists (select 1 from public.messages m
                  where m.id = current_setting('test.admindel')::uuid and m.deleted_body = 'See you there') then
    raise exception 'FAIL 7 the deleted text was not kept for evidence';
  end if;
end $$;

select 'messaging: PASS' as result;

rollback;
