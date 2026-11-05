-- ============================================================================
-- Staging check for migration 20261225000100_coaching_review_fixes.sql
-- (migration 61). One transaction, throwaway accounts and fake connected
-- account rows (no Stripe call is ever made from SQL; pg_net requests queued
-- here are rolled back), DO blocks that raise on failure, ROLLBACK. Prints
-- pass/fail only.
--
--   0 static: schema_version 2.57 or later; coach_stripe_close_blocked is
--     service role only.
--   1 group seats: a group request holds the session's row lock (the
--     second request for the last seat waits for it); the last seat taken,
--     the next request is full.
--   2 a paused or hidden listing: a waiting request cannot be confirmed
--     (listing_unavailable); active again, it can.
--   3 payments off: a booking still due falls back to off-platform at
--     pay_by instead of being cancelled; a refund queued while payments are
--     off is still dispatched.
--   4 a coach deleted during a paid session: the Stripe account stays open
--     (coach_stripe_close_blocked, a close_account job held without an
--     attempt) while a refund is pending or the session could still refund;
--     once completed there is no review prompt and write_review refuses;
--     then the close job is claimed.
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
create function pg_temp.own_val(p_sql text) returns text language plpgsql security definer as $$
declare
  v text;
begin
  execute p_sql into v;
  return v;
end $$;
create function pg_temp.at_local(p_days integer, p_time time) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/New_York')::date + p_days) + p_time) at time zone 'America/New_York';
$$;
create function pg_temp.request(p_client text, p_listing text, p_at timestamptz) returns uuid language plpgsql as $$
begin
  perform pg_temp.act(p_client);
  return (public.request_booking(current_setting('test.' || p_listing)::uuid, p_at, '',
                                 public.coaching_config() ->> 'policy_version', gen_random_uuid()) ->> 'id')::uuid;
end $$;
create function pg_temp.booked(p_client text, p_coach text, p_listing text, p_at timestamptz) returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  v_id := pg_temp.request(p_client, p_listing, p_at);
  perform pg_temp.act(p_coach);
  perform public.confirm_booking(v_id);
  return v_id;
end $$;
create function pg_temp.pay(p_booking uuid) returns text language plpgsql security definer as $$
declare
  v jsonb;
begin
  v := public.booking_checkout_params(p_booking, (select b.client_id from public.bookings b where b.id = p_booking));
  perform public.booking_checkout_opened(p_booking, 'cs_test_' || replace(p_booking::text, '-', ''),
                                         (v ->> 'amount_minor')::integer, (v ->> 'fee_minor')::integer,
                                         v ->> 'currency', v ->> 'stripe_account_id');
  return public.booking_mark_paid(p_booking, 'cs_test_' || replace(p_booking::text, '-', ''),
                                  'pi_test_' || replace(p_booking::text, '-', ''), (v ->> 'amount_minor')::integer);
end $$;
create function pg_temp.state(p_booking uuid) returns text language sql security definer as $$
  select b.status::text || '/' || b.payment_state::text from public.bookings b where b.id = p_booking;
$$;

-- ---------------------------------------------------------------------------
-- Setup: c, d coaches (New York); a, b, k clients; m a moderator.
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['c', 'd', 'a', 'b', 'k', 'm'];
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
            'crf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1985-01-15' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days',
           avatar_url = public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('m'), 'moderator');
  update public.meta set value = 'off' where key = 'coach_payments';
end $$;

-- ---------------------------------------------------------------------------
-- 0. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if string_to_array((select value from public.meta where key = 'schema_version'), '.')::int[] < array[2, 57] then
    raise exception 'FAIL 0 schema_version is %', (select value from public.meta where key = 'schema_version');
  end if;
  if has_function_privilege('authenticated', 'public.coach_stripe_close_blocked(uuid)', 'execute')
     or has_function_privilege('anon', 'public.coach_stripe_close_blocked(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.coach_stripe_close_blocked(uuid)', 'execute') then
    raise exception 'FAIL 0 coach_stripe_close_blocked grants';
  end if;
  if public.coach_stripe_close_blocked(null) then
    raise exception 'FAIL 0 null is blocked';
  end if;
