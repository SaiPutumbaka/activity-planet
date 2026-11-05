-- ============================================================================
-- Staging check for migration 20261217000100_admin_panel.sql (migration 53).
-- One transaction: sets up throwaway accounts, asserts with DO blocks that
-- raise on failure, then rolls everything back. Prints pass/fail only (no
-- user rows; the accounts, reports and requests are invented).
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 static: schema_version 2.49 or later, grants, cron job, SLA hours.
--   2 members and anon are refused every panel RPC.
--   3 mod_queue: reports grouped and overdue, a takedown, most urgent first,
--     the second-moderator rule, no reporter ids.
--   4 mod_scorecard: queue counts, breaches, resolved, actions.
--   5 mod_user_search: handle prefix, email (never returned or logged), id,
--     invalid queries; every search logged.
--   6 mod_user_lookup: minimal fields, counts, logged; can_ban follows the
--     mod_ban_user rules.
--   7 ban with a reason, lookup shows it, unban.
--   8 mod_lookup_log: admins only.
--   9 purge after a year.
--  10 account deletion: the moderator link on lookups is cleared.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  v text := (select value from public.meta where key = 'schema_version');
begin
  if string_to_array(v, '.')::integer[] < array[2, 49] then
    raise exception 'FAIL 1 schema_version is below 2.49';
  end if;
  if has_table_privilege('authenticated', 'public.admin_lookups', 'select')
     or has_table_privilege('authenticated', 'public.admin_lookups', 'insert')
     or has_table_privilege('anon', 'public.admin_lookups', 'select')
     or not has_table_privilege('service_role', 'public.admin_lookups', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if has_function_privilege('anon', 'public.mod_queue(integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_queue(integer)', 'execute')
     or has_function_privilege('anon', 'public.mod_scorecard()', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_scorecard()', 'execute')
     or has_function_privilege('anon', 'public.mod_user_search(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_user_search(text)', 'execute')
     or has_function_privilege('anon', 'public.mod_user_lookup(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_user_lookup(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mod_lookup_log(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.mod_sla_hours(text)', 'execute')
     or has_function_privilege('authenticated', 'public.purge_admin_lookups()', 'execute')
     or has_function_privilege('anon', 'public.purge_admin_lookups()', 'execute')
     or has_function_privilege('anon', 'public.request_account_deletion(text)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if public.mod_sla_hours('place_report') <> 24 or public.mod_sla_hours('claim') <> 72
     or public.mod_sla_hours('calendar') <> 168 or public.mod_sla_hours('place') <> 72
     or public.mod_sla_hours('place_edit') <> 72 or public.mod_sla_hours('report') is not null then
    raise exception 'FAIL 1 mod_sla_hours';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'admin-lookups-purge') then
    raise exception 'FAIL 1 cron job missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['u', 'r1', 'r2', 'x', 'm', 'm2', 'a', 'mem'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  perform set_config('test.tag', v_tag, true);
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ap-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           handle = 'ap' || v_tag || '_' || v_names[i],
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values
    (current_setting('test.m')::uuid, 'moderator'),
    (current_setting('test.m2')::uuid, 'moderator'),
    (current_setting('test.a')::uuid, 'admin');

  -- Open reports on u: one overdue child-safety report, one ordinary.
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, priority, due_at, created_at)
  values (current_setting('test.r1')::uuid, 'profile', current_setting('test.u')::uuid, current_setting('test.u')::uuid,
          'child_safety', 0, now() - interval '1 hour', now() - interval '5 hours'),
         (current_setting('test.r2')::uuid, 'profile', current_setting('test.u')::uuid, current_setting('test.u')::uuid,
          'harassment', 2, now() + interval '20 hours', now() - interval '4 hours');
  -- A report m filed on x: m may not act on it.
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, priority, due_at)
  values (current_setting('test.m')::uuid, 'profile', current_setting('test.x')::uuid, current_setting('test.x')::uuid,
          'spam', 2, now() + interval '24 hours');
  -- A report closed late (a breach) and one closed in time.
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, priority, due_at, created_at,
                              status, resolved_by, resolved_at)
  values (current_setting('test.r1')::uuid, 'profile', current_setting('test.x')::uuid, current_setting('test.x')::uuid,
          'scam', 2, now() - interval '2 days', now() - interval '3 days', 'dismissed',
          current_setting('test.m2')::uuid, now() - interval '1 day'),
         (current_setting('test.r2')::uuid, 'profile', current_setting('test.x')::uuid, current_setting('test.x')::uuid,
          'scam', 2, now() + interval '1 day', now() - interval '2 hours', 'dismissed',
          current_setting('test.m2')::uuid, now() - interval '1 hour');
  -- An NCII request about u, due in 40 hours.
  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship, locations,
                                        good_faith, signature, priority, due_at, target_user_id)
  values ('NCII-' || upper(substr(v_tag, 1, 8)), 'Pat Requester', 'req-' || v_tag || '@example.com', repeat('a', 64),
          'self', 'a profile photo', true, 'Pat Requester', 1, now() + interval '40 hours',
          current_setting('test.u')::uuid)
  returning id::text into v_tag;
  perform set_config('test.req', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. Members and anon are refused
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_fn text;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.mem'), 'role', 'authenticated')::text, true);
  foreach v_fn in array array['queue', 'scorecard', 'search', 'lookup', 'log'] loop
    begin
      case v_fn
        when 'queue' then perform public.mod_queue(10);
        when 'scorecard' then perform public.mod_scorecard();
        when 'search' then perform public.mod_user_search('ap');
        when 'lookup' then perform public.mod_user_lookup(current_setting('test.u')::uuid);
        else perform public.mod_lookup_log(10);
      end case;
      raise exception 'FAIL 2 member runs %', v_fn;
    exception when others then
      if sqlerrm <> 'forbidden' then raise exception 'FAIL 2 member %: %', v_fn, sqlerrm; end if;
    end;
  end loop;
  begin
    perform 1 from public.admin_lookups limit 1;
    raise exception 'FAIL 2 member reads admin_lookups';
  exception when insufficient_privilege then null;
  end;
  -- A moderator who is not an admin cannot read the lookup log.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_lookup_log(10);
    raise exception 'FAIL 2 moderator reads the lookup log';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 2 moderator log: %', sqlerrm; end if;
  end;
end $$;
reset role;
set local role anon;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  begin
    perform public.mod_queue(10);
    raise exception 'FAIL 2 anon runs mod_queue';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.mod_user_search('ap');
    raise exception 'FAIL 2 anon runs mod_user_search';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. mod_queue
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j    jsonb;
  it   jsonb;
  prev jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_queue(500);
  if jsonb_typeof(j) <> 'array' then
    raise exception 'FAIL 3 not an array';
  end if;
  select e into it from jsonb_array_elements(j) e
   where e ->> 'source' = 'report' and e ->> 'id' = 'profile:' || current_setting('test.u');
  if it is null or (it ->> 'count')::integer <> 2 or (it ->> 'priority')::integer <> 0
     or not (it ->> 'overdue')::boolean or (it ->> 'minutes_left')::integer >= 0
     or not (it ->> 'can_act')::boolean or it -> 'ref' ->> 'target_id' <> current_setting('test.u')
     or not (it -> 'ref' -> 'reasons') ? 'child_safety' then
    raise exception 'FAIL 3 report item';
  end if;
  select e into it from jsonb_array_elements(j) e
   where e ->> 'source' = 'report' and e ->> 'id' = 'profile:' || current_setting('test.x');
  if it is null or (it ->> 'can_act')::boolean or (it ->> 'count')::integer <> 1 then
    raise exception 'FAIL 3 own report item';
  end if;
  select e into it from jsonb_array_elements(j) e
   where e ->> 'source' = 'takedown' and e ->> 'id' = current_setting('test.req');
  if it is null or (it ->> 'overdue')::boolean or (it ->> 'minutes_left')::integer not between 2390 and 2401
     or not (it ->> 'can_act')::boolean or it -> 'ref' ->> 'request_id' <> current_setting('test.req') then
    raise exception 'FAIL 3 takedown item';
  end if;
  -- Ordered by priority, then due time.
  for it in select e from jsonb_array_elements(j) e loop
    if prev is not null and ((prev ->> 'priority')::integer > (it ->> 'priority')::integer
        or ((prev ->> 'priority')::integer = (it ->> 'priority')::integer
            and (prev ->> 'due_at')::timestamptz > (it ->> 'due_at')::timestamptz)) then
      raise exception 'FAIL 3 order';
    end if;
    prev := it;
  end loop;
  if j::text like '%' || current_setting('test.r1') || '%' or j::text like '%' || current_setting('test.r2') || '%'
     or j::text like '%@example.com%' then
    raise exception 'FAIL 3 queue names a reporter or requester';
  end if;
  -- The NCII request is about u; a moderator who is u would not act. m2 sees can_act on it.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  if not exists (select 1 from jsonb_array_elements(public.mod_queue(500)) e
                  where e ->> 'id' = 'profile:' || current_setting('test.x') and (e ->> 'can_act')::boolean) then
    raise exception 'FAIL 3 m2 cannot act on the report m filed';
  end if;
  if jsonb_array_length(public.mod_queue(1)) > 1 then
    raise exception 'FAIL 3 limit';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. mod_scorecard
-- ---------------------------------------------------------------------------
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_scorecard();
  if (j -> 'queues' -> 'report' ->> 'open')::integer < 2
     or (j -> 'queues' -> 'report' ->> 'overdue')::integer < 1
     or (j -> 'queues' -> 'takedown' ->> 'open')::integer < 1
     or not (j -> 'queues') ?& array['place_report', 'place', 'place_edit', 'claim', 'calendar']
     or (j -> 'breaches_30d' ->> 'report')::integer < 1
     or (j -> 'resolved_7d' ->> 'report')::integer < 2
     or (j -> 'median_hours_30d' ->> 'report') is null
     or (j -> 'people' ->> 'members')::integer < 8
     or not (j -> 'plans') ?& array['human_hosted_next_7d', 'human_hosted_last_7d', 'four_plus_checked_in_last_7d']
     or (j ->> 'chapters_active') is null then
    raise exception 'FAIL 4 scorecard';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. mod_user_search
-- ---------------------------------------------------------------------------
do $$
declare
  j   jsonb;
  v_q text := 'ap' || current_setting('test.tag');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_user_search('@' || upper(v_q));
  if jsonb_array_length(j) <> 8 then
    raise exception 'FAIL 5 handle prefix found %', jsonb_array_length(j);
  end if;
  if exists (select 1 from jsonb_array_elements(j) e where e ? 'email' or e ? 'birth_date')
     or not exists (select 1 from jsonb_array_elements(j) e
                     where e ->> 'id' = current_setting('test.u') and e ? 'handle' and e ? 'status' and e ? 'joined_at') then
    raise exception 'FAIL 5 handle result fields';
  end if;
  -- "_" is literal, not a wildcard.
  if jsonb_array_length(public.mod_user_search(v_q || '_u')) <> 1 then
    raise exception 'FAIL 5 underscore';
  end if;
  j := public.mod_user_search('AP-U-' || current_setting('test.tag') || '@Example.com');
  if jsonb_array_length(j) <> 1 or j -> 0 ->> 'id' <> current_setting('test.u') or j::text like '%example.com%' then
    raise exception 'FAIL 5 email search';
  end if;
  if jsonb_array_length(public.mod_user_search('nobody-' || current_setting('test.tag') || '@example.com')) <> 0 then
    raise exception 'FAIL 5 unknown email';
  end if;
  j := public.mod_user_search(current_setting('test.x'));
  if jsonb_array_length(j) <> 1 or j -> 0 ->> 'id' <> current_setting('test.x') then
    raise exception 'FAIL 5 id search';
  end if;
  begin
    perform public.mod_user_search('a');
    raise exception 'FAIL 5 one character accepted';
  exception when others then
    if sqlerrm <> 'invalid_query' then raise exception 'FAIL 5 short: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_user_search('a%b');
    raise exception 'FAIL 5 wildcard accepted';
  exception when others then
    if sqlerrm <> 'invalid_query' then raise exception 'FAIL 5 wildcard: %', sqlerrm; end if;
  end;
end $$;
reset role;
do $$
begin
  if (select count(*) from public.admin_lookups where moderator_id = current_setting('test.m')::uuid) <> 5
     or (select count(*) from public.admin_lookups
          where moderator_id = current_setting('test.m')::uuid and via = 'email' and query is null) <> 2
     or exists (select 1 from public.admin_lookups where query like '%@%')
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = current_setting('test.m')::uuid and via = 'handle'
                       and query = 'ap' || current_setting('test.tag') and result_count = 8)
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = current_setting('test.m')::uuid and via = 'id' and result_count = 1) then
    raise exception 'FAIL 5 search log';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. mod_user_lookup
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_user_lookup(current_setting('test.u')::uuid);
  if j ->> 'id' <> current_setting('test.u') or j ->> 'status' <> 'active'
     or (j -> 'counts' ->> 'open_reports')::integer <> 2 or (j -> 'counts' ->> 'takedowns_about')::integer <> 1
     or (j ->> 'account_days')::integer <> 3 or not (j ->> 'onboarded')::boolean
     or not (j ->> 'can_ban')::boolean or (j ->> 'can_unban')::boolean or (j ->> 'is_self')::boolean then
    raise exception 'FAIL 6 lookup of u';
  end if;
  if j ? 'email' or j ? 'birth_date' or j::text like '%example.com%' then
    raise exception 'FAIL 6 lookup leaks private fields';
  end if;
  -- Another moderator: only an admin bans one.
  if (public.mod_user_lookup(current_setting('test.m2')::uuid) ->> 'can_ban')::boolean then
    raise exception 'FAIL 6 moderator may ban a moderator';
  end if;
  -- Oneself, an admin, someone m reported: never.
  if (public.mod_user_lookup(current_setting('test.m')::uuid) ->> 'can_ban')::boolean
     or not (public.mod_user_lookup(current_setting('test.m')::uuid) ->> 'is_self')::boolean
     or (public.mod_user_lookup(current_setting('test.a')::uuid) ->> 'can_ban')::boolean
     or (public.mod_user_lookup(current_setting('test.x')::uuid) ->> 'can_ban')::boolean then
    raise exception 'FAIL 6 can_ban rules';
  end if;
  begin
    perform public.mod_user_lookup(gen_random_uuid());
    raise exception 'FAIL 6 unknown user';
  exception when others then
    if sqlerrm <> 'user_not_found' then raise exception 'FAIL 6 unknown: %', sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  if not (public.mod_user_lookup(current_setting('test.m2')::uuid) ->> 'can_ban')::boolean then
    raise exception 'FAIL 6 admin cannot ban a moderator';
  end if;
