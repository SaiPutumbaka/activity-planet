-- ============================================================================
-- Staging check for migration 20270103000100_chat_image_classifier.sql
-- (migration 71, the chat-image classifier step). One transaction: throwaway
-- accounts, a group, image messages inserted as the migration owner (no
-- Storage bytes are needed: the classifier itself is mocked in the Deno
-- tests), DO blocks that raise on failure, then ROLLBACK. Nothing reaches
-- image-guard (pg_net sends only after a commit). Prints pass/fail only.
--
--   1 static: schema_version 2.67 or later; chat images still off; the
--     classifier RPCs are service role only; the moderator RPCs are not for
--     anon; the moderator storage policy exists.
--   2 reserve: nothing waits until the pHash check passes; then operations
--     are reserved under the monthly cap, refused past it and settled back.
--   3 verdicts: visible only after a passed pHash check and once; queued
--     files one automatic report with the category and the reason; blocked
--     queues the object for deletion and logs numbers only.
--   4 moderators: the queue lists a queued photo; allow shows it and
--     dismisses only the automatic report; block hides it for good; a
--     member is refused; a decided photo is item_not_pending; moderators
--     may read only queued photos.
--   5 tick: a chat image left classifying over an hour is queued for a
--     moderator.
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
-- A chat image message by a in the test group, its object at a fresh path.
create function pg_temp.image_message(p_seq bigint, p_age interval default '0 minutes')
returns text language plpgsql as $$
declare
  v_path text := current_setting('test.a') || '/' || current_setting('test.g') || '/' || gen_random_uuid() || '.jpg';
begin
  insert into public.messages (conversation_id, seq, author_id, kind, body, image_path, image_state, created_at)
  values (pg_temp.uid('g'), p_seq, pg_temp.uid('a'), 'image', '', v_path, 'pending', now() - p_age);
  return v_path;
end $$;
-- Marks the object's pHash check passed (as image_guard_record would).
create function pg_temp.hashed(p_path text) returns void language sql as $$
  update public.image_hashes
     set status = 'hashed', checked_at = now(), sha256 = encode(sha256(convert_to(p_path, 'utf8')), 'hex'),
         phash = 1, dhash = 2
   where bucket = 'chat-images' and path = p_path;