end $$;

set local role authenticated;
do $$
declare
  v_terms text := public.coaching_config() ->> 'coach_terms_version';
  v_rules jsonb := (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '07:00', 'end', '21:00')) from generate_series(1, 7) d);
  n text;
begin
  foreach n in array array['c', 'd'] loop
    perform pg_temp.act(n);
    perform public.upsert_coach_profile('{"headline":"Tennis coach","timezone":"America/New_York","in_person":true,"lat":40.71,"lng":-74.0,"radius_km":20}'::jsonb);
    perform public.accept_coach_terms(v_terms);
    perform set_config('test.l' || n,
      public.upsert_listing('{"title":"Tennis, one hour","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","min_notice_hours":1,"slot_step_minutes":60,"meeting_note":"Court 3"}'::jsonb) ->> 'id', true);
    perform public.set_availability(v_rules);
    perform public.publish_coach_profile();
  end loop;
  perform pg_temp.act('c');
  perform set_config('test.lg',
    public.upsert_listing('{"title":"Group tennis","delivery":"in_person","format":"group","capacity":2,"duration_minutes":60,"price_minor":0,"currency":"usd","min_notice_hours":1,"auto_confirm":true}'::jsonb) ->> 'id', true);
  perform set_config('test.sg', public.schedule_group_session(current_setting('test.lg')::uuid, pg_temp.at_local(3, time '18:00'))::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Group seats
-- ---------------------------------------------------------------------------
do $$
declare
  v_b uuid;
begin
  v_b := pg_temp.request('a', 'lg', pg_temp.at_local(3, time '18:00'));
  perform set_config('test.ga', v_b::text, true);
end $$;
reset role;
do $$
begin
  -- The request locked the session row in this transaction (xmax is this transaction's id), so a
  -- concurrent request for the same session waits and then counts this seat.
  if (select s.xmax::text from public.coach_sessions s where s.id = current_setting('test.sg')::uuid)
     <> (txid_current() % 4294967296)::text then
    raise exception 'FAIL 1 a group request does not lock its session';
  end if;
  if pg_temp.state(current_setting('test.ga')::uuid) <> 'confirmed/none' then
    raise exception 'FAIL 1 the group request was not auto-confirmed: %', pg_temp.state(current_setting('test.ga')::uuid);
  end if;
end $$;
set local role authenticated;
do $$
declare
  v_b uuid;
begin
  v_b := pg_temp.request('b', 'lg', pg_temp.at_local(3, time '18:00'));
  if pg_temp.state(v_b) <> 'confirmed/none' then raise exception 'FAIL 1 the last seat: %', pg_temp.state(v_b); end if;
  perform pg_temp.act('k');
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.lg'),
                        pg_temp.at_local(3, time '18:00'), '', public.coaching_config() ->> 'policy_version',
                        gen_random_uuid())) <> 'full' then
    raise exception 'FAIL 1 a full session took another booking';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Paused or hidden listings take no new bookings
-- ---------------------------------------------------------------------------
do $$
declare
  v_a uuid;
  v_b uuid;
begin
  v_a := pg_temp.request('a', 'lc', pg_temp.at_local(2, time '09:00'));
  perform pg_temp.act('c');
  perform public.set_listing_status(current_setting('test.lc')::uuid, 'paused');
  if pg_temp.err(format('select public.confirm_booking(%L)', v_a)) <> 'listing_unavailable' then
    raise exception 'FAIL 2 a paused listing confirmed a waiting request';
  end if;
  perform public.set_listing_status(current_setting('test.lc')::uuid, 'active');
  perform public.confirm_booking(v_a);
  if pg_temp.state(v_a) <> 'confirmed/off_platform' then raise exception 'FAIL 2 active again: %', pg_temp.state(v_a); end if;

  v_b := pg_temp.request('b', 'lc', pg_temp.at_local(2, time '11:00'));
  perform pg_temp.own(format($q$update public.coach_listings set moderation_state = 'hidden' where id = %L$q$, current_setting('test.lc')));
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.confirm_booking(%L)', v_b)) <> 'listing_unavailable' then
    raise exception 'FAIL 2 a hidden listing confirmed a waiting request';
  end if;
  perform pg_temp.own(format($q$update public.coach_listings set moderation_state = null where id = %L$q$, current_setting('test.lc')));
  perform public.decline_booking(v_b);
