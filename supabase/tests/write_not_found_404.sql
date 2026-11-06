-- ============================================================================
-- Staging check for migration 20270102000100_write_not_found_404.sql (migration 70).
-- One transaction: three throwaway accounts (two members and a moderator); DO
-- blocks that raise on failure, then ROLLBACK. Prints pass/fail only (no user
-- rows; the accounts are invented).
--
--   1 static: schema_version 2.66 or later; the 66 rebuilt functions keep
--     their grants and raise P0002 only for profile_missing and
--     coach_profile_required.
--   2 Write RPCs answer a missing row with their documented code and SQLSTATE
--     PT404 (PostgREST's HTTP 404), never P0002 (HTTP 500).
--   3 A row that exists but is hidden from the caller (a blocked pair) still
--     answers exactly like a missing one.
--   4 Order kept: signed out answers 42501 first; a member reaching a
--     moderator RPC answers 42501 forbidden before any lookup.
--   5 source_candidates_rescore (new): service role only; a missing region is
--     PT404; a dry run counts and writes nothing; a real run sets the scores
--     (rolled back), and a second identical run changes nothing.
-- ============================================================================
begin;

create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;

-- Runs p_sql and returns 'SQLSTATE:message', or 'ok' when it does not raise.
create function pg_temp.outcome(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlstate || ':' || sqlerrm;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f      text;
  v_src  text;
  v_n    integer;
  v_svc  text[] := array[
    'private.booking_confirm(uuid)', 'private.booking_for_party(uuid, text)', 'private.coach_raise(text)',
    'public.event_rules_check(public.event_kind, uuid, uuid, public.event_visibility, uuid, smallint, uuid, text, public.address_visibility)',
    'public.event_set_location(uuid, uuid, text, text, public.address_visibility, text, uuid)',
    'public.materialize_event_series(uuid, integer)', 'public.place_apply_changes(uuid, jsonb, text, boolean)'];
  v_auth text[] := array[
    'public.add_group_members(uuid, uuid[])', 'public.admin_set_moderator(uuid, boolean, text)',
    'public.approve_rsvp(uuid, uuid, boolean)', 'public.block_user(uuid)', 'public.broadcast_to_event(uuid, text)',
    'public.cancel_event(uuid, text)', 'public.cancel_event_series(uuid, text)', 'public.cancel_group_session(uuid)',
    'public.check_in(uuid)', 'public.confirm_booking(uuid)',
    'public.connect_organizer_feed(text, uuid, double precision, double precision)', 'public.delete_message(uuid)',
    'public.delete_my_place(uuid)', 'public.host_check_in(uuid, uuid, boolean)', 'public.leave_conversation(uuid)',
    'public.mark_conversation_read(uuid, bigint)', 'public.mod_ban_user(uuid, text)',
    'public.mod_booking(uuid, text, text)', 'public.mod_listing_removal_resolve(uuid, text, text)',
    'public.mod_moderate(text, uuid, text, text)', 'public.mod_organizer_claim_review(uuid, text, text)',
    'public.mod_set_coach_status(uuid, text, text)', 'public.mod_takedown_block_image(uuid, text)',
    'public.mod_takedown_resolve(uuid, text, text, uuid)', 'public.mod_unban_user(uuid, text)',
    'public.mute_conversation(uuid, timestamptz)', 'public.mute_user(uuid)', 'public.organizer_claim_check(uuid)',
    'public.remove_chapter_member(uuid, uuid)', 'public.remove_conversation_member(uuid, uuid)',
    'public.remove_rsvp(uuid, uuid, text)', 'public.rename_group(uuid, text)', 'public.reply_to_review(uuid, text)',
    'public.report_content(text, uuid, text, text)', 'public.report_place(uuid, text, text)',
    'public.request_booking(uuid, timestamptz, text, text, uuid)', 'public.respond_message_request(uuid, text)',
    'public.review_chapter_claim(uuid, boolean, text)', 'public.schedule_group_session(uuid, timestamptz)',
    'public.send_message(uuid, uuid, text, text)', 'public.set_chapter_role(uuid, uuid, public.chapter_role)',
    'public.set_conversation_notify(uuid, boolean)',
    'public.set_conversation_role(uuid, uuid, public.conversation_role)', 'public.set_home_area(uuid, smallint)',
    'public.set_listing_status(uuid, public.listing_status)', 'public.set_my_place_visibility(uuid, boolean, boolean)',
    'public.set_rsvp(uuid, public.rsvp_status)', 'public.start_dm(uuid)',
    'public.start_organizer_claim(uuid, uuid, text, text, text)', 'public.submit_attendance(uuid, boolean, uuid[])',
    'public.submit_chapter_claim(jsonb)', 'public.suggest_place_edit(uuid, jsonb, text)',
    'public.update_event(uuid, jsonb)', 'public.update_event_series(uuid, jsonb)', 'public.upsert_listing(jsonb)',
    'public.upsert_venue(jsonb)', 'public.venue_for_place(uuid)', 'public.withdraw_chapter_claim(uuid)',
    'public.write_review(uuid, integer, text)'];
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 66] then
    raise exception 'FAIL 1 schema_version is older than 2.66';
  end if;
  if array_length(v_svc, 1) + array_length(v_auth, 1) <> 66 then
    raise exception 'FAIL 1 the list has % functions, want 66', array_length(v_svc, 1) + array_length(v_auth, 1);
  end if;
  foreach f in array v_svc || v_auth loop
    select p.prosrc into v_src from pg_proc p where p.oid = f::regprocedure;
    -- Every P0002 left is a profile_missing or coach_profile_required raise.
    select count(*) into v_n
      from regexp_matches(v_src,
             'raise exception ''(profile_missing|coach_profile_required)'' using errcode = ''P0002''', 'g');
    if (length(v_src) - length(replace(v_src, 'P0002', ''))) / 5 <> v_n then
      raise exception 'FAIL 1 % still raises P0002 for a missing row', f;
    end if;
    if position('PT404' in v_src) = 0 then
      raise exception 'FAIL 1 % has no PT404', f;
    end if;
    if has_function_privilege('anon', f, 'execute') then
      raise exception 'FAIL 1 anon can run %', f;
    end if;
    if not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL 1 service_role cannot run %', f;
    end if;
    if has_function_privilege('authenticated', f, 'execute') <> (f = any (v_auth)) then
      raise exception 'FAIL 1 authenticated grant on % changed', f;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['u', 'v', 'm'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'wnf404-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (current_setting('test.m')::uuid, 'moderator');
  perform set_config('test.missing', gen_random_uuid()::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Missing rows answer PT404 with the documented code
-- ---------------------------------------------------------------------------
set local role authenticated;

do $$
declare
  x   text := quote_literal(current_setting('test.missing')) || '::uuid';
  r   text;
  c   record;
begin
  perform pg_temp.act('u');
  for c in select * from (values
    ('cancel_event',            'select public.cancel_event(' || x || ')',                                'event_not_found'),
    ('set_rsvp',                'select public.set_rsvp(' || x || ', ''going'')',                         'event_not_found'),
    ('send_message',            'select public.send_message(' || x || ', gen_random_uuid(), ''hi'')',     'not_found'),
    ('respond_message_request', 'select public.respond_message_request(' || x || ', ''accept'')',         'not_found'),
    ('delete_message',          'select public.delete_message(' || x || ')',                              'not_found'),
    ('confirm_booking',         'select public.confirm_booking(' || x || ')',                             'not_found'),
    ('decline_booking',         'select public.decline_booking(' || x || ')',                             'not_found'),
    ('cancel_booking',          'select public.cancel_booking(' || x || ')',                              'not_found'),
    ('complete_booking',        'select public.complete_booking(' || x || ')',                            'not_found'),
    ('cancel_group_session',    'select public.cancel_group_session(' || x || ')',                        'not_found'),
    ('start_dm',                'select public.start_dm(' || x || ')',                                    'user_not_found'),
    ('block_user',              'select public.block_user(' || x || ')',                                  'user_not_found'),
    ('report_content',          'select public.report_content(''message'', ' || x || ', ''harassment'')', 'target_not_found'),
    ('withdraw_chapter_claim',  'select public.withdraw_chapter_claim(' || x || ')',                      'claim_not_found'),
    ('organizer_claim_check',   'select public.organizer_claim_check(' || x || ')',                       'not_found'),
    ('delete_my_place',         'select public.delete_my_place(' || x || ')',                             'place_not_found'),
    ('venue_for_place',         'select public.venue_for_place(' || x || ')',                             'place_not_found')
  ) v(fn, q, code) loop
    r := pg_temp.outcome(c.q);
    if r <> 'PT404:' || c.code then
      raise exception 'FAIL 2 % answered % (want PT404:%)', c.fn, r, c.code;
    end if;
  end loop;

  perform pg_temp.act('m');
  for c in select * from (values
    ('mod_moderate', 'select public.mod_moderate(''message'', ' || x || ', ''hide'')', 'target_not_found'),
    ('mod_ban_user', 'select public.mod_ban_user(' || x || ')',                       'user_not_found')
  ) v(fn, q, code) loop
    r := pg_temp.outcome(c.q);
    if r <> 'PT404:' || c.code then
      raise exception 'FAIL 2 % answered % (want PT404:%)', c.fn, r, c.code;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Exists but hidden from the caller: the same answer as missing
-- ---------------------------------------------------------------------------
do $$
declare
  r text;
begin
  perform pg_temp.act('v');
  r := pg_temp.outcome(format('select public.block_user(%L::uuid)', current_setting('test.u')));
  if r <> 'ok' then
    raise exception 'FAIL 3 block_user answered %', r;
  end if;
  perform pg_temp.act('u');
  r := pg_temp.outcome(format('select public.start_dm(%L::uuid)', current_setting('test.v')));
  if r <> 'PT404:user_not_found' then
    raise exception 'FAIL 3 start_dm to a blocked pair answered % (want the missing answer)', r;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Order kept: signed out, then forbidden, then not found
-- ---------------------------------------------------------------------------
do $$
declare
  x text := quote_literal(current_setting('test.missing')) || '::uuid';
  r text;
  q text;
begin
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  foreach q in array array[
    'select public.cancel_event(' || x || ')',
    'select public.send_message(' || x || ', gen_random_uuid(), ''hi'')',
    'select public.delete_message(' || x || ')',
    'select public.confirm_booking(' || x || ')',
    'select public.mod_moderate(''message'', ' || x || ', ''hide'')'] loop
    r := pg_temp.outcome(q);
    if r <> '42501:not_authenticated' then
      raise exception 'FAIL 4 signed out answered % for %', r, q;
    end if;
  end loop;

  perform pg_temp.act('u');
  foreach q in array array[
    'select public.mod_moderate(''message'', ' || x || ', ''hide'')',
    'select public.mod_ban_user(' || x || ')'] loop
    r := pg_temp.outcome(q);
    if r <> '42501:forbidden' then
      raise exception 'FAIL 4 a member answered % for %', r, q;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 5. source_candidates_rescore: service role only, dry run writes nothing
-- ---------------------------------------------------------------------------
do $$
declare
  r text;
begin
  perform pg_temp.act('u');
  r := pg_temp.outcome('select public.source_candidates_rescore(gen_random_uuid(), ''[]''::jsonb)');
  if r not like '42501:%' then
    raise exception 'FAIL 5 a member reached source_candidates_rescore: %', r;
  end if;
end $$;

reset role;

do $$
declare
  v_region uuid;
  v_list   jsonb;
  v_n      integer;
  v_before bigint;
  v_after  bigint;
  v_res    jsonb;
  r        text;
begin
  if has_function_privilege('anon', 'public.source_candidates_rescore(uuid, jsonb, boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.source_candidates_rescore(uuid, jsonb, boolean)', 'execute')
     or not has_function_privilege('service_role', 'public.source_candidates_rescore(uuid, jsonb, boolean)', 'execute') then
    raise exception 'FAIL 5 grants on source_candidates_rescore';
  end if;
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  r := pg_temp.outcome('select public.source_candidates_rescore(gen_random_uuid(), ''[]''::jsonb)');
  if r <> 'PT404:region_not_found' then
    raise exception 'FAIL 5 a missing region answered %', r;
  end if;
  r := pg_temp.outcome('select public.source_candidates_rescore(null, ''{}''::jsonb)');
  if r <> '23514:scores_invalid' then
    raise exception 'FAIL 5 a bad list answered %', r;
  end if;

  -- Up to five stored automatic candidates of one region, each sent one point off.
  select sc.region_id into v_region
    from public.source_candidates sc
   where sc.region_id is not null and sc.origin in ('osm', 'wikidata')
   group by sc.region_id order by count(*) desc limit 1;
  if v_region is null then
    return;  -- nothing stored on this project: the checks above still ran
  end if;
  select jsonb_agg(jsonb_build_object('url', x.url, 'score', case when x.score > 0 then x.score - 1 else 1 end)),
         count(*), sum(x.score)
    into v_list, v_n, v_before
    from (select sc.url, sc.score from public.source_candidates sc
           where sc.region_id = v_region and sc.origin in ('osm', 'wikidata')
           order by sc.id limit 5) x;
  v_list := v_list || jsonb_build_array(jsonb_build_object('url', 'https://wnf404-' || md5(random()::text) || '.org/', 'score', 5),
                                        jsonb_build_object('url', 'not a url', 'score', 5),
                                        jsonb_build_object('url', 'https://x.example.org/'));

  v_res := public.source_candidates_rescore(v_region, v_list, true);
  if (v_res ->> 'lowered')::int + (v_res ->> 'raised')::int <> v_n or (v_res ->> 'missing')::int <> 1
     or (v_res ->> 'invalid')::int <> 2 or (v_res ->> 'dry_run')::boolean is not true then
    raise exception 'FAIL 5 dry run counted %', v_res;
  end if;
  select sum(x.score) into v_after
    from (select sc.score from public.source_candidates sc
           where sc.region_id = v_region and sc.origin in ('osm', 'wikidata')
           order by sc.id limit 5) x;
  if v_after <> v_before then
    raise exception 'FAIL 5 the dry run wrote scores';
  end if;

  v_res := public.source_candidates_rescore(v_region, v_list);
  if (v_res ->> 'lowered')::int + (v_res ->> 'raised')::int <> v_n then
    raise exception 'FAIL 5 rescore counted %', v_res;
  end if;
  v_res := public.source_candidates_rescore(v_region, v_list);
  if (v_res ->> 'unchanged')::int <> v_n then
    raise exception 'FAIL 5 a second rescore changed scores again: %', v_res;
  end if;
end $$;

select 'PASS write_not_found_404' as result;
rollback;
