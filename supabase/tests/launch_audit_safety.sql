-- ============================================================================
-- Staging check for migration 20270110000100_launch_audit_safety.sql
-- (migration 78). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never ids or rows
-- (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.74 or later; grants; copyright is a reason.
--   2 Shared context: a fresh chapter join or a fresh RSVP gives none; a day
--     later (or the host's approval) it does; a sensitive hub's chapter never.
--   3 set_rsvp: a moderated plan and a plan in an inactive hub answer
--     event_not_found to a member, not to the host.
--   4 Read paths: a member does not read a plan of an inactive hub or a banned
--     host (table and can_read_event); the host still does.
--   5 Classifier: a sender's sixth photo of the day and a spent daily share are
--     refused, the month's reservation given back.
--   6 export_my_data returns the caller's own document; strikes count upheld
--     copyright reports for moderators only.
-- ============================================================================
begin;

create function pg_temp.member(p_tag text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'las-' || p_tag || '-' || substr(md5(random()::text), 1, 8) || '@example.com', now(), now(), now());
  update public.profile_private set birth_date = date '1990-02-02' where user_id = v_id;
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
         created_at = now() - interval '5 days'
   where id = v_id;
  perform set_config('test.' || p_tag, v_id::text, true);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 74] then
    raise exception 'FAIL 1 schema_version is older than 2.74';
  end if;
  -- Migration 79 replaced event_owner_ok(hub, host) with event_owner_ok(event).
  if not has_function_privilege('anon', 'public.event_owner_ok(uuid)', 'execute')
     or has_function_privilege('anon', 'public.export_my_data()', 'execute')
     or not has_function_privilege('authenticated', 'public.export_my_data()', 'execute')
     or has_function_privilege('anon', 'public.mod_copyright_strikes(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.chat_classifier_reserve(text,integer)', 'execute') then
    raise exception 'FAIL 1 grants';
  end if;
  if pg_get_constraintdef((select oid from pg_constraint where conname = 'reports_reason'
                             and conrelid = 'public.reports'::regclass)) !~ 'copyright' then
    raise exception 'FAIL 1 copyright is not a report reason';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup: a, b members; h host; m moderator. A general hub, a sensitive hub.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hub  uuid;
  v_sens uuid;
  v_ch   uuid;
  v_chs  uuid;
  v_e    uuid;
  v_tag  text := substr(md5(random()::text), 1, 8);
begin
  perform pg_temp.member('a'); perform pg_temp.member('b'); perform pg_temp.member('h'); perform pg_temp.member('m');
  insert into public.user_roles (user_id, role) values (current_setting('test.m')::uuid, 'moderator');
  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and c.is_sensitive order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, (select a.id from public.areas a
                   where not exists (select 1 from public.hub_chapters c where c.hub_id = v_hub and c.area_id = a.id)
                   order by a.id limit 1),
          'las-' || v_tag, 'Launch audit test chapter')
  returning id into v_ch;
  perform set_config('test.ch', v_ch::text, true);
  insert into public.chapter_members (user_id, chapter_id)
  values (current_setting('test.a')::uuid, v_ch), (current_setting('test.b')::uuid, v_ch);
  if v_sens is not null then
    insert into public.hub_chapters (hub_id, area_id, slug, name)
    values (v_sens, (select a.id from public.areas a
                      where not exists (select 1 from public.hub_chapters c where c.hub_id = v_sens and c.area_id = a.id)
                      order by a.id limit 1),
            'las-s-' || v_tag, 'Launch audit sensitive chapter')
    returning id into v_chs;
    perform set_config('test.chs', v_chs::text, true);
  end if;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Zzq launch audit plan', now() + interval '3 days',
          now() + interval '3 days 2 hours', 'Park')
  returning id into v_e;
  perform set_config('test.e', v_e::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Shared context
-- ---------------------------------------------------------------------------
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_h  uuid := current_setting('test.h')::uuid;
  v_e  uuid := current_setting('test.e')::uuid;
begin
  if private.chat_shared_context(v_a, v_b) then
    raise exception 'FAIL 2 a fresh chapter join gave shared context';
  end if;
  update public.chapter_members set joined_at = now() - interval '2 days'
   where chapter_id = current_setting('test.ch')::uuid;
  if not private.chat_shared_context(v_a, v_b) then
    raise exception 'FAIL 2 day-old chapter joins gave no shared context';
  end if;
  delete from public.chapter_members where chapter_id = current_setting('test.ch')::uuid;
  if nullif(current_setting('test.chs', true), '') is not null then
    insert into public.chapter_members (user_id, chapter_id, joined_at)
    values (v_a, current_setting('test.chs')::uuid, now() - interval '2 days'),
           (v_b, current_setting('test.chs')::uuid, now() - interval '2 days');
    if private.chat_shared_context(v_a, v_b) then
      raise exception 'FAIL 2 a sensitive hub''s chapter gave shared context';
    end if;
    delete from public.chapter_members where chapter_id = current_setting('test.chs')::uuid;
  end if;

  insert into public.rsvps (event_id, user_id, status) values (v_e, v_a, 'going');
  if private.chat_shared_context(v_a, v_h) then
    raise exception 'FAIL 2 a fresh RSVP gave shared context';
  end if;
  update public.rsvps set approved_by_host = true where event_id = v_e and user_id = v_a;
  if not private.chat_shared_context(v_a, v_h) then
    raise exception 'FAIL 2 an approved RSVP gave no shared context';
  end if;
  update public.rsvps set approved_by_host = false, created_at = now() - interval '2 days'
   where event_id = v_e and user_id = v_a;
  if not private.chat_shared_context(v_a, v_h) then
    raise exception 'FAIL 2 a day-old RSVP gave no shared context';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. set_rsvp and 4. read paths
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
end $$;
set local role authenticated;
do $$
declare
  v_e uuid := current_setting('test.e')::uuid;
begin
  if not exists (select 1 from public.events where id = v_e) or not public.can_read_event(v_e) then
    raise exception 'FAIL 4 a member cannot read a normal plan';
  end if;
end $$;
reset role;

update public.events set moderation_state = 'hidden' where id = current_setting('test.e')::uuid;
set local role authenticated;
do $$
begin
  begin
    perform public.set_rsvp(current_setting('test.e')::uuid, 'going');
    raise exception 'FAIL 3 a member RSVPed to a hidden plan';
  exception when others then
    if sqlerrm <> 'event_not_found' then raise exception 'FAIL 3 hidden plan: %', sqlerrm; end if;
  end;
end $$;
reset role;

update public.events set moderation_state = null where id = current_setting('test.e')::uuid;
update public.hubs set is_active = false where id = current_setting('test.hub')::uuid;
set local role authenticated;
do $$
declare
  v_e uuid := current_setting('test.e')::uuid;
begin
  begin
    perform public.set_rsvp(v_e, 'going');
    raise exception 'FAIL 3 a member RSVPed in an inactive hub';
  exception when others then
    if sqlerrm <> 'event_not_found' then raise exception 'FAIL 3 inactive hub: %', sqlerrm; end if;
  end;
  if exists (select 1 from public.events where id = v_e) or public.can_read_event(v_e) then
    raise exception 'FAIL 4 a member reads a plan of an inactive hub';
  end if;
  -- The host still reads it.
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.events where id = v_e) then
    raise exception 'FAIL 4 the host lost their plan';
  end if;
