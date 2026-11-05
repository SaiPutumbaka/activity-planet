-- ============================================================================
-- Staging check for migration 20261224000100_coaching.sql (migration 60):
-- slot generation and the booking rules around it. One transaction,
-- throwaway accounts, DO blocks that raise on failure, ROLLBACK. Prints
-- pass/fail only.
--
--   1 time zones and daylight saving (fixed dates in 2030, so the checks do
--     not depend on today): Europe/Berlin spring forward (a local time that
--     does not exist is skipped), fall back (an ambiguous time is its first
--     occurrence), wall-clock rules on either side of the change, and
--     Australia/Sydney (southern hemisphere) spring forward.
--   2 exceptions and rule dates: unavailable removes, available adds,
--     valid_until ends a rule.
--   3 notice and advance limits through coach_slots.
--   4 group sessions: seats, auto-confirm, full, an overlapping session
--     refused (slot_taken), not_group, a one-on-one start inside a group
--     session not offered, cancelling the session cancels every seat.
--   5 client rules: photo, 24-hour account, guidelines, booking yourself,
--     five open requests, ten a day; a suspended coach cannot confirm and is
--     hidden; confirming one listing declines an overlapping request on
--     another listing of the same coach.
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
create function pg_temp.own(p_sql text) returns void language plpgsql security definer as $$
begin
  execute p_sql;
