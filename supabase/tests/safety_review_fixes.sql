-- ============================================================================
-- Staging check for migration 20261218000100_safety_review_fixes.sql
-- (migration 54). One transaction: sets up throwaway accounts, a chapter,
-- plans, a place and requests, asserts with DO blocks that raise on failure,
-- then rolls everything back. Prints pass/fail only (no user rows; the
-- accounts and requests are invented).
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 static: schema_version 2.50 or later, public.is_blocked_with gone,
--     private.is_blocked_with for the signed-in role only, the takedown
--     function for the service role only, the client_hash column.
--   2 blocks still hide profiles both ways through the policies.
--   3 auto-hide: not again within 30 days of a dismissal; a reporter the
--     target blocked does not count; hidden answers only for this report.
--   4 report answers: a hidden plan the caller cannot read is not found.
--   5 second-moderator rule: a plan in a chapter the moderator runs; a
--     place the moderator reported among others.
--   6 leadership needs an active account (is_chapter_captain,
--     viewer_can_manage).
--   7 ban: chapter roles to member and a review report for the chapter,
--     a plan under way cancelled, sessions ended.
--   8 mod_user_search: id and email searches record the account; 200 a day.
--   9 submit_takedown_request: 5 a day per client, 3 per email, priority 2
--     past 200 an hour instead of refused.
--  10 purge: log notes of purged requests lose the free text; old client
--     hashes cleared.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  v text := (select value from public.meta where key = 'schema_version');
begin
  if string_to_array(v, '.')::integer[] < array[2, 50] then
    raise exception 'FAIL 1 schema_version is below 2.50';
  end if;
  if to_regprocedure('public.is_blocked_with(uuid)') is not null then
    raise exception 'FAIL 1 public.is_blocked_with still exists';
  end if;
  if to_regprocedure('private.is_blocked_with(uuid)') is null
     or not has_function_privilege('authenticated', 'private.is_blocked_with(uuid)', 'execute')
     or has_function_privilege('anon', 'private.is_blocked_with(uuid)', 'execute')
     or has_schema_privilege('anon', 'private', 'usage')
     or not has_schema_privilege('authenticated', 'private', 'usage') then
    raise exception 'FAIL 1 private.is_blocked_with grants';
  end if;
  if has_function_privilege('anon', 'public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean,text)', 'execute')
     or has_function_privilege('authenticated', 'public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean,text)', 'execute')
     or not has_function_privilege('service_role', 'public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean,text)', 'execute')
     or to_regprocedure('public.submit_takedown_request(text,text,text,text,boolean,text,text,boolean)') is not null then
    raise exception 'FAIL 1 submit_takedown_request grants';
  end if;
  if has_function_privilege('authenticated', 'public.moderation_is_own(text,uuid,uuid)', 'execute')
     or has_function_privilege('anon', 'public.report_content(text,uuid,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.is_chapter_captain(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_user_search(text)', 'execute')
     or has_function_privilege('authenticated', 'public.purge_takedown_contacts()', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'takedown_requests' and column_name = 'client_hash') then
    raise exception 'FAIL 1 takedown_requests.client_hash missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['t', 't2', 'r1', 'r2', 'r3', 'r4', 'h', 'x', 'c', 'c2', 'm', 'm2', 'adm'];
  v_id    uuid;
  v_hub   uuid;
  v_area  uuid;
  v_ch    uuid;
  v_ch2   uuid;
  v_e     uuid;
  v_pl    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  perform set_config('test.tag', v_tag, true);
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'srf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           handle = 'srf' || v_tag || '_' || v_names[i],
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values
    (current_setting('test.m')::uuid, 'moderator'),
    (current_setting('test.m2')::uuid, 'moderator'),
    (current_setting('test.adm')::uuid, 'admin');

  select h.id, a.id into v_hub, v_area
    from public.hubs h
    join public.hub_categories cat on cat.slug = h.category_slug
    cross join public.areas a
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not cat.is_sensitive
     and not exists (select 1 from public.hub_chapters ch
                      where ch.hub_id = h.id and ch.area_id = a.id and ch.org_id is null and ch.campus_id is null)
   order by h.slug, a.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no hub and area'; end if;
  perform set_config('test.hub', v_hub::text, true);

  -- ch: c is its only organizer, c2 a captain.
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_area, 'srf-' || v_tag, 'Review Fix Chapter')
  returning id into v_ch;
  perform set_config('test.ch', v_ch::text, true);
  insert into public.chapter_members (user_id, chapter_id, role) values
    (current_setting('test.c')::uuid, v_ch, 'organizer'),
    (current_setting('test.c2')::uuid, v_ch, 'captain'),
    (current_setting('test.r1')::uuid, v_ch, 'member');
  -- ch2: a second chapter of the same hub (an org chapter would need an org,
  -- so use another area) that m captains.
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  select v_hub, a.id, 'srf2-' || v_tag, 'Review Fix Chapter Two'
    from public.areas a
   where a.id <> v_area
     and not exists (select 1 from public.hub_chapters ch
                      where ch.hub_id = v_hub and ch.area_id = a.id and ch.org_id is null and ch.campus_id is null)
   order by a.slug limit 1
  returning id into v_ch2;
  if v_ch2 is null then raise exception 'FAIL setup: no second area'; end if;
  perform set_config('test.ch2', v_ch2::text, true);
  insert into public.chapter_members (user_id, chapter_id, role)
  values (current_setting('test.m')::uuid, v_ch2, 'captain');

  -- e_live: c hosts a plan under way in ch; r1 going.
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, location_hint)
  values ('chapter', v_hub, v_ch, current_setting('test.c')::uuid, 'Review live run', now() - interval '1 hour',
          now() + interval '1 hour', 'Park')
  returning id into v_e;
  perform set_config('test.e_live', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.r1')::uuid, 'going');
  -- e_m: h hosts a plan in ch2 (m captains it).
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, location_hint)
  values ('chapter', v_hub, v_ch2, current_setting('test.h')::uuid, 'Review captained run', now() + interval '2 days',
          now() + interval '2 days 2 hours', 'Park')
  returning id into v_e;
  perform set_config('test.e_m', v_e::text, true);
  -- e_hidden: h hosts a plan a moderator hid.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Review hidden run', now() + interval '3 days',
          now() + interval '3 days 2 hours', 'Park')
  returning id into v_e;
  update public.events set moderation_state = 'hidden', moderated_at = now() where id = v_e;
  perform set_config('test.e_hidden', v_e::text, true);

  -- t2 blocked r1.
  insert into public.blocks (blocker_id, blocked_id)
  values (current_setting('test.t2')::uuid, current_setting('test.r1')::uuid);

  -- A place m and r2 reported.
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-srf-' || v_tag, 'SRF Court', 'court_field',
          extensions.ST_SetSRID(extensions.ST_MakePoint(-141.1, -62.1), 4326)::extensions.geography,
          true, 'active', '© OpenStreetMap contributors')
  returning id into v_pl;
  perform set_config('test.pl', v_pl::text, true);
  insert into public.place_reports (place_id, reporter_id, reason) values
    (v_pl, current_setting('test.m')::uuid, 'spam'), (v_pl, current_setting('test.r2')::uuid, 'spam');

  -- A session for c.
  insert into auth.sessions (id, user_id, created_at, updated_at)
  values (gen_random_uuid(), current_setting('test.c')::uuid, now(), now());