$$;
create function pg_temp.state(p_path text) returns text language sql stable as $$
  select m.image_state from public.messages m where m.image_path = p_path;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 67] then
    raise exception 'FAIL 1 schema_version is older than 2.67';
  end if;
  if (select value from public.meta where key = 'chat_images') is distinct from 'off' then
    raise exception 'FAIL 1 chat images are not off';
  end if;
  if has_function_privilege('authenticated', 'public.chat_classifier_reserve(text,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_classifier_settle(integer,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_image_classified(text,text,text,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.image_guard_tick()', 'execute')
     or not has_function_privilege('service_role', 'public.chat_classifier_reserve(text,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.chat_classifier_settle(integer,integer)', 'execute') then
    raise exception 'FAIL 1 classifier RPC grants';
  end if;
  if has_function_privilege('anon', 'public.mod_chat_image(uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'public.mod_chat_image_queue(integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_chat_image(uuid,text,text)', 'execute') then
    raise exception 'FAIL 1 moderator RPC grants';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                                             and policyname = 'chat_images_select_mod') then
    raise exception 'FAIL 1 chat_images_select_mod policy missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['a', 'b', 'm'];
  v_id    uuid;
  v_g     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'cic-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('m'), 'moderator');
  insert into public.conversations (kind, title, created_by) values ('group', 'Classifier test', pg_temp.uid('a'))
  returning id into v_g;
  insert into public.conversation_members (conversation_id, user_id, role)
  values (v_g, pg_temp.uid('a'), 'owner'), (v_g, pg_temp.uid('b'), 'member');
  perform set_config('test.g', v_g::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Reserve and settle
-- ---------------------------------------------------------------------------
do $$
declare
  v_p     text;
  v       jsonb;
  v_month date := date_trunc('month', now() at time zone 'utc')::date;
  v_used  integer;
begin
  v_p := pg_temp.image_message(1);
  if pg_temp.state(v_p) <> 'pending'
     or not exists (select 1 from public.image_hashes h where h.bucket = 'chat-images' and h.path = v_p and h.status = 'pending') then
    raise exception 'FAIL 2 a new chat image did not wait for its pHash check';
  end if;
  v := public.chat_classifier_reserve(v_p, 4);
  if (v ->> 'pending')::boolean then
    raise exception 'FAIL 2 an image whose pHash check has not passed was offered to the classifier';
  end if;
  perform pg_temp.hashed(v_p);
  if pg_temp.state(v_p) <> 'classifying' then
    raise exception 'FAIL 2 a passed pHash check did not move the image to classifying';
  end if;
  update public.meta set value = '100000' where key = 'chat_classifier_monthly_cap';
  select coalesce((select b.used from public.collector_budget b where b.day = v_month and b.source = 'sightengine_ops'), 0)
    into v_used;
  v := public.chat_classifier_reserve(v_p, 4);
  if not (v ->> 'pending')::boolean or not (v ->> 'allowed')::boolean or (v ->> 'used')::int <> v_used + 4 then
    raise exception 'FAIL 2 operations were not reserved under the cap';
  end if;
  -- At the cap: refused, nothing counted.
  update public.meta set value = (v_used + 6)::text where key = 'chat_classifier_monthly_cap';
  v := public.chat_classifier_reserve(v_p, 4);
  if (v ->> 'allowed')::boolean or (select b.used from public.collector_budget b
                                     where b.day = v_month and b.source = 'sightengine_ops') <> v_used + 4 then
    raise exception 'FAIL 2 a reservation past the monthly cap was allowed';
  end if;
  -- Settle: Sightengine counted nothing (a failed call).
  if public.chat_classifier_settle(4, 0) <> v_used then
    raise exception 'FAIL 2 settle did not give the operations back';
  end if;
  perform set_config('test.p1', v_p, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Verdicts
-- ---------------------------------------------------------------------------
do $$
declare
  v_p1 text := current_setting('test.p1');
  v_p2 text;
  v_p3 text;
  v_p0 text;
  v_n  integer;
  v_snap jsonb;
begin
  -- No pass before the pHash check.
  v_p0 := pg_temp.image_message(2);
  if public.chat_image_classified('chat-images', v_p0, 'visible', '{}'::jsonb) <> 0 or pg_temp.state(v_p0) <> 'pending' then
    raise exception 'FAIL 3 an image was shown before its pHash check passed';
  end if;
  -- Visible once.
  if public.chat_image_classified('chat-images', v_p1, 'visible', '{"reason": "classified"}'::jsonb) <> 1
     or pg_temp.state(v_p1) <> 'visible' then
    raise exception 'FAIL 3 a passed image did not become visible';
  end if;
  if public.chat_image_classified('chat-images', v_p1, 'blocked', '{}'::jsonb) <> 0 or pg_temp.state(v_p1) <> 'visible' then
    raise exception 'FAIL 3 a repeated verdict changed a decided image';
  end if;
  -- Queued: one automatic report, category and reason kept; a repeat files nothing.
  v_p2 := pg_temp.image_message(3);
  perform pg_temp.hashed(v_p2);
  perform public.chat_image_classified('chat-images', v_p2, 'queued', '{"reason": "cap", "category": "hate"}'::jsonb);
  perform public.chat_image_classified('chat-images', v_p2, 'queued', '{"reason": "cap", "category": "hate"}'::jsonb);
  select count(*) into v_n from public.reports r join public.messages m on m.id = r.target_id
   where r.target_kind = 'message' and m.image_path = v_p2 and r.reporter_id is null and r.status = 'open'
     and r.reason = 'hate' and r.note like '%allowance%';
  if pg_temp.state(v_p2) <> 'queued' or v_n <> 1 then
    raise exception 'FAIL 3 a queued image did not file exactly one automatic report (%)', v_n;
  end if;
  perform set_config('test.p2', v_p2, true);
  -- Blocked: queued for deletion, logged with numbers only.
  v_p3 := pg_temp.image_message(4);
  perform pg_temp.hashed(v_p3);
  perform public.chat_image_classified('chat-images', v_p3, 'blocked',
                                       '{"reason": "classified", "category": "sexual_content", "sexual": 0.97, "gore": 0.01, "note": "x"}'::jsonb);
  if pg_temp.state(v_p3) <> 'blocked'
     or not exists (select 1 from public.image_hashes h where h.bucket = 'chat-images' and h.path = v_p3
                                                         and h.status = 'blocked' and h.purged_at is null)
     or not exists (select 1 from public.image_guard_purge_list(200) l(x), jsonb_array_elements(l.x) e
                     where e ->> 'path' = v_p3) then
    raise exception 'FAIL 3 a blocked image was not queued for deletion';
  end if;
  select a.snapshot into v_snap from public.moderation_actions a
    join public.image_hashes h on h.id = a.target_id
   where h.path = v_p3 and a.action = 'image_remove' and a.target_kind = 'image';
  if v_snap is null or v_snap ? 'note' or (v_snap ->> 'sexual')::numeric <> 0.97 then
    raise exception 'FAIL 3 the block was not logged with numeric scores only';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Moderators
-- ---------------------------------------------------------------------------
do $$
declare
  v_p4 text;
begin
  v_p4 := pg_temp.image_message(5);
  perform pg_temp.hashed(v_p4);
  perform public.chat_image_classified('chat-images', v_p4, 'queued', '{"reason": "classified", "category": "violence"}'::jsonb);
  -- A person's report on the queued photo too (b reports it).
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
  select pg_temp.uid('b'), 'message', m.id, m.author_id, 'harassment', 'test'
    from public.messages m where m.image_path = current_setting('test.p2');
  perform set_config('test.p4', v_p4, true);
  perform set_config('test.m2', (select m.id::text from public.messages m where m.image_path = current_setting('test.p2')), true);
  perform set_config('test.m4', (select m.id::text from public.messages m where m.image_path = v_p4), true);
end $$;

set local role authenticated;
do $$
declare
  v_q   jsonb;
  v_m2  uuid := current_setting('test.m2')::uuid;
  v_m4  uuid := current_setting('test.m4')::uuid;
  v     jsonb;
begin

  perform pg_temp.act('b');
  if pg_temp.err(format('select public.mod_chat_image(%L, %L)', v_m2, 'allow')) <> 'forbidden'
     or pg_temp.err('select public.mod_chat_image_queue()') <> 'forbidden' then
    raise exception 'FAIL 4 a member could decide chat photos';
  end if;
  if private.chat_image_moderatable(current_setting('test.p2')) then
    raise exception 'FAIL 4 a member may read a queued photo';
  end if;

  perform pg_temp.act('m');
  v_q := public.mod_chat_image_queue(200);
  if not exists (select 1 from jsonb_array_elements(v_q) e where (e ->> 'message_id')::uuid = v_m2)
     or not exists (select 1 from jsonb_array_elements(v_q) e where (e ->> 'message_id')::uuid = v_m4
                                                              and e ->> 'reason' = 'violence') then
    raise exception 'FAIL 4 the moderator queue misses a queued photo';
  end if;
  if not private.chat_image_moderatable(current_setting('test.p2'))
     or private.chat_image_moderatable(current_setting('test.p1')) then
    raise exception 'FAIL 4 moderators may read the wrong chat photos';
  end if;

  v := public.mod_chat_image(v_m2, 'allow', null);
  if v ->> 'state' <> 'visible' then
    raise exception 'FAIL 4 allow did not show the photo';
  end if;
  v := public.mod_chat_image(v_m4, 'block', 'test');
  if v ->> 'state' <> 'blocked' then
    raise exception 'FAIL 4 block did not block the photo';
  end if;
  if pg_temp.err(format('select public.mod_chat_image(%L, %L)', v_m2, 'block')) <> 'item_not_pending' then
    raise exception 'FAIL 4 a decided photo was decided again';
  end if;
  if pg_temp.err(format('select public.mod_chat_image(%L, %L)', gen_random_uuid(), 'allow')) <> 'target_not_found' then
    raise exception 'FAIL 4 an unknown message was not target_not_found';
  end if;
end $$;
reset role;

do $$
begin
  if pg_temp.state(current_setting('test.p2')) <> 'visible' or pg_temp.state(current_setting('test.p4')) <> 'blocked' then
    raise exception 'FAIL 4 decided states';
  end if;
  -- Allow dismissed the automatic report and kept b's report open.
  if exists (select 1 from public.reports r join public.messages m on m.id = r.target_id
              where m.image_path = current_setting('test.p2') and r.reporter_id is null and r.status = 'open')
     or not exists (select 1 from public.reports r join public.messages m on m.id = r.target_id
                     where m.image_path = current_setting('test.p2') and r.reporter_id = pg_temp.uid('b')
                       and r.status = 'open') then
    raise exception 'FAIL 4 allow closed the wrong reports';
  end if;
  if exists (select 1 from public.reports r join public.messages m on m.id = r.target_id
              where m.image_path = current_setting('test.p4') and r.status = 'open')
     or not exists (select 1 from public.image_hashes h where h.path = current_setting('test.p4') and h.status = 'blocked') then
    raise exception 'FAIL 4 block left reports open or the object kept';
  end if;
  if (select count(*) from public.moderation_actions a
       where a.moderator_id = pg_temp.uid('m') and a.target_kind = 'message') <> 2 then
    raise exception 'FAIL 4 the decisions were not logged';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Tick
-- ---------------------------------------------------------------------------
do $$
declare
  v_p5 text;
  v    jsonb;
begin
  v_p5 := pg_temp.image_message(6, '2 hours');
  perform pg_temp.hashed(v_p5);
  if pg_temp.state(v_p5) <> 'classifying' then
    raise exception 'FAIL 5 setup';
  end if;
  v := public.image_guard_tick();
  if pg_temp.state(v_p5) <> 'queued' or (v ->> 'classify_queued')::int < 1
     or not exists (select 1 from public.reports r join public.messages m on m.id = r.target_id
                     where m.image_path = v_p5 and r.reporter_id is null and r.reason = 'other'
                       and r.note like '%did not answer%') then
    raise exception 'FAIL 5 a stuck chat image was not queued for a moderator';
  end if;
end $$;

select 'chat_image_classifier: all checks passed' as result;
rollback;
