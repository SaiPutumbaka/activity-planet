-- ============================================================================
-- Staging check for migration 20261223000100_messaging_review_fixes.sql
-- (migration 59). One transaction: throwaway accounts, DO blocks that raise
-- on failure, then ROLLBACK. Prints pass/fail only (no user rows; the
-- accounts are invented).
--
--   1 static: schema_version 2.55 or later; the link rule counts www. after
--     "-" and "."; other members' mute, notify and read columns are not
--     granted; no client insert policy on realtime.messages; chat_typing is
--     for signed-in people only; the old chat_list and people_you_met
--     signatures are gone; send_message locks the client id.
--   2 links: "-www.x.dev" and ".www.x.dev" are refused in a request.
--   3 a requester who left a pending request reads it again after start_dm.
--   4 a DM member reads the other member's row but not muted_until, notify
--     or last_read_at.
--   5 typing: chat_typing sends {user_id} for the caller; a member cannot
--     insert on the topic; someone outside the room sends nothing.
--   6 a new request after a decline (and the 30 days) is notified again.
--   7 a retried client id returns the stored row.
--   8 chat_list pages through 105 chats with the same activity time without
--     skipping or repeating; chat_unread_total counts more than 100.
--   9 people_you_met pages through people from one plan without skipping.
--  10 feed_event_area: nothing for an account that has not onboarded.
-- ============================================================================
begin;

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

-- ---------------------------------------------------------------------------
-- 1. Static (as the owner)
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 55] then
    raise exception 'FAIL 1 schema_version is older than 2.55';
  end if;
  if not private.chat_has_link('-www.evil.dev/x') or not private.chat_has_link('.www.evil.dev')
     or not private.chat_has_link('x -www.paypa1-login.dev') or not private.chat_has_link('see www.example.com')
     or private.chat_has_link('mail sam@www.example.com') or private.chat_has_link('e.g. bring water')
     or private.chat_has_link('awww.') then
    raise exception 'FAIL 1 link rule';
  end if;
  if has_column_privilege('authenticated', 'public.conversation_members', 'muted_until', 'select')
     or has_column_privilege('authenticated', 'public.conversation_members', 'notify', 'select')
     or has_column_privilege('authenticated', 'public.conversation_members', 'last_read_at', 'select')
     or has_column_privilege('authenticated', 'public.conversation_members', 'last_read_seq', 'select')
     or has_column_privilege('authenticated', 'public.conversation_members', 'removed_by', 'select')
     or not has_column_privilege('authenticated', 'public.conversation_members', 'role', 'select')
     or not has_column_privilege('authenticated', 'public.conversation_members', 'left_at', 'select') then
    raise exception 'FAIL 1 conversation_members column grants';
  end if;
  if exists (select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages'
                                         and cmd in ('INSERT', 'ALL') and policyname like 'chat%') then
    raise exception 'FAIL 1 a client insert policy on realtime.messages remains';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'realtime' and tablename = 'messages'
                                             and policyname = 'chat_topics_read') then
    raise exception 'FAIL 1 the realtime read policy is missing';
  end if;
  if has_function_privilege('anon', 'public.chat_typing(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.chat_typing(uuid)', 'execute')
     or not (select prosecdef from pg_proc where oid = 'public.chat_typing(uuid)'::regprocedure)
     or not has_function_privilege('authenticated', 'public.chat_list(text,timestamptz,integer,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.people_you_met(timestamptz,integer,uuid)', 'execute')
     or has_function_privilege('anon', 'public.chat_list(text,timestamptz,integer,uuid)', 'execute')
     or has_function_privilege('anon', 'public.people_you_met(timestamptz,integer,uuid)', 'execute')
     or has_function_privilege('anon', 'public.feed_event_area(uuid)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if to_regprocedure('public.chat_list(text,timestamptz,integer)') is not null
     or to_regprocedure('public.people_you_met(timestamptz,integer)') is not null then
    raise exception 'FAIL 1 an old paging signature remains';
  end if;
  if position('chat_client:' in (select prosrc from pg_proc where oid = 'public.send_message(uuid,uuid,text,text)'::regprocedure)) = 0 then
    raise exception 'FAIL 1 send_message does not lock the client id';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- a, b: share plan e1 (b hosts it). c, d: strangers. x: on nothing.
  -- u: signed up, never onboarded. m1 to m4: checked in with a at e2.
  v_names text[] := array['a', 'b', 'c', 'd', 'x', 'u', 'm1', 'm2', 'm3', 'm4'];
  v_id    uuid;
  v_hub   uuid;
  v_area  uuid := (select id from public.areas where slug = 'atlanta');
  v_e     uuid;
  v_g     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  if public.project_url() is null then
    raise exception 'FAIL setup: meta.project_url is not set';
  end if;
  if v_area is null then
    raise exception 'FAIL setup: no atlanta area';
  end if;
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'msgfix-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    if v_names[i] <> 'u' then
      update public.profile_private set birth_date = date '1994-04-04' where user_id = v_id;
      update public.profiles
         set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
             created_at = now() - interval '3 days',
             avatar_url = public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg'
       where id = v_id;
    end if;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  update public.profile_private set home_area_id = v_area where user_id = pg_temp.uid('b');

  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;

  -- e1: a plan b hosts and a is going to (shared context; no point, so
  -- feed_event_area places it at b's home area).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point, location_hint)
  values (v_hub, pg_temp.uid('b'), 'Review fixes plan', now() + interval '2 days', now() + interval '2 days 2 hours',
          null, 'The park')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, pg_temp.uid('a'), 'going');

  -- e2: a and m1 to m4 checked in (people_you_met, all with the same starts_at).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, pg_temp.uid('b'), 'Review fixes check-in plan', now() + interval '3 days',
          now() + interval '3 days 2 hours', 'The hall')
  returning id into v_e;
  insert into public.rsvps (event_id, user_id, status, checked_in_at)
  select v_e, u, 'going', now()
    from unnest(array[pg_temp.uid('a'), pg_temp.uid('m1'), pg_temp.uid('m2'), pg_temp.uid('m3'), pg_temp.uid('m4')]) u;

  -- 105 groups b owns with a in them, each with one unread message, all at now().
  for i in 1..105 loop
    insert into public.conversations (kind, title, created_by) values ('group', 'Paging test', pg_temp.uid('b'))
    returning id into v_g;
    insert into public.conversation_members (conversation_id, user_id, role)
    values (v_g, pg_temp.uid('b'), 'owner'), (v_g, pg_temp.uid('a'), 'member');
    insert into public.messages (conversation_id, seq, author_id, kind, body) values (v_g, 1, pg_temp.uid('b'), 'text', 'Hi');
    update public.conversations set last_seq = 1, last_message_at = now() where id = v_g;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 2 to 5. Links, leaving a request, member columns, typing
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v    jsonb;
  v_rq uuid;
  v_dm uuid;
