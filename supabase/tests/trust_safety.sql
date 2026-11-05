-- ============================================================================
-- Staging check for migration 20261215000100_trust_safety.sql (migration 51).
-- One transaction: sets up throwaway accounts, a chapter and plans, asserts
-- with DO blocks that raise on failure, then rolls everything back. Prints
-- pass/fail only (no user rows; the test accounts are invented).
-- Run as the staging_file of a staging_only migrate.yml run.
--
--   1 static: schema_version 2.47, grants on tables and functions.
--   2 blocks are symmetric across profiles, rsvps, hub_members and
--     chapter_members; my_blocks, event_block_warning, is_blocked_with.
--   3 co-attendance warning both ways; attendee_joined dropped for a mute.
--   4 meets across a block are dropped; pending_attendance_prompts leaves
--     the blocked person out.
--   5 reports: repeat, own item, place hand-over, new accounts do not count,
--     auto-hide at three for a plan, a profile and a chapter, never a hub.
--   6 a hidden plan: unreadable to others and anon, no share card, no new
--     RSVP; the host still reads it.
--   7 moderators: queue, second-moderator rule, dismiss, remove (soft
--     delete) of a plan and a profile, restore of a chapter.
--   8 ban and unban; only an admin bans a moderator; nobody bans an admin.
--   9 admin_set_moderator and mod_team.
--  10 account deletion clears blocks, mutes and the reporter link.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.47' then
    raise exception 'FAIL 1 schema_version is not 2.47';
  end if;
  if has_table_privilege('authenticated', 'public.blocks', 'insert')
     or has_table_privilege('authenticated', 'public.mutes', 'insert')
     or has_table_privilege('authenticated', 'public.reports', 'insert')
     or has_table_privilege('authenticated', 'public.reports', 'update')
     or has_table_privilege('authenticated', 'public.moderation_actions', 'insert')
     or has_table_privilege('anon', 'public.blocks', 'select')
     or has_table_privilege('anon', 'public.reports', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if has_column_privilege('authenticated', 'public.reports', 'reporter_id', 'select')
     or has_column_privilege('authenticated', 'public.reports', 'resolved_by', 'select')
     or not has_column_privilege('authenticated', 'public.reports', 'status', 'select') then
    raise exception 'FAIL 1 reports column grants';
  end if;
  if has_function_privilege('anon', 'public.is_blocked_with(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.is_blocked_with(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.users_blocked(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.moderation_set_state(text,uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.moderation_is_own(text,uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.enqueue_notification(uuid,public.notification_kind,text,uuid,uuid,uuid,uuid,jsonb,boolean)', 'execute')
     or has_function_privilege('anon', 'public.report_content(text,uuid,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.report_content(text,uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'public.block_user(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mod_ban_user(uuid,text)', 'execute')
     or not has_function_privilege('anon', 'public.event_share_card(uuid)', 'execute')
     or not has_function_privilege('anon', 'public.chapter_public_card(text)', 'execute')
     or has_function_privilege('anon', 'public.can_read_event(uuid)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'notification_kind' and e.enumlabel = 'blocked_attendee') then
    raise exception 'FAIL 1 notification_kind has no blocked_attendee';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['a', 'b', 'h', 'r1', 'r2', 'r3', 'r4', 'n', 'x', 'm', 'm2', 'adm'];
  v_id    uuid;
  v_hub   uuid;
  v_hub2  uuid;
  v_atl   uuid;
  v_ch    uuid;
  v_e     uuid;
  v_h     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ts-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = case when v_names[i] = 'n' then now() else now() - interval '3 days' end
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  update public.profiles set bio = 'Test bio' where id = current_setting('test.b')::uuid;
  insert into public.user_roles (user_id, role) values
    (current_setting('test.m')::uuid, 'moderator'),
    (current_setting('test.m2')::uuid, 'moderator'),
    (current_setting('test.adm')::uuid, 'admin');
  v_h := current_setting('test.h')::uuid;

  select id into v_atl from public.areas where slug = 'atlanta';
  if v_atl is null then raise exception 'FAIL setup: no atlanta area'; end if;
  select h.id into v_hub from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
     and not exists (select 1 from public.hub_chapters ch
                      where ch.hub_id = h.id and ch.area_id = v_atl and ch.org_id is null and ch.campus_id is null)
   order by h.slug limit 1;
  select h.id into v_hub2 from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.id <> v_hub
   order by h.slug desc limit 1;
  if v_hub is null or v_hub2 is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.hub2', v_hub2::text, true);

  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_atl, 'ts-' || v_tag, 'Trust Test Chapter')
  returning id into v_ch;
  perform set_config('test.ch', v_ch::text, true);
  insert into public.hub_members (user_id, hub_id) values
    (current_setting('test.a')::uuid, v_hub), (current_setting('test.b')::uuid, v_hub);
  insert into public.chapter_members (user_id, chapter_id, role) values
    (current_setting('test.a')::uuid, v_ch, 'member'), (current_setting('test.b')::uuid, v_ch, 'member');

  -- e1: upcoming, a and b going.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Trust main run', now() + interval '2 days', now() + interval '2 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values
    (v_e, current_setting('test.a')::uuid, 'going'), (v_e, current_setting('test.b')::uuid, 'going');
  -- e2, e3: upcoming, empty (RSVPs come through set_rsvp below).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Trust second run', now() + interval '3 days', now() + interval '3 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e2', v_e::text, true);
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Trust third run', now() + interval '4 days', now() + interval '4 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e3', v_e::text, true);
  -- p: ended a day ago; a, b and r1 going.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Trust past run', now() - interval '1 day 2 hours', now() - interval '1 day', 'Midtown')
  returning id into v_e;
  perform set_config('test.p', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values
    (v_e, current_setting('test.a')::uuid, 'going'), (v_e, current_setting('test.b')::uuid, 'going'),
    (v_e, current_setting('test.r1')::uuid, 'going');
  -- e4: hosted by x, r4 going (for the ban).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.x')::uuid, 'Trust x run', now() + interval '5 days',
          now() + interval '5 days 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e4', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.r4')::uuid, 'going');
  insert into public.rsvps (event_id, user_id, status)
  values (current_setting('test.e1')::uuid, current_setting('test.x')::uuid, 'going');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Blocks are symmetric
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_e1 uuid := current_setting('test.e1')::uuid;
  j    jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.profiles where id = v_a)
     or not exists (select 1 from public.rsvps where event_id = v_e1 and user_id = v_a)
     or not exists (select 1 from public.hub_members where user_id = v_a)
     or not exists (select 1 from public.chapter_members where user_id = v_a) then
    raise exception 'FAIL 2 b cannot see a before the block';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    perform public.block_user(v_a);
    raise exception 'FAIL 2 self block accepted';
  exception when others then
    if sqlerrm <> 'cannot_block_self' then raise exception 'FAIL 2 self block: %', sqlerrm; end if;
  end;
  j := public.block_user(v_b);
  if not (j ->> 'blocked')::boolean or (j ->> 'already')::boolean or (j ->> 'shared_upcoming')::integer <> 1 then
    raise exception 'FAIL 2 block_user answer %', j;
  end if;
  j := public.block_user(v_b);
  if not (j ->> 'already')::boolean then raise exception 'FAIL 2 repeat block not already'; end if;

  -- a no longer sees b ...
  if exists (select 1 from public.profiles where id = v_b)
     or exists (select 1 from public.rsvps where event_id = v_e1 and user_id = v_b)
     or exists (select 1 from public.hub_members where user_id = v_b)
     or exists (select 1 from public.chapter_members where user_id = v_b) then
    raise exception 'FAIL 2 a still sees b';
  end if;
  if not public.is_blocked_with(v_b) then raise exception 'FAIL 2 is_blocked_with for a'; end if;
  if (select count(*) from public.my_blocks() where user_id = v_b) <> 1 then raise exception 'FAIL 2 my_blocks'; end if;
  if public.event_block_warning(v_e1) <> 1 then raise exception 'FAIL 2 event_block_warning for a'; end if;
  if (select count(*) from public.blocks) <> 1 then raise exception 'FAIL 2 a reads own block'; end if;

  -- ... and b no longer sees a, cannot tell who blocked them beyond that.
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  if exists (select 1 from public.profiles where id = v_a)
     or exists (select 1 from public.rsvps where event_id = v_e1 and user_id = v_a)
     or exists (select 1 from public.hub_members where user_id = v_a)
     or exists (select 1 from public.chapter_members where user_id = v_a) then
    raise exception 'FAIL 2 b still sees a';
  end if;
  if not exists (select 1 from public.rsvps where event_id = v_e1 and user_id = current_setting('test.h')::uuid) then
    raise exception 'FAIL 2 b lost an unrelated RSVP row';
  end if;
  if not public.is_blocked_with(v_a) then raise exception 'FAIL 2 is_blocked_with for b'; end if;
  if exists (select 1 from public.blocks) then raise exception 'FAIL 2 b reads the block row'; end if;
  if public.event_block_warning(v_e1) <> 0 then raise exception 'FAIL 2 event_block_warning for b'; end if;
  if (select count(*) from public.my_blocks()) <> 0 then raise exception 'FAIL 2 my_blocks for b'; end if;

  -- An unrelated person still sees both.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  if (select count(*) from public.profiles where id in (v_a, v_b)) <> 2 then raise exception 'FAIL 2 bystander'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Co-attendance warning and the mute
-- ---------------------------------------------------------------------------
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_h  uuid := current_setting('test.h')::uuid;
  v_e2 uuid := current_setting('test.e2')::uuid;
  v_e3 uuid := current_setting('test.e3')::uuid;
  r    public.rsvps;
  j    jsonb;
begin
  -- h mutes r1.
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  j := public.mute_user(current_setting('test.r1')::uuid);
  if not (j ->> 'muted')::boolean or (j ->> 'already')::boolean then raise exception 'FAIL 3 mute %', j; end if;
  if (select count(*) from public.mutes) <> 1 then raise exception 'FAIL 3 h reads own mute'; end if;

  -- e2: a (the blocker) goes first, then b: a is warned, b is not.
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e2, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e2, 'going');
  if r.status <> 'going' then raise exception 'FAIL 3 b could not RSVP'; end if;
  -- r1 (muted by the host) and then r2 go.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e2, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r2'), 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e2, 'going');

  -- e3: b goes first, then a (the newcomer who blocked b is warned).
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e3, 'going');
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  r := public.set_rsvp(v_e3, 'going');
end $$;
reset role;
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_h  uuid := current_setting('test.h')::uuid;
  v_e2 uuid := current_setting('test.e2')::uuid;
  v_e3 uuid := current_setting('test.e3')::uuid;
  n    record;
begin
  if not exists (select 1 from public.notifications where user_id = v_a and event_id = v_e2
                  and kind = 'blocked_attendee' and actor_id is null) then
    raise exception 'FAIL 3 a not warned on e2';
  end if;
  if exists (select 1 from public.notifications where user_id = v_b and kind = 'blocked_attendee') then
    raise exception 'FAIL 3 the blocked person was told';
  end if;
  if not exists (select 1 from public.notifications where user_id = v_a and event_id = v_e3 and kind = 'blocked_attendee') then
    raise exception 'FAIL 3 a not warned as the newcomer on e3';
  end if;
  select * into n from public.notifications where user_id = v_h and event_id = v_e2 and kind = 'attendee_joined';
  if not found or (n.payload ->> 'count')::integer <> 3 then
    raise exception 'FAIL 3 attendee_joined count % (a, b, r2; the muted r1 left out)', n.payload ->> 'count';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Meets across a block
-- ---------------------------------------------------------------------------
do $$
declare
  v_p uuid := current_setting('test.p')::uuid;
begin
  insert into public.event_meets (event_id, user_id, met_user_id) values
    (v_p, current_setting('test.a')::uuid, current_setting('test.b')::uuid),
    (v_p, current_setting('test.b')::uuid, current_setting('test.a')::uuid),
    (v_p, current_setting('test.a')::uuid, current_setting('test.r1')::uuid);
  if (select count(*) from public.event_meets where event_id = v_p) <> 1 then
    raise exception 'FAIL 4 a meet across the block was kept';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v_att jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  select attendees into v_att from public.pending_attendance_prompts() where event_id = current_setting('test.p')::uuid;
  if v_att is null then raise exception 'FAIL 4 no prompt for a'; end if;
  if v_att @> jsonb_build_array(jsonb_build_object('id', current_setting('test.b')))
     or not v_att @> jsonb_build_array(jsonb_build_object('id', current_setting('test.r1'))) then
    raise exception 'FAIL 4 prompt attendees across the block';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5 and 6. Reports, auto-hide, a hidden plan
-- ---------------------------------------------------------------------------
do $$
declare
  v_e1  uuid := current_setting('test.e1')::uuid;
  v_b   uuid := current_setting('test.b')::uuid;
  v_ch  uuid := current_setting('test.ch')::uuid;
  v_hub uuid := current_setting('test.hub2')::uuid;
  v_who text;
  j     jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  begin
    perform public.report_content('event', v_e1, 'scam', null);
    raise exception 'FAIL 5 own plan report accepted';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 5 own plan: %', sqlerrm; end if;
  end;
  begin
    perform public.report_content('event', v_e1, 'nonsense', null);
    raise exception 'FAIL 5 bad reason accepted';
  exception when others then
    if sqlerrm <> 'invalid_reason' then raise exception 'FAIL 5 bad reason: %', sqlerrm; end if;
  end;
  begin
    perform public.report_content('place', gen_random_uuid(), 'spam', null);
    raise exception 'FAIL 5 place report on nothing accepted';
  exception when others then
    if sqlerrm <> 'place_not_found' then raise exception 'FAIL 5 place hand-over: %', sqlerrm; end if;
  end;

  -- r1, then n (new account: does not count), then r2: still visible.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  j := public.report_content('event', v_e1, 'scam', 'Asked for money up front');
  if (j ->> 'already')::boolean or (j ->> 'hidden')::boolean then raise exception 'FAIL 5 first report %', j; end if;
  j := public.report_content('event', v_e1, 'spam', null);
  if not (j ->> 'already')::boolean then raise exception 'FAIL 5 repeat not already'; end if;
  if (select count(*) from public.reports) <> 1 then raise exception 'FAIL 5 reporter reads own report'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.n'), 'role', 'authenticated')::text, true);
  j := public.report_content('event', v_e1, 'scam', null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r2'), 'role', 'authenticated')::text, true);
  j := public.report_content('event', v_e1, 'scam', null);
  if (j ->> 'hidden')::boolean then raise exception 'FAIL 5 hidden at two counted reports'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r3'), 'role', 'authenticated')::text, true);
  j := public.report_content('event', v_e1, 'scam', null);
  if not (j ->> 'hidden')::boolean then raise exception 'FAIL 5 not hidden at three'; end if;

  -- 6: the hidden plan.
  if exists (select 1 from public.events where id = v_e1) or public.can_read_event(v_e1) then
    raise exception 'FAIL 6 a reporter still reads the hidden plan';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r4'), 'role', 'authenticated')::text, true);
  begin
    perform public.set_rsvp(v_e1, 'going');
    raise exception 'FAIL 6 RSVP to a hidden plan accepted';
  exception when others then
    if sqlerrm <> 'event_not_found' then raise exception 'FAIL 6 RSVP hidden: %', sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.events where id = v_e1 and moderation_state = 'hidden') then
    raise exception 'FAIL 6 the host lost the hidden plan';
  end if;
  if public.event_share_card(v_e1) is not null then raise exception 'FAIL 6 share card for a hidden plan'; end if;

  -- Profile b: three reports hide it from others, never from b.
  foreach v_who in array array['r1', 'r2', 'r3'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.' || v_who), 'role', 'authenticated')::text, true);
    j := public.report_content('profile', v_b, 'harassment', null);
  end loop;
  if not (j ->> 'hidden')::boolean then raise exception 'FAIL 5 profile not hidden at three'; end if;
  if exists (select 1 from public.profiles where id = v_b) then raise exception 'FAIL 5 hidden profile readable'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.profiles where id = v_b) then raise exception 'FAIL 5 b lost own profile'; end if;
  begin
    perform public.report_content('profile', v_b, 'harassment', null);
    raise exception 'FAIL 5 self report accepted';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 5 self report: %', sqlerrm; end if;
  end;

  -- Chapter: hidden and inactive at three. Hub: never auto-hidden.
  foreach v_who in array array['r1', 'r2', 'r3'] loop
    perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.' || v_who), 'role', 'authenticated')::text, true);
    j := public.report_content('chapter', v_ch, 'spam', null);
    j := public.report_content('hub', v_hub, 'other', null);
  end loop;
  if (j ->> 'hidden')::boolean then raise exception 'FAIL 5 hub auto-hidden'; end if;
  if exists (select 1 from public.hub_chapters where id = v_ch) then raise exception 'FAIL 5 hidden chapter readable'; end if;
  if not exists (select 1 from public.hubs where id = v_hub) then raise exception 'FAIL 5 reported hub went'; end if;
end $$;
reset role;
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
begin
  if exists (select 1 from public.events where id = current_setting('test.e1')::uuid) then
    raise exception 'FAIL 6 anon reads the hidden plan';
  end if;
  if public.event_share_card(current_setting('test.e1')::uuid) is not null then
    raise exception 'FAIL 6 anon share card for a hidden plan';
  end if;
end $$;
reset role;
do $$
begin
  if (select is_active from public.hub_chapters where id = current_setting('test.ch')::uuid)
     or (select moderation_state from public.hub_chapters where id = current_setting('test.ch')::uuid) <> 'hidden' then
    raise exception 'FAIL 5 chapter state';
  end if;
  if (select count(*) from public.moderation_actions
       where action = 'auto_hide' and moderator_id is null
         and target_id in (current_setting('test.e1')::uuid, current_setting('test.b')::uuid,
                           current_setting('test.ch')::uuid)) <> 3 then
    raise exception 'FAIL 5 auto_hide log';
  end if;
  if (select priority from public.reports where target_id = current_setting('test.e1')::uuid limit 1) <> 2
     or (select max(due_at) from public.reports where target_id = current_setting('test.e1')::uuid) > now() + interval '25 hours' then
    raise exception 'FAIL 5 SLA fields';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Moderators
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e1  uuid := current_setting('test.e1')::uuid;
  v_b   uuid := current_setting('test.b')::uuid;
  v_ch  uuid := current_setting('test.ch')::uuid;
  v_hub uuid := current_setting('test.hub2')::uuid;
  q     jsonb;
  it    jsonb;
  j     jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_report_queue(100);
    raise exception 'FAIL 7 queue for a member';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 7 queue member: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_moderate('event', v_e1, 'dismiss', null);
    raise exception 'FAIL 7 member moderated';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 7 member moderate: %', sqlerrm; end if;
  end;

  -- m reports the hub, so m cannot act on it; m2 can.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.report_content('hub', v_hub, 'spam', null);
  q := public.mod_report_queue(500);
  select x into it from jsonb_array_elements(q) x where x ->> 'target_id' = v_e1::text;
  if it is null or (it ->> 'report_count')::integer <> 4 or (it ->> 'reporter_count')::integer <> 4
     or it ->> 'state' <> 'hidden' or not (it ->> 'can_act')::boolean or (it -> 'reasons' ->> 'scam')::integer <> 4
     or it ? 'reporter_ids' or it::text like '%' || current_setting('test.r1') || '%' then
    raise exception 'FAIL 7 queue item for e1 %', it;
  end if;
  select x into it from jsonb_array_elements(q) x where x ->> 'target_id' = v_hub::text;
  if it is null or (it ->> 'can_act')::boolean then raise exception 'FAIL 7 hub item can_act for its reporter'; end if;
  begin
    perform public.mod_moderate('hub', v_hub, 'dismiss', null);
    raise exception 'FAIL 7 own report acted on';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 7 own report: %', sqlerrm; end if;
  end;

  -- Dismiss the plan's reports: visible again.
  j := public.mod_moderate('event', v_e1, 'dismiss', 'Not a scam');
  if (j ->> 'reports_closed')::integer <> 4 or j ->> 'state' is not null then raise exception 'FAIL 7 dismiss %', j; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.events where id = v_e1) then raise exception 'FAIL 7 dismissed plan still hidden'; end if;

  -- Soft delete the plan: removed, cancelled, the audience told without a moderator name.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  j := public.mod_moderate('event', v_e1, 'remove', null);
  if j ->> 'state' <> 'removed' then raise exception 'FAIL 7 remove %', j; end if;
  -- Soft delete b's profile content; restore the chapter.
  j := public.mod_moderate('profile', v_b, 'remove', 'Abusive bio');
  j := public.mod_moderate('chapter', v_ch, 'restore', null);

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  j := public.mod_moderate('hub', v_hub, 'dismiss', null);
  if (j ->> 'reports_closed')::integer <> 4 then raise exception 'FAIL 7 m2 hub dismiss %', j; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.events where id = v_e1) then raise exception 'FAIL 7 removed plan readable'; end if;
  if not exists (select 1 from public.profiles where id = v_b and avatar_url is null and bio = '') then
    raise exception 'FAIL 7 removed profile not readable or not cleared';
  end if;
  if not exists (select 1 from public.hub_chapters where id = v_ch and is_active) then raise exception 'FAIL 7 chapter not restored'; end if;
