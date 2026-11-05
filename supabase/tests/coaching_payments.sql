-- ============================================================================
-- Staging check for migration 20261224000100_coaching.sql (migration 60):
-- payments, refunds, the webhook ledger, reports and moderation, bans and
-- account deletion. One transaction, throwaway accounts and a fake connected
-- account row (no Stripe call is ever made from SQL), DO blocks that raise on
-- failure, ROLLBACK. Prints pass/fail only.
--
--   1 requests only (the default): off_platform, no payment rows, no jobs.
--   2 payments on (flag set inside this transaction) with a fake account:
--     payable shapes, the fee (12%, $3 minimum), pay_by, payment due notice.
--   3 checkout params and the service-role checkout path; paid once.
--   4 refunds per Refund Policy row: client 24 h or more, client inside 24 h,
--     coach cancellation, block by the coach, block by the client.
--   5 the webhook ledger (stripe_event_begin idempotency) and the handlers:
--     refunds recorded, disputes, a payment after a cancellation, an expired
--     checkout; jobs claim, retry and fail.
--   6 coaching_tick: unpaid cancelled; no checkout ever possible falls back to
--     off-platform.
--   7 reports and moderation: the four new kinds, booking-only reasons, a
--     hidden review leaves the rating, a removed listing ends its bookings,
--     mod_booking, the second-moderator rule, mod_set_coach_status, a ban.
--   8 account deletion of a client and of a coach: every new table.
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
create function pg_temp.own_err(p_sql text) returns text language plpgsql security definer as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
create function pg_temp.at_local(p_days integer, p_time time) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/New_York')::date + p_days) + p_time) at time zone 'America/New_York';
$$;
-- A confirmed booking: p_client asks p_listing for p_at, the listing's coach confirms.
create function pg_temp.booked(p_client text, p_coach text, p_listing text, p_at timestamptz) returns uuid language plpgsql as $$
declare
  v_id uuid;
begin
  perform pg_temp.act(p_client);
  v_id := (public.request_booking(current_setting('test.' || p_listing)::uuid, p_at, 'Bring a racket',
                                  public.coaching_config() ->> 'policy_version', gen_random_uuid()) ->> 'id')::uuid;
  perform pg_temp.act(p_coach);
  perform public.confirm_booking(v_id);
  return v_id;
end $$;
-- Paid through the same service-role calls stripe-checkout and stripe-webhook make.
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
create function pg_temp.job_amount(p_booking uuid) returns integer language sql security definer as $$
  select coalesce(sum(j.amount_minor), 0)::integer from public.stripe_jobs j where j.booking_id = p_booking and j.op = 'refund';
$$;
create function pg_temp.state(p_booking uuid) returns text language sql security definer as $$
  select b.status::text || '/' || b.payment_state::text from public.bookings b where b.id = p_booking;
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  -- c, d: coaches (New York). a, b, k, z: clients. x: a stranger. m, m2: moderators.
  v_names text[] := array['c', 'd', 'a', 'b', 'k', 'z', 'x', 'm', 'm2'];
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
            'pay-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1985-01-15' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
           created_at = now() - interval '3 days',
           avatar_url = public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('m'), 'moderator'), (pg_temp.uid('m2'), 'moderator');
  insert into public.notification_prefs (user_id) values (pg_temp.uid('a')), (pg_temp.uid('c')) on conflict do nothing;
  delete from public.meta where key = 'stripe_checkout_seen_at';
end $$;

set local role authenticated;
do $$
declare
  v jsonb;
  v_terms text := public.coaching_config() ->> 'coach_terms_version';
  v_rules jsonb := (select jsonb_agg(jsonb_build_object('weekday', d, 'start', '07:00', 'end', '21:00')) from generate_series(1, 7) d);