begin
  -- 2. A request: the dash and dot forms of www. are links.
  perform pg_temp.act('a');
  v := public.start_dm(pg_temp.uid('c'));
  if v ->> 'state' <> 'request' then raise exception 'FAIL 2 no request to a stranger'; end if;
  v_rq := (v ->> 'conversation_id')::uuid;
  perform set_config('test.rq_ac', v_rq::text, true);
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_rq, 'hey -www.paypa1-login.dev')) <> 'link_not_allowed'
     or pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_rq, '.www.evil.dev')) <> 'link_not_allowed' then
    raise exception 'FAIL 2 a hidden www. link was allowed in a request';
  end if;
  v := public.send_message(v_rq, gen_random_uuid(), 'Hi, I saw your post about the climbing gym');
  if v ->> 'id' is null then raise exception 'FAIL 2 the request message was refused'; end if;

  -- 3. Leave the pending request, then tap Message again: readable.
  perform public.leave_conversation(v_rq);
  if pg_temp.err(format('select * from public.get_messages(%L)', v_rq)) <> 'not_found' then
    raise exception 'FAIL 3 setup: leaving did not hide the request';
  end if;
  v := public.start_dm(pg_temp.uid('c'));
  if v ->> 'state' <> 'request_pending' or (v ->> 'conversation_id')::uuid <> v_rq then
    raise exception 'FAIL 3 start_dm did not return the pending request';
  end if;
  if pg_temp.err(format('select * from public.get_messages(%L)', v_rq)) <> 'ok'
     or (select count(*) from public.get_messages(v_rq)) <> 1
     or pg_temp.err(format('select public.conversation_info(%L)', v_rq)) <> 'ok' then
    raise exception 'FAIL 3 the requester cannot read the request after coming back';
  end if;
  if pg_temp.err(format('select public.send_message(%L, gen_random_uuid(), %L)', v_rq, 'Hello?')) <> 'request_pending' then
    raise exception 'FAIL 3 coming back allowed a second request message';
  end if;

  -- 4. The DM with b: b's row is visible, b's settings are not.
  v := public.start_dm(pg_temp.uid('b'));
  if v ->> 'state' <> 'open' then raise exception 'FAIL 4 the shared-plan DM did not open'; end if;
  v_dm := (v ->> 'conversation_id')::uuid;
  perform set_config('test.dm_ab', v_dm::text, true);
  perform pg_temp.act('b');
  perform public.mute_conversation(v_dm, 'infinity');
  perform pg_temp.act('a');
  if (select count(*) from public.conversation_members where conversation_id = v_dm) <> 2
     or (select role::text from public.conversation_members
          where conversation_id = v_dm and user_id = pg_temp.uid('b')) <> 'member' then
    raise exception 'FAIL 4 a member cannot read the other member row';
  end if;
  if pg_temp.err(format('select muted_until from public.conversation_members where conversation_id = %L', v_dm)) = 'ok'
     or pg_temp.err(format('select notify from public.conversation_members where conversation_id = %L', v_dm)) = 'ok'
     or pg_temp.err(format('select last_read_at from public.conversation_members where conversation_id = %L', v_dm)) = 'ok'
     or pg_temp.err(format('select * from public.conversation_members where conversation_id = %L', v_dm)) = 'ok' then
    raise exception 'FAIL 4 a member reads the other member''s mute or read state';
  end if;
  perform pg_temp.act('b');
  if (public.conversation_info(v_dm) ->> 'muted_until') is null then
    raise exception 'FAIL 4 the owner of a mute cannot read it';
  end if;

  -- 5. Typing.
  perform pg_temp.act('a');
  perform public.chat_typing(v_dm);
  perform pg_temp.act('x');
  if pg_temp.err(format('select public.chat_typing(%L)', v_dm)) <> 'ok' then
    raise exception 'FAIL 5 chat_typing raised for someone outside the room';
  end if;
  perform pg_temp.act('b');
  perform set_config('realtime.topic', 'conv:' || v_dm, true);
  if not exists (select 1 from realtime.messages
                  where topic = 'conv:' || v_dm and event = 'typing' and payload ->> 'user_id' = current_setting('test.a')) then
    raise exception 'FAIL 5 chat_typing did not send for the caller';
  end if;
  if exists (select 1 from realtime.messages
              where topic = 'conv:' || v_dm and event = 'typing'
                and payload ->> 'user_id' is distinct from current_setting('test.a')) then
    raise exception 'FAIL 5 a typing signal names someone who did not type';
  end if;
  if pg_temp.err(format($q$insert into realtime.messages (topic, extension, event, payload, private)
                          values (%L, 'broadcast', 'typing', %L, true)$q$,
                        'conv:' || v_dm, json_build_object('user_id', current_setting('test.a'))::text)) = 'ok' then
    raise exception 'FAIL 5 a member sent a typing signal directly';
  end if;
  perform set_config('realtime.topic', '', true);
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 6. A new request after a decline is notified again
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v    jsonb;
  v_rq uuid;