end $$;

-- ---------------------------------------------------------------------------
-- 2. Blocks still hide profiles both ways
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.profiles where id = current_setting('test.t2')::uuid) then
    raise exception 'FAIL 2 the blocked person reads the blocker';
  end if;
  if not exists (select 1 from public.profiles where id = current_setting('test.r2')::uuid) then
    raise exception 'FAIL 2 an ordinary profile is unreadable';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.t2'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.profiles where id = current_setting('test.r1')::uuid) then
    raise exception 'FAIL 2 the blocker reads the blocked person';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Auto-hide
-- ---------------------------------------------------------------------------
do $$
declare
  v_t  uuid := current_setting('test.t')::uuid;
  v_t2 uuid := current_setting('test.t2')::uuid;
  j    jsonb;
  r    text;
begin
  -- Three reports hide t.
  foreach r in array array['r1', 'r2', 'r3'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.' || r), 'role', 'authenticated')::text, true);
    j := public.report_content('profile', v_t, 'spam', null);
  end loop;
  if not (j->>'hidden')::boolean then
    raise exception 'FAIL 3 three reports did not hide t';
  end if;
  -- A repeat says nothing about the state.
  j := public.report_content('profile', v_t, 'spam', null);
  if not (j->>'already')::boolean or (j->>'hidden')::boolean then
    raise exception 'FAIL 3 a repeat reveals the hide';
  end if;
  -- m2 dismisses.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  perform public.mod_moderate('profile', v_t, 'dismiss', 'not spam');
  -- The same three report again: no auto-hide.
  foreach r in array array['r1', 'r2', 'r3'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.' || r), 'role', 'authenticated')::text, true);
    j := public.report_content('profile', v_t, 'spam', null);
    if (j->>'hidden')::boolean then
      raise exception 'FAIL 3 re-hidden after a dismissal';
    end if;
  end loop;
  -- t2 blocked r1: r1, r2 and r3 make only two that count.
  foreach r in array array['r1', 'r2', 'r3'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.' || r), 'role', 'authenticated')::text, true);
    j := public.report_content('profile', v_t2, 'harassment', null);
    if (j->>'hidden')::boolean then
      raise exception 'FAIL 3 a reporter the target blocked counted';
    end if;
  end loop;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r4'), 'role', 'authenticated')::text, true);
  j := public.report_content('profile', v_t2, 'harassment', null);
  if not (j->>'hidden')::boolean then
    raise exception 'FAIL 3 three other reporters did not hide t2';
  end if;
end $$;
reset role;
do $$
begin
  if (select moderation_state from public.profiles where id = current_setting('test.t')::uuid) is not null then
    raise exception 'FAIL 3 t is hidden again';
  end if;
  if (select count(*) from public.reports
       where target_kind = 'profile' and target_id = current_setting('test.t2')::uuid and status = 'open') <> 4 then
    raise exception 'FAIL 3 the blocked reporter''s report was not filed';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. A hidden plan the caller cannot read is not found
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  begin
    perform public.report_content('event', current_setting('test.e_hidden')::uuid, 'spam', null);
    raise exception 'FAIL 4 a hidden plan took a report';
  exception when others then
    if sqlerrm <> 'target_not_found' then
      raise exception 'FAIL 4 expected target_not_found, got %', sqlerrm;
    end if;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 5. Second-moderator rule
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  if not public.moderation_is_own('event', current_setting('test.e_m')::uuid, current_setting('test.h')::uuid) then
    raise exception 'FAIL 5 a plan in the moderator''s chapter is not their own';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  if public.moderation_is_own('event', current_setting('test.e_m')::uuid, current_setting('test.h')::uuid) then
    raise exception 'FAIL 5 another moderator may not act';
  end if;
end $$;
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  select x into j from jsonb_array_elements(public.mod_queue(500)) x
   where x->>'source' = 'place_report' and x->>'id' = current_setting('test.pl');
  if j is null or (j->>'can_act')::boolean then
    raise exception 'FAIL 5 a moderator who reported the place may act';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  select x into j from jsonb_array_elements(public.mod_queue(500)) x
   where x->>'source' = 'place_report' and x->>'id' = current_setting('test.pl');
  if j is null or not (j->>'can_act')::boolean then
    raise exception 'FAIL 5 another moderator may not act on the place';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 6. Leadership needs an active account
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c2'), 'role', 'authenticated')::text, true);
  if not public.is_chapter_captain(current_setting('test.ch')::uuid)
     or not public.viewer_can_manage_event(current_setting('test.e_live')::uuid) then
    raise exception 'FAIL 6 an active captain does not manage';
  end if;
  update public.profiles set status = 'suspended' where id = current_setting('test.c2')::uuid;
  if public.is_chapter_captain(current_setting('test.ch')::uuid)
     or public.viewer_can_manage_event(current_setting('test.e_live')::uuid) then
    raise exception 'FAIL 6 a suspended captain still manages';
  end if;
  update public.profiles set status = 'active' where id = current_setting('test.c2')::uuid;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Ban
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  j := public.mod_ban_user(current_setting('test.c')::uuid, 'test ban');
  if (j->>'chapter_roles_removed')::integer <> 1 or (j->>'chapters_need_organizer')::integer <> 1
     or (j->>'events_cancelled')::integer < 1 then
    raise exception 'FAIL 7 ban answer';
  end if;
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.chapter_members
              where user_id = current_setting('test.c')::uuid and role <> 'member') then
    raise exception 'FAIL 7 the banned person kept a chapter role';
  end if;
  if (select role from public.chapter_members
       where user_id = current_setting('test.c2')::uuid and chapter_id = current_setting('test.ch')::uuid) <> 'captain' then
    raise exception 'FAIL 7 another captain lost the role';
  end if;
  if not exists (select 1 from public.reports
                  where target_kind = 'chapter' and target_id = current_setting('test.ch')::uuid
                    and status = 'open' and reporter_id is null) then
    raise exception 'FAIL 7 no review report for the chapter';
  end if;
  if (select status from public.events where id = current_setting('test.e_live')::uuid) <> 'cancelled' then
    raise exception 'FAIL 7 the plan under way was not cancelled';
  end if;
  if exists (select 1 from auth.sessions where user_id = current_setting('test.c')::uuid) then
    raise exception 'FAIL 7 sessions survived the ban';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. mod_user_search records the account; 200 a day
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_user_search(current_setting('test.t'));
  j := public.mod_user_search('srf-r4-' || current_setting('test.tag') || '@example.com');
  if jsonb_array_length(j) <> 1 then
    raise exception 'FAIL 8 email search';
  end if;
  j := public.mod_user_search('nobody-' || current_setting('test.tag') || '@example.com');
end $$;
reset role;
do $$
declare
  v_m uuid := current_setting('test.m')::uuid;
begin
  if not exists (select 1 from public.admin_lookups
                  where moderator_id = v_m and via = 'id' and target_user_id = current_setting('test.t')::uuid)
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = v_m and via = 'email' and target_user_id = current_setting('test.r4')::uuid
                       and query is null)
     or not exists (select 1 from public.admin_lookups
                     where moderator_id = v_m and via = 'email' and target_user_id is null and result_count = 0) then
    raise exception 'FAIL 8 searches do not record the account';
  end if;
  insert into public.admin_lookups (moderator_id, via, query, result_count)
  select current_setting('test.m2')::uuid, 'handle', 'ab', 0 from generate_series(1, 200);
end $$;
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_user_search('srf');
    raise exception 'FAIL 8 the 201st search ran';
  exception when others then
    if sqlerrm <> 'rate_limited' then
      raise exception 'FAIL 8 expected rate_limited, got %', sqlerrm;
    end if;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 9. submit_takedown_request
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag    text := current_setting('test.tag');
  v_client text := repeat('c', 64);
  j        jsonb;
begin
  for i in 1..5 loop
    j := public.submit_takedown_request('Pat Requester', 'srf-' || i || '-' || v_tag || '@example.com', 'self',
                                        'a profile photo', true, 'Pat Requester', '', false, v_client);
  end loop;
  begin
    perform public.submit_takedown_request('Pat Requester', 'srf-6-' || v_tag || '@example.com', 'self',
                                           'a profile photo', true, 'Pat Requester', '', false, v_client);
    raise exception 'FAIL 9 a sixth request from one client';
  exception when others then
    if sqlerrm <> 'rate_limited' then
      raise exception 'FAIL 9 expected rate_limited for the client, got %', sqlerrm;
    end if;
  end;
  for i in 1..3 loop
    j := public.submit_takedown_request('Pat Requester', 'srf-same-' || v_tag || '@example.com', 'self',
                                        'a profile photo', true, 'Pat Requester', '', false, repeat(i::text, 64));
  end loop;
  begin
    perform public.submit_takedown_request('Pat Requester', 'srf-same-' || v_tag || '@example.com', 'self',
                                           'a profile photo', true, 'Pat Requester', '', false, repeat('d', 64));
    raise exception 'FAIL 9 a fourth request from one email';
  exception when others then
    if sqlerrm <> 'rate_limited' then
      raise exception 'FAIL 9 expected rate_limited for the email, got %', sqlerrm;
    end if;
  end;
  begin
    perform public.submit_takedown_request('Pat Requester', 'srf-bad-' || v_tag || '@example.com', 'self',
                                           'a profile photo', true, 'Pat Requester', '', false, 'not-a-hash');
    raise exception 'FAIL 9 a malformed client hash was taken';
  exception when others then
    if sqlerrm <> 'bad_request' then
      raise exception 'FAIL 9 expected bad_request, got %', sqlerrm;
    end if;
  end;
end $$;
reset role;
do $$
begin
  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship, locations,
                                        good_faith, signature, priority, due_at)
  select 'SRF-' || current_setting('test.tag') || '-' || g, 'Flood', 'flood-' || g || '@example.com', repeat('f', 64),
         'self', 'x', true, 'Flood', 1, now() + interval '48 hours'
    from generate_series(1, 200) g;
