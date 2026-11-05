-- ============================================================================
-- Activity Planet schema v2 — migration 61: coaching review fixes
--   (D-044, docs/design/coaching/COACHING_DESIGN.md). Builds on migration 60
--   (20261224000100_coaching.sql), which reached staging and is not edited.
--   Every rebuilt function starts from its latest body (all in migration 60)
--   and each change is marked "Migration 61". Checks:
--   supabase/tests/coaching_review_fixes.sql.
--
--   1. Group seats: request_booking locks the group session's row before it
--      counts seats, and booking_confirm locks it before its own count, so
--      two people asking for the last seat at once can no longer both get
--      it (the second waits, then sees the seat taken: full).
--   2. A deleted coach's Stripe account: public.coach_stripe_close_blocked
--      (service role) is true while a refund or expiry job for the coach's
--      bookings is pending or sent, or a booking could still refund (paid or
--      processing and confirmed, an unsettled no-show, a dispute).
--      delete-account asks it before DELETE /v1/accounts and queues the
--      close_account job instead; stripe_jobs_claim holds such a job an
--      hour at a time, without counting an attempt, until it is false. The
--      refund queued by the deletion therefore runs while the account exists.
--   3. Payments off (meta.coach_payments): stripe_dispatch no longer needs
--      the flag, so refunds, expiries and closes already owed still run
--      (stripe-checkout answers 503 without its key). coaching_tick turns a
--      booking whose payment is still due (no checkout open) into an
--      off-platform one at pay_by while payments are off, as it does when no
--      checkout could ever open, instead of cancelling it as unpaid.
--   4. A deleted coach: write_review refuses (not_found) and coaching_tick
--      sends no review prompt, so a session that had started when the coach
--      deleted their account cannot produce a coach_reviews row afterwards.
--   5. Listings: booking_confirm refuses a listing that is hidden, removed,
--      paused or archived (listing_unavailable), so a request that was
--      already waiting can no longer be confirmed there.
--   6. Grants (explicit) and meta.schema_version 2.57.
--
--   The app (packages/core coaching api) now reads the Edge Functions' JSON
--   error body, so payments_off, not_payable and the Connect errors reach the
--   copy table.
--
--   Account deletion: no new table or column.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 2. Closing a deleted coach's Stripe account waits for refunds
-- ---------------------------------------------------------------------------
create or replace function public.coach_stripe_close_blocked(p_coach uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_coach is not null and (
    exists (select 1 from public.stripe_jobs j
              join public.bookings b on b.id = j.booking_id
             where b.coach_id = p_coach and j.status in ('pending', 'sent'))
    or exists (select 1 from public.bookings b
                where b.coach_id = p_coach and b.payment_mode = 'stripe'
                  and (b.payment_state = 'disputed'
                       or (b.status = 'confirmed' and b.payment_state in ('processing', 'paid'))
                       or (b.status = 'no_show' and b.no_show_settled_at is null and b.payment_state = 'paid'))));
$$;
comment on function public.coach_stripe_close_blocked(uuid) is
  'Migration 61, service role (delete-account, stripe_jobs_claim): true while the coach''s connected account must stay open because money can still move back through it: a refund or checkout-expiry job for one of their bookings is pending or sent, or a booking is disputed, paid or processing and confirmed, or a paid no-show is not settled. False for null.';

create or replace function public.stripe_jobs_claim(p_limit integer default 20)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_out jsonb;
begin
  update public.stripe_jobs j set status = 'pending', updated_at = now()
   where j.status = 'sent' and j.updated_at < now() - interval '10 minutes';
  -- Migration 61: a deleted coach's account is closed only once nothing can still refund through
  -- it (reverse_transfer needs the account); until then the job waits an hour, without an attempt.
  update public.stripe_jobs j set next_at = now() + interval '1 hour', updated_at = now()
   where j.status = 'pending' and j.op = 'close_account' and j.next_at <= now()
     and public.coach_stripe_close_blocked((select a.coach_id from public.coach_stripe_accounts a
                                             where a.stripe_account_id = j.stripe_account_id));
  with picked as (
    select j.id from public.stripe_jobs j
     where j.status = 'pending' and j.next_at <= now()
     order by j.next_at, j.id
     limit greatest(1, least(coalesce(p_limit, 20), 50))
     for update skip locked
  ), u as (
    update public.stripe_jobs j
       set status = 'sent', attempts = j.attempts + 1, updated_at = now()
      from picked
     where j.id = picked.id
    returning j.*
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', u.id, 'op', u.op, 'booking_id', u.booking_id, 'amount_minor', u.amount_minor,
           'idempotency_key', u.idempotency_key,
           'payment_intent_id', bp.payment_intent_id, 'checkout_session_id', bp.checkout_session_id,
           'stripe_account_id', coalesce(u.stripe_account_id, bp.stripe_account_id)) order by u.id), '[]'::jsonb)
    into v_out
    from u left join public.booking_payments bp on bp.booking_id = u.booking_id;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 1 and 5. Group seats under a lock; no new bookings on an unavailable listing
