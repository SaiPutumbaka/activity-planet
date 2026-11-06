-- ============================================================================
-- Staging check for migration 20270104000100_chat_image_evidence.sql
-- (migration 72, chat photo evidence and storage clean-up). One transaction:
-- throwaway accounts, a group, image messages and Storage object rows
-- inserted as the migration owner (no bytes), DO blocks that raise on
-- failure, then ROLLBACK. Nothing reaches image-guard. Prints pass/fail only.
--
--   1 static: schema_version 2.68 or later; the new RPCs are service role
--     only; moderators' chat-evidence read policy exists.
--   2 evidence: a reported photo is listed for copying until its copy is
--     recorded (only as <report id>.jpg).
--   3 purge: a deleted message's photo is listed, unless a report's copy is
--     pending; an upload never sent is listed after a day, not before; an
--     evidence copy is listed only once its record is gone.
--   4 tick: asks for a sweep when chat storage waits.
-- ============================================================================
begin;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
-- A storage row (no bytes) and, unless p_message is false, a message by a for it.
create function pg_temp.photo(p_seq bigint, p_state text, p_message boolean default true,
                              p_age interval default '0 minutes')
returns text language plpgsql as $$
declare
  v_path text := current_setting('test.a') || '/' || current_setting('test.g') || '/' || gen_random_uuid() || '.jpg';
begin
  insert into storage.objects (bucket_id, name, created_at) values ('chat-images', v_path, now() - p_age);
  if p_message then
    insert into public.messages (conversation_id, seq, author_id, kind, body, image_path, image_state)
    values (pg_temp.uid('g'), p_seq, pg_temp.uid('a'), 'image', '', v_path, p_state);
  end if;
  return v_path;
end $$;
-- A report on the message with that photo, with its evidence row. Returns the report id.
create function pg_temp.report(p_path text) returns uuid language plpgsql as $$
declare
  v_r uuid;
  v_m uuid;
begin
  select m.id into v_m from public.messages m where m.image_path = p_path;
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
  values (pg_temp.uid('b'), 'message', v_m, pg_temp.uid('a'), 'harassment', 'test')
  returning id into v_r;
  insert into public.message_report_evidence (report_id, message_id, conversation_id, conversation_kind, author_id, body, context)
  values (v_r, v_m, pg_temp.uid('g'), 'group', pg_temp.uid('a'), '', '[]'::jsonb);
  return v_r;
end $$;
create function pg_temp.purge_has(p_bucket text, p_path text) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.chat_image_purge_list(200)) e
                  where e ->> 'bucket' = p_bucket and e ->> 'path' = p_path);
$$;
create function pg_temp.evidence_has(p_report uuid) returns boolean language sql as $$
  select exists (select 1 from jsonb_array_elements(public.chat_image_evidence_list(100)) e
                  where (e ->> 'report_id')::uuid = p_report);
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 68] then
    raise exception 'FAIL 1 schema_version is older than 2.68';
  end if;
  if has_function_privilege('authenticated', 'public.chat_image_evidence_list(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_image_evidence_saved(uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_image_purge_list(integer)', 'execute')
     or has_function_privilege('anon', 'public.chat_image_purge_list(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.chat_image_purge_list(integer)', 'execute')
     or not has_function_privilege('service_role', 'public.chat_image_evidence_saved(uuid,text)', 'execute') then
    raise exception 'FAIL 1 grants';
  end if;
  if not exists (select 1 from pg_policies where schemaname = 'storage' and tablename = 'objects'
                                             and policyname = 'chat_evidence_select_mod') then
    raise exception 'FAIL 1 chat_evidence_select_mod policy missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['a', 'b'];
  v_id    uuid;
  v_g     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'cie-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.conversations (kind, title, created_by) values ('group', 'Evidence test', pg_temp.uid('a'))
  returning id into v_g;
  insert into public.conversation_members (conversation_id, user_id, role)
  values (v_g, pg_temp.uid('a'), 'owner'), (v_g, pg_temp.uid('b'), 'member');
  perform set_config('test.g', v_g::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Evidence
-- ---------------------------------------------------------------------------
do $$
declare
  v_p text;
  v_r uuid;
begin
  v_p := pg_temp.photo(1, 'visible');
  v_r := pg_temp.report(v_p);
  if not pg_temp.evidence_has(v_r) then
    raise exception 'FAIL 2 a reported photo was not listed for its evidence copy';
  end if;
  -- (A null path marks the original missing since migration 73; chat_image_evidence_fixes.sql.)
  if public.chat_image_evidence_saved(v_r, 'other.jpg') then
    raise exception 'FAIL 2 a copy under another name was recorded';
  end if;
  if not public.chat_image_evidence_saved(v_r, v_r::text || '.jpg') or pg_temp.evidence_has(v_r) then
    raise exception 'FAIL 2 the evidence copy was not recorded';
  end if;
  perform set_config('test.r1', v_r::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Purge
-- ---------------------------------------------------------------------------
do $$
declare
  v_removed  text;
  v_reported text;
  v_r        uuid;
  v_old      text;
  v_new      text;
  v_visible  text;
begin
  v_removed := pg_temp.photo(2, 'removed');
  v_visible := pg_temp.photo(3, 'visible');
  if not pg_temp.purge_has('chat-images', v_removed) or pg_temp.purge_has('chat-images', v_visible) then
    raise exception 'FAIL 3 a deleted message''s photo was not listed (or a shown one was)';
  end if;
  -- Reported, copy pending: kept until the copy is made.
  v_reported := pg_temp.photo(4, 'removed');
  v_r := pg_temp.report(v_reported);
  if pg_temp.purge_has('chat-images', v_reported) then
    raise exception 'FAIL 3 a reported photo would be deleted before its evidence copy';
  end if;
  perform public.chat_image_evidence_saved(v_r, v_r::text || '.jpg');
  if not pg_temp.purge_has('chat-images', v_reported) then
    raise exception 'FAIL 3 a reported photo was kept after its copy';
  end if;
  -- Never sent: after a day only.
  v_old := pg_temp.photo(0, null, false, '2 days');
  v_new := pg_temp.photo(0, null, false);
  if not pg_temp.purge_has('chat-images', v_old) or pg_temp.purge_has('chat-images', v_new) then
    raise exception 'FAIL 3 unsent uploads';
  end if;
  -- Evidence copies: kept while their record exists.
  insert into storage.objects (bucket_id, name, created_at)
  values ('chat-evidence', current_setting('test.r1') || '.jpg', now() - interval '2 days'),
         ('chat-evidence', gen_random_uuid() || '.jpg', now() - interval '2 days');
  if pg_temp.purge_has('chat-evidence', current_setting('test.r1') || '.jpg')
     or (select count(*) from jsonb_array_elements(public.chat_image_purge_list(200)) e
          where e ->> 'bucket' = 'chat-evidence') < 1 then
    raise exception 'FAIL 3 evidence copies';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Tick
-- ---------------------------------------------------------------------------
do $$
begin
  if not (public.image_guard_tick() ->> 'sweep')::boolean then
    raise exception 'FAIL 4 the tick did not ask for a sweep while chat storage waits';
  end if;
end $$;

select 'chat_image_evidence: all checks passed' as result;
rollback;