end $$;
set local role service_role;
do $$
declare
  j jsonb;
begin
  j := public.submit_takedown_request('Real Person', 'srf-real-' || current_setting('test.tag') || '@example.com', 'self',
                                      'a profile photo', true, 'Real Person', '', false, repeat('e', 64));
  perform set_config('test.real', j->>'reference', true);
  j := public.submit_takedown_request('Real Minor', 'srf-minor-' || current_setting('test.tag') || '@example.com', 'self',
                                      'a profile photo', true, 'Real Minor', '', true, repeat('9', 64));
  perform set_config('test.minor', j->>'reference', true);
end $$;
reset role;
do $$
begin
  if (select priority from public.takedown_requests where reference = current_setting('test.real')) <> 2
     or (select due_at from public.takedown_requests where reference = current_setting('test.real'))
          < now() + interval '47 hours' then
    raise exception 'FAIL 9 past the hourly cap: not taken at priority 2 with a 48-hour due time';
  end if;
  if (select priority from public.takedown_requests where reference = current_setting('test.minor')) <> 0 then
    raise exception 'FAIL 9 a minor request lost priority 0';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Purge
-- ---------------------------------------------------------------------------
do $$
declare
  v_old uuid;
begin
  insert into public.takedown_requests (reference, requester_name, requester_email, email_hash, relationship, locations,
                                        good_faith, signature, priority, due_at, status, resolved_at, created_at,
                                        client_hash)
  values ('SRF-OLD-' || current_setting('test.tag'), 'Old Requester', 'old@example.com', repeat('a', 64), 'self', 'x',
          true, 'Old Requester', 1, now() - interval '398 days', 'rejected', now() - interval '397 days',
          now() - interval '400 days', repeat('b', 64))
  returning id into v_old;
  perform set_config('test.old', v_old::text, true);
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
  values (current_setting('test.m2')::uuid, 'ncii_reject', 'takedown', v_old, 'rejected: Old Requester wrote from old@example.com');
  perform public.purge_takedown_contacts();
  if (select note from public.moderation_actions where target_id = v_old and action = 'ncii_reject') <> 'rejected' then
    raise exception 'FAIL 10 the log note kept the free text';
  end if;
  if (select client_hash from public.takedown_requests where id = v_old) is not null then
    raise exception 'FAIL 10 an old client hash stayed';
  end if;
  if (select client_hash from public.takedown_requests where reference = current_setting('test.real')) is null then
    raise exception 'FAIL 10 a fresh client hash was cleared';
  end if;
end $$;

select 'safety_review_fixes: PASS' as result;

rollback;