-- ---------------------------------------------------------------------------
create or replace function private.booking_confirm(p_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  b       public.bookings%rowtype;
  l       public.coach_listings%rowtype;
  v_sess  uuid;
  v_pay   timestamptz;
  v_other uuid;
begin
  select * into b from public.bookings where id = p_id for update;
  if not found then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if b.status <> 'requested' then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if now() >= b.expires_at or now() >= b.starts_at then
    raise exception 'expired' using errcode = 'check_violation';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_client:' || b.client_id::text));
  if exists (select 1 from public.bookings x
              where x.client_id = b.client_id and x.id <> b.id and x.status = 'confirmed'
                and x.starts_at < b.ends_at and x.ends_at > b.starts_at) then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end if;
  select * into l from public.coach_listings where id = b.listing_id;
  -- Migration 61: a hidden, removed, paused or archived listing takes no new bookings, even from
  -- requests that were already waiting.
  if l.id is not null and (l.status <> 'active' or l.moderation_state is not null) then
    raise exception 'listing_unavailable' using errcode = 'check_violation';
  end if;
  if b.format = 'one_on_one' then
    if l.id is null then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    begin
      insert into public.coach_sessions (coach_id, listing_id, starts_at, ends_at, busy, capacity)
      values (b.coach_id, l.id, b.starts_at, b.ends_at, tstzrange(b.starts_at, b.ends_at, '[)'), 1)
      returning id into v_sess;
    exception when exclusion_violation then
      raise exception 'slot_taken' using errcode = 'check_violation';
    end;
  else
    v_sess := b.session_id;
    -- Migration 61: seats are counted under the session's row lock (request_booking takes it too),
    -- so two confirmations for the last seat cannot both pass.
    perform 1 from public.coach_sessions s where s.id = v_sess for update;
    if v_sess is null or not exists (select 1 from public.coach_sessions s where s.id = v_sess and s.status = 'scheduled') then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    if (select count(*) from public.bookings x where x.session_id = v_sess and x.status = 'confirmed')
       >= (select s.capacity from public.coach_sessions s where s.id = v_sess) then
      raise exception 'full' using errcode = 'check_violation';
    end if;
  end if;
  if b.payment_mode = 'stripe' then
    v_pay := least(now() + interval '24 hours', b.starts_at - interval '2 hours');
    if v_pay <= now() then
      v_pay := least(now() + interval '1 hour', b.starts_at);
    end if;
  end if;
  update public.bookings
     set status = 'confirmed', confirmed_at = now(), session_id = v_sess, pay_by = v_pay,
         payment_state = case when payment_mode = 'stripe' then 'due'::public.booking_payment_state else payment_state end
   where id = b.id;
  insert into public.booking_private (booking_id, meeting_note, online_link)
  select b.id, coalesce(lp.meeting_note, ''), lp.online_link
    from (select 1) one left join public.coach_listing_private lp on lp.listing_id = b.listing_id
  on conflict (booking_id) do nothing;
  -- Requests do not hold time: the coach's other one-on-one requests that overlap are declined.
  if b.format = 'one_on_one' then
    for v_other in
      select x.id from public.bookings x
        join public.coach_sessions s on s.id = v_sess
       where x.coach_id = b.coach_id and x.id <> b.id and x.status = 'requested' and x.format = 'one_on_one'
         and tstzrange(x.starts_at, x.ends_at, '[)') && s.busy
    loop
      perform private.booking_decline(v_other, 'slot_taken', true);
    end loop;
  end if;
  perform private.booking_notify(b.id, b.client_id, 'booking_confirmed');
  if b.payment_mode = 'stripe' then
    perform private.booking_notify(b.id, b.client_id, 'booking_payment_due',
                                   jsonb_build_object('pay_by', v_pay, 'price_minor', b.price_minor,
                                                      'currency', b.currency));
  end if;
end $$;

create or replace function public.request_booking(p_listing uuid, p_starts_at timestamptz, p_note text,
                                                  p_policy_version text, p_client_request_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  l         public.coach_listings%rowtype;
  b         public.bookings%rowtype;
  v_tz      text;
  v_day     date;
  v_found   boolean;
  v_end     timestamptz;
  v_session uuid;
  v_mode    text;
  v_state   public.booking_payment_state;
  v_fee     integer := 0;
  v_expires timestamptz;
  v_note    text := btrim(coalesce(p_note, ''));
  v_id      uuid;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  if p_client_request_id is null or p_listing is null or p_starts_at is null then
    raise exception 'invalid_request' using errcode = 'check_violation';
  end if;
  -- Idempotent: a retry with the same client request id returns the stored booking.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_req:' || uid::text || ':' || p_client_request_id::text));
  select * into b from public.bookings where client_id = uid and client_request_id = p_client_request_id;
  if found then
    return jsonb_build_object('id', b.id, 'status', b.status, 'payment_mode', b.payment_mode, 'duplicate', true);
  end if;
  if p_policy_version is null or p_policy_version <> private.refund_policy_version() then
    raise exception 'policy_ack_required' using errcode = 'check_violation';
  end if;
  select * into l from public.coach_listings where id = p_listing;
  if not found or not private.coach_listing_visible(p_listing) then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if l.coach_id = uid then
    raise exception 'cannot_book_self' using errcode = 'check_violation';
  end if;
  if char_length(v_note) > 500 or not private.coach_text_ok(v_note) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;

  -- The message-request limits (a request opens a DM): 10 a day, 5 open, one open per listing.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('booking_requests:' || uid::text));
  if (select count(*) from public.bookings x where x.client_id = uid and x.requested_at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
  end if;
  if (select count(*) from public.bookings x where x.client_id = uid and x.status = 'requested') >= 5
     or exists (select 1 from public.bookings x where x.client_id = uid and x.listing_id = l.id and x.status = 'requested') then
    raise exception 'too_many_open' using errcode = 'check_violation';
  end if;

  -- Migration 61: a group session's seats are counted under its row lock, so two requests for the
  -- last seat cannot both see it free (the second waits, then counts the first).
  if l.format = 'group' then
    perform 1 from public.coach_sessions s
     where s.listing_id = l.id and s.starts_at = p_starts_at and s.status = 'scheduled'
     for update;
  end if;

  -- The same function the client was shown (design section 4).
  select cp.timezone into v_tz from public.coach_profiles cp where cp.user_id = l.coach_id;
  v_day := (p_starts_at at time zone v_tz)::date;
  select true, s.ends_at, s.session_id into v_found, v_end, v_session
    from private.coach_open_slots(l.id, v_day, v_day) s
   where s.starts_at = p_starts_at
   limit 1;
  if not coalesce(v_found, false) then
    if l.format = 'group' and exists (select 1 from public.coach_sessions s
                                       where s.listing_id = l.id and s.status = 'scheduled' and s.starts_at = p_starts_at
                                         and s.starts_at > now()
                                         and s.capacity <= private.coach_session_seats(s.id)) then
      raise exception 'full' using errcode = 'check_violation';
    end if;
    raise exception 'slot_unavailable' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.bookings x
              where x.client_id = uid and x.status = 'confirmed'
                and x.starts_at < v_end and x.ends_at > p_starts_at) then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end if;

  if l.price_minor = 0 then
    v_mode := 'none'; v_state := 'none';
  elsif private.coach_listing_payable(l.id) then
    v_mode := 'stripe'; v_state := 'none'; v_fee := private.coach_fee(l.price_minor, l.currency);
  else
    v_mode := 'off_platform'; v_state := 'off_platform';
  end if;
  v_expires := least(now() + interval '48 hours', p_starts_at - interval '2 hours');
  if v_expires <= now() then
    v_expires := p_starts_at;
  end if;

  begin
    insert into public.bookings (listing_id, session_id, coach_id, client_id, starts_at, ends_at, title, delivery,
                                 format, price_minor, currency, fee_minor, payment_mode, payment_state,
                                 policy_version, free_cancel_until, client_note, client_request_id, expires_at)
    values (l.id, v_session, l.coach_id, uid, p_starts_at, v_end, l.title, l.delivery, l.format, l.price_minor,
            l.currency, v_fee, v_mode, v_state, p_policy_version, p_starts_at - interval '24 hours', v_note,
            p_client_request_id, v_expires)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'client_overlap' using errcode = 'check_violation';
  end;
  perform private.booking_notify(v_id, l.coach_id, 'booking_requested');
  if l.auto_confirm then
    perform private.booking_confirm(v_id);
  end if;
  select * into b from public.bookings where id = v_id;
  return jsonb_build_object('id', b.id, 'status', b.status, 'payment_mode', b.payment_mode, 'duplicate', false);
end $$;
comment on function public.request_booking(uuid, timestamptz, text, text, uuid) is
  'Migration 60 (61: a group session''s seats are counted under its row lock): the caller asks for p_starts_at on a listing. The start must be one coach_slots offers now (slot_unavailable; a group session with no seat left is full). Stores the snapshot (title, delivery, format, price, currency), the payment mode (none for free, stripe when payments are on and the listing is payable, else off_platform), the Refund Policy version acknowledged, free_cancel_until (start - 24 h) and expires_at (least(now + 48 h, start - 2 h), or the start when that is past). Idempotent on (caller, p_client_request_id). With auto_confirm it confirms at once. Message-request limits apply: 10 requests a day (rate_limited), 5 open and one open per listing (too_many_open). Errors: section 2 rules, invalid_request, policy_ack_required, not_found (also a block or over the viewer''s age), cannot_book_self, invalid_text, rate_limited, too_many_open, slot_unavailable, full, client_overlap.';

-- ---------------------------------------------------------------------------
-- 3 and 4. Payments off; a deleted coach
-- ---------------------------------------------------------------------------
create or replace function public.stripe_dispatch()
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_secret text;
begin
  -- Migration 61: not gated on meta.coach_payments. Turning payments off stops new checkouts;
  -- refunds, expiries and account closes already owed still run (stripe-checkout answers 503
  -- without its key, so nothing is sent then).
  if not exists (select 1 from public.stripe_jobs j where j.status = 'pending' and j.next_at <= now() + interval '1 minute') then
    return null;
  end if;
  if v_base is null then
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'stripe_dispatch_secret' limit 1;
  end if;
  if v_secret is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/stripe-checkout',
    body := jsonb_build_object('op', 'job'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-stripe-dispatch-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;

create or replace function public.coaching_tick()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b          public.bookings%rowtype;
  n_expired  integer := 0;
  n_unpaid   integer := 0;
  n_fallback integer := 0;
  n_remind   integer := 0;
  n_complete integer := 0;
  n_settled  integer := 0;
  n_prompts  integer := 0;
begin
  -- Requests nobody answered.
  for b in select * from public.bookings x where x.status = 'requested' and x.expires_at <= now() for update skip locked loop
    update public.bookings set status = 'expired', expired_at = now() where id = b.id;
    perform private.booking_notify(b.id, b.client_id, 'booking_declined', jsonb_build_object('reason', 'expired'));
    n_expired := n_expired + 1;
  end loop;

  -- Unpaid in-app payments: cancelled once pay_by passes. When no checkout could ever open (the
  -- flag is on but stripe-checkout has never run with its keys, meta.stripe_checkout_seen_at),
  -- the booking falls back to off-platform payment with a notice to both sides instead.
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.payment_mode = 'stripe' and x.payment_state in ('due', 'processing')
              and x.pay_by <= now() - case when x.payment_state = 'processing' then interval '15 minutes' else interval '0' end
            for update skip locked loop
    -- Migration 61: also while meta.coach_payments is off, a booking still due (no checkout open)
    -- falls back instead of being cancelled: the client could not have paid.
    if (not exists (select 1 from public.booking_payments bp where bp.booking_id = b.id)
        and coalesce((select m.value from public.meta m where m.key = 'stripe_checkout_seen_at'), '') = '')
       or (b.payment_state = 'due' and not private.coach_payments_on()) then
      update public.bookings set payment_mode = 'off_platform', payment_state = 'off_platform', fee_minor = 0, pay_by = null
       where id = b.id;
      perform private.booking_notify(b.id, b.client_id, 'booking_payment_due',
                                     jsonb_build_object('fallback', 'off_platform', 'key', 'fallback'));
      perform private.booking_notify(b.id, b.coach_id, 'booking_payment_due',
                                     jsonb_build_object('fallback', 'off_platform', 'key', 'fallback'));
      n_fallback := n_fallback + 1;
    elsif private.booking_cancel(b.id, 'system', 'unpaid', 'none', true) then
      n_unpaid := n_unpaid + 1;
    end if;
  end loop;

  -- Reminders, a day and 2 hours before, to both sides (idempotent by dedupe key).
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.starts_at > now() and x.starts_at <= now() + interval '24 hours' loop
    if b.starts_at > now() + interval '2 hours' then
      perform private.booking_notify(b.id, b.client_id, 'booking_reminder_day');
      perform private.booking_notify(b.id, b.coach_id, 'booking_reminder_day');
    else
      perform private.booking_notify(b.id, b.client_id, 'booking_reminder_2h');
      perform private.booking_notify(b.id, b.coach_id, 'booking_reminder_2h');
    end if;
    n_remind := n_remind + 1;
  end loop;

  -- Completed automatically 48 hours after the end when nobody reported a no-show.
  for b in select * from public.bookings x
            where x.status = 'confirmed' and x.ends_at + interval '48 hours' <= now() for update skip locked loop
    update public.bookings set status = 'completed', completed_at = now() where id = b.id;
    if b.format = 'one_on_one' then
      update public.coach_sessions set status = 'done' where id = b.session_id and status = 'scheduled';
    end if;
    n_complete := n_complete + 1;
  end loop;

  -- Uncontested no-shows settle after 48 hours; a coach no-show refunds in full.
  for b in select * from public.bookings x
            where x.status = 'no_show' and x.no_show_contested_at is null and x.no_show_settled_at is null
              and x.no_show_at + interval '48 hours' <= now() for update skip locked loop
    update public.bookings set no_show_settled_at = now(),
           payment_state = case when b.no_show_party = 'coach' and payment_state = 'paid'
                                then 'refund_pending'::public.booking_payment_state else payment_state end
     where id = b.id;
    if b.no_show_party = 'coach' and b.payment_state = 'paid' then
      insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
      select b.id, 'refund', bp.amount_minor, 'refund:' || b.id::text || ':no_show_coach'
        from public.booking_payments bp where bp.booking_id = b.id
      on conflict (idempotency_key) do nothing;
    end if;
    n_settled := n_settled + 1;
  end loop;

  -- Review prompts, 2 hours after completion.
  for b in select * from public.bookings x
            where x.status = 'completed' and x.completed_at <= now() - interval '2 hours'
              and x.completed_at > now() - interval '7 days'
              and not exists (select 1 from public.coach_reviews r where r.booking_id = x.id)
              -- Migration 61: no prompt to review a coach whose account was deleted.
              and not exists (select 1 from public.profiles p where p.id = x.coach_id and p.status = 'deleted')
              and not exists (select 1 from public.notifications n
                               where n.dedupe_key = 'booking_review_prompt:' || x.id::text || ':' || x.client_id::text) loop
    perform private.booking_notify(b.id, b.client_id, 'booking_review_prompt');
    n_prompts := n_prompts + 1;
  end loop;

  perform public.stripe_dispatch();
  return jsonb_build_object('expired', n_expired, 'unpaid_cancelled', n_unpaid, 'fell_back', n_fallback,
                            'reminders', n_remind, 'completed', n_complete, 'no_shows_settled', n_settled,
                            'review_prompts', n_prompts);
end $$;
comment on function public.coaching_tick() is
  'Migration 60 (61), service role (pg_cron coaching-tick every 5 minutes): expires unanswered requests, cancels unpaid in-app bookings past pay_by (or turns them off-platform when no checkout ever opened, or when payments are off and no checkout is open), sends day and 2-hour reminders, completes confirmed bookings 48 hours after the end, settles uncontested no-shows after 48 hours (a coach no-show queues a full refund), sends review prompts 2 hours after completion (not for a deleted coach), and dispatches due stripe_jobs. Returns counts.';

create or replace function public.write_review(p_booking uuid, p_rating integer, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b      public.bookings%rowtype;
  r      public.coach_reviews%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
begin
  b := private.booking_for_party(p_booking, 'client');
  -- Migration 61: no review of a coach whose account was deleted (nothing would remove it later).
  if public.users_blocked(b.coach_id, b.client_id)
     or exists (select 1 from public.profiles p where p.id = b.coach_id and p.status = 'deleted') then
    raise exception 'not_found' using errcode = 'P0002';
  end if;
  if b.status <> 'completed' then
    raise exception 'not_completed' using errcode = 'check_violation';
  end if;
  if now() > b.completed_at + interval '30 days' then
    raise exception 'review_window_closed' using errcode = 'check_violation';
  end if;
  if p_rating is null or p_rating not between 1 and 5 then
    raise exception 'invalid_rating' using errcode = 'check_violation';
  end if;
  if char_length(v_body) > 1000 or not private.review_text_ok(v_body) then
    raise exception 'review_filtered' using errcode = 'check_violation', hint = 'No links, and nothing from the blocked-words list.';
  end if;
  select * into r from public.coach_reviews where booking_id = b.id for update;
  if found then
    if r.created_at < now() - interval '7 days' then
      raise exception 'already_reviewed' using errcode = 'check_violation';
    end if;
    update public.coach_reviews set rating = p_rating, body = v_body, edited_at = now() where booking_id = b.id;
    return jsonb_build_object('booking_id', b.id, 'edited', true);
  end if;
  insert into public.coach_reviews (booking_id, coach_id, client_id, rating, body)
  values (b.id, b.coach_id, b.client_id, p_rating, v_body);
  perform private.booking_notify(b.id, b.coach_id, 'review_received', jsonb_build_object('rating', p_rating));
  return jsonb_build_object('booking_id', b.id, 'edited', false);
end $$;
comment on function public.write_review(uuid, integer, text) is
  'Migration 60: the client of a completed booking reviews it, from completed_at to 30 days later; one review per booking, editable for 7 days (a second call edits). No links, slur list refused. Errors: not_authenticated, not_found (also a block, or a coach whose account was deleted: migration 61), not_completed (no-shows, cancellations and open bookings cannot be reviewed), review_window_closed, invalid_rating, review_filtered, already_reviewed.';

-- ---------------------------------------------------------------------------
-- 6. Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.coach_stripe_close_blocked(uuid) from public, anon, authenticated;
grant execute on function public.coach_stripe_close_blocked(uuid) to service_role;
revoke all on function public.stripe_jobs_claim(integer) from public, anon, authenticated;
grant execute on function public.stripe_jobs_claim(integer) to service_role;
revoke all on function public.stripe_dispatch() from public, anon, authenticated;
grant execute on function public.stripe_dispatch() to service_role;
revoke all on function public.coaching_tick() from public, anon, authenticated;
grant execute on function public.coaching_tick() to service_role;
revoke all on function private.booking_confirm(uuid) from public, anon, authenticated;
grant execute on function private.booking_confirm(uuid) to service_role;
revoke all on function public.request_booking(uuid, timestamptz, text, text, uuid) from public, anon;
grant execute on function public.request_booking(uuid, timestamptz, text, text, uuid) to authenticated;
revoke all on function public.write_review(uuid, integer, text) from public, anon;
grant execute on function public.write_review(uuid, integer, text) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.57')
  on conflict (key) do update set value = excluded.value, updated_at = now();