end $$;
reset role;
do $$
declare
  v_e1 uuid := current_setting('test.e1')::uuid;
begin
  if (select status from public.events where id = v_e1) <> 'cancelled'
     or (select cancel_reason from public.events where id = v_e1) <> 'moderator_removed' then
    raise exception 'FAIL 7 removed plan not cancelled';
  end if;
  if not exists (select 1 from public.notifications where user_id = current_setting('test.a')::uuid and event_id = v_e1
                  and kind = 'event_cancelled' and actor_id is null and payload ->> 'reason' = 'moderator_removed') then
    raise exception 'FAIL 7 attendee not told of the removal';
  end if;
  if (select snapshot ->> 'bio' from public.moderation_actions
       where action = 'remove' and target_id = current_setting('test.b')::uuid) <> 'Test bio' then
    raise exception 'FAIL 7 profile snapshot';
  end if;
  if exists (select 1 from public.reports where target_id = v_e1 and status = 'open') then
    raise exception 'FAIL 7 open reports left on e1';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Ban and unban
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_x  uuid := current_setting('test.x')::uuid;
  j    jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.mod_ban_user(current_setting('test.m2')::uuid, null);
    raise exception 'FAIL 8 a moderator banned a moderator';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 8 mod bans mod: %', sqlerrm; end if;
  end;
  begin
    perform public.mod_ban_user(current_setting('test.adm')::uuid, null);
    raise exception 'FAIL 8 an admin was banned';
  exception when others then
    if sqlerrm <> 'cannot_ban_admin' then raise exception 'FAIL 8 ban admin: %', sqlerrm; end if;
  end;
  j := public.mod_ban_user(v_x, 'Scam reports');
  if not (j ->> 'banned')::boolean or (j ->> 'events_cancelled')::integer <> 1 or (j ->> 'rsvps_removed')::integer <> 0 then
    -- x's RSVP on e1 is on a plan removed (cancelled) above, so nothing live is left there.
    raise exception 'FAIL 8 ban answer %', j;
  end if;
  j := public.mod_ban_user(v_x, null);
  if not (j ->> 'already')::boolean then raise exception 'FAIL 8 repeat ban'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_x, 'role', 'authenticated')::text, true);
  if public.viewer_is_adult() then raise exception 'FAIL 8 banned account still reads'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r4'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.profiles where id = v_x) then raise exception 'FAIL 8 banned profile readable'; end if;
