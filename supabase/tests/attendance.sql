-- ============================================================================
-- Staging check for migration 20261115000100_attendance.sql. One transaction:
-- throwaway users, an area chapter with a captain, past and future events;
-- DO blocks raise on failure; ROLLBACK at the end. Prints only pass/fail,
-- never user rows.
--   1 submit_attendance: before the end, after 7 days, a met id who was not
--     going, the caller as a met id and 31 ids are refused.
--   2 a self-report leaves checked_in_at null and stamps
--     attended_self_reported_at; a checked-in attendee keeps checked_in_at
--     and gets no self-report; the checkin_prompt is marked read.
--   3 re-submitting replaces the caller's meets.
--   4 pending_attendance_prompts excludes answered and dismissed events and
--     lists the other going attendees (id, first_name, avatar_url only).
--   5 another user cannot read the caller's reports or meets; no client writes.
--   6 chapter_dashboard: refused for a non-manager; counts for a captain.
--   7 account deletion removes the user's reports and meets, both directions.
--   8 schema_version 2.16.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['h', 'a', 'b', 'c', 'x', 'k', 'n'];
  v_id    uuid;
  v_hub   uuid;
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
            'att-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  v_h := current_setting('test.h')::uuid;

  select id into v_atl from public.areas where slug = 'atlanta';
  if v_atl is null then raise exception 'FAIL setup: no atlanta area'; end if;
  select h.id into v_hub from public.hubs h
   where h.is_active and h.min_age = 18 and h.scope = 'general'
     and not exists (select 1 from public.hub_chapters ch
                      where ch.hub_id = h.id and ch.area_id = v_atl and ch.org_id is null and ch.campus_id is null)
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;

  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_atl, 'att-' || v_tag, 'Attendance Test Chapter')
  returning id into v_ch;
  insert into public.chapter_members (user_id, chapter_id, role)
  values (current_setting('test.k')::uuid, v_ch, 'captain');
  perform set_config('test.ch', v_ch::text, true);

  -- e0: chapter event 10 days ago (a checked in: makes a "returning" at e1).
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, location_hint)
  values ('chapter', v_hub, v_ch, v_h, 'Attendance earlier run', now() - interval '10 days 2 hours',
          now() - interval '10 days', 'Midtown')
  returning id into v_e;
  perform set_config('test.e0', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status, checked_in_at)
  values (v_e, current_setting('test.a')::uuid, 'going', now() - interval '10 days 1 hour');

  -- e1: chapter event that ended a day ago; a, b, c going (c checked in), x interested.
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, location_hint)
  values ('chapter', v_hub, v_ch, v_h, 'Attendance main run', now() - interval '1 day 2 hours',
          now() - interval '1 day', 'Midtown')
  returning id into v_e;
  perform set_config('test.e1', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values
    (v_e, current_setting('test.a')::uuid, 'going'),
    (v_e, current_setting('test.b')::uuid, 'going'),
    (v_e, current_setting('test.x')::uuid, 'interested');
  insert into public.rsvps (event_id, user_id, status, checked_in_at, checked_in_by)
  values (v_e, current_setting('test.c')::uuid, 'going', now() - interval '1 day 1 hour', current_setting('test.c')::uuid);
  insert into public.notifications (user_id, kind, event_id, dedupe_key)
  values (current_setting('test.a')::uuid, 'checkin_prompt', v_e, 'checkin_prompt:' || v_e || ':' || current_setting('test.a'));

  -- e2: future; e3: ended 8 days ago; e4: ended 2 days ago; e5: ended 3 days ago.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Attendance future run', now() + interval '1 day', now() + interval '1 day 2 hours', 'Midtown')
  returning id into v_e;
  perform set_config('test.e2', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.a')::uuid, 'going');

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Attendance old run', now() - interval '8 days 2 hours', now() - interval '8 days', 'Midtown')
  returning id into v_e;
  perform set_config('test.e3', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.a')::uuid, 'going');

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Attendance dismissed run', now() - interval '2 days 2 hours', now() - interval '2 days', 'Midtown')
  returning id into v_e;
  perform set_config('test.e4', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.a')::uuid, 'going');

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, v_h, 'Attendance pending run', now() - interval '3 days 2 hours', now() - interval '3 days', 'Midtown')
  returning id into v_e;
  perform set_config('test.e5', v_e::text, true);
  insert into public.rsvps (event_id, user_id, status) values
    (v_e, current_setting('test.a')::uuid, 'going'),
    (v_e, current_setting('test.b')::uuid, 'going'),
    (v_e, current_setting('test.x')::uuid, 'interested');
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- 1 to 3: refusals, self-report, re-submit
-- ---------------------------------------------------------------------------
do $$
declare
  v_e1 uuid := current_setting('test.e1')::uuid;
  v_a  uuid := current_setting('test.a')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_c  uuid := current_setting('test.c')::uuid;
  v_x  uuid := current_setting('test.x')::uuid;
  v_many uuid[];
  j    jsonb;
  n    integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);

  begin
    perform public.submit_attendance(current_setting('test.e2')::uuid, true, '{}');
    raise exception 'FAIL 1 submit before the end accepted';
  exception when others then
    if sqlerrm <> 'event_not_over' then raise exception 'FAIL 1 before end: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_attendance(current_setting('test.e3')::uuid, true, '{}');
    raise exception 'FAIL 1 submit after 7 days accepted';
  exception when others then
    if sqlerrm <> 'attendance_window_closed' then raise exception 'FAIL 1 after 7 days: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_attendance(v_e1, true, array[v_b, v_x]);
    raise exception 'FAIL 1 met id who was not going accepted';
  exception when others then
    if sqlerrm <> 'met_not_going' then raise exception 'FAIL 1 not going: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_attendance(v_e1, true, array[v_a]);
    raise exception 'FAIL 1 met self accepted';
  exception when others then
    if sqlerrm <> 'met_self' then raise exception 'FAIL 1 met self: %', sqlerrm; end if;
  end;
  select array_agg(gen_random_uuid()) into v_many from generate_series(1, 31);
  begin
    perform public.submit_attendance(v_e1, true, v_many);
    raise exception 'FAIL 1 31 met ids accepted';
  exception when others then
    if sqlerrm <> 'too_many_met' then raise exception 'FAIL 1 too many: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_attendance(v_e1, false, array[v_b]);
    raise exception 'FAIL 1 meets without attending accepted';
  exception when others then
    if sqlerrm <> 'met_requires_attended' then raise exception 'FAIL 1 met without attending: %', sqlerrm; end if;
  end;
  -- x was only interested: no prompt to answer.
  perform set_config('request.jwt.claims', json_build_object('sub', v_x, 'role', 'authenticated')::text, true);
  begin
    perform public.submit_attendance(v_e1, true, '{}');
    raise exception 'FAIL 1 interested RSVP accepted';
  exception when others then
    if sqlerrm <> 'not_going' then raise exception 'FAIL 1 interested: %', sqlerrm; end if;
  end;

  -- 2 and 3: a reports (b and c), then again (b only).
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  j := public.submit_attendance(v_e1, true, array[v_b, v_c, v_b]);
  if (j ->> 'met_count')::integer <> 2 then raise exception 'FAIL 3 first submit met_count %', j ->> 'met_count'; end if;
  j := public.submit_attendance(v_e1, true, array[v_b]);
  if (j ->> 'met_count')::integer <> 1 then raise exception 'FAIL 3 re-submit met_count %', j ->> 'met_count'; end if;
  select count(*) into n from public.event_meets where event_id = v_e1;
  if n <> 1 then raise exception 'FAIL 3 re-submit left % meets', n; end if;
  if not exists (select 1 from public.event_meets where event_id = v_e1 and met_user_id = v_b) then
    raise exception 'FAIL 3 re-submit lost the remaining meet';
  end if;
  select count(*) into n from public.event_attendance_reports where event_id = v_e1;
  if n <> 1 then raise exception 'FAIL 5 owner sees % reports', n; end if;

  -- c (checked in) says they went and met a.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  j := public.submit_attendance(v_e1, true, array[v_a]);
  if not (j ->> 'checked_in')::boolean then raise exception 'FAIL 2 checked_in flag'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4: pending prompts, dismiss
-- ---------------------------------------------------------------------------
do $$
declare
  v_a   uuid := current_setting('test.a')::uuid;
  v_ids uuid[];
  v_att jsonb;
  n     integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  select array_agg(event_id order by ends_at desc) into v_ids from public.pending_attendance_prompts();
  if v_ids is distinct from array[current_setting('test.e4')::uuid, current_setting('test.e5')::uuid] then
    raise exception 'FAIL 4 pending before dismiss: wrong events (% rows)', coalesce(array_length(v_ids, 1), 0);
  end if;

  perform public.dismiss_attendance_prompt(current_setting('test.e4')::uuid);
  perform public.dismiss_attendance_prompt(current_setting('test.e4')::uuid);
  select array_agg(event_id) into v_ids from public.pending_attendance_prompts();
  if v_ids is distinct from array[current_setting('test.e5')::uuid] then
    raise exception 'FAIL 4 pending after dismiss: wrong events (% rows)', coalesce(array_length(v_ids, 1), 0);
  end if;

  select attendees into v_att from public.pending_attendance_prompts();
  -- The host (auto-RSVP) and b; never the caller, never x (interested).
  if jsonb_array_length(v_att) <> 2
     or not v_att @> jsonb_build_array(jsonb_build_object('id', current_setting('test.b')))
     or not v_att @> jsonb_build_array(jsonb_build_object('id', current_setting('test.h'))) then
    raise exception 'FAIL 4 attendees list is wrong (% entries)', jsonb_array_length(v_att);
  end if;
  if (select array_agg(k order by k) from jsonb_object_keys(v_att -> 0) k) <> array['avatar_url', 'first_name', 'id'] then
    raise exception 'FAIL 4 attendee entry carries extra keys';
  end if;

  -- Dismissing an event the caller was not going to is refused.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  begin
    perform public.dismiss_attendance_prompt(current_setting('test.e5')::uuid);
    raise exception 'FAIL 4 dismiss without going accepted';
  exception when others then
    if sqlerrm <> 'not_going' then raise exception 'FAIL 4 dismiss: %', sqlerrm; end if;
  end;
  select count(*) into n from public.pending_attendance_prompts();
  if n <> 0 then raise exception 'FAIL 4 interested RSVP has % prompts', n; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5: privacy, no client writes
-- ---------------------------------------------------------------------------
do $$
declare
  v_e1 uuid := current_setting('test.e1')::uuid;
  n    integer;
begin
  -- b is the met user of a's pick and still sees nothing.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  select count(*) into n from public.event_meets;
  if n <> 0 then raise exception 'FAIL 5 another user reads % meets', n; end if;
  select count(*) into n from public.event_attendance_reports;
  if n <> 0 then raise exception 'FAIL 5 another user reads % reports', n; end if;
  begin
    insert into public.event_meets (event_id, user_id, met_user_id)
    values (v_e1, current_setting('test.b')::uuid, current_setting('test.a')::uuid);
    raise exception 'FAIL 5 client insert on event_meets allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.event_attendance_reports (event_id, user_id, attended, answered_at)
    values (v_e1, current_setting('test.b')::uuid, true, now());
    raise exception 'FAIL 5 client insert on event_attendance_reports allowed';
  exception when insufficient_privilege then null;
  end;
  begin
    perform attended_self_reported_at from public.rsvps limit 1;
    raise exception 'FAIL 5 attended_self_reported_at is client-selectable';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 6: dashboard
-- ---------------------------------------------------------------------------
do $$
declare
  v_ch uuid := current_setting('test.ch')::uuid;
  j    jsonb;
  t    jsonb;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.n'), 'role', 'authenticated')::text, true);
  begin
    perform public.chapter_dashboard(v_ch);
    raise exception 'FAIL 6 dashboard for a non-manager';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 6 non-manager: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.k'), 'role', 'authenticated')::text, true);
  j := public.chapter_dashboard(v_ch);
  t := j -> 'totals';
  -- e0: h, a going (a checked in). e1: h, a, b, c going (c checked in, a self-reported).
  if (t ->> 'events_held')::integer <> 2 then raise exception 'FAIL 6 events_held %', t ->> 'events_held'; end if;
  if (t ->> 'going')::integer <> 6 then raise exception 'FAIL 6 going %', t ->> 'going'; end if;
  if (t ->> 'checked_in')::integer <> 2 then raise exception 'FAIL 6 checked_in %', t ->> 'checked_in'; end if;
  if (t ->> 'self_reported')::integer <> 1 then raise exception 'FAIL 6 self_reported %', t ->> 'self_reported'; end if;
  if (t ->> 'distinct_attendees')::integer <> 2 then raise exception 'FAIL 6 distinct_attendees %', t ->> 'distinct_attendees'; end if;
  if (t ->> 'returning_attendees')::integer <> 1 then raise exception 'FAIL 6 returning_attendees %', t ->> 'returning_attendees'; end if;
  if (j ->> 'members_count')::integer <> 1 then raise exception 'FAIL 6 members_count %', j ->> 'members_count'; end if;
  if jsonb_array_length(j -> 'by_week') <> 12 then raise exception 'FAIL 6 by_week length'; end if;
  if (select sum((w ->> 'events_held')::integer) from jsonb_array_elements(j -> 'by_week') w) <> 2 then
    raise exception 'FAIL 6 weekly events_held do not add up';
  end if;
  if position('Tester' in j::text) > 0 or position(current_setting('test.a') in j::text) > 0 then
    raise exception 'FAIL 6 dashboard carries a name or user id';
  end if;
  begin
    perform public.chapter_dashboard(v_ch, 0);
    raise exception 'FAIL 6 zero weeks accepted';
  exception when others then
    if sqlerrm <> 'weeks_range' then raise exception 'FAIL 6 weeks: %', sqlerrm; end if;
  end;

  -- b reports e1, meeting a and c (a is deleted below).
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  perform public.submit_attendance(current_setting('test.e1')::uuid, true,
    array[current_setting('test.a')::uuid, current_setting('test.c')::uuid]);
end $$;
reset role;

-- 2 (as the owner): rsvps and the notification.
do $$
declare
  r public.rsvps;
begin
  select * into r from public.rsvps where event_id = current_setting('test.e1')::uuid and user_id = current_setting('test.a')::uuid;
  if r.checked_in_at is not null then raise exception 'FAIL 2 self-report set checked_in_at'; end if;
  if r.attended_self_reported_at is null then raise exception 'FAIL 2 self-report not stamped'; end if;
  select * into r from public.rsvps where event_id = current_setting('test.e1')::uuid and user_id = current_setting('test.c')::uuid;
  if r.checked_in_at is null or r.attended_self_reported_at is not null then
    raise exception 'FAIL 2 checked-in attendee changed by a self-report';
  end if;
  if exists (select 1 from public.notifications
              where user_id = current_setting('test.a')::uuid and kind = 'checkin_prompt'
                and event_id = current_setting('test.e1')::uuid and read_at is null) then
    raise exception 'FAIL 2 checkin_prompt not marked read';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7: account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;
reset role;

do $$
declare
  v_a uuid := current_setting('test.a')::uuid;
begin
  if exists (select 1 from public.event_attendance_reports where user_id = v_a) then
    raise exception 'FAIL 7 reports survive deletion';
  end if;
  if exists (select 1 from public.event_meets where user_id = v_a) then
    raise exception 'FAIL 7 own meets survive deletion';
  end if;
  if exists (select 1 from public.event_meets where met_user_id = v_a) then
    raise exception 'FAIL 7 meets naming the user survive deletion';
  end if;
  if not exists (select 1 from public.event_meets
                  where user_id = current_setting('test.b')::uuid and met_user_id = current_setting('test.c')::uuid) then
    raise exception 'FAIL 7 deletion removed an unrelated meet';
  end if;
  if (select value from public.meta where key = 'schema_version') <> '2.16' then
    raise exception 'FAIL 8 schema_version';
  end if;
end $$;

select 'attendance: PASS' as result;

rollback;
