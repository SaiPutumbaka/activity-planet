-- ============================================================================
-- Staging check for migration 20270105000100_chat_image_evidence_fixes.sql
-- (migration 73, review fixes for chat photo evidence and the classifier
-- cap). One transaction: throwaway accounts, a group, image messages and
-- Storage object rows inserted as the migration owner (no bytes), DO blocks
-- that raise on failure, then ROLLBACK. Nothing reaches image-guard. Prints
-- pass/fail only.
--
--   1 static: schema_version 2.69 or later; chat_image_evidence_list_for is
--     service role only; the two-argument settle is gone; the evidence read
--     policy goes through chat_evidence_readable.
--   2 missing: a null path marks a copy handled; it is not listed again and
--     the original of a deleted message is then let go.
--   3 one account: chat_image_evidence_list_for lists that account's
--     pending copies only.
--   4 blocked: a blocked chat photo is not deleted while its copy is pending.
--   5 read policy: a moderator sees a chat-evidence object only after
--     opening its report through mod_message_evidence; a member never.
--   6 settle: the reservation's month is returned and settled.
-- ============================================================================
begin;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
-- A storage row (no bytes) and a message by p_author for it.
create function pg_temp.photo(p_author text, p_seq bigint, p_state text) returns text language plpgsql as $$
declare
  v_path text := current_setting('test.' || p_author) || '/' || current_setting('test.g') || '/' || gen_random_uuid() || '.jpg';
begin
  insert into storage.objects (bucket_id, name) values ('chat-images', v_path);
  insert into public.messages (conversation_id, seq, author_id, kind, body, image_path, image_state)
  values (pg_temp.uid('g'), p_seq, pg_temp.uid(p_author), 'image', '', v_path, p_state);
  return v_path;
end $$;
-- A report by c on the message with that photo, with its evidence row. Returns the report id.
create function pg_temp.report(p_path text) returns uuid language plpgsql as $$
declare
  v_r uuid;
  v_m uuid;
  v_a uuid;
begin
  select m.id, m.author_id into v_m, v_a from public.messages m where m.image_path = p_path;
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
  values (pg_temp.uid('c'), 'message', v_m, v_a, 'harassment', 'test')
  returning id into v_r;
  insert into public.message_report_evidence (report_id, message_id, conversation_id, conversation_kind, author_id, body, context)
  values (v_r, v_m, pg_temp.uid('g'), 'group', v_a, '', '[]'::jsonb);
  return v_r;
end $$;
create function pg_temp.in_list(p_list jsonb, p_report uuid) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(p_list) e where (e ->> 'report_id')::uuid = p_report);
$$;
create function pg_temp.purge_has(p_path text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.chat_image_purge_list(200)) e
                  where e ->> 'bucket' = 'chat-images' and e ->> 'path' = p_path);