end $$;
reset role;
do $$
begin
  if (select count(*) from public.admin_lookups
       where moderator_id = current_setting('test.m')::uuid and via = 'open') <> 6
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = current_setting('test.m')::uuid and via = 'open'
                       and target_user_id = current_setting('test.u')::uuid)
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = current_setting('test.a')::uuid and via = 'open'
                       and target_user_id = current_setting('test.m2')::uuid) then
    raise exception 'FAIL 6 lookup log';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Ban with a reason, then unban
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  j := public.mod_ban_user(current_setting('test.u')::uuid, 'Repeated harassment after a warning');
  if not (j ->> 'banned')::boolean then
    raise exception 'FAIL 7 ban';
  end if;
  j := public.mod_user_lookup(current_setting('test.u')::uuid);
  if j ->> 'status' <> 'banned' or (j ->> 'can_ban')::boolean or not (j ->> 'can_unban')::boolean
     or not exists (select 1 from jsonb_array_elements(j -> 'actions') a
                     where a ->> 'action' = 'ban' and a ->> 'note' = 'Repeated harassment after a warning'
                       and (a ->> 'by_me')::boolean)
     or (j -> 'counts' ->> 'open_reports')::integer <> 0 then
    raise exception 'FAIL 7 lookup after ban';
  end if;
  if exists (select 1 from jsonb_array_elements(public.mod_queue(500)) e
              where e ->> 'id' = 'profile:' || current_setting('test.u')) then
    raise exception 'FAIL 7 banned profile still queued';
  end if;
  j := public.mod_unban_user(current_setting('test.u')::uuid, 'Appeal accepted');
  if not (j ->> 'unbanned')::boolean
     or public.mod_user_lookup(current_setting('test.u')::uuid) ->> 'status' <> 'active' then
    raise exception 'FAIL 7 unban';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. mod_lookup_log (admins)