end $$;
reset role;

update public.hubs set is_active = true where id = current_setting('test.hub')::uuid;
update public.profiles set status = 'banned' where id = current_setting('test.h')::uuid;
do $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
end $$;
set local role authenticated;
do $$
begin
  if exists (select 1 from public.events where id = current_setting('test.e')::uuid) then
    raise exception 'FAIL 4 a member reads a banned host''s plan';
  end if;
end $$;
reset role;
set local role anon;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  if exists (select 1 from public.events where id = current_setting('test.e')::uuid) then
    raise exception 'FAIL 4 anon reads a banned host''s plan';
  end if;
end $$;
reset role;
update public.profiles set status = 'active' where id = current_setting('test.h')::uuid;

-- ---------------------------------------------------------------------------
-- 5. Classifier
-- ---------------------------------------------------------------------------
do $$
declare
  v_a     uuid := current_setting('test.a')::uuid;
  v_conv  uuid;
  v_path  text;
  v_month date := date_trunc('month', now() at time zone 'utc')::date;
  v_used  integer;
  v_res   jsonb;
begin
  insert into public.conversations (kind, title, created_by) values ('group', 'Classifier test', v_a)
  returning id into v_conv;
  insert into public.conversation_members (conversation_id, user_id, role) values (v_conv, v_a, 'owner');
  -- Five photos already classified today, then the sixth waits.
  for i in 1 .. 6 loop
    v_path := v_a::text || '/' || v_conv::text || '/' || gen_random_uuid()::text || '.jpg';
    insert into public.messages (conversation_id, seq, author_id, kind, body, image_path, image_state)
    values (v_conv, i, v_a, 'image', '', v_path, case when i < 6 then 'visible' else 'pending' end);
  end loop;
  insert into public.image_hashes (bucket, path, owner_id, status, sha256, phash, dhash)
  values ('chat-images', v_path, v_a, 'hashed', md5(v_path) || md5(v_path), 1, 1)
    on conflict (bucket, path) do update set status = 'hashed', sha256 = excluded.sha256,
                                             phash = excluded.phash, dhash = excluded.dhash;
  insert into public.meta (key, value) values ('chat_classifier_monthly_cap', '9999999')
    on conflict (key) do update set value = excluded.value;
  v_res := public.chat_classifier_reserve(v_path, 4);
  if coalesce((v_res ->> 'allowed')::boolean, true) or v_res ->> 'limit' <> 'user_daily' then
    raise exception 'FAIL 5 a sender''s sixth photo of the day reached the classifier';
  end if;

  -- Under the sender's quota, but the day's share spent: refused, the month given back.
  update public.messages set image_state = 'pending' where conversation_id = v_conv and image_path <> v_path;
  insert into public.meta (key, value) values ('chat_classifier_daily_cap', '0')
    on conflict (key) do update set value = excluded.value;
  select used into v_used from public.collector_budget where day = v_month and source = 'sightengine_ops';
  v_res := public.chat_classifier_reserve(v_path, 4);
  if coalesce((v_res ->> 'allowed')::boolean, true) or v_res ->> 'limit' <> 'daily' then
    raise exception 'FAIL 5 a photo past the day''s share reached the classifier';
  end if;
  if (select used from public.collector_budget where day = v_month and source = 'sightengine_ops')
     is distinct from coalesce(v_used, 0) then
    raise exception 'FAIL 5 the month''s reservation was not given back';
  end if;
  update public.meta set value = '9999' where key = 'chat_classifier_daily_cap';
  v_res := public.chat_classifier_reserve(v_path, 4);
  if not coalesce((v_res ->> 'allowed')::boolean, false) then
    raise exception 'FAIL 5 a photo under every cap was refused';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Export and strikes