end $$;

-- ---------------------------------------------------------------------------
-- 3. Payments off
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  update public.meta set value = 'on' where key = 'coach_payments';
  perform public.stripe_account_upsert(pg_temp.uid('c'), '{"stripe_account_id":"acct_TestCrfC1","country":"US","default_currency":"usd","charges_enabled":true,"payouts_enabled":true,"details_submitted":true,"requirements_due":[]}'::jsonb);
  perform public.stripe_account_upsert(pg_temp.uid('d'), '{"stripe_account_id":"acct_TestCrfD1","country":"US","default_currency":"usd","charges_enabled":true,"payouts_enabled":true,"details_submitted":true,"requirements_due":[]}'::jsonb);
  perform public.stripe_checkout_heartbeat();
end $$;
set local role authenticated;
do $$
begin
  perform set_config('test.due', pg_temp.booked('k', 'c', 'lc', pg_temp.at_local(5, time '08:00'))::text, true);
  perform set_config('test.paid', pg_temp.booked('b', 'c', 'lc', pg_temp.at_local(5, time '12:00'))::text, true);
end $$;
reset role;
do $$
declare
  v_due    uuid := current_setting('test.due')::uuid;
  v_paid   uuid := current_setting('test.paid')::uuid;
  v_expect boolean := false;
begin
  if pg_temp.state(v_due) <> 'confirmed/due' then raise exception 'FAIL 3 setup due: %', pg_temp.state(v_due); end if;
  perform pg_temp.pay(v_paid);
  update public.meta set value = 'off' where key = 'coach_payments';
  update public.bookings set pay_by = now() - interval '1 minute' where id = v_due;
  perform public.coaching_tick();
  if pg_temp.state(v_due) <> 'confirmed/off_platform'
     or (select payment_mode from public.bookings where id = v_due) <> 'off_platform' then
    raise exception 'FAIL 3 a due booking was cancelled while payments were off: %', pg_temp.state(v_due);
  end if;
  -- The client cancels a paid booking while payments are off: the refund is still dispatched.
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid('b'), 'role', 'authenticated')::text, true);
  perform public.cancel_booking(v_paid);
  if pg_temp.state(v_paid) <> 'cancelled/refund_pending'
     or not exists (select 1 from public.stripe_jobs j where j.booking_id = v_paid and j.op = 'refund' and j.status = 'pending') then
    raise exception 'FAIL 3 refund: %', pg_temp.state(v_paid);
  end if;
  if pg_get_functiondef('public.stripe_dispatch()'::regprocedure) like '%coach_payments_on%' then
    raise exception 'FAIL 3 stripe_dispatch is still gated on the payments flag';
  end if;
  if to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is not null
     and to_regclass('vault.decrypted_secrets') is not null then
    execute $q$select exists (select 1 from vault.decrypted_secrets where name = 'stripe_dispatch_secret')$q$ into v_expect;
  end if;
  if v_expect and public.stripe_dispatch() is null then
    raise exception 'FAIL 3 a due refund was not dispatched while payments were off';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. A coach deleted during a paid session
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  update public.meta set value = 'on' where key = 'coach_payments';
end $$;
set local role authenticated;
do $$
begin
  perform set_config('test.now', pg_temp.booked('a', 'd', 'ld', pg_temp.at_local(4, time '10:00'))::text, true);
  perform set_config('test.fut', pg_temp.booked('k', 'd', 'ld', pg_temp.at_local(8, time '10:00'))::text, true);