begin
  foreach v in array array['"c"', '"d"']::jsonb[] loop
    perform pg_temp.act(v #>> '{}');
    perform public.upsert_coach_profile('{"headline":"Tennis coach","timezone":"America/New_York","in_person":true,"lat":40.71,"lng":-74.0,"radius_km":20}'::jsonb);
    perform public.accept_coach_terms(v_terms);
    perform set_config('test.l' || (v #>> '{}'),
      public.upsert_listing('{"title":"Tennis, one hour","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","min_notice_hours":1,"slot_step_minutes":60,"meeting_note":"Court 3"}'::jsonb) ->> 'id', true);
    perform public.set_availability(v_rules);
    perform public.publish_coach_profile();
  end loop;
  perform pg_temp.act('c');
  perform set_config('test.lsmall', public.upsert_listing('{"title":"Quick drill","delivery":"in_person","format":"one_on_one","duration_minutes":15,"price_minor":500,"currency":"usd","min_notice_hours":1,"slot_step_minutes":15}'::jsonb) ->> 'id', true);
  perform set_config('test.leur', public.upsert_listing('{"title":"Tennis in euros","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"eur","min_notice_hours":1,"slot_step_minutes":60}'::jsonb) ->> 'id', true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Requests only
-- ---------------------------------------------------------------------------
do $$
declare
  v_b uuid;
  v   jsonb;
begin
  if (public.coaching_config() ->> 'payments_enabled')::boolean then
    raise exception 'FAIL 1 payments are on by default';
  end if;
  v_b := pg_temp.booked('a', 'c', 'lc', pg_temp.at_local(3, time '08:00'));
  perform pg_temp.act('a');
  v := public.get_booking(v_b);
  if v ->> 'payment_mode' <> 'off_platform' or v ->> 'payment_state' <> 'off_platform' or v ->> 'pay_by' is not null
     or (v ->> 'can_pay')::boolean or v ->> 'fee_minor' is not null then
    raise exception 'FAIL 1 requests-only booking: % %', v ->> 'payment_mode', v ->> 'payment_state';
  end if;
  v := public.cancel_booking(v_b);
  if (v ->> 'refund_minor')::integer <> 4000 then raise exception 'FAIL 1 the policy expectation is not shown'; end if;
  if pg_temp.job_amount(v_b) <> 0
     or pg_temp.own_val(format('select count(*) from public.booking_payments where booking_id = %L', v_b)) <> '0' then
    raise exception 'FAIL 1 a payment row or job exists with payments off';
  end if;
  if (public.coach_payout_status() ->> 'state') <> 'none' then raise exception 'FAIL 1 payout state'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Payments on, with a fake connected account for c
-- ---------------------------------------------------------------------------
reset role;
do $$
begin
  update public.meta set value = 'on' where key = 'coach_payments';
  perform public.stripe_account_upsert(pg_temp.uid('c'), '{"stripe_account_id":"acct_TestCoachC1","country":"us","default_currency":"usd","charges_enabled":true,"payouts_enabled":true,"details_submitted":true,"requirements_due":[]}'::jsonb);
  if pg_temp.own_err(format($q$select public.stripe_account_upsert(%L, '{"stripe_account_id":"acct_Other2","country":"US"}'::jsonb)$q$, pg_temp.uid('c'))) <> 'account_mismatch' then
    raise exception 'FAIL 2 a second account for one coach';
  end if;
  if private.coach_fee(4000, 'usd') <> 480 or private.coach_fee(2000, 'usd') <> 300 or private.coach_fee(10000, 'usd') <> 1200
     or private.coach_fee(2500, 'usd') <> 300 or private.coach_fee(2600, 'usd') <> 312 or private.coach_fee(4000, 'eur') is not null then
    raise exception 'FAIL 2 fee fixtures';
  end if;
  if private.booking_refund_minor(4000, 'policy', now() + interval '1 hour', now()) <> 4000
     or private.booking_refund_minor(4000, 'policy', now() - interval '1 hour', now()) <> 2000
     or private.booking_refund_minor(4001, 'policy', now() - interval '1 hour', now()) <> 2001
     or private.booking_refund_minor(4000, 'full', now() - interval '1 hour', now()) <> 4000
     or private.booking_refund_minor(4000, 'none', now() + interval '1 hour', now()) <> 0 then
    raise exception 'FAIL 2 refund fixtures';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v    jsonb;
  v_b  uuid;
  v_at timestamptz := pg_temp.at_local(3, time '09:00');
begin
  perform pg_temp.act('a');
  if not (public.coaching_config() ->> 'payments_enabled')::boolean then raise exception 'FAIL 2 flag'; end if;
  v := public.get_coach((select handle from public.profiles where id = pg_temp.uid('c')));
  if not (select (e ->> 'payable')::boolean from jsonb_array_elements(v -> 'listings') e where e ->> 'id' = current_setting('test.lc'))
     or (select (e ->> 'payable')::boolean from jsonb_array_elements(v -> 'listings') e where e ->> 'id' = current_setting('test.lsmall'))
     or (select (e ->> 'payable')::boolean from jsonb_array_elements(v -> 'listings') e where e ->> 'id' = current_setting('test.leur')) then
    raise exception 'FAIL 2 payable: usd 40 yes, usd 5 (under twice the minimum) no, eur (another currency) no';
  end if;
  -- d has no connected account: requests only.
  v := public.get_coach((select handle from public.profiles where id = pg_temp.uid('d')));
  if (v -> 'listings' -> 0 ->> 'payable')::boolean then raise exception 'FAIL 2 payable without an account'; end if;

  v_b := pg_temp.booked('a', 'c', 'lc', v_at);
  perform set_config('test.p1', v_b::text, true);
  perform pg_temp.act('a');
  v := public.get_booking(v_b);
  if v ->> 'payment_mode' <> 'stripe' or v ->> 'payment_state' <> 'due' or (v ->> 'fee_minor')::integer <> 480
     or (v ->> 'pay_by')::timestamptz > now() + interval '24 hours' or (v ->> 'pay_by')::timestamptz > v_at - interval '2 hours'
     or not (v ->> 'can_pay')::boolean then
    raise exception 'FAIL 2 in-app booking after confirmation: % % %', v ->> 'payment_mode', v ->> 'payment_state', v ->> 'fee_minor';
  end if;
  if not exists (select 1 from public.notifications n where n.kind = 'booking_payment_due' and n.payload ->> 'booking_id' = v_b::text
                    and n.email_status = 'pending') then
    raise exception 'FAIL 2 no payment due notice';
  end if;
  if (public.coach_payout_status() ->> 'state') <> 'none' then raise exception 'FAIL 2 a client has a payout state'; end if;
  perform pg_temp.act('c');
  if (public.coach_payout_status() ->> 'state') <> 'active' then raise exception 'FAIL 2 the coach''s payout state'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Checkout
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_b uuid := current_setting('test.p1')::uuid;
  v   jsonb;
begin
  if pg_temp.own_err(format('select public.booking_checkout_params(%L, %L)', v_b, pg_temp.uid('b'))) <> 'not_payable' then
    raise exception 'FAIL 3 checkout params for someone else';
  end if;
  v := public.booking_checkout_params(v_b, pg_temp.uid('a'));
  if (v ->> 'amount_minor')::integer <> 4000 or (v ->> 'fee_minor')::integer <> 480 or v ->> 'currency' <> 'usd'
     or v ->> 'stripe_account_id' <> 'acct_TestCoachC1' or (v ->> 'attempt')::integer <> 1 then
    raise exception 'FAIL 3 checkout params: %', v;
  end if;
  if pg_temp.pay(v_b) <> 'paid' then raise exception 'FAIL 3 mark paid'; end if;
  if public.booking_mark_paid(v_b, 'cs_test_' || replace(v_b::text, '-', ''), 'pi_test_' || replace(v_b::text, '-', ''), 4000) <> 'already' then
    raise exception 'FAIL 3 a replayed payment was applied twice';
  end if;
  if pg_temp.state(v_b) <> 'confirmed/paid' then raise exception 'FAIL 3 state after payment: %', pg_temp.state(v_b); end if;
  if pg_temp.own_err(format('select public.booking_checkout_params(%L, %L)', v_b, pg_temp.uid('a'))) <> 'not_payable' then
    raise exception 'FAIL 3 a paid booking is payable again';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Refunds per policy row
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_b uuid;
begin
  -- Client, 24 hours or more before: full.
  perform pg_temp.act('a');
  perform public.cancel_booking(current_setting('test.p1')::uuid);
  if pg_temp.job_amount(current_setting('test.p1')::uuid) <> 4000 or pg_temp.state(current_setting('test.p1')::uuid) <> 'cancelled/refund_pending' then
    raise exception 'FAIL 4 client early cancel: % %', pg_temp.job_amount(current_setting('test.p1')::uuid), pg_temp.state(current_setting('test.p1')::uuid);
  end if;
  -- Client inside 24 hours: half.
  v_b := pg_temp.booked('a', 'c', 'lc', pg_temp.at_local(3, time '11:00'));
  perform set_config('test.p2', v_b::text, true);
  perform pg_temp.pay(v_b);
  perform pg_temp.own(format($q$update public.bookings set free_cancel_until = now() - interval '1 minute' where id = %L$q$, v_b));
  perform pg_temp.act('a');
  if (public.cancel_booking(v_b) ->> 'refund_minor')::integer <> 2000 then
    raise exception 'FAIL 4 client late cancel answer';
  end if;
  if pg_temp.job_amount(v_b) <> 2000 then
    raise exception 'FAIL 4 client late cancel: %', pg_temp.job_amount(v_b);
  end if;
  -- Coach cancels: full.
  v_b := pg_temp.booked('a', 'c', 'lc', pg_temp.at_local(3, time '13:00'));
  perform pg_temp.pay(v_b);
  perform pg_temp.own(format($q$update public.bookings set free_cancel_until = now() - interval '1 minute' where id = %L$q$, v_b));
  perform pg_temp.act('c');
  perform public.cancel_booking(v_b);
  if pg_temp.job_amount(v_b) <> 4000 then raise exception 'FAIL 4 coach cancel: %', pg_temp.job_amount(v_b); end if;
  -- Block by the coach: full, even inside 24 hours.
  v_b := pg_temp.booked('b', 'c', 'lc', pg_temp.at_local(3, time '15:00'));
  perform pg_temp.pay(v_b);
  perform pg_temp.own(format($q$update public.bookings set free_cancel_until = now() - interval '1 minute' where id = %L$q$, v_b));
  perform pg_temp.act('c');
  perform public.block_user(pg_temp.uid('b'));
  if pg_temp.job_amount(v_b) <> 4000 or pg_temp.state(v_b) <> 'cancelled/refund_pending' then
    raise exception 'FAIL 4 block by the coach: %', pg_temp.job_amount(v_b);
  end if;
  perform public.unblock_user(pg_temp.uid('b'));
  -- Block by the client inside 24 hours: a client cancellation now (half).
  v_b := pg_temp.booked('k', 'c', 'lc', pg_temp.at_local(3, time '17:00'));
  perform pg_temp.pay(v_b);
  perform pg_temp.own(format($q$update public.bookings set free_cancel_until = now() - interval '1 minute' where id = %L$q$, v_b));
  perform pg_temp.act('k');
  perform public.block_user(pg_temp.uid('c'));
  if pg_temp.job_amount(v_b) <> 2000 then raise exception 'FAIL 4 block by the client: %', pg_temp.job_amount(v_b); end if;
  perform public.unblock_user(pg_temp.uid('c'));
  -- An open checkout on a cancelled booking is expired.
  v_b := pg_temp.booked('a', 'c', 'lc', pg_temp.at_local(4, time '08:00'));
  perform set_config('test.p6', v_b::text, true);
  perform pg_temp.own(format($q$select public.booking_checkout_opened(%L, 'cs_test_open6', 4000, 480, 'usd', 'acct_TestCoachC1')$q$, v_b));
  perform pg_temp.act('a');
  perform public.cancel_booking(v_b);
  if pg_temp.own_val(format($q$select count(*) from public.stripe_jobs where booking_id = %L and op = 'expire_checkout'$q$, v_b)) <> '1' then
    raise exception 'FAIL 4 the open checkout was not expired';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Webhook ledger, handlers, jobs
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_b  uuid;
  v_pi text;
  v    jsonb;
  v_id bigint;
begin
  if public.stripe_event_begin('evt_TestOne1', 'charge.refunded', null, 'ch_1', false) <> 'new' then
    raise exception 'FAIL 5 event begin new';
  end if;
  if public.stripe_event_begin('evt_TestOne1', 'charge.refunded', null, 'ch_1', false) <> 'retry' then
    raise exception 'FAIL 5 event begin retry';
  end if;
  perform public.stripe_event_finish('evt_TestOne1', 'boom');
  if public.stripe_event_begin('evt_TestOne1', 'charge.refunded', null, 'ch_1', false) <> 'retry' then
    raise exception 'FAIL 5 a failed event counts as done';
  end if;
  perform public.stripe_event_finish('evt_TestOne1', null);
  if public.stripe_event_begin('evt_TestOne1', 'charge.refunded', null, 'ch_1', false) <> 'done' then
    raise exception 'FAIL 5 a processed event is not done';
  end if;
  if pg_temp.own_err($q$select public.stripe_event_begin('bad id', 'x', null, null, false)$q$) = 'ok' then
    raise exception 'FAIL 5 an event id that is not evt_';
  end if;

  -- Refund recorded: partial, then full, never down.
  v_b := current_setting('test.p2')::uuid;
  v_pi := 'pi_test_' || replace(v_b::text, '-', '');
  if public.booking_refund_recorded(v_pi, 2000) <> 'partially_refunded' then
    raise exception 'FAIL 5 partial refund answer';
  end if;
  if pg_temp.state(v_b) <> 'cancelled/partially_refunded' then
    raise exception 'FAIL 5 partial refund';
  end if;
  perform public.booking_refund_recorded(v_pi, 4000);
  perform public.booking_refund_recorded(v_pi, 1000);
  if pg_temp.state(v_b) <> 'cancelled/refunded'
     or pg_temp.own_val(format('select refunded_minor from public.booking_payments where booking_id = %L', v_b)) <> '4000' then
    raise exception 'FAIL 5 refund totals';
  end if;
  if public.booking_refund_recorded('pi_unknown', 100) <> 'unknown' then raise exception 'FAIL 5 unknown intent'; end if;

  -- A payment that lands after the booking was cancelled is refunded in full at once.
  v_b := current_setting('test.p6')::uuid;
  if public.booking_mark_paid(v_b, 'cs_test_open6', 'pi_test_late6', 4000) <> 'refund_queued' then
    raise exception 'FAIL 5 a late payment answer';
  end if;
  if pg_temp.own_val(format($q$select amount_minor from public.stripe_jobs where idempotency_key = 'refund:%s:late_payment'$q$, v_b)) <> '4000' then
    raise exception 'FAIL 5 a late payment was not refunded';
  end if;

  -- Dispute on a paid booking: disputed, an automatic booking report, the coach told; won: paid again.
  v_b := pg_temp.booked('z', 'c', 'lc', pg_temp.at_local(4, time '10:00'));
  perform set_config('test.p7', v_b::text, true);
  perform pg_temp.pay(v_b);
  v_pi := 'pi_test_' || replace(v_b::text, '-', '');
  if public.booking_dispute_update(v_pi, 'needs_response', false) <> 'disputed' then
    raise exception 'FAIL 5 dispute answer';
  end if;
  if pg_temp.state(v_b) <> 'confirmed/disputed'
     or not exists (select 1 from public.reports r where r.target_kind = 'booking' and r.target_id = v_b and r.reason = 'payment'
                       and r.reporter_id is null and r.status = 'open')
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('c') and n.kind = 'coach_payout_action') then
    raise exception 'FAIL 5 dispute opened';
  end if;
  perform public.booking_dispute_update(v_pi, 'won', true);
  if pg_temp.state(v_b) <> 'confirmed/paid' then raise exception 'FAIL 5 dispute won: %', pg_temp.state(v_b); end if;

  -- A listing under twice the minimum fee stays off-platform; no checkout opens for it.
  v_b := pg_temp.booked('z', 'c', 'lsmall', pg_temp.at_local(4, time '13:00'));
  if pg_temp.state(v_b) <> 'confirmed/off_platform'
     or pg_temp.own_err(format($q$select public.booking_checkout_opened(%L, 'cs_test_exp', 500, 0, 'usd', 'acct_TestCoachC1')$q$, v_b)) <> 'not_payable' then
    raise exception 'FAIL 5 a non-payable booking: %', pg_temp.state(v_b);
  end if;

  -- Jobs: claimed once, retried with backoff, failed after 8 attempts.
  v := public.stripe_jobs_claim(50);
  if jsonb_array_length(v) < 5 or exists (select 1 from jsonb_array_elements(v) e where e ->> 'op' = 'refund' and e ->> 'payment_intent_id' is null) then
    raise exception 'FAIL 5 jobs claim: %', jsonb_array_length(v);
  end if;
  if jsonb_array_length(public.stripe_jobs_claim(50)) <> 0 then raise exception 'FAIL 5 jobs claimed twice'; end if;
  v_id := (v -> 0 ->> 'id')::bigint;
  if public.stripe_job_done(v_id, false, 'stripe_error') <> 'pending' then raise exception 'FAIL 5 retry'; end if;
  update public.stripe_jobs set attempts = 8 where id = v_id;
  if public.stripe_job_done(v_id, false, 'stripe_error') <> 'failed' then raise exception 'FAIL 5 failed after 8'; end if;
  if public.stripe_job_done((v -> 1 ->> 'id')::bigint, true) <> 'done' then raise exception 'FAIL 5 done'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. coaching_tick and unpaid bookings
-- ---------------------------------------------------------------------------
do $$
declare
  v_due  uuid;
  v_fall uuid;
  v_late uuid;
begin
  v_due := pg_temp.booked('a', 'c', 'lc', pg_temp.at_local(5, time '08:00'));
  perform public.booking_checkout_opened(v_due, 'cs_test_due', 4000, 480, 'usd', 'acct_TestCoachC1');
  perform public.booking_payment_expired('cs_test_due');
  if pg_temp.state(v_due) <> 'confirmed/due' then raise exception 'FAIL 6 an expired checkout is not due again'; end if;
  v_fall := pg_temp.booked('b', 'c', 'lc', pg_temp.at_local(5, time '10:00'));
  update public.bookings set pay_by = now() - interval '1 minute' where id in (v_due, v_fall);
  perform public.coaching_tick();
  if pg_temp.state(v_due) <> 'cancelled/none'
     or pg_temp.own_val(format('select cancel_reason from public.bookings where id = %L', v_due)) <> 'unpaid' then
    raise exception 'FAIL 6 an unpaid booking was not cancelled: %', pg_temp.state(v_due);
  end if;
  if pg_temp.state(v_fall) <> 'confirmed/off_platform'
     or pg_temp.own_val(format('select payment_mode from public.bookings where id = %L', v_fall)) <> 'off_platform' then
    raise exception 'FAIL 6 a booking whose checkout never could open did not fall back: %', pg_temp.state(v_fall);
  end if;
  -- Once stripe-checkout has run with its keys, an unpaid booking is cancelled instead.
  perform public.stripe_checkout_heartbeat();
  v_late := pg_temp.booked('k', 'c', 'lc', pg_temp.at_local(5, time '12:00'));
  update public.bookings set pay_by = now() - interval '1 minute' where id = v_late;
  perform public.coaching_tick();
  if pg_temp.state(v_late) <> 'cancelled/none' then raise exception 'FAIL 6 heartbeat: %', pg_temp.state(v_late); end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Reports and moderation
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_done uuid;
begin
  -- A completed booking with a review and a reply (z with d).
  v_done := pg_temp.booked('z', 'd', 'ld', pg_temp.at_local(2, time '08:00'));
  perform set_config('test.done', v_done::text, true);
  perform pg_temp.own(format($q$update public.bookings set starts_at = now() - interval '3 hours', ends_at = now() - interval '2 hours' where id = %L$q$, v_done));
  perform pg_temp.act('d');
  perform public.complete_booking(v_done);
  perform pg_temp.act('z');
  perform public.write_review(v_done, 2, 'Late and distracted');
  perform pg_temp.act('d');
  perform public.reply_to_review(v_done, 'Sorry, the court was double booked');
end $$;
set local role authenticated;
do $$
declare
  v jsonb;
begin
  perform pg_temp.act('x');
  v := public.report_content('coach_listing', current_setting('test.ld')::uuid, 'scam', 'Looks fake');
  if (v ->> 'already')::boolean then raise exception 'FAIL 7 listing report'; end if;
  v := public.report_content('coach_review', current_setting('test.done')::uuid, 'harassment', null);
  v := public.report_content('coach_review_reply', current_setting('test.done')::uuid, 'harassment', null);
  if pg_temp.err(format('select public.report_content(%L, %L, %L)', 'booking', current_setting('test.done'), 'unsafe')) <> 'target_not_found' then
    raise exception 'FAIL 7 a stranger reported a booking';
  end if;
  if pg_temp.err(format('select public.report_content(%L, %L, %L)', 'profile', pg_temp.uid('d'), 'no_show')) <> 'invalid_reason' then
    raise exception 'FAIL 7 a booking reason on a profile';
  end if;
  perform pg_temp.act('z');
  v := public.report_content('booking', current_setting('test.done')::uuid, 'no_show', 'The coach left after ten minutes');
  if (v ->> 'hidden')::boolean then raise exception 'FAIL 7 a booking report hid something'; end if;
  if pg_temp.err(format('select public.report_content(%L, %L, %L)', 'coach_review', current_setting('test.done'), 'spam')) <> 'own_item' then
    raise exception 'FAIL 7 an author reported their own review';
  end if;
end $$;
reset role;
do $$
begin
  if (select r.target_user_id from public.reports r where r.target_kind = 'coach_listing' and r.target_id = current_setting('test.ld')::uuid limit 1) <> pg_temp.uid('d')
     or (select r.target_user_id from public.reports r where r.target_kind = 'coach_review' and r.target_id = current_setting('test.done')::uuid limit 1) <> pg_temp.uid('z')
     or (select r.target_user_id from public.reports r where r.target_kind = 'coach_review_reply' and r.target_id = current_setting('test.done')::uuid limit 1) <> pg_temp.uid('d')
     or (select r.target_user_id from public.reports r where r.target_kind = 'booking' and r.target_id = current_setting('test.done')::uuid and r.reporter_id = pg_temp.uid('z')) <> pg_temp.uid('d') then
    raise exception 'FAIL 7 report target users';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v   jsonb;
  v_b uuid;
begin
  perform pg_temp.act('m');
  if not exists (select 1 from jsonb_array_elements(public.mod_queue(500)) e where e ->> 'detail' = 'booking') then
    raise exception 'FAIL 7 booking reports are not in the queue';
  end if;
  -- A hidden review leaves the rating; the reply can be hidden on its own.
  perform public.mod_moderate('coach_review', current_setting('test.done')::uuid, 'hide', null);
  if (select cp.rating_count from public.coach_profiles cp where cp.user_id = pg_temp.uid('d')) <> 0 then
    raise exception 'FAIL 7 a hidden review still counts';
  end if;
  perform public.mod_moderate('coach_review_reply', current_setting('test.done')::uuid, 'hide', null);
  perform pg_temp.act('x');
  if exists (select 1 from public.coach_reviews where booking_id = current_setting('test.done')::uuid)
     or jsonb_array_length(public.coach_reviews_page(pg_temp.uid('d')) -> 'items') <> 0 then
    raise exception 'FAIL 7 a hidden review is visible';
  end if;
  perform pg_temp.act('d');
  v := public.coach_reviews_page(pg_temp.uid('d'));
  if v -> 'items' -> 0 ->> 'moderation_state' <> 'hidden' then raise exception 'FAIL 7 the coach does not see the label'; end if;
  perform pg_temp.act('m');
  if pg_temp.err(format('select public.mod_moderate(%L, %L, %L)', 'booking', current_setting('test.done'), 'hide')) <> 'invalid_action' then
    raise exception 'FAIL 7 a booking was hidden through mod_moderate';
  end if;
  v := public.mod_booking(current_setting('test.done')::uuid, 'cancel_refund', 'Upheld for the client');
  if v ->> 'status' <> 'cancelled' or (v ->> 'reports_closed')::integer < 1 then raise exception 'FAIL 7 mod_booking: %', v; end if;
  -- Removing a listing ends its open bookings with full refunds.
  v_b := pg_temp.booked('a', 'd', 'ld', pg_temp.at_local(6, time '09:00'));
  perform pg_temp.act('m');
  perform public.mod_moderate('coach_listing', current_setting('test.ld')::uuid, 'remove', null);
  perform pg_temp.act('a');
  v := public.get_booking(v_b);
  if v ->> 'status' <> 'cancelled' or v ->> 'cancel_reason' <> 'listing_removed' then
    raise exception 'FAIL 7 a removed listing kept its booking';
  end if;
  if exists (select 1 from public.coach_listings where id = current_setting('test.ld')::uuid) then
    raise exception 'FAIL 7 a removed listing is visible';
  end if;
  -- The second-moderator rule: a party cannot decide their own booking.
  perform pg_temp.act('m');
  if pg_temp.err(format('select public.mod_booking(%L, %L)', current_setting('test.p7'), 'complete')) <> 'ok' then
    raise exception 'FAIL 7 an unrelated moderator could not act';
  end if;
  perform pg_temp.own(format('insert into public.user_roles (user_id, role) values (%L, %L)', pg_temp.uid('a'), 'moderator'));
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.mod_booking(%L, %L)', v_b, 'complete')) <> 'own_item' then
    raise exception 'FAIL 7 a party decided their own booking';
  end if;
  perform pg_temp.own(format('delete from public.user_roles where user_id = %L', pg_temp.uid('a')));
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.mod_booking(%L, %L)', current_setting('test.p7'), 'complete')) <> 'forbidden'
     or pg_temp.err('select public.mod_coaching_numbers()') <> 'forbidden' then
    raise exception 'FAIL 7 a member used moderator RPCs';
  end if;
  perform pg_temp.act('m');
  v := public.mod_coaching_numbers();
  if (v ->> 'bookings_week')::integer < 5 then raise exception 'FAIL 7 numbers'; end if;
end $$;
-- Suspension and ban of a coach: future bookings end with full refunds.
do $$
declare
  v_b1 uuid;
  v_b2 uuid;
  v    jsonb;
begin
  v_b1 := pg_temp.booked('b', 'c', 'lc', pg_temp.at_local(6, time '08:00'));
  perform pg_temp.pay(v_b1);
  perform pg_temp.act('m');
  v := public.mod_set_coach_status(pg_temp.uid('c'), 'suspended', 'Repeated no-shows');
  if v ->> 'status' <> 'suspended' or (v ->> 'bookings_cancelled')::integer < 1 or pg_temp.job_amount(v_b1) <> 4000 then
    raise exception 'FAIL 7 suspension: %', v;
  end if;
  v := public.mod_set_coach_status(pg_temp.uid('c'), 'active', null);
  if v ->> 'status' <> 'active' then raise exception 'FAIL 7 restore'; end if;
  perform pg_temp.act('c');
  perform public.set_listing_status(current_setting('test.lc')::uuid, 'active');
  v_b2 := pg_temp.booked('b', 'c', 'lc', pg_temp.at_local(6, time '12:00'));
  perform pg_temp.pay(v_b2);
  perform pg_temp.own(format($q$update public.bookings set free_cancel_until = now() - interval '1 minute' where id = %L$q$, v_b2));
  perform pg_temp.act('m2');
  v := public.mod_ban_user(pg_temp.uid('c'), 'Test ban');
  if (v ->> 'bookings_cancelled')::integer <> 1 or pg_temp.job_amount(v_b2) <> 4000
     or pg_temp.own_val(format('select cancel_reason from public.bookings where id = %L', v_b2)) <> 'banned'
     or pg_temp.own_val(format('select status::text from public.coach_profiles where user_id = %L', pg_temp.uid('c'))) <> 'suspended' then
    raise exception 'FAIL 7 ban: %', v;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_past uuid;
  v_fut  uuid;
  v_zf   uuid;
begin
  -- d gets everything a coach can have; z is a client of d with a past (reviewed) and a future booking.
  perform pg_temp.act('d');
  perform public.set_coach_credentials('[{"title":"Club coach"}]'::jsonb);
  perform public.set_coach_photos(array[public.project_url() || '/storage/v1/object/public/avatars/' || pg_temp.uid('d') || '/coach/1.jpg']);
  perform public.add_availability_exception(format('{"kind":"unavailable","starts_at":"%s","ends_at":"%s"}', now() + interval '20 days', now() + interval '21 days')::jsonb);
  perform set_config('test.ld2', public.upsert_listing('{"title":"Tennis again","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","min_notice_hours":1,"slot_step_minutes":60,"meeting_note":"Court 5"}'::jsonb) ->> 'id', true);
  perform public.stripe_account_upsert(pg_temp.uid('d'), '{"stripe_account_id":"acct_TestCoachD1","country":"US","default_currency":"usd","charges_enabled":true}'::jsonb);
  v_past := pg_temp.booked('z', 'd', 'ld2', pg_temp.at_local(2, time '14:00'));
  update public.bookings set starts_at = now() - interval '3 hours', ends_at = now() - interval '2 hours' where id = v_past;
  perform pg_temp.act('d');
  perform public.complete_booking(v_past);
  perform pg_temp.act('z');
  perform public.write_review(v_past, 5, 'Great session');
  perform pg_temp.act('x');
  perform public.report_content('coach_review', v_past, 'spam', null);
  v_fut := pg_temp.booked('a', 'd', 'ld2', pg_temp.at_local(7, time '09:00'));
  perform pg_temp.pay(v_fut);
  v_zf := pg_temp.booked('z', 'd', 'ld2', pg_temp.at_local(7, time '13:00'));
  perform set_config('test.past', v_past::text, true);
  perform set_config('test.fut', v_fut::text, true);
  perform set_config('test.zf', v_zf::text, true);
end $$;
set local role authenticated;
do $$
begin
  -- The client z leaves first.
  perform pg_temp.act('z');
  perform public.request_account_deletion('test');
end $$;
reset role;
do $$
begin
  if exists (select 1 from public.coach_reviews where client_id = pg_temp.uid('z')) then
    raise exception 'FAIL 8 a deleted client''s reviews remain';
  end if;
  if not exists (select 1 from public.reports r where r.target_kind = 'coach_review' and r.target_id = current_setting('test.past')::uuid
                    and r.note like '%Great session%') then
    raise exception 'FAIL 8 the reported review''s text was not kept in the report';
  end if;
  if pg_temp.state(current_setting('test.zf')::uuid) not like 'cancelled/%'
     or (select cancel_reason from public.bookings where id = current_setting('test.zf')::uuid) <> 'account_deleted' then
    raise exception 'FAIL 8 a deleted client''s future booking was not cancelled';
  end if;
  if exists (select 1 from public.bookings where client_id = pg_temp.uid('z') and client_note <> '')
     or exists (select 1 from public.booking_private bp join public.bookings b on b.id = bp.booking_id where b.client_id = pg_temp.uid('z'))
     or (select count(*) from public.bookings where client_id = pg_temp.uid('z')) = 0 then
    raise exception 'FAIL 8 a deleted client''s bookings: notes and meeting details must go, the records stay';
  end if;
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
  d uuid := pg_temp.uid('d');
begin
  if exists (select 1 from public.coach_profiles where user_id = d)
     or exists (select 1 from public.coach_credentials where coach_id = d)
     or exists (select 1 from public.coach_photos where coach_id = d)
     or exists (select 1 from public.coach_hubs where coach_id = d)
     or exists (select 1 from public.coach_listings where coach_id = d)
     or exists (select 1 from public.coach_listing_private where listing_id = current_setting('test.ld2')::uuid)
     or exists (select 1 from public.coach_availability_rules where coach_id = d)
     or exists (select 1 from public.coach_availability_exceptions where coach_id = d)
     or exists (select 1 from public.coach_sessions where coach_id = d)
     or exists (select 1 from public.coach_reviews where coach_id = d or client_id = d) then
    raise exception 'FAIL 8 coach rows remain after deletion';
  end if;
  if (select count(*) from public.bookings where coach_id = d) < 3
     or exists (select 1 from public.bookings where coach_id = d and (listing_id is not null or session_id is not null))
     or exists (select 1 from public.bookings where coach_id = d and client_note <> '')
     or exists (select 1 from public.booking_private bp join public.bookings b on b.id = bp.booking_id where b.coach_id = d) then
    raise exception 'FAIL 8 past bookings must stay as records without links, notes or meeting details';
  end if;
  if pg_temp.state(current_setting('test.fut')::uuid) <> 'cancelled/refund_pending'
     or pg_temp.job_amount(current_setting('test.fut')::uuid) <> 4000
     or (select cancel_reason from public.bookings where id = current_setting('test.fut')::uuid) <> 'account_deleted' then
    raise exception 'FAIL 8 the deleted coach''s future booking: %', pg_temp.state(current_setting('test.fut')::uuid);
  end if;
  if not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('a') and n.kind = 'booking_cancelled'
                    and n.payload ->> 'booking_id' = current_setting('test.fut')) then
    raise exception 'FAIL 8 the client was not told';
  end if;
  -- Kept on purpose: payment records (7 years) and the Stripe account row until delete-account closes it.
  if not exists (select 1 from public.booking_payments where booking_id = current_setting('test.fut')::uuid)
     or not exists (select 1 from public.coach_stripe_accounts where coach_id = d) then
    raise exception 'FAIL 8 payment records or the Stripe account row went too early';
  end if;
  if (select first_name from public.profiles where id = d) <> 'Deleted user' then
    raise exception 'FAIL 8 the tombstone';
  end if;
end $$;

select 'coaching_payments: PASS' as result;

rollback;