end $$;
-- Candidate starts as UTC text, ordered (as the owner: the helper is not in the API).
create function pg_temp.cands(p_listing uuid, p_from date, p_to date) returns text language sql security definer as $$
  select coalesce(string_agg(to_char(c.starts_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI'), ',' order by c.starts_at), '')
    from private.coach_slot_candidates(p_listing, p_from, p_to) c;
$$;
create function pg_temp.at_local(p_tz text, p_days integer, p_time time) returns timestamptz language sql stable as $$
  select (((now() at time zone p_tz)::date + p_days) + p_time) at time zone p_tz;
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  -- e: coach in Berlin. f: coach in Sydney. g: coach in New York (group and one-on-one).
  -- a, b, h: clients. n: 23-hour account. p: no photo. q: no guidelines.
  v_names text[] := array['e', 'f', 'g', 'a', 'b', 'h', 'n', 'p', 'q'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  if public.project_url() is null then
    raise exception 'FAIL setup: meta.project_url is not set';
  end if;
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'rules-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1988-08-08' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester',
           guidelines_accepted_at = case when v_names[i] = 'q' then null else now() end,
           created_at = case when v_names[i] = 'n' then now() - interval '23 hours' else now() - interval '3 days' end,
           avatar_url = case when v_names[i] = 'p' then null
                             else public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg' end
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
end $$;

set local role authenticated;
do $$
declare
  v jsonb;
  v_terms text := public.coaching_config() ->> 'coach_terms_version';
begin
  perform pg_temp.act('e');
  perform public.upsert_coach_profile('{"headline":"Piano online","timezone":"Europe/Berlin","in_person":false,"online":true}'::jsonb);
  perform public.accept_coach_terms(v_terms);
  v := public.upsert_listing('{"title":"Piano, one hour","delivery":"online","format":"one_on_one","duration_minutes":60,"price_minor":3000,"currency":"eur","slot_step_minutes":30,"min_notice_hours":1,"max_advance_days":180}'::jsonb);
  perform set_config('test.le', v ->> 'id', true);
  -- Sundays 01:00 to 04:00 local: the night of both European changes.
  perform public.set_availability('[{"weekday":7,"start":"01:00","end":"04:00"}]'::jsonb);

  perform pg_temp.act('f');
  perform public.upsert_coach_profile('{"headline":"Surf theory online","timezone":"Australia/Sydney","in_person":false,"online":true}'::jsonb);
  perform public.accept_coach_terms(v_terms);
  v := public.upsert_listing('{"title":"Surf theory","delivery":"online","format":"one_on_one","duration_minutes":30,"price_minor":2000,"currency":"aud","slot_step_minutes":30,"min_notice_hours":1}'::jsonb);
  perform set_config('test.lf', v ->> 'id', true);
  perform public.set_availability('[{"weekday":7,"start":"02:00","end":"03:30"}]'::jsonb);

  perform pg_temp.act('g');
  perform public.upsert_coach_profile('{"headline":"Climbing coach","timezone":"America/New_York","in_person":true,"lat":40.7128,"lng":-74.006,"radius_km":15,"area_label":"Lower Manhattan"}'::jsonb);
  perform public.accept_coach_terms(v_terms);
  v := public.upsert_listing('{"title":"Climbing, one hour","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":5000,"currency":"usd","slot_step_minutes":60,"min_notice_hours":12,"max_advance_days":3}'::jsonb);
  perform set_config('test.lg', v ->> 'id', true);
  v := public.upsert_listing('{"title":"Climbing, half hour","delivery":"in_person","format":"one_on_one","duration_minutes":30,"price_minor":2500,"currency":"usd","slot_step_minutes":30,"min_notice_hours":1}'::jsonb);
  perform set_config('test.lg30', v ->> 'id', true);
  v := public.upsert_listing('{"title":"Group climbing","delivery":"in_person","format":"group","capacity":2,"duration_minutes":90,"price_minor":2000,"currency":"usd","min_notice_hours":1}'::jsonb);
  perform set_config('test.lgg', v ->> 'id', true);
  if not (select l.auto_confirm from public.coach_listings l where l.id = (v ->> 'id')::uuid) then
    raise exception 'FAIL 4 a group listing does not auto-confirm by default';
  end if;
  -- The hour listing: Mondays 09:00 to 12:00, Mondays 16:00 to 17:00 until May 2030, and every day
  -- 07:00 to 21:00 until the end of 2029 (for today's bookings). The half-hour listing: every day
  -- 07:00 to 21:00.
  perform public.set_availability((
    select jsonb_agg(r) from (
      select jsonb_build_object('weekday', 1, 'start', '09:00', 'end', '12:00', 'listing_id', current_setting('test.lg')) r
      union all
      select jsonb_build_object('weekday', 1, 'start', '16:00', 'end', '17:00', 'valid_until', '2030-05-31',
                                'listing_id', current_setting('test.lg'))
      union all
      select jsonb_build_object('weekday', d, 'start', '07:00', 'end', '21:00', 'valid_until', '2029-12-31',
                                'listing_id', current_setting('test.lg'))
        from generate_series(1, 7) d
      union all
      select jsonb_build_object('weekday', d, 'start', '07:00', 'end', '21:00', 'listing_id', current_setting('test.lg30'))
        from generate_series(1, 7) d) x));
  perform public.publish_coach_profile();
end $$;

-- ---------------------------------------------------------------------------
-- 1. Time zones and daylight saving
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v text;
begin
  -- 2030-03-31, Berlin springs forward at 02:00 (to 03:00): 02:00 and 02:30 do not exist.
  v := pg_temp.cands(current_setting('test.le')::uuid, date '2030-03-31', date '2030-03-31');
  if v <> '2030-03-31 00:00,2030-03-31 00:30,2030-03-31 01:00' then
    raise exception 'FAIL 1 Berlin spring forward: %', v;
  end if;
  -- 2030-10-27, Berlin falls back at 03:00 (to 02:00): 02:00 and 02:30 happen twice; the first counts.
  v := pg_temp.cands(current_setting('test.le')::uuid, date '2030-10-27', date '2030-10-27');
  if v <> '2030-10-26 23:00,2030-10-26 23:30,2030-10-27 00:00,2030-10-27 00:30,2030-10-27 02:00' then
    raise exception 'FAIL 1 Berlin fall back: %', v;
  end if;
  -- Wall clock: 01:00 local the week before (CET, 00:00 UTC) and the week after (CEST, 23:00 UTC the day before).
  v := pg_temp.cands(current_setting('test.le')::uuid, date '2030-03-24', date '2030-03-24');
  if split_part(v, ',', 1) <> '2030-03-24 00:00' then raise exception 'FAIL 1 Berlin winter: %', v; end if;
  v := pg_temp.cands(current_setting('test.le')::uuid, date '2030-04-07', date '2030-04-07');
  if split_part(v, ',', 1) <> '2030-04-06 23:00' or v like '%,%,%,%,%,%' then
    raise exception 'FAIL 1 Berlin summer: %', v;
  end if;
  -- Only Sundays.
  if pg_temp.cands(current_setting('test.le')::uuid, date '2030-03-25', date '2030-03-30') <> '' then
    raise exception 'FAIL 1 slots on a day without a rule';
  end if;
  -- 2030-10-06, Sydney springs forward at 02:00 (to 03:00): only 03:00 local (16:00 UTC the day before) is left.
  v := pg_temp.cands(current_setting('test.lf')::uuid, date '2030-10-06', date '2030-10-06');
  if v <> '2030-10-05 16:00' then raise exception 'FAIL 1 Sydney spring forward: %', v; end if;
  v := pg_temp.cands(current_setting('test.lf')::uuid, date '2030-09-29', date '2030-09-29');
  if v <> '2030-09-28 16:00,2030-09-28 16:30,2030-09-28 17:00' then
    raise exception 'FAIL 1 Sydney before the change: %', v;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Exceptions and rule dates
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform pg_temp.act('g');
  perform public.add_availability_exception('{"kind":"unavailable","starts_at":"2030-06-03T13:30:00Z","ends_at":"2030-06-03T14:10:00Z","note":"Dentist"}'::jsonb);
  perform public.add_availability_exception('{"kind":"available","starts_at":"2030-06-04T18:00:00Z","ends_at":"2030-06-04T20:00:00Z"}'::jsonb);
  if pg_temp.err($q$select public.add_availability_exception('{"kind":"available","starts_at":"2030-06-04T20:00:00Z","ends_at":"2030-06-04T19:00:00Z"}'::jsonb)$q$) <> 'invalid_range'
     or pg_temp.err($q$select public.add_availability_exception('{"kind":"maybe","starts_at":"2030-06-04T18:00:00Z","ends_at":"2030-06-04T19:00:00Z"}'::jsonb)$q$) <> 'invalid_range' then
    raise exception 'FAIL 2 a bad exception was accepted';
  end if;
  perform pg_temp.act('a');
  if exists (select 1 from public.coach_availability_exceptions) then
    raise exception 'FAIL 2 a client reads a coach''s exceptions';
  end if;
end $$;
reset role;
do $$
declare
  v text;
begin
  -- Monday 2030-06-03 (EDT): 09:00-12:00 gives 13:00, 14:00 and 15:00 UTC; the exception takes 13:00
  -- and 14:00; the 16:00 rule ended in May. Tuesday: no rule for this listing, the exception adds two.
  v := pg_temp.cands(current_setting('test.lg')::uuid, date '2030-06-03', date '2030-06-04');
  if v <> '2030-06-03 15:00,2030-06-04 18:00,2030-06-04 19:00' then
    raise exception 'FAIL 2 exceptions: %', v;
  end if;
  -- Before May 31 the 16:00 rule applies (2030-05-27 is a Monday): 13:00, 14:00, 15:00, 20:00 UTC.
  v := pg_temp.cands(current_setting('test.lg')::uuid, date '2030-05-27', date '2030-05-27');
  if v <> '2030-05-27 13:00,2030-05-27 14:00,2030-05-27 15:00,2030-05-27 20:00' then
    raise exception 'FAIL 2 valid_until: %', v;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Notice and advance limits
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform pg_temp.act('a');
  -- lg: 12 hours' notice, 3 days ahead (in the coach's zone).
  if exists (select 1 from public.coach_slots(current_setting('test.lg')::uuid, current_date - 1, current_date + 10) s
              where s.starts_at < now() + interval '12 hours'
                 or (s.starts_at at time zone 'America/New_York')::date > (now() at time zone 'America/New_York')::date + 3) then
    raise exception 'FAIL 3 a slot inside the notice or past the advance limit';
  end if;
  if pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date + 5, current_date + 1)', current_setting('test.lg'))) <> 'invalid_range' then
    raise exception 'FAIL 3 a reversed range';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Group sessions
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   timestamptz := pg_temp.at_local('America/New_York', 2, time '14:00');
  v_s   uuid;
  v     jsonb;
  v_pol text := public.coaching_config() ->> 'policy_version';
  v_n   integer;
begin
  perform pg_temp.act('g');
  if pg_temp.err(format('select public.schedule_group_session(%L, %L)', current_setting('test.lg'), v_t)) <> 'not_group' then
    raise exception 'FAIL 4 a group session on a one-on-one listing';
  end if;
  v_s := public.schedule_group_session(current_setting('test.lgg')::uuid, v_t);
  perform set_config('test.gs', v_s::text, true);
  if pg_temp.err(format('select public.schedule_group_session(%L, %L)', current_setting('test.lgg'), v_t + interval '1 hour')) <> 'slot_taken' then
    raise exception 'FAIL 4 an overlapping group session was accepted';
  end if;
  perform pg_temp.act('a');
  select s.seats_left into v_n from public.coach_slots(current_setting('test.lgg')::uuid, current_date, current_date + 5) s where s.starts_at = v_t;
  if v_n is distinct from 2::smallint then raise exception 'FAIL 4 seats_left before booking: %', v_n; end if;
  -- The half-hour listing does not offer time inside the group session.
  if exists (select 1 from public.coach_slots(current_setting('test.lg30')::uuid, current_date, current_date + 5) s
              where s.starts_at >= v_t and s.starts_at < v_t + interval '90 minutes') then
    raise exception 'FAIL 4 a one-on-one slot inside a group session';
  end if;
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'), v_t + interval '30 minutes',
                        '', v_pol, gen_random_uuid())) <> 'slot_unavailable' then
    raise exception 'FAIL 4 a one-on-one request inside a group session';
  end if;
  v := public.request_booking(current_setting('test.lgg')::uuid, v_t, '', v_pol, gen_random_uuid());
  if v ->> 'status' <> 'confirmed' then raise exception 'FAIL 4 a group seat did not auto-confirm'; end if;
  perform set_config('test.ga', v ->> 'id', true);
  perform pg_temp.act('b');
  v := public.request_booking(current_setting('test.lgg')::uuid, v_t, '', v_pol, gen_random_uuid());
  perform set_config('test.gb', v ->> 'id', true);
  if exists (select 1 from public.coach_slots(current_setting('test.lgg')::uuid, current_date, current_date + 5) s where s.starts_at = v_t) then
    raise exception 'FAIL 4 a full session is still offered';
  end if;
  perform pg_temp.act('h');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lgg'), v_t, '', v_pol, gen_random_uuid())) <> 'full' then
    raise exception 'FAIL 4 a third seat in a group of two';
  end if;
  -- Cancelling the session cancels every seat (a coach cancellation).
  perform pg_temp.act('g');
  v := public.cancel_group_session(v_s);
  if (v ->> 'bookings_cancelled')::integer <> 2 then raise exception 'FAIL 4 cancel_group_session: %', v; end if;
  perform pg_temp.act('a');
  v := public.get_booking(current_setting('test.ga')::uuid);
  if v ->> 'status' <> 'cancelled' or v ->> 'cancelled_by' <> 'coach' or v ->> 'cancel_reason' <> 'coach' then
    raise exception 'FAIL 4 a seat was not cancelled by the coach';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Client rules, suspension, cross-listing overlap
-- ---------------------------------------------------------------------------
do $$
declare
  v_pol text := public.coaching_config() ->> 'policy_version';
  v_t   timestamptz := pg_temp.at_local('America/New_York', 3, time '10:00');
  v     jsonb;
begin
  perform pg_temp.act('p');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'), v_t, '', v_pol, gen_random_uuid())) <> 'photo_required' then
    raise exception 'FAIL 5 a client without a photo booked';
  end if;
  perform pg_temp.act('n');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'), v_t, '', v_pol, gen_random_uuid())) <> 'account_too_new' then
    raise exception 'FAIL 5 a 23-hour account booked';
  end if;
  perform pg_temp.act('q');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'), v_t, '', v_pol, gen_random_uuid())) <> 'guidelines_required' then
    raise exception 'FAIL 5 a client booked without the guidelines';
  end if;
  perform pg_temp.act('g');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'), v_t, '', v_pol, gen_random_uuid())) <> 'cannot_book_self' then
    raise exception 'FAIL 5 a coach booked themselves';
  end if;
  -- a asks for 10:00-10:30 on the half-hour listing, b for 10:00-11:00 on the hour listing.
  perform pg_temp.act('a');
  v := public.request_booking(current_setting('test.lg30')::uuid, v_t, '', v_pol, gen_random_uuid());
  perform set_config('test.xa', v ->> 'id', true);
  perform pg_temp.act('b');
  if not exists (select 1 from public.coach_slots(current_setting('test.lg')::uuid, current_date, current_date + 5) s
                  where s.starts_at = v_t) then
    raise exception 'FAIL 5 no 10:00 slot on the hour listing';
  end if;
  v := public.request_booking(current_setting('test.lg')::uuid, v_t, '', v_pol, gen_random_uuid());
  perform set_config('test.xb', v ->> 'id', true);
  perform pg_temp.act('g');
  perform public.confirm_booking(current_setting('test.xb')::uuid);
  perform pg_temp.act('a');
  v := public.get_booking(current_setting('test.xa')::uuid);
  if v ->> 'status' <> 'declined' or v ->> 'cancel_reason' <> 'slot_taken' then
    raise exception 'FAIL 5 an overlapping request on another listing was not declined';
  end if;
end $$;
reset role;
do $$
declare
  v_ids uuid[];
begin
  -- Ten requests in the last day (as the owner), then the eleventh is rate_limited.
  for i in 1..10 loop
    perform pg_temp.own(format($q$insert into public.bookings (listing_id, coach_id, client_id, starts_at, ends_at, status, title, delivery,
                                    format, price_minor, currency, payment_mode, payment_state, policy_version, free_cancel_until,
                                    client_request_id, expires_at, declined_at)
                                  values (%L, %L, %L, now() + interval '5 days', now() + interval '5 days 1 hour', 'declined', 'Old',
                                          'in_person', 'one_on_one', 0, 'usd', 'none', 'none', '2026-12', now() + interval '4 days',
                                          gen_random_uuid(), now() + interval '1 day', now())$q$,
                               current_setting('test.lg30'), pg_temp.uid('g'), pg_temp.uid('h')));
  end loop;
end $$;
set local role authenticated;
do $$
declare
  v_pol text := public.coaching_config() ->> 'policy_version';
begin
  perform pg_temp.act('h');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'),
                        pg_temp.at_local('America/New_York', 2, time '08:00'), '', v_pol, gen_random_uuid())) <> 'rate_limited' then
    raise exception 'FAIL 5 an eleventh request in a day';
  end if;