end $$;
reset role;
do $$
begin
  perform pg_temp.pay(current_setting('test.now')::uuid);
  perform pg_temp.pay(current_setting('test.fut')::uuid);
  -- The session is under way.
  update public.bookings set starts_at = now() - interval '30 minutes', ends_at = now() + interval '30 minutes'
   where id = current_setting('test.now')::uuid;
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('d');
  perform public.request_account_deletion('test');
end $$;
reset role;
do $$
declare
  d      uuid := pg_temp.uid('d');
  v_now  uuid := current_setting('test.now')::uuid;
  v_job  bigint;
  v      jsonb;
begin
  if pg_temp.state(current_setting('test.fut')::uuid) <> 'cancelled/refund_pending' then
    raise exception 'FAIL 4 setup: the future booking was not refunded';
  end if;
  if pg_temp.state(v_now) <> 'confirmed/paid' then raise exception 'FAIL 4 setup: %', pg_temp.state(v_now); end if;
  if not public.coach_stripe_close_blocked(d) then
    raise exception 'FAIL 4 the account may close while a refund is pending';
  end if;
  -- What delete-account queues; the claim holds it without an attempt.
  insert into public.stripe_jobs (op, stripe_account_id, idempotency_key, next_at)
  values ('close_account', 'acct_TestCrfD1', 'close:acct_TestCrfD1', now() - interval '1 minute')
  returning id into v_job;
  v := public.stripe_jobs_claim(50);
  if exists (select 1 from jsonb_array_elements(v) e where (e ->> 'id')::bigint = v_job)
     or (select status from public.stripe_jobs where id = v_job) <> 'pending'
     or (select attempts from public.stripe_jobs where id = v_job) <> 0
     or (select next_at from public.stripe_jobs where id = v_job) < now() + interval '50 minutes' then
    raise exception 'FAIL 4 a close_account job ran while refunds were pending';
  end if;

  -- The refunds ran; the session is still open to a no-show report, so the account stays.
  update public.stripe_jobs j set status = 'done'
    from public.bookings b where b.id = j.booking_id and b.coach_id = d;
  if not public.coach_stripe_close_blocked(d) then
    raise exception 'FAIL 4 the account may close while a paid session can still refund';
  end if;

  -- Completed by coaching_tick 48 hours after the end: no review prompt, no review.
  update public.bookings set starts_at = now() - interval '50 hours', ends_at = now() - interval '49 hours' where id = v_now;
  perform public.coaching_tick();
  if pg_temp.state(v_now) <> 'completed/paid' then raise exception 'FAIL 4 not completed: %', pg_temp.state(v_now); end if;
  update public.bookings set completed_at = now() - interval '3 hours' where id = v_now;
  perform public.coaching_tick();
  if exists (select 1 from public.notifications n
              where n.dedupe_key = 'booking_review_prompt:' || v_now::text || ':' || pg_temp.uid('a')::text) then
    raise exception 'FAIL 4 a review prompt about a deleted coach';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', pg_temp.uid('a'), 'role', 'authenticated')::text, true);
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', v_now, 'Great session')) <> 'not_found'
     or exists (select 1 from public.coach_reviews where booking_id = v_now) then
    raise exception 'FAIL 4 a review of a deleted coach was written';
  end if;

  if public.coach_stripe_close_blocked(d) then
    raise exception 'FAIL 4 the account stays blocked after everything settled';
  end if;
  update public.stripe_jobs set next_at = now() - interval '1 minute' where id = v_job;
  v := public.stripe_jobs_claim(50);
  if not exists (select 1 from jsonb_array_elements(v) e
                  where (e ->> 'id')::bigint = v_job and e ->> 'stripe_account_id' = 'acct_TestCrfD1') then
    raise exception 'FAIL 4 the close_account job was not claimed once nothing was pending';
  end if;
end $$;

select 'coaching_review_fixes: PASS' as result;

rollback;