$$;
create function pg_temp.guard_purge_has(p_path text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.image_guard_purge_list(200)) e
                  where e ->> 'bucket' = 'chat-images' and e ->> 'path' = p_path);
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 69] then
    raise exception 'FAIL 1 schema_version is older than 2.69';
  end if;
  if has_function_privilege('authenticated', 'public.chat_image_evidence_list_for(uuid)', 'execute')
     or has_function_privilege('anon', 'public.chat_image_evidence_list_for(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.chat_image_evidence_list_for(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_classifier_settle(integer,integer,date)', 'execute')
     or not has_function_privilege('service_role', 'public.chat_classifier_settle(integer,integer,date)', 'execute')
     or has_function_privilege('anon', 'private.chat_evidence_readable(text)', 'execute') then
    raise exception 'FAIL 1 grants';
  end if;
  if to_regprocedure('public.chat_classifier_settle(integer,integer)') is not null then
    raise exception 'FAIL 1 the two-argument chat_classifier_settle is still there';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                                             and policyname = 'chat_evidence_select_mod'
                                             and qual like '%chat_evidence_readable%') then
    raise exception 'FAIL 1 chat_evidence_select_mod does not go through chat_evidence_readable';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['a', 'b', 'c', 'm'];
  v_id    uuid;
  v_g     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'cif-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('m'), 'moderator');
  insert into public.conversations (kind, title, created_by) values ('group', 'Evidence fixes test', pg_temp.uid('a'))
  returning id into v_g;
  insert into public.conversation_members (conversation_id, user_id, role)
  values (v_g, pg_temp.uid('a'), 'owner'), (v_g, pg_temp.uid('b'), 'member'), (v_g, pg_temp.uid('c'), 'member');
  perform set_config('test.g', v_g::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. A missing original is recorded
-- ---------------------------------------------------------------------------
do $$
declare
  v_p text;
  v_r uuid;
begin
  v_p := pg_temp.photo('a', 1, 'removed');
  v_r := pg_temp.report(v_p);
  if not pg_temp.in_list(public.chat_image_evidence_list(100), v_r) or pg_temp.purge_has(v_p) then
    raise exception 'FAIL 2 setup: the copy is not pending';
  end if;
  if not public.chat_image_evidence_saved(v_r, null) then
    raise exception 'FAIL 2 a missing original was not recorded';
  end if;
  if public.chat_image_evidence_saved(v_r, null) then
    raise exception 'FAIL 2 a missing original was recorded twice';
  end if;
  if pg_temp.in_list(public.chat_image_evidence_list(100), v_r)
     or pg_temp.in_list(public.chat_image_evidence_list_for(pg_temp.uid('a')), v_r) then
    raise exception 'FAIL 2 a copy marked missing is still listed';
  end if;
  if not pg_temp.purge_has(v_p) then
    raise exception 'FAIL 2 a deleted message''s photo marked missing is kept';
  end if;
  if public.chat_image_evidence_saved(null, null) or public.chat_image_evidence_saved(v_r, 'other.jpg') then
    raise exception 'FAIL 2 a bad call was recorded';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. One account's pending copies
-- ---------------------------------------------------------------------------
do $$
declare
  v_ra uuid;
  v_rb uuid;
  v_la jsonb;
begin
  v_ra := pg_temp.report(pg_temp.photo('a', 2, 'visible'));
  v_rb := pg_temp.report(pg_temp.photo('b', 3, 'visible'));
  v_la := public.chat_image_evidence_list_for(pg_temp.uid('a'));
  if not pg_temp.in_list(v_la, v_ra) or pg_temp.in_list(v_la, v_rb)
     or exists (select 1 from jsonb_array_elements(v_la) e
                 where left(e ->> 'path', 37) <> current_setting('test.a') || '/') then
    raise exception 'FAIL 3 the account''s list is wrong';
  end if;
  if pg_temp.in_list(public.chat_image_evidence_list_for(pg_temp.uid('b')), v_ra)
     or jsonb_array_length(public.chat_image_evidence_list_for(null)) <> 0 then
    raise exception 'FAIL 3 another account''s copies were listed';
  end if;
  perform public.chat_image_evidence_saved(v_ra, v_ra::text || '.jpg');
  if pg_temp.in_list(public.chat_image_evidence_list_for(pg_temp.uid('a')), v_ra) then
    raise exception 'FAIL 3 a made copy is still listed';
  end if;
  perform set_config('test.ra', v_ra::text, true);
  perform set_config('test.rb', v_rb::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 4. A blocked chat photo waits for its copy
-- ---------------------------------------------------------------------------
do $$
declare
  v_p text;
  v_r uuid;
begin
  v_p := pg_temp.photo('a', 4, 'blocked');
  v_r := pg_temp.report(v_p);
  update public.image_hashes set status = 'blocked', blocked_at = now(), purged_at = null
   where bucket = 'chat-images' and path = v_p;
  if not found then
    insert into public.image_hashes (bucket, path, owner_id, status, blocked_at)
    values ('chat-images', v_p, pg_temp.uid('a'), 'blocked', now());
  end if;
  if pg_temp.guard_purge_has(v_p) then
    raise exception 'FAIL 4 a blocked photo would be deleted before its evidence copy';
  end if;
  perform public.chat_image_evidence_saved(v_r, v_r::text || '.jpg');
  if not pg_temp.guard_purge_has(v_p) then
    raise exception 'FAIL 4 a blocked photo was kept after its copy';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Evidence is read through the logged path only
-- ---------------------------------------------------------------------------
do $$
begin
  perform public.chat_image_evidence_saved(pg_temp.uid('rb'), current_setting('test.rb') || '.jpg');
  insert into storage.objects (bucket_id, name)
  values ('chat-evidence', current_setting('test.ra') || '.jpg'),
         ('chat-evidence', current_setting('test.rb') || '.jpg');
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.act('m');
  if exists (select 1 from storage.objects where bucket_id = 'chat-evidence'
                                            and name in (current_setting('test.ra') || '.jpg',
                                                         current_setting('test.rb') || '.jpg')) then
    raise exception 'FAIL 5 a moderator could list evidence without opening its report';
  end if;
  perform public.mod_message_evidence(pg_temp.uid('ra'));
  if not exists (select 1 from storage.objects where bucket_id = 'chat-evidence'
                                                and name = current_setting('test.ra') || '.jpg') then
    raise exception 'FAIL 5 a moderator could not read the evidence of a report they opened';
  end if;
  if exists (select 1 from storage.objects where bucket_id = 'chat-evidence'
                                            and name = current_setting('test.rb') || '.jpg') then
    raise exception 'FAIL 5 a moderator could read the evidence of a report they did not open';
  end if;
  perform pg_temp.act('b');
  if exists (select 1 from storage.objects where bucket_id = 'chat-evidence') then
    raise exception 'FAIL 5 a member could read chat evidence';
  end if;
end $$;
reset role;

do $$
begin
  if not exists (select 1 from public.admin_lookups l
                  where l.moderator_id = pg_temp.uid('m') and l.report_id = pg_temp.uid('ra') and l.via = 'open') then
    raise exception 'FAIL 5 opening the evidence was not logged with its report';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Settle in the reservation's month
-- ---------------------------------------------------------------------------
do $$
declare
  v_month date := date_trunc('month', now() at time zone 'utc')::date;
  v_prev  date := (date_trunc('month', now() at time zone 'utc') - interval '1 month')::date;
  v_p     text;
  v       jsonb;
  v_now   integer;
begin
  v_p := current_setting('test.a') || '/' || current_setting('test.g') || '/' || gen_random_uuid() || '.jpg';
  insert into public.messages (conversation_id, seq, author_id, kind, body, image_path, image_state)
  values (pg_temp.uid('g'), 5, pg_temp.uid('a'), 'image', '', v_p, 'pending');
  update public.image_hashes set status = 'hashed', checked_at = now(),
         sha256 = encode(sha256(convert_to(v_p, 'utf8')), 'hex'), phash = 1, dhash = 2
   where bucket = 'chat-images' and path = v_p;
  insert into public.meta (key, value) values ('chat_classifier_monthly_cap', '100000')
    on conflict (key) do update set value = excluded.value;
  v := public.chat_classifier_reserve(v_p, 4);
  if not (v ->> 'allowed')::boolean or (v ->> 'month')::date <> v_month then
    raise exception 'FAIL 6 the reservation did not return its month';
  end if;
  insert into public.collector_budget (day, source, used) values (v_prev, 'sightengine_ops', 10)
    on conflict (day, source) do update set used = 10;
  select b.used into v_now from public.collector_budget b where b.day = v_month and b.source = 'sightengine_ops';
  if public.chat_classifier_settle(4, 0, v_prev) <> 6
     or (select b.used from public.collector_budget b where b.day = v_month and b.source = 'sightengine_ops') <> v_now then
    raise exception 'FAIL 6 settle did not correct the reservation''s month';
  end if;
  if public.chat_classifier_settle(4, 0, null) <> greatest(0, v_now - 4) then
    raise exception 'FAIL 6 settle without a month did not use this month';
  end if;
end $$;

select 'chat_image_evidence_fixes: all checks passed' as result;
rollback;
