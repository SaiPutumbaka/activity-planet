-- ============================================================================
-- Staging check for migration 20270101000100_not_found_404.sql (migration 69).
-- One transaction: two throwaway accounts (a member and a moderator); DO
-- blocks that raise on failure, then ROLLBACK. Prints pass/fail only (no user
-- rows; the accounts are invented).
--
--   1 static: schema_version 2.65 or later; the rebuilt functions keep their
--     grants (anon only on place_detail) and raise no P0002.
--   2 Each read RPC answers a missing id with its documented code and
--     SQLSTATE PT404 (PostgREST's HTTP 404), never P0002 (HTTP 500).
--   3 Not-authenticated still answers 42501 before the not-found check.
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
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 65] then
    raise exception 'FAIL 1 schema_version is older than 2.65';
  end if;
  foreach f in array array[
    'public.get_coach(text)', 'public.coach_reviews_page(uuid, jsonb, integer)', 'public.coach_slots(uuid, date, date)',
    'public.get_booking(uuid)', 'public.conversation_info(uuid)', 'public.get_messages(uuid, bigint, bigint, integer)',
    'public.mod_message_evidence(uuid)', 'public.venue_preview_for_place(uuid)', 'public.organizer_source_detail(uuid)',
    'public.recs_similar_events(uuid, double precision, double precision, integer, text, integer)',
    'public.chapter_dashboard(uuid, integer)', 'public.mod_user_lookup(uuid)'] loop
    if has_function_privilege('anon', f, 'execute') or not has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL 1 grants on %', f;
    end if;
    if position('P0002' in pg_get_functiondef(f::regprocedure)) > 0 then
      raise exception 'FAIL 1 % still raises P0002', f;
    end if;
  end loop;
  if not has_function_privilege('anon', 'public.place_detail(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.place_detail(uuid)', 'execute') then
    raise exception 'FAIL 1 grants on place_detail';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['u', 'm'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'nf404-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
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
-- 2. Missing ids answer PT404 with the documented code
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
    ('get_coach',               'select public.get_coach(''nf404-nobody-' || md5(x) || ''')',          'not_found'),
    ('coach_reviews_page',      'select public.coach_reviews_page(' || x || ')',                        'not_found'),
    ('coach_slots',             'select * from public.coach_slots(' || x || ', current_date, current_date + 7)', 'not_found'),
    ('get_booking',             'select public.get_booking(' || x || ')',                               'not_found'),
    ('conversation_info',       'select public.conversation_info(' || x || ')',                         'not_found'),
    ('get_messages',            'select * from public.get_messages(' || x || ')',                       'not_found'),
    ('place_detail',            'select public.place_detail(' || x || ')',                              'place_not_found'),
    ('venue_preview_for_place', 'select public.venue_preview_for_place(' || x || ')',                   'place_not_found'),
    ('organizer_source_detail', 'select public.organizer_source_detail(' || x || ')',                   'not_found'),
    ('recs_similar_events',     'select * from public.recs_similar_events(' || x || ', null, null, 25, ''UTC'', 6)', 'not_found'),
    ('chapter_dashboard',       'select public.chapter_dashboard(' || x || ')',                         'chapter_not_found')
  ) v(fn, q, code) loop
    r := pg_temp.outcome(c.q);
    if r <> 'PT404:' || c.code then
      raise exception 'FAIL 2 % answered % (want PT404:%)', c.fn, r, c.code;
    end if;
  end loop;

  perform pg_temp.act('m');
  r := pg_temp.outcome('select public.mod_user_lookup(' || x || ')');
  if r <> 'PT404:user_not_found' then
    raise exception 'FAIL 2 mod_user_lookup answered %', r;
  end if;
  r := pg_temp.outcome('select public.mod_message_evidence(' || x || ')');
  if r <> 'PT404:not_found' then
    raise exception 'FAIL 2 mod_message_evidence answered %', r;
  end if;
  -- A non-moderator is still refused before the lookup.
  perform pg_temp.act('u');
  r := pg_temp.outcome('select public.mod_user_lookup(' || x || ')');
  if r <> '42501:forbidden' then
    raise exception 'FAIL 2 a member reached mod_user_lookup: %', r;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Signed out: 42501 first
-- ---------------------------------------------------------------------------
do $$
declare
  r text;
begin
  perform set_config('request.jwt.claims', '{"role":"authenticated"}', true);
  r := pg_temp.outcome('select public.get_booking(' || quote_literal(current_setting('test.missing')) || '::uuid)');
  if r <> '42501:not_authenticated' then
    raise exception 'FAIL 3 signed-out get_booking answered %', r;
  end if;
end $$;

reset role;
select 'PASS not_found_404' as result;
rollback;