end $$;
reset role;
do $$
declare
  v_x uuid := current_setting('test.x')::uuid;
begin
  if (select banned_until from auth.users where id = v_x) < now() + interval '50 years'
     or (select status from public.profiles where id = v_x) <> 'banned' then
    raise exception 'FAIL 8 ban not recorded';
  end if;
  if (select status from public.events where id = current_setting('test.e4')::uuid) <> 'cancelled'
     or not exists (select 1 from public.notifications where user_id = current_setting('test.r4')::uuid
                     and event_id = current_setting('test.e4')::uuid and kind = 'event_cancelled') then
    raise exception 'FAIL 8 the banned host''s plan not cancelled or audience not told';
  end if;
end $$;
set local role authenticated;
do $$
declare
  j jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m2'), 'role', 'authenticated')::text, true);
  j := public.mod_unban_user(current_setting('test.x')::uuid, null);
  if not (j ->> 'unbanned')::boolean then raise exception 'FAIL 8 unban'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  if not public.viewer_is_adult() then raise exception 'FAIL 8 unbanned account cannot read'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. The moderator role
-- ---------------------------------------------------------------------------
do $$
declare
  v_r3 uuid := current_setting('test.r3')::uuid;
  j    jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.admin_set_moderator(v_r3, true, null);
    raise exception 'FAIL 9 a moderator granted a role';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 9 mod grants: %', sqlerrm; end if;
  end;
  -- r3 reports r4 before becoming a moderator.
  perform set_config('request.jwt.claims', json_build_object('sub', v_r3, 'role', 'authenticated')::text, true);
  j := public.report_content('profile', current_setting('test.r4')::uuid, 'impersonation', null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.adm'), 'role', 'authenticated')::text, true);
  begin
    perform public.admin_set_moderator(current_setting('test.adm')::uuid, false, null);
    raise exception 'FAIL 9 an admin changed their own role';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 9 own role: %', sqlerrm; end if;
  end;
  j := public.admin_set_moderator(v_r3, true, 'Second moderator');
  if not (j ->> 'changed')::boolean then raise exception 'FAIL 9 grant'; end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_r3, 'role', 'authenticated')::text, true);
  if not public.is_moderator() then raise exception 'FAIL 9 r3 is not a moderator'; end if;
  if not exists (select 1 from jsonb_array_elements(public.mod_team()) t where t ->> 'user_id' = v_r3::text) then
    raise exception 'FAIL 9 mod_team';
  end if;
  -- r3 filed the open report on r4: the second-moderator rule keeps r3 off it.
  begin
    perform public.mod_moderate('profile', current_setting('test.r4')::uuid, 'dismiss', null);
    raise exception 'FAIL 9 r3 acted on a profile they reported';
  exception when others then
    if sqlerrm <> 'own_item' then raise exception 'FAIL 9 r3 own: %', sqlerrm; end if;
  end;
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.adm'), 'role', 'authenticated')::text, true);
  j := public.admin_set_moderator(v_r3, false, null);
  if not (j ->> 'changed')::boolean then raise exception 'FAIL 9 revoke'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 10. Account deletion
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.r1'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.blocks where blocker_id = current_setting('test.a')::uuid
                                         or blocked_id = current_setting('test.a')::uuid) then
    raise exception 'FAIL 10 blocks left after deletion';
  end if;
  if exists (select 1 from public.mutes where muted_id = current_setting('test.r1')::uuid) then
    raise exception 'FAIL 10 mutes left after deletion';
  end if;
  if exists (select 1 from public.reports where reporter_id = current_setting('test.r1')::uuid)
     or not exists (select 1 from public.reports where target_id = current_setting('test.e1')::uuid
                     and reporter_id is null and note = '' and reason = 'scam') then
    raise exception 'FAIL 10 reports not anonymized';
  end if;
end $$;

select 'trust_safety: PASS' as result;

rollback;