-- ---------------------------------------------------------------------------
do $$
begin
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, status, priority)
  values (current_setting('test.a')::uuid, 'profile', current_setting('test.b')::uuid, current_setting('test.b')::uuid,
          'copyright', 'actioned', 2);
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
end $$;
set local role authenticated;
do $$
declare
  v jsonb;
begin
  v := public.export_my_data();
  if v ->> 'format' <> 'activity-planet-export-1' or (v #>> '{profile,id}') <> current_setting('test.a')
     or jsonb_array_length(v -> 'rsvps') < 1 or jsonb_array_length(v -> 'reports_filed') < 1 then
    raise exception 'FAIL 6 export_my_data is missing the caller''s rows';
  end if;
  if v::text like '%' || current_setting('test.h') || '%' then
    raise exception 'FAIL 6 export_my_data names another person';
  end if;
  begin
    perform public.mod_copyright_strikes(current_setting('test.b')::uuid);
    raise exception 'FAIL 6 a member read copyright strikes';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 6 strikes: %', sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  if public.mod_copyright_strikes(current_setting('test.b')::uuid) <> 1 then
    raise exception 'FAIL 6 the upheld copyright report was not counted';
  end if;
end $$;
reset role;

select 'launch_audit_safety: PASS' as result;

rollback;