begin
  perform pg_temp.act('a');
  v := public.start_dm(pg_temp.uid('d'));
  if v ->> 'state' <> 'request' then raise exception 'FAIL 6 no request to d'; end if;
  v_rq := (v ->> 'conversation_id')::uuid;
  perform set_config('test.rq_ad', v_rq::text, true);
  perform public.send_message(v_rq, gen_random_uuid(), 'Hi, are you going to the run club?');
  perform pg_temp.act('d');
  perform public.respond_message_request(v_rq, 'decline');
end $$;
reset role;
-- 40 days pass (now() is fixed in a transaction, so the rows move back instead).
update public.message_requests set created_at = now() - interval '40 days', decided_at = now() - interval '31 days'
 where conversation_id = current_setting('test.rq_ad')::uuid;
update public.messages set created_at = created_at - interval '40 days'
 where conversation_id = current_setting('test.rq_ad')::uuid;
update public.notifications
   set created_at = created_at - interval '40 days',
       dedupe_key = 'message_request:' || current_setting('test.rq_ad') || ':' || current_setting('test.d') || ':'
                    || floor(extract(epoch from now() - interval '40 days'))::bigint::text
 where user_id = pg_temp.uid('d') and kind = 'message_request'
   and payload ->> 'conversation_id' = current_setting('test.rq_ad');
set local role authenticated;
do $$
declare
  v    jsonb;
  v_rq uuid := current_setting('test.rq_ad')::uuid;