-- ---------------------------------------------------------------------------
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  j := public.mod_lookup_log(500);
  if not exists (select 1 from jsonb_array_elements(j) e
                  where e -> 'moderator' ->> 'id' = current_setting('test.m') and e ->> 'via' = 'open'
                    and e -> 'target' ->> 'id' = current_setting('test.u'))
     or j::text like '%example.com%' then
    raise exception 'FAIL 8 lookup log';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 9. Purge after a year
-- ---------------------------------------------------------------------------
do $$
begin
  update public.admin_lookups set created_at = now() - interval '366 days'
   where moderator_id = current_setting('test.m')::uuid and via = 'id';
  perform public.purge_admin_lookups();
  if exists (select 1 from public.admin_lookups where moderator_id = current_setting('test.m')::uuid and via = 'id')
     or not exists (select 1 from public.admin_lookups where moderator_id = current_setting('test.m')::uuid and via = 'open') then
    raise exception 'FAIL 9 purge';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion('test');
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.admin_lookups where moderator_id = current_setting('test.m')::uuid) then
    raise exception 'FAIL 10 lookups keep the deleted moderator';
  end if;
  if not exists (select 1 from public.admin_lookups
                  where moderator_id is null and via = 'open' and target_user_id = current_setting('test.u')::uuid) then
    raise exception 'FAIL 10 lookups about u went';
  end if;
  if exists (select 1 from public.user_roles where user_id = current_setting('test.m')::uuid) then
    raise exception 'FAIL 10 roles stayed';
  end if;
end $$;

select 'admin_panel: PASS' as result;

rollback;