end $$;
reset role;
do $$
begin
  perform pg_temp.own(format('delete from public.bookings where client_id = %L', pg_temp.uid('h')));
  -- Five open requests (with other coaches' listings faked as the owner), then the sixth is too_many_open.
  for i in 1..5 loop
    perform pg_temp.own(format($q$insert into public.bookings (coach_id, client_id, starts_at, ends_at, status, title, delivery,
                                    format, price_minor, currency, payment_mode, payment_state, policy_version, free_cancel_until,
                                    client_request_id, expires_at, requested_at)
                                  values (%L, %L, now() + interval '5 days', now() + interval '5 days 1 hour', 'requested', 'Open',
                                          'online', 'one_on_one', 0, 'usd', 'none', 'none', '2026-12', now() + interval '4 days',
                                          gen_random_uuid(), now() + interval '1 day', now() - interval '2 days')$q$,
                               pg_temp.uid('e'), pg_temp.uid('h')));
  end loop;
end $$;
set local role authenticated;
do $$
declare
  v_pol text := public.coaching_config() ->> 'policy_version';
begin
  perform pg_temp.act('h');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg30'),
                        pg_temp.at_local('America/New_York', 2, time '08:00'), '', v_pol, gen_random_uuid())) <> 'too_many_open' then
    raise exception 'FAIL 5 a sixth open request';
  end if;
end $$;
reset role;
do $$
begin
  perform pg_temp.own(format($q$update public.coach_profiles set status = 'suspended' where user_id = %L$q$, pg_temp.uid('g')));
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('a');
  if exists (select 1 from public.coach_profiles where user_id = pg_temp.uid('g'))
     or pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date, current_date + 3)', current_setting('test.lg30'))) <> 'not_found' then
    raise exception 'FAIL 5 a suspended coach is visible';
  end if;
  perform pg_temp.act('g');
  if pg_temp.err('select public.publish_coach_profile()') <> 'forbidden' then
    raise exception 'FAIL 5 a suspended coach published';
  end if;
end $$;
reset role;

select 'coaching_rules: PASS' as result;

rollback;