begin
  perform pg_temp.act('a');
  v := public.start_dm(pg_temp.uid('d'));
  if v ->> 'state' <> 'request' then raise exception 'FAIL 6 a new request after the cooldown was refused'; end if;
  v := public.send_message(v_rq, gen_random_uuid(), 'Hi again, the run club meets Saturdays');
  if v ->> 'id' is null then raise exception 'FAIL 6 the second request message was refused'; end if;
end $$;
reset role;
do $$
begin
  if (select count(*) from public.notifications n
       where n.user_id = pg_temp.uid('d') and n.kind = 'message_request'
         and n.payload ->> 'conversation_id' = current_setting('test.rq_ad')) <> 2 then
    raise exception 'FAIL 6 the second request was not notified';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7 to 10. Retries, paging, the badge, feed_event_area
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v       jsonb;
  v2      jsonb;
  v_cid   uuid := gen_random_uuid();
  v_ids   uuid[] := '{}';
  v_page  uuid[];
  v_at    timestamptz;
  v_last  uuid;
  v_n     integer := 0;
  v_users uuid[] := '{}';
  v_upage uuid[];
  v_st    timestamptz;
  v_lu    uuid;
begin
  -- 7. The same client id twice: one row.
  perform pg_temp.act('a');
  v := public.send_message(current_setting('test.dm_ab')::uuid, v_cid, 'On my way');
  v2 := public.send_message(current_setting('test.dm_ab')::uuid, v_cid, 'On my way');
  if (v2 ->> 'duplicate')::boolean is not true or v2 ->> 'id' <> v ->> 'id' then
    raise exception 'FAIL 7 a retried client id did not return the stored row';
  end if;

  -- 8. chat_list in pages of 10.
  loop
    select array_agg(l.conversation_id order by l.activity_at desc, l.conversation_id),
           -- The last row held: the oldest time, and the highest id at that time.
           (array_agg(l.activity_at order by l.activity_at, l.conversation_id desc))[1],
           (array_agg(l.conversation_id order by l.activity_at, l.conversation_id desc))[1]
      into v_page, v_at, v_last
      from (select * from public.chat_list('chats', v_at, 10, v_last)) l;
    exit when v_page is null;
    v_ids := v_ids || v_page;
    v_n := v_n + 1;
    exit when cardinality(v_page) < 10 or v_n > 30;
  end loop;
  if (select count(distinct i) from unnest(v_ids) i) <> cardinality(v_ids) then
    raise exception 'FAIL 8 chat_list repeated a chat across pages';
  end if;
  perform set_config('test.paged', array_to_string(v_ids, ','), true);
  if ((public.chat_unread_total()) ->> 'chats')::integer < 105 then
    raise exception 'FAIL 8 the badge stops at the newest 100 chats';
  end if;

  -- 9. people_you_met in pages of 1.
  v_n := 0;
  loop
    select array_agg(m.user_id), max(m.user_id::text)::uuid, max((m.last_plan ->> 'starts_at')::timestamptz)
      into v_upage, v_lu, v_st
      from public.people_you_met(v_st, 1, v_lu) m;
    exit when v_upage is null;
    v_users := v_users || v_upage;
    v_n := v_n + 1;
    exit when v_n > 20;
  end loop;
  if (select count(distinct u) from unnest(v_users) u) <> cardinality(v_users)
     or not (array[pg_temp.uid('m1'), pg_temp.uid('m2'), pg_temp.uid('m3'), pg_temp.uid('m4')] <@ v_users) then
    raise exception 'FAIL 9 people_you_met skipped or repeated people from one plan';
  end if;

  -- 10. feed_event_area: an onboarded adult gets the area, an account that has not onboarded gets nothing.
  if public.feed_event_area(current_setting('test.e1')::uuid) is null then
    raise exception 'FAIL 10 setup: no area for the plan';
  end if;
  perform pg_temp.act('u');
  if public.feed_event_area(current_setting('test.e1')::uuid) is not null then
    raise exception 'FAIL 10 an account that has not onboarded got a plan''s area';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.conversations c
              where c.kind = 'group' and c.title = 'Paging test' and c.created_by = pg_temp.uid('b')
                and c.id <> all (string_to_array(current_setting('test.paged'), ',')::uuid[])) then
    raise exception 'FAIL 8 chat_list skipped chats with the same activity time';
  end if;
end $$;

select 'PASS' as messaging_review_fixes;
rollback;
