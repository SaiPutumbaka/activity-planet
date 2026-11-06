-- ============================================================================
-- Activity Planet schema v2 — migration 70: write RPCs answer not-found with HTTP 404.
--   Builds on migrations 1 to 69, which reached staging and are not edited.
--
--   Migration 69 moved the read RPCs' not-found answers to SQLSTATE PT404
--   (PostgREST: HTTP 404). The write RPCs that act on a missing row (cancel,
--   send, respond, confirm, decline, complete, hide, delete, report, moderate
--   and the rest) still raised P0002, which PostgREST reports as HTTP 500.
--   Each function below is rebuilt from its latest body with one change: the
--   raise of a missing-row code (not_found, *_not_found, not_a_member) uses
--   SQLSTATE PT404. Messages are unchanged, every auth and forbidden check
--   stays where it was (so "exists but forbidden" and "missing" read the same
--   as before), and grants are restated as they were. The app reads both
--   PT404 and P0002 as not found (packages/core NOT_FOUND_CODES).
--
--   66 functions, 98 raises:
--     private.booking_confirm, private.booking_for_party, private.coach_raise, add_group_members,
--     admin_set_moderator, approve_rsvp, block_user, broadcast_to_event, cancel_event, cancel_event_series,
--     cancel_group_session, check_in, confirm_booking, connect_organizer_feed, delete_message,
--     delete_my_place, event_rules_check, event_set_location, host_check_in, leave_conversation,
--     mark_conversation_read, materialize_event_series, mod_ban_user, mod_booking,
--     mod_listing_removal_resolve, mod_moderate, mod_organizer_claim_review, mod_set_coach_status,
--     mod_takedown_block_image, mod_takedown_resolve, mod_unban_user, mute_conversation, mute_user,
--     organizer_claim_check, place_apply_changes, remove_chapter_member, remove_conversation_member,
--     remove_rsvp, rename_group, reply_to_review, report_content, report_place, request_booking,
--     respond_message_request, review_chapter_claim, schedule_group_session, send_message, set_chapter_role,
--     set_conversation_notify, set_conversation_role, set_home_area, set_listing_status,
--     set_my_place_visibility, set_rsvp, start_dm, start_organizer_claim, submit_attendance,
--     submit_chapter_claim, suggest_place_edit, update_event, update_event_series, upsert_listing,
--     upsert_venue, venue_for_place, withdraw_chapter_claim, write_review
--
--   Left on P0002 on purpose: profile_missing and coach_profile_required (the
--   caller's own setup is incomplete, not a missing target); the service-role
--   collector paths (ingest_places, finish_place_tile, import_upsert_batch,
--   create_verification_code), whose callers read P0002 as they are; and the
--   rsvps_moderation_guard trigger (set_rsvp answers a missing event first).
--     * source_candidates_rescore (new, service role): stored discovery scores
--       from the current code (Wikidata bonus +10 again, commit a18f495).
--     * meta.schema_version 2.66.
--
--   Account deletion: no new table, nothing to add.
--   Idempotent: safe to re-run.
-- ============================================================================

-- booking_confirm: from 20261225000100_coaching_review_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
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
    raise exception 'not_found' using errcode = 'PT404';
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

revoke all on function private.booking_confirm(p_id uuid) from public, anon, authenticated;
grant execute on function private.booking_confirm(p_id uuid) to service_role;

-- booking_for_party: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function private.booking_for_party(p_id uuid, p_role text)
returns public.bookings language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  b   public.bookings%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into b from public.bookings where id = p_id for update;
  if not found
     or (p_role = 'coach' and b.coach_id <> uid)
     or (p_role = 'client' and b.client_id <> uid)
     or (p_role = 'either' and uid not in (b.coach_id, b.client_id)) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  return b;
end $$;

revoke all on function private.booking_for_party(p_id uuid, p_role text) from public, anon, authenticated;
grant execute on function private.booking_for_party(p_id uuid, p_role text) to service_role;

-- coach_raise: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function private.coach_raise(p_code text)
returns void language plpgsql set search_path = '' as $$
begin
  if p_code is null then
    return;
  end if;
  if p_code = 'not_authenticated' or p_code = 'forbidden' then
    raise exception '%', p_code using errcode = '42501';
  elsif p_code = 'not_found' then
    raise exception 'not_found' using errcode = 'PT404';
  elsif p_code = 'photo_required' then
    raise exception 'photo_required' using errcode = 'check_violation', hint = 'Add a profile photo first.';
  else
    raise exception '%', p_code using errcode = 'check_violation';
  end if;
end $$;

revoke all on function private.coach_raise(p_code text) from public, anon, authenticated;
grant execute on function private.coach_raise(p_code text) to service_role;

-- add_group_members: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.add_group_members(p_conversation uuid, p_users uuid[])
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  c       public.conversations%rowtype;
  v_users uuid[];
  v_user  uuid;
  v_n     integer;
  v_added integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found or c.kind <> 'group' or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if private.chat_role(c.id, uid) not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select coalesce(array_agg(distinct u), '{}') into v_users from unnest(coalesce(p_users, '{}')) u
   where u is not null and u <> uid
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = c.id and cm.user_id = u and cm.left_at is null and cm.removed_at is null);
  select count(*)::integer into v_n from public.conversation_members cm
   where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null;
  if v_n + cardinality(v_users) > 50 then
    raise exception 'too_many_members' using errcode = 'check_violation', hint = 'Up to 50 people.';
  end if;
  foreach v_user in array v_users loop
    if private.chat_can_add(uid, v_user, c.id) then
      insert into public.conversation_members (conversation_id, user_id) values (c.id, v_user)
      on conflict (conversation_id, user_id) do update
         set left_at = null, removed_at = null, removed_by = null, role = 'member', joined_at = now();
      v_added := v_added + 1;
    end if;
  end loop;
  return jsonb_build_object('added', v_added, 'skipped', cardinality(v_users) - v_added);
end $$;

revoke all on function public.add_group_members(p_conversation uuid, p_users uuid[]) from public, anon;
grant execute on function public.add_group_members(p_conversation uuid, p_users uuid[]) to authenticated, service_role;

-- admin_set_moderator: from 20261215000100_trust_safety.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.admin_set_moderator(p_user uuid, p_grant boolean, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  n      integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.has_role('admin'::public.app_role) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid or p_grant is null then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_grant then
    if not exists (select 1 from public.profiles p
                     join public.profile_private pp on pp.user_id = p.id
                    where p.id = p_user and p.status = 'active' and p.deleted_at is null
                      and p.onboarding_completed_at is not null
                      and pp.birth_date <= (current_date - interval '18 years')::date) then
      raise exception 'user_not_found' using errcode = 'PT404', hint = 'Moderators are active, onboarded adults.';
    end if;
    insert into public.user_roles (user_id, role, granted_by) values (p_user, 'moderator', uid)
    on conflict do nothing;
  else
    delete from public.user_roles where user_id = p_user and role = 'moderator';
  end if;
  get diagnostics n = row_count;
  if n > 0 then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
    values (uid, case when p_grant then 'grant_moderator' else 'revoke_moderator' end, 'profile', p_user, p_user, v_note);
  end if;
  return jsonb_build_object('moderator', p_grant, 'changed', n > 0);
end $$;

revoke all on function public.admin_set_moderator(p_user uuid, p_grant boolean, p_note text) from public, anon;
grant execute on function public.admin_set_moderator(p_user uuid, p_grant boolean, p_note text) to authenticated, service_role;

-- approve_rsvp: from 20261117000100_security_fixes.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.approve_rsvp(p_event_id uuid, p_user_id uuid, p_approved boolean default true)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
  v_was boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'PT404';
  end if;
  if r.status <> 'going' then
    raise exception 'not_going' using errcode = 'check_violation', hint = 'Only going attendees can be approved.';
  end if;
  v_was := r.approved_by_host;
  update public.rsvps
     set approved_by_host = coalesce(p_approved, true)
   where event_id = p_event_id and user_id = p_user_id
   returning * into r;
  if r.approved_by_host and not v_was and p_user_id is distinct from uid then
    perform public.enqueue_notification(
      p_user_id, 'rsvp_approved', 'rsvp_approved:' || p_event_id || ':' || p_user_id,
      p_event_id, e.hub_id, e.chapter_id, uid, public.notification_event_payload(p_event_id));
  end if;
  return r;
end $$;

revoke all on function public.approve_rsvp(p_event_id uuid, p_user_id uuid, p_approved boolean) from public, anon;
grant execute on function public.approve_rsvp(p_event_id uuid, p_user_id uuid, p_approved boolean) to authenticated, service_role;

-- block_user: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.block_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_already boolean;
  v_shared  integer;
  v_b       record;    -- Migration 60
  v_bk      integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'cannot_block_self' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  v_already := exists (select 1 from public.blocks where blocker_id = uid and blocked_id = p_user);
  if not v_already then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('blocks:' || uid::text));
    if (select count(*) from public.blocks where blocker_id = uid) >= 1000 then
      raise exception 'too_many_blocks' using errcode = 'check_violation', hint = 'Up to 1000 blocks.';
    end if;
    insert into public.blocks (blocker_id, blocked_id) values (uid, p_user) on conflict do nothing;
  end if;
  -- A block replaces a mute, and neither person keeps a "met" pick of the other.
  delete from public.mutes where muter_id = uid and muted_id = p_user;
  delete from public.event_meets
   where (user_id = uid and met_user_id = p_user) or (user_id = p_user and met_user_id = uid);
  -- Migration 58: a DM between them closes and a pending request is declined.
  update public.message_requests set status = 'declined', decided_at = now()
   where status = 'pending'
     and conversation_id in (select c.id from public.conversations c
                              where c.kind = 'dm' and c.dm_key = private.chat_dm_key(uid, p_user));
  update public.conversations set closed_at = coalesce(closed_at, now())
   where kind = 'dm' and dm_key = private.chat_dm_key(uid, p_user);
  -- Migration 60: their open bookings end, silently (design section 3.7). Requests are declined;
  -- a confirmed booking is cancelled: a block by the coach refunds in full, a block by the client
  -- is a client cancellation at this moment.
  for v_b in select b.id, b.status, (b.coach_id = uid) as by_coach from public.bookings b
              where ((b.coach_id = uid and b.client_id = p_user) or (b.coach_id = p_user and b.client_id = uid))
                and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
    if v_b.status = 'requested' then
      perform private.booking_decline(v_b.id, 'blocked', false);
    else
      perform private.booking_cancel(v_b.id, 'system', 'blocked', case when v_b.by_coach then 'full' else 'policy' end, false);
    end if;
    v_bk := v_bk + 1;
  end loop;
  -- Upcoming plans both are on (host or live RSVP), for the "you'll both be there" warning.
  select count(*)::integer into v_shared
    from public.events e
   where e.status = 'published' and e.ends_at > now()
     and (e.host_id = uid or exists (select 1 from public.rsvps r
                                      where r.event_id = e.id and r.user_id = uid and r.status <> 'cancelled'))
     and (e.host_id = p_user or exists (select 1 from public.rsvps r
                                         where r.event_id = e.id and r.user_id = p_user and r.status <> 'cancelled'));
  return jsonb_build_object('blocked', true, 'already', v_already, 'shared_upcoming', v_shared,
                            'bookings_ended', v_bk);   -- Migration 60
end $$;

revoke all on function public.block_user(p_user uuid) from public, anon;
grant execute on function public.block_user(p_user uuid) to authenticated, service_role;

-- broadcast_to_event: from 20261114000100_notifications.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.broadcast_to_event(p_event_id uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  e      public.events%rowtype;
  v_body text := btrim(coalesce(p_body, ''));
  v_id   uuid;
  n      integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage_event(p_event_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if e.ends_at < now() - interval '1 day' then
    raise exception 'event_over' using errcode = 'check_violation';
  end if;
  if char_length(v_body) not between 1 and 500 then
    raise exception 'body_length' using errcode = 'check_violation', hint = '1 to 500 characters.';
  end if;
  if (select count(*) from public.event_broadcasts
       where event_id = p_event_id and created_at > now() - interval '1 day') >= 3 then
    raise exception 'broadcast_limit' using errcode = 'check_violation',
      hint = 'Up to 3 messages per event per day.';
  end if;

  insert into public.event_broadcasts (event_id, sender_id, body)
  values (p_event_id, uid, v_body)
  returning id into v_id;
  n := public.notify_event_audience(
    p_event_id, 'broadcast', array['going', 'waitlisted']::public.rsvp_status[], v_id::text, uid,
    jsonb_build_object('body', v_body, 'broadcast_id', v_id));
  update public.event_broadcasts set recipient_count = n where id = v_id;
  return jsonb_build_object('broadcast_id', v_id, 'recipients', n);
end $$;

revoke all on function public.broadcast_to_event(p_event_id uuid, p_body text) from public, anon;
grant execute on function public.broadcast_to_event(p_event_id uuid, p_body text) to authenticated, service_role;

-- cancel_event: from 20261117000100_security_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.cancel_event(p_event_id uuid, p_reason text default null)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    return e;
  end if;
  update public.events
     set status        = 'cancelled',
         cancelled_at  = now(),
         cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 500)
   where id = e.id
   returning * into e;
  -- Going, waitlisted and interested people hear about it (migration 18).
  perform public.notify_event_audience(
    e.id, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
    e.id::text, uid, jsonb_build_object('reason', e.cancel_reason));
  return e;
end $$;

revoke all on function public.cancel_event(p_event_id uuid, p_reason text) from public, anon;
grant execute on function public.cancel_event(p_event_id uuid, p_reason text) to authenticated, service_role;

-- cancel_event_series: from 20261117000100_security_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.cancel_event_series(p_series_id uuid, p_reason text default null)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  s        public.event_series%rowtype;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 500);
  v_ids    uuid[];
  v_user   uuid;
  v_first  uuid;
  v_n      integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage(s.host_id, s.chapter_id, s.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.status = 'cancelled' then
    return s;
  end if;
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason
   where id = s.id
   returning * into s;
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason
     where series_id = s.id and status = 'published' and starts_at > now()
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;

  -- One notification per person for the whole series (migration 18), pointing
  -- at their next cancelled occurrence.
  for v_user, v_first, v_n in
    select r.user_id, (array_agg(r.event_id order by ev.starts_at))[1], count(*)::integer
      from public.rsvps r
      join public.events ev on ev.id = r.event_id
     where r.event_id = any (v_ids)
       and r.status in ('going', 'waitlisted', 'interested')
       and r.user_id <> uid
     group by r.user_id
  loop
    perform public.enqueue_notification(
      v_user, 'event_cancelled', 'event_cancelled:series:' || s.id || ':' || v_user,
      v_first, s.hub_id, s.chapter_id, uid,
      public.notification_event_payload(v_first)
        || jsonb_build_object('reason', v_reason, 'series_id', s.id, 'occurrences', v_n));
  end loop;
  return s;
end $$;

revoke all on function public.cancel_event_series(p_series_id uuid, p_reason text) from public, anon;
grant execute on function public.cancel_event_series(p_series_id uuid, p_reason text) to authenticated, service_role;

-- cancel_group_session: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.cancel_group_session(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  s   public.coach_sessions%rowtype;
  v_b uuid;
  n   integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into s from public.coach_sessions where id = p_id and coach_id = uid for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if not exists (select 1 from public.coach_listings l where l.id = s.listing_id and l.format = 'group') then
    raise exception 'not_group' using errcode = 'check_violation';
  end if;
  if s.status <> 'scheduled' or s.starts_at <= now() then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  for v_b in select b.id from public.bookings b where b.session_id = s.id and b.status in ('requested', 'confirmed') loop
    if private.booking_cancel(v_b, 'coach', 'coach', 'full', true) then
      n := n + 1;
    end if;
  end loop;
  update public.coach_sessions set status = 'cancelled', cancelled_at = now() where id = s.id;
  return jsonb_build_object('id', s.id, 'bookings_cancelled', n);
end $$;

revoke all on function public.cancel_group_session(p_id uuid) from public, anon;
grant execute on function public.cancel_group_session(p_id uuid) to authenticated, service_role;

-- check_in: from 20261113000100_chapter_tools.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.check_in(p_event_id uuid)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.starts_at - interval '1 hour' or now() > e.ends_at + interval '6 hours' then
    raise exception 'check_in_window' using errcode = 'check_violation',
      hint = 'Check in from an hour before the start until six hours after the end.';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  if not found or r.status <> 'going' then
    raise exception 'not_going' using errcode = 'check_violation', hint = 'Tap Going first.';
  end if;
  if r.checked_in_at is null then
    update public.rsvps set checked_in_at = now(), checked_in_by = uid
     where event_id = p_event_id and user_id = uid
     returning * into r;
  end if;
  return r;
end $$;

revoke all on function public.check_in(p_event_id uuid) from public, anon;
grant execute on function public.check_in(p_event_id uuid) to authenticated, service_role;

-- confirm_booking: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.confirm_booking(p_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  b public.bookings%rowtype;
begin
  b := private.booking_for_party(p_id, 'coach');
  if public.users_blocked(b.coach_id, b.client_id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if exists (select 1 from public.coach_profiles cp where cp.user_id = b.coach_id and cp.status = 'suspended')
     or exists (select 1 from public.profiles p where p.id = b.coach_id and p.status <> 'active') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  perform private.booking_confirm(p_id);
  return jsonb_build_object('id', p_id, 'status', 'confirmed');
end $$;

revoke all on function public.confirm_booking(p_id uuid) from public, anon;
grant execute on function public.confirm_booking(p_id uuid) to authenticated, service_role;

-- connect_organizer_feed: from 20261226000100_collector_completion.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.connect_organizer_feed(p_url text, p_claim uuid,
                                                        p_lat double precision default null,
                                                        p_lng double precision default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_claim  public.organizer_claims%rowtype;
  v_chk    jsonb;
  v_url    text;
  v_host   text;
  v_point  extensions.geography;
  v_region public.collector_regions%rowtype;
  v_rid    uuid;
  v_src    public.feed_sources%rowtype;
  v_id     uuid := gen_random_uuid();
  v_name   text;
  v_parent public.feed_sources%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found or v_claim.user_id <> uid then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  v_chk := public.source_url_check(p_url);
  if not (v_chk ->> 'ok')::boolean then
    raise exception '%', v_chk ->> 'error' using errcode = '22023', hint = coalesce(v_chk ->> 'reason', '');
  end if;
  v_url := v_chk ->> 'url';
  v_host := v_chk ->> 'host';
  if v_claim.status = 'verified' and v_claim.method <> 'feed' then
    if not (v_host = v_claim.host or public.registrable_domain(v_host) = public.registrable_domain(v_claim.host)) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  elsif v_claim.method = 'feed' and v_claim.status in ('pending', 'verified') then
    if v_url is distinct from v_claim.feed_url then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  else
    raise exception 'claim_not_verified' using errcode = 'P0001';
  end if;

  select * into v_src from public.feed_sources f where f.organizer_claim_id = v_claim.id and f.origin = 'organizer'
     and f.kind = 'ics' order by f.created_at limit 1 for update;
  if found then
    update public.feed_sources set url = v_url, last_error = null where id = v_src.id;
    return jsonb_build_object('source_id', v_src.id, 'slug', v_src.slug, 'created', false, 'enabled', v_src.enabled);
  end if;

  perform pg_advisory_xact_lock(hashtextextended('connect_organizer_feed:' || uid::text, 0));
  if (select count(*) from public.feed_sources f
        join public.organizer_claims c on c.id = f.organizer_claim_id
       where f.origin = 'organizer' and c.user_id = uid and f.organizer_stopped_at is null) >= 3 then
    raise exception 'feed_limit' using errcode = 'P0001';
  end if;

  -- The region: the owner's saved home, else the point they picked (rounded to 0.1 degree).
  select pp.home_point into v_point from public.profile_private pp where pp.user_id = uid;
  if v_point is null and p_lat between -90 and 90 and p_lng between -180 and 180 then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(round(p_lng::numeric, 1)::double precision,
                                                             round(p_lat::numeric, 1)::double precision), 4326)::extensions.geography;
  end if;
  if v_point is null then
    raise exception 'region_required' using errcode = '22023';
  end if;
  v_rid := public.organizer_region_for(v_point);
  if v_rid is null then
    raise exception 'region_unavailable' using errcode = 'P0001';
  end if;
  select * into v_region from public.collector_regions where id = v_rid;

  select * into v_parent from public.feed_sources where id = v_claim.source_id;
  v_name := left(coalesce(v_parent.name, 'Calendar from ' || v_claim.host), 80);
  insert into public.feed_sources
    (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane, origin,
     organizer_id, organizer_verified_at, organizer_claim_id, collector_region_id,
     region_point, region_radius_km, region_label, region_timezone)
  values
    ('org-' || substr(replace(v_id::text, '-', ''), 1, 12), 'ics', v_url, v_name,
     left('Listed by the organizer (' || v_claim.host || ').', 300),
     coalesce(v_parent.homepage_url, 'https://' || v_claim.host || '/'), false, true, 'feed', 'organizer',
     case when v_claim.status = 'verified' then uid end,
     case when v_claim.status = 'verified' then v_claim.verified_at end,
     v_claim.id, v_rid, v_region.point, v_region.radius_km, v_region.label, v_region.timezone)
  returning * into v_src;
  return jsonb_build_object('source_id', v_src.id, 'slug', v_src.slug, 'created', true, 'enabled', false);
end $$;

revoke all on function public.connect_organizer_feed(p_url text, p_claim uuid, p_lat double precision, p_lng double precision) from public, anon;
grant execute on function public.connect_organizer_feed(p_url text, p_claim uuid, p_lat double precision, p_lng double precision) to authenticated, service_role;

-- delete_message: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.delete_message(p_message uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  m      public.messages%rowtype;
  v_kind public.conversation_kind;
  v_by   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into m from public.messages where id = p_message for update;
  if not found or not private.chat_can_read(m.conversation_id)
     or not private.chat_visible_author(m.author_id, uid) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if m.deleted_at is not null then
    return;
  end if;
  select c.kind into v_kind from public.conversations c where c.id = m.conversation_id;
  if m.author_id = uid then
    v_by := 'author';
  elsif v_kind in ('group', 'event', 'chapter')
        and private.chat_role(m.conversation_id, uid) in ('owner', 'admin') then
    v_by := 'room_admin';
  else
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.messages
     set deleted_at = now(), deleted_by = v_by, deleted_body = body, body = '',
         image_state = case when kind = 'image' then 'removed' else image_state end
   where id = m.id;
  if v_by = 'room_admin' then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
    values (uid, 'remove', 'message', m.id, m.author_id, 'room_admin');
  end if;
end $$;

revoke all on function public.delete_message(p_message uuid) from public, anon;
grant execute on function public.delete_message(p_message uuid) to authenticated, service_role;

-- delete_my_place: from 20261128000100_place_contributions.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.delete_my_place(p_place uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   public.places%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.places where id = p_place and created_by = uid and source = 'user' for update;
  if not found then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  if p.is_public and p.status not in ('pending') then
    raise exception 'reviewed_place' using errcode = 'check_violation',
      hint = 'A reviewed public place stays on the map for everyone. Report it as closed if it is gone.';
  end if;
  delete from public.places where id = p.id;
end $$;

revoke all on function public.delete_my_place(p_place uuid) from public, anon;
grant execute on function public.delete_my_place(p_place uuid) to authenticated, service_role;

-- event_rules_check: from 20261025000100_v2_events.sql; 4 not-found raise(s) now PT404 (Migration 70).
create or replace function public.event_rules_check(
  p_kind               public.event_kind,
  p_hub_id             uuid,
  p_chapter_id         uuid,
  p_visibility         public.event_visibility,
  p_campus_id          uuid,
  p_min_age            smallint,
  p_venue_id           uuid,
  p_location_text      text,
  p_address_visibility public.address_visibility
)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_hub     public.hubs%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_venue   public.venues%rowtype;
  v_campus  uuid := p_campus_id;
  v_mod     boolean := public.is_moderator();
  v_age     integer := public.viewer_age();
begin
  if p_kind is null or p_kind = 'imported' then
    raise exception 'kind_not_allowed' using errcode = 'check_violation',
      hint = 'Imported events are written by the importer with the service role.';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;

  select * into v_hub from public.hubs where id = p_hub_id;
  if not found then
    raise exception 'hub_not_found' using errcode = 'PT404';
  end if;
  if not v_hub.is_active then
    raise exception 'hub_inactive' using errcode = 'check_violation';
  end if;

  if p_min_age is null or p_min_age not in (18, 21) then
    raise exception 'min_age_invalid' using errcode = 'check_violation';
  end if;
  if p_min_age < v_hub.min_age then
    raise exception 'hub_min_age' using errcode = 'check_violation',
      hint = 'Events in this hub are ' || v_hub.min_age || '+.';
  end if;
  if v_hub.scope = 'campus' and p_min_age <> 18 then
    raise exception 'campus_min_age' using errcode = 'check_violation',
      hint = '21+ events belong to non-campus hubs (D-027).';
  end if;
  if v_age is null or v_age < p_min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  if p_kind = 'member' then
    if p_chapter_id is not null then
      raise exception 'invalid_chapter' using errcode = 'check_violation',
        hint = 'Member events do not belong to a chapter.';
    end if;
    if not v_mod and not exists (select 1 from public.hub_members where hub_id = p_hub_id and user_id = uid) then
      raise exception 'not_hub_member' using errcode = '42501', hint = 'Join the hub to post an event in it.';
    end if;
  else
    if p_chapter_id is null then
      raise exception 'invalid_chapter' using errcode = 'check_violation', hint = 'Chapter events need a chapter.';
    end if;
    select * into v_chapter from public.hub_chapters where id = p_chapter_id;
    if not found or not v_chapter.is_active then
      raise exception 'chapter_not_found' using errcode = 'PT404';
    end if;
    if v_chapter.hub_id <> p_hub_id then
      raise exception 'chapter_mismatch' using errcode = 'check_violation', hint = 'The chapter belongs to another hub.';
    end if;
    if not v_mod and not public.is_chapter_captain(p_chapter_id) then
      raise exception 'not_chapter_captain' using errcode = '42501',
        hint = 'Only captains and organizers post as the chapter.';
    end if;
    if p_visibility = 'campus' then
      v_campus := coalesce(v_campus, v_chapter.campus_id);
    end if;
  end if;

  if p_visibility = 'campus' and v_campus is null then
    raise exception 'campus_required' using errcode = 'check_violation';
  end if;
  -- A campus tag puts the event in that campus's space whatever the visibility:
  -- verified members only, never 21+.
  if v_campus is not null then
    if not exists (select 1 from public.org_campuses where id = v_campus) then
      raise exception 'campus_not_found' using errcode = 'PT404';
    end if;
    if p_min_age <> 18 then
      raise exception 'campus_min_age' using errcode = 'check_violation',
        hint = '21+ events live outside the campus space (D-027).';
    end if;
    if v_chapter.id is not null and v_chapter.campus_id is not null and v_chapter.campus_id <> v_campus then
      raise exception 'chapter_mismatch' using errcode = 'check_violation', hint = 'The chapter belongs to another campus.';
    end if;
    if not v_mod and not public.is_campus_org_member(v_campus) then
      raise exception 'not_campus_member' using errcode = '42501',
        hint = 'Verify a campus email to post in the campus space.';
    end if;
  end if;

  if p_venue_id is not null then
    select * into v_venue from public.venues v
     where v.id = p_venue_id and (v.is_public or v.created_by = uid or v_mod);
    if not found then
      raise exception 'venue_not_found' using errcode = 'PT404';
    end if;
    if not v_venue.is_public and coalesce(p_address_visibility, 'public') = 'public' then
      raise exception 'private_venue_requires_approval' using errcode = 'check_violation',
        hint = 'This venue is a private address; share it after approval.';
    end if;
  elsif nullif(btrim(coalesce(p_location_text, '')), '') is null then
    raise exception 'location_required' using errcode = 'check_violation',
      hint = 'Pick a venue or describe where to meet.';
  end if;

  return v_campus;
end $$;

revoke all on function public.event_rules_check(p_kind public.event_kind, p_hub_id uuid, p_chapter_id uuid, p_visibility public.event_visibility, p_campus_id uuid, p_min_age smallint, p_venue_id uuid, p_location_text text, p_address_visibility public.address_visibility) from public, anon, authenticated;
grant execute on function public.event_rules_check(p_kind public.event_kind, p_hub_id uuid, p_chapter_id uuid, p_visibility public.event_visibility, p_campus_id uuid, p_min_age smallint, p_venue_id uuid, p_location_text text, p_address_visibility public.address_visibility) to service_role;

-- event_set_location: from 20261111000100_everyone_feed_v2.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.event_set_location(
  p_event_id           uuid,
  p_venue_id           uuid,
  p_location_text      text,
  p_address_note       text,
  p_address_visibility public.address_visibility,
  p_location_hint      text,
  p_campus_id          uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_venue  public.venues%rowtype;
  v_host   uuid;
  v_campus public.org_campuses%rowtype;
  v_hint   text;
  v_point  extensions.geography;
  v_text   text := btrim(coalesce(p_location_text, ''));
begin
  select host_id into v_host from public.events where id = p_event_id;
  if p_venue_id is not null then
    select * into v_venue from public.venues where id = p_venue_id;
    if not found then
      raise exception 'venue_not_found' using errcode = 'PT404';
    end if;
  end if;
  if p_campus_id is not null then
    select * into v_campus from public.org_campuses where id = p_campus_id;
  end if;

  if p_address_visibility = 'public' then
    if v_venue.id is not null and not v_venue.is_public then
      raise exception 'private_venue_requires_approval' using errcode = 'check_violation';
    end if;
    v_hint  := coalesce(nullif(btrim(coalesce(p_location_hint, '')), ''), v_venue.name, nullif(v_text, ''), '');
    v_point := v_venue.location;
  else
    if v_venue.id is not null and v_venue.is_public and v_venue.created_by is not null and v_venue.created_by = v_host
       and not exists (
         select 1 from public.event_addresses ea
           join public.events e2 on e2.id = ea.event_id
          where ea.venue_id = v_venue.id and ea.event_id <> p_event_id and e2.address_visibility = 'public') then
      update public.venues set is_public = false where id = v_venue.id;
      v_venue.is_public := false;
    end if;
    v_hint := coalesce(
      nullif(btrim(coalesce(p_location_hint, '')), ''),
      case when v_campus.id is not null then 'Near ' || v_campus.name end,
      case when nullif(v_venue.city, '') is not null then 'Near ' || v_venue.city end,
      'Address shared after approval');
    -- The campus centroid stands in only when the venue is within 2 km of the
    -- campus (or the venue has no point at all); a venue farther out would be
    -- placed kilometres from where it is, so it gets the 0.1 degree cell (D-038).
    if v_campus.location is not null
       and (v_venue.location is null or extensions.ST_DWithin(v_venue.location, v_campus.location, 2000)) then
      v_point := v_campus.location;
    elsif v_venue.location is not null then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
                   round(extensions.ST_X(v_venue.location::extensions.geometry)::numeric, 1)::double precision,
                   round(extensions.ST_Y(v_venue.location::extensions.geometry)::numeric, 1)::double precision
                 ), 4326)::extensions.geography;
    end if;
  end if;

  insert into public.event_addresses (event_id, venue_id, location_text, address_note)
  values (p_event_id, p_venue_id, v_text, btrim(coalesce(p_address_note, '')))
  on conflict (event_id) do update
     set venue_id      = excluded.venue_id,
         location_text = excluded.location_text,
         address_note  = excluded.address_note;

  update public.events
     set location_hint = left(v_hint, 120),
         approx_point  = v_point
   where id = p_event_id
     and (location_hint is distinct from left(v_hint, 120) or approx_point::text is distinct from v_point::text);
end $$;

revoke all on function public.event_set_location(p_event_id uuid, p_venue_id uuid, p_location_text text, p_address_note text, p_address_visibility public.address_visibility, p_location_hint text, p_campus_id uuid) from public, anon, authenticated;
grant execute on function public.event_set_location(p_event_id uuid, p_venue_id uuid, p_location_text text, p_address_note text, p_address_visibility public.address_visibility, p_location_hint text, p_campus_id uuid) to service_role;

-- host_check_in: from 20261113000100_chapter_tools.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.host_check_in(p_event_id uuid, p_user_id uuid, p_checked boolean default true)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage_event(p_event_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.starts_at - interval '1 hour' or now() > e.ends_at + interval '24 hours' then
    raise exception 'check_in_window' using errcode = 'check_violation',
      hint = 'Check people in from an hour before the start until a day after the end.';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'PT404';
  end if;
  if coalesce(p_checked, true) then
    if r.status <> 'going' then
      raise exception 'not_going' using errcode = 'check_violation';
    end if;
    if r.checked_in_at is null then
      update public.rsvps set checked_in_at = now(), checked_in_by = uid
       where event_id = p_event_id and user_id = p_user_id
       returning * into r;
    end if;
  elsif r.checked_in_at is not null then
    update public.rsvps set checked_in_at = null, checked_in_by = null
     where event_id = p_event_id and user_id = p_user_id
     returning * into r;
  end if;
  return r;
end $$;

revoke all on function public.host_check_in(p_event_id uuid, p_user_id uuid, p_checked boolean) from public, anon;
grant execute on function public.host_check_in(p_event_id uuid, p_user_id uuid, p_checked boolean) to authenticated, service_role;

-- leave_conversation: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.leave_conversation(p_conversation uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  c      public.conversations%rowtype;
  v_role text;
  v_next uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if c.kind not in ('dm', 'group') then
    raise exception 'forbidden' using errcode = '42501',
      hint = 'Leave the plan, hub or chapter to leave its chat, or mute it.';
  end if;
  v_role := private.chat_role(c.id, uid);
  if v_role is null then
    return;
  end if;
  update public.conversation_members set left_at = now(), role = 'member'
   where conversation_id = c.id and user_id = uid;
  if v_role = 'owner' then
    select cm.user_id into v_next from public.conversation_members cm
     where cm.conversation_id = c.id and cm.user_id <> uid and cm.left_at is null and cm.removed_at is null
     order by (cm.role = 'admin') desc, cm.joined_at, cm.user_id
     limit 1;
    if v_next is not null then
      update public.conversation_members set role = 'owner' where conversation_id = c.id and user_id = v_next;
    end if;
  end if;
  -- Nobody left: the conversation goes (reported messages live on in their evidence).
  if not exists (select 1 from public.conversation_members cm
                  where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null) then
    delete from public.conversations where id = c.id;
  end if;
end $$;

revoke all on function public.leave_conversation(p_conversation uuid) from public, anon;
grant execute on function public.leave_conversation(p_conversation uuid) to authenticated, service_role;

-- mark_conversation_read: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mark_conversation_read(p_conversation uuid, p_seq bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  v_seq bigint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  select least(greatest(coalesce(p_seq, 0), 0), c.last_seq) into v_seq
    from public.conversations c where c.id = p_conversation;
  insert into public.conversation_members (conversation_id, user_id, last_read_seq, last_read_at)
  values (p_conversation, uid, v_seq, now())
  on conflict (conversation_id, user_id) do update
     set last_read_seq = greatest(public.conversation_members.last_read_seq, excluded.last_read_seq),
         last_read_at = now();
  -- What was seen in the chat is not pushed.
  update public.notifications n
     set read_at = now()
   where n.user_id = uid and n.read_at is null and n.kind in ('message', 'message_request')
     and n.payload ->> 'conversation_id' = p_conversation::text
     and coalesce((n.payload ->> 'seq')::bigint, 0) <= v_seq;
end $$;

revoke all on function public.mark_conversation_read(p_conversation uuid, p_seq bigint) from public, anon;
grant execute on function public.mark_conversation_read(p_conversation uuid, p_seq bigint) to authenticated, service_role;

-- materialize_event_series: from 20261025000100_v2_events.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.materialize_event_series(p_series_id uuid, p_weeks integer default 8)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s          public.event_series%rowtype;
  v_today    date;
  v_horizon  date;
  v_date     date;
  v_count    integer;
  v_inserted integer := 0;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_id       uuid;
begin
  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'PT404';
  end if;
  if s.status = 'cancelled' then
    return 0;
  end if;
  if s.host_id is null or not exists (select 1 from public.profiles where id = s.host_id and status = 'active') then
    return 0;
  end if;

  v_today   := (now() at time zone s.timezone)::date;
  v_date    := greatest(s.starts_on, v_today);
  v_horizon := v_date + greatest(1, least(coalesce(p_weeks, 8), 26)) * 7;
  v_date    := v_date + ((s.weekday - extract(dow from v_date)::integer + 7) % 7);
  select count(*) into v_count from public.events where series_id = s.id;

  while v_date < v_horizon and (s.ends_on is null or v_date <= s.ends_on) loop
    exit when s.max_occurrences is not null and v_count >= s.max_occurrences;
    v_starts := (v_date + s.start_time) at time zone s.timezone;
    v_ends   := v_starts + make_interval(mins => s.duration_minutes);
    if v_starts > now() then
      insert into public.events (kind, hub_id, chapter_id, campus_id, host_id, series_id, occurrence_date,
                                 title, description, cover_url, starts_at, ends_at, timezone, min_age,
                                 capacity, waitlist_enabled, min_headcount, members_only, is_free, price_text,
                                 visibility, address_visibility, status)
      values (s.kind, s.hub_id, s.chapter_id, s.campus_id, s.host_id, s.id, v_date,
              s.title, s.description, s.cover_url, v_starts, v_ends, s.timezone, s.min_age,
              s.capacity, s.waitlist_enabled, s.min_headcount, s.members_only, s.is_free, s.price_text,
              s.visibility, s.address_visibility, 'published')
      on conflict (series_id, occurrence_date) where series_id is not null do nothing
      returning id into v_id;
      if v_id is not null then
        perform public.event_set_location(v_id, s.venue_id, s.location_text, s.address_note,
                                          s.address_visibility, s.location_hint, s.campus_id);
        v_inserted := v_inserted + 1;
        v_count    := v_count + 1;
        v_id       := null;
      end if;
    end if;
    v_date := v_date + 7;
  end loop;
  return v_inserted;
end $$;

revoke all on function public.materialize_event_series(p_series_id uuid, p_weeks integer) from public, anon, authenticated;
grant execute on function public.materialize_event_series(p_series_id uuid, p_weeks integer) to service_role;

-- mod_ban_user: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_ban_user(p_user uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p       public.profiles%rowtype;
  v_ids   uuid[];
  v_event uuid;
  v_open  integer;
  v_rsvps integer := 0;
  v_chapters uuid[];
  v_orphans  uuid[];
  v_b        record;   -- Migration 60
  v_bk       integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_user for update;
  if not found or p.deleted_at is not null or p.status = 'deleted' then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  if p.status = 'banned' then
    return jsonb_build_object('banned', true, 'already', true);
  end if;
  if exists (select 1 from public.user_roles where user_id = p_user and role = 'admin') then
    raise exception 'cannot_ban_admin' using errcode = '42501';
  end if;
  if exists (select 1 from public.user_roles where user_id = p_user)
     and not public.has_role('admin'::public.app_role) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only an admin bans a moderator.';
  end if;
  if public.moderation_is_own('profile', p_user, p_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;

  update public.profiles set status = 'banned', moderated_at = now() where id = p_user;
  update auth.users set banned_until = now() + interval '100 years' where id = p_user;
  delete from public.user_roles where user_id = p_user;
  -- Migration 54: every session ends now (refresh tokens go with them).
  delete from auth.sessions where user_id = p_user;

  -- Migration 54: chapter roles drop to member. A chapter left without an
  -- organizer gets an open report (no reporter) so a moderator hands it over.
  select coalesce(array_agg(cm.chapter_id), '{}') into v_orphans
    from public.chapter_members cm where cm.user_id = p_user and cm.role = 'organizer';
  with d as (
    update public.chapter_members set role = 'member'
     where user_id = p_user and role in ('captain', 'organizer')
    returning chapter_id
  )
  select coalesce(array_agg(distinct chapter_id), '{}') into v_chapters from d;
  select coalesce(array_agg(c.id), '{}') into v_orphans
    from public.hub_chapters c
   where c.id = any (v_orphans)
     and not exists (select 1 from public.chapter_members cm where cm.chapter_id = c.id and cm.role = 'organizer')
     and not exists (select 1 from public.reports r
                      where r.target_kind = 'chapter' and r.target_id = c.id and r.status = 'open'
                        and r.reporter_id is null);
  insert into public.reports (reporter_id, target_kind, target_id, reason, note, priority, due_at)
  select null, 'chapter', c, 'other', 'Its organizer was banned; it needs a new organizer.', 2, now() + interval '24 hours'
    from unnest(v_orphans) c;

  -- Hosted upcoming plans and series end, and their audience hears why
  -- (the same steps as account deletion, migration 36). Migration 54: plans
  -- already under way end too.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
   where host_id = p_user and status = 'published';
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
     where host_id = p_user and status = 'published' and ends_at > now()   -- Migration 54
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'moderator_removed'));
  end loop;

  -- Live RSVPs on other upcoming plans go; seats pass to the waitlist.
  for v_event in
    select r.event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = p_user and r.status <> 'cancelled' and e.status = 'published' and e.ends_at > now()
  loop
    update public.rsvps
       set status = 'cancelled', waitlist_position = null, approved_by_host = false,
           removed_by = uid, removed_at = now(), removed_reason = 'banned'
     where event_id = v_event and user_id = p_user;
    perform public.rsvp_promote_waitlist(v_event);
    v_rsvps := v_rsvps + 1;
  end loop;

  -- Migration 60: coaching. A banned coach's profile is suspended and their listings paused, and
  -- their upcoming bookings are cancelled with full refunds; a banned client's upcoming bookings
  -- are cancelled with the client-cancellation refund. The other side is told.
  update public.coach_profiles set status = 'suspended', suspended_at = now()
   where user_id = p_user and status <> 'suspended';
  update public.coach_listings set status = 'paused' where coach_id = p_user and status = 'active';
  for v_b in select b.id, b.coach_id from public.bookings b
              where (b.coach_id = p_user or b.client_id = p_user)
                and b.status in ('requested', 'confirmed') and b.starts_at > now() loop
    if private.booking_cancel(v_b.id, 'system', 'banned', case when v_b.coach_id = p_user then 'full' else 'policy' end, true) then
      v_bk := v_bk + 1;
    end if;
  end loop;

  update public.reports
     set status = 'actioned', resolved_by = uid, resolved_at = now()
   where target_kind = 'profile' and target_id = p_user and status = 'open';
  get diagnostics v_open = row_count;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count, note)
  values (uid, 'ban', 'profile', p_user, p_user, v_open, v_note);

  return jsonb_build_object('banned', true, 'already', false, 'events_cancelled', cardinality(v_ids),
                            'rsvps_removed', v_rsvps, 'reports_closed', v_open,
                            'chapter_roles_removed', cardinality(v_chapters),             -- Migration 54
                            'chapters_need_organizer', cardinality(v_orphans),
                            'bookings_cancelled', v_bk);                                  -- Migration 60
end $$;

revoke all on function public.mod_ban_user(p_user uuid, p_note text) from public, anon;
grant execute on function public.mod_ban_user(p_user uuid, p_note text) to authenticated, service_role;

-- mod_booking: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_booking(p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  b      public.bookings%rowtype;
  bp     public.booking_payments%rowtype;
  v_open integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('cancel_refund', 'uphold_no_show', 'reject_no_show', 'complete') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  select * into b from public.bookings where id = p_id for update;
  if not found then
    raise exception 'target_not_found' using errcode = 'PT404';
  end if;
  if uid in (b.coach_id, b.client_id) or public.moderation_is_own('booking', p_id, null) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  select * into bp from public.booking_payments where booking_id = b.id;
  if p_action = 'cancel_refund' then
    if b.status in ('requested', 'confirmed') then
      perform private.booking_cancel(b.id, 'moderator', 'moderator', 'full', true);
    elsif b.status in ('no_show', 'completed') then
      update public.bookings
         set status = 'cancelled', cancelled_at = now(), cancelled_by = 'moderator', cancel_reason = 'moderator',
             no_show_settled_at = coalesce(no_show_settled_at, case when b.status = 'no_show' then now() end),
             payment_state = case when payment_state = 'paid' then 'refund_pending'::public.booking_payment_state
                                  else payment_state end
       where id = b.id;
      if b.payment_state = 'paid' then
        insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
        values (b.id, 'refund', bp.amount_minor - bp.refunded_minor, 'refund:' || b.id::text || ':moderator')
        on conflict (idempotency_key) do nothing;
        perform public.stripe_dispatch();
      end if;
      perform private.booking_notify(b.id, b.client_id, 'booking_cancelled', jsonb_build_object('reason', 'moderator'));
      perform private.booking_notify(b.id, b.coach_id, 'booking_cancelled', jsonb_build_object('reason', 'moderator'));
    else
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
  elsif p_action = 'uphold_no_show' then
    if b.status <> 'no_show' then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    update public.bookings set no_show_settled_at = now() where id = b.id;
    if b.no_show_party = 'coach' and b.payment_state = 'paid' then
      update public.bookings set payment_state = 'refund_pending' where id = b.id;
      insert into public.stripe_jobs (booking_id, op, amount_minor, idempotency_key)
      values (b.id, 'refund', bp.amount_minor, 'refund:' || b.id::text || ':no_show_coach')
      on conflict (idempotency_key) do nothing;
      perform public.stripe_dispatch();
    end if;
  else
    if not (b.status = 'confirmed' or (b.status = 'no_show' and p_action in ('reject_no_show', 'complete'))) then
      raise exception 'invalid_state' using errcode = 'check_violation';
    end if;
    update public.bookings
       set status = 'completed', completed_at = now(),
           no_show_settled_at = case when b.status = 'no_show' then now() else no_show_settled_at end
     where id = b.id;
  end if;
  update public.reports set status = 'actioned', resolved_by = uid, resolved_at = now()
   where target_kind = 'booking' and target_id = b.id and status = 'open';
  get diagnostics v_open = row_count;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count, note)
  values (uid, p_action, 'booking', b.id, b.coach_id, v_open, v_note);
  return jsonb_build_object('id', b.id, 'action', p_action,
                            'status', (select x.status from public.bookings x where x.id = b.id), 'reports_closed', v_open);
end $$;

revoke all on function public.mod_booking(p_id uuid, p_action text, p_note text) from public, anon;
grant execute on function public.mod_booking(p_id uuid, p_action text, p_note text) to authenticated, service_role;

-- mod_listing_removal_resolve: from 20261226000100_collector_completion.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_listing_removal_resolve(p_request uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_req   public.listing_removal_requests%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 1000);
  v_src   public.feed_sources%rowtype;
  v_host  text;
  v_n     integer := 0;
  v_deny  boolean := false;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('removed', 'rejected', 'reopen') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if p_action = 'rejected' and v_note = '' then
    raise exception 'note_required' using errcode = '22023';
  end if;
  select * into v_req from public.listing_removal_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if v_req.contact_cleared_at is not null then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if p_action = 'reopen' then
    if v_req.status = 'open' then
      raise exception 'request_open' using errcode = 'P0001';
    end if;
  elsif v_req.status <> 'open' then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;

  if p_action = 'removed' then
    if v_req.scope = 'item' then
      if v_req.event_id is null then
        raise exception 'no_listing' using errcode = '22023';
      end if;
      -- The column's first writer: every import row of the event, so a linked copy from another
      -- source can never republish it.
      update public.event_imports
         set removed_at = coalesce(removed_at, now()),
             removed_reason = coalesce(removed_reason, 'owner request ' || v_req.reference)
       where event_id = v_req.event_id;
      get diagnostics v_n = row_count;
      update public.events set moderation_state = 'removed', moderated_at = now()
       where id = v_req.event_id and kind = 'imported';
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
      values (uid, 'listing_remove', 'listing', v_req.id,
              left(v_req.reference || ': item, ' || v_n || ' import rows' || case when v_note <> '' then '; ' || v_note else '' end, 500));
    else
      if v_req.source_id is null then
        raise exception 'no_source' using errcode = '22023';
      end if;
      select * into v_src from public.feed_sources where id = v_req.source_id for update;
      v_n := public.feed_source_withdraw(v_src.id, 'remove', 'owner request ' || v_req.reference);
      update public.feed_sources set enabled = false, denylisted = true where id = v_src.id;
      v_host := public.source_url_host(v_src.url);
      if v_host is not null and v_host ~ '^[a-z0-9]([a-z0-9.-]{0,98}[a-z0-9])?$'
         and not public.collector_shared_host(v_host) then
        insert into public.collector_denylist (name, match, reason)
        values (v_host, 'domain', 'owner request ' || v_req.reference)
        on conflict (name, match) do nothing;
        v_deny := true;
      end if;
      update public.source_candidates
         set status = 'rejected', status_at = now(), locked = true, retry_after = null,
             reason = left('owner request ' || v_req.reference, 200)
       where id = v_src.candidate_id or (v_deny and host = v_host);
      update public.feed_sources set enabled = false, denylisted = true
       where v_deny and public.source_url_host(url) = v_host and id <> v_src.id;
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
      values (uid, 'source_remove', 'source', v_src.id,
              left(v_req.reference || ': source ' || v_src.slug || ', ' || v_n || ' import rows'
                   || case when v_deny then ', host denylisted' else ', shared host kept' end
                   || case when v_note <> '' then '; ' || v_note else '' end, 500));
    end if;
  elsif p_action = 'rejected' then
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, 'listing_reject', 'listing', v_req.id, left(v_req.reference || ': ' || v_note, 500));
  else
    insert into public.moderation_actions (moderator_id, action, target_kind, target_id, note)
    values (uid, 'listing_reopen', 'listing', v_req.id,
            left(v_req.reference || case when v_note <> '' then ': ' || v_note else '' end, 500));
  end if;

  update public.listing_removal_requests
     set status          = case p_action when 'reopen' then 'open' else p_action end,
         resolution_note = case when v_note <> '' then v_note else resolution_note end,
         resolved_by     = case when p_action = 'reopen' then null else uid end,
         resolved_at     = case when p_action = 'reopen' then null else now() end
   where id = p_request;
  return jsonb_build_object('id', p_request, 'status', case p_action when 'reopen' then 'open' else p_action end,
                            'rows', v_n, 'host_denylisted', v_deny);
end $$;

revoke all on function public.mod_listing_removal_resolve(p_request uuid, p_action text, p_note text) from public, anon;
grant execute on function public.mod_listing_removal_resolve(p_request uuid, p_action text, p_note text) to authenticated, service_role;

-- mod_moderate: from 20261224000100_coaching.sql; 8 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_moderate(p_kind text, p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid           uuid := (select auth.uid());
  v_note        text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  v_target_user uuid;
  v_state       text;
  v_new         text;
  v_open        integer;
  v_snapshot    jsonb;
  e             public.events%rowtype;
  p             public.profiles%rowtype;
  v_b           uuid;   -- Migration 60
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_id is null
     or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message',                   -- Migration 58
                       'coach_listing', 'coach_review', 'coach_review_reply', 'booking') then   -- Migration 60
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if p_action is null or p_action not in ('dismiss', 'hide', 'remove', 'restore') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  -- Migration 60: a booking is decided by mod_booking; here its reports can only be dismissed.
  if p_kind = 'booking' and p_action <> 'dismiss' then
    raise exception 'invalid_action' using errcode = 'check_violation', hint = 'Use mod_booking.';
  end if;

  if p_kind = 'profile' then
    select * into p from public.profiles where id = p_id for update;
    if not found or p.deleted_at is not null then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
    v_target_user := p.id;
    v_state := p.moderation_state;
  elsif p_kind = 'event' then
    select * into e from public.events where id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
    v_target_user := e.host_id;
    v_state := e.moderation_state;
  elsif p_kind = 'message' then
    -- Migration 58: a chat message (soft delete only; nothing is hard-deleted).
    select m.author_id, m.moderation_state into v_target_user, v_state from public.messages m
     where m.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'coach_listing' then
    -- Migration 60
    select l.coach_id, l.moderation_state into v_target_user, v_state from public.coach_listings l
     where l.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind in ('coach_review', 'coach_review_reply') then
    select case when p_kind = 'coach_review' then r.client_id else r.coach_id end,
           case when p_kind = 'coach_review' then r.moderation_state else r.reply_moderation_state end
      into v_target_user, v_state
      from public.coach_reviews r where r.booking_id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'booking' then
    select b.coach_id into v_target_user from public.bookings b where b.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'chapter' then
    select c.moderation_state into v_state from public.hub_chapters c where c.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  else
    select h.moderation_state into v_state from public.hubs h where h.id = p_id for update;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  end if;
  if public.moderation_is_own(p_kind, p_id, v_target_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;

  select count(*)::integer into v_open from public.reports r
   where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open';
  if p_action = 'dismiss' and v_open = 0 then
    raise exception 'item_not_pending' using errcode = 'check_violation';
  end if;

  if p_action in ('dismiss', 'restore') then
    -- Reports were wrong, or a moderator undoes a hide or removal: back to normal.
    v_new := null;
    if v_state is not null then
      perform public.moderation_set_state(p_kind, p_id, null);
    end if;
  elsif p_action = 'hide' then
    v_new := 'hidden';
    perform public.moderation_set_state(p_kind, p_id, 'hidden');
  else
    -- Soft delete.
    if p_kind = 'profile' then
      v_new := null;
      v_snapshot := jsonb_build_object('avatar_url', p.avatar_url, 'bio', p.bio);
      update public.profiles
         set avatar_url = null, bio = '', moderation_state = null, moderated_at = now()
       where id = p.id;
    else
      v_new := 'removed';
      perform public.moderation_set_state(p_kind, p_id, 'removed');
      -- Migration 60: a removed listing's open bookings end with full refunds.
      if p_kind = 'coach_listing' then
        for v_b in select b.id from public.bookings b
                    where b.listing_id = p_id and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
          perform private.booking_cancel(v_b, 'moderator', 'listing_removed', 'full', true);
        end loop;
      end if;
      if p_kind = 'event' and e.status = 'published' and e.starts_at > now() then
        update public.events
           set status = 'cancelled', cancelled_at = now(), cancel_reason = 'moderator_removed'
         where id = e.id;
        perform public.notify_event_audience(
          e.id, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
          e.id::text, null, jsonb_build_object('reason', 'moderator_removed'));
      end if;
    end if;
  end if;

  update public.reports
     set status = case when p_action in ('dismiss', 'restore') then 'dismissed' else 'actioned' end,
         resolved_by = uid, resolved_at = now()
   where target_kind = p_kind and target_id = p_id and status = 'open';

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id,
                                         report_count, note, snapshot)
  values (uid, p_action, p_kind, p_id, v_target_user, v_open, v_note, v_snapshot);

  return jsonb_build_object('kind', p_kind, 'id', p_id, 'action', p_action, 'state', v_new,
                            'reports_closed', v_open);
end $$;

revoke all on function public.mod_moderate(p_kind text, p_id uuid, p_action text, p_note text) from public, anon;
grant execute on function public.mod_moderate(p_kind text, p_id uuid, p_action text, p_note text) to authenticated, service_role;

-- mod_organizer_claim_review: from 20261226000100_collector_completion.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_organizer_claim_review(p_claim uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_claim public.organizer_claims%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 400);
  v_src   uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('ok', 'revoke') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if v_claim.user_id = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_action = 'ok' then
    update public.organizer_claims set reviewed_at = now() where id = p_claim;
  else
    if v_claim.status not in ('pending', 'verified') then
      raise exception 'claim_closed' using errcode = 'P0001';
    end if;
    update public.organizer_claims set status = 'revoked', reviewed_at = now(), failure = 'revoked' where id = p_claim;
    -- Connected feeds of the claim stop; a found source loses its owner and stays as it was.
    for v_src in select f.id from public.feed_sources f where f.organizer_claim_id = p_claim and f.origin = 'organizer' loop
      perform public.feed_source_withdraw(v_src, 'stop');
      update public.feed_sources set enabled = false, organizer_stopped_at = coalesce(organizer_stopped_at, now()),
                                     organizer_id = null, organizer_verified_at = null
       where id = v_src;
    end loop;
    update public.feed_sources
       set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
     where id = v_claim.source_id and organizer_id = v_claim.user_id;
  end if;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case p_action when 'ok' then 'organizer_review' else 'organizer_revoke' end, 'organizer_claim',
          p_claim, v_claim.user_id, nullif(v_note, ''));
  return jsonb_build_object('claim_id', p_claim, 'status', case p_action when 'ok' then v_claim.status else 'revoked' end);
end $$;

revoke all on function public.mod_organizer_claim_review(p_claim uuid, p_action text, p_note text) from public, anon;
grant execute on function public.mod_organizer_claim_review(p_claim uuid, p_action text, p_note text) to authenticated, service_role;

-- mod_set_coach_status: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_set_coach_status(p_user uuid, p_status text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  cp     public.coach_profiles%rowtype;
  v_b    uuid;
  n      integer := 0;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_status is null or p_status not in ('suspended', 'active') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  if p_user is null or public.moderation_is_own('profile', p_user, p_user) then
    raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews this one.';
  end if;
  select * into cp from public.coach_profiles where user_id = p_user for update;
  if not found then
    raise exception 'target_not_found' using errcode = 'PT404';
  end if;
  if p_status = 'suspended' then
    update public.coach_profiles set status = 'suspended', suspended_at = now() where user_id = p_user;
    update public.coach_listings set status = 'paused' where coach_id = p_user and status = 'active';
    for v_b in select b.id from public.bookings b
                where b.coach_id = p_user and b.status in ('requested', 'confirmed') and b.starts_at > now() loop
      if private.booking_cancel(v_b, 'moderator', 'moderator', 'full', true) then
        n := n + 1;
      end if;
    end loop;
  elsif cp.status = 'suspended' then
    update public.coach_profiles
       set status = case when published_at is not null then 'active'::public.coach_status else 'draft'::public.coach_status end,
           suspended_at = null
     where user_id = p_user;
  end if;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case when p_status = 'suspended' then 'coach_suspend' else 'coach_restore' end, 'profile', p_user,
          p_user, v_note);
  return jsonb_build_object('user_id', p_user, 'status', (select c.status from public.coach_profiles c where c.user_id = p_user),
                            'bookings_cancelled', n);
end $$;

revoke all on function public.mod_set_coach_status(p_user uuid, p_status text, p_note text) from public, anon;
grant execute on function public.mod_set_coach_status(p_user uuid, p_status text, p_note text) to authenticated, service_role;

-- mod_takedown_block_image: from 20261216000100_ncii_takedown.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_takedown_block_image(p_request uuid, p_image_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_req     public.takedown_requests%rowtype;
  v_bucket  text;
  v_path    text;
  v_owner   uuid;
  v_row     public.image_hashes%rowtype;
  v_cleared integer;
  v_blocked uuid;
  v_copies  integer := 0;
  v_state   text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_req from public.takedown_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if v_req.status not in ('open', 'waiting') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  select o.bucket, o.path into v_bucket, v_path from public.storage_object_from_url(btrim(p_image_url)) o;
  if v_bucket is null then
    raise exception 'invalid_image_url' using errcode = '22023';
  end if;
  v_owner := public.image_owner_from_path(v_path);
  if v_owner = uid or v_req.target_user_id = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;

  -- Off every surface at once, whatever the hashing does next.
  v_cleared := public.image_clear_references(v_bucket, v_path);
  update public.takedown_requests
     set target_user_id = coalesce(target_user_id, v_owner), updated_at = now()
   where id = p_request;

  insert into public.image_hashes (bucket, path, owner_id, status)
  values (v_bucket, v_path, v_owner, 'pending')
  on conflict (bucket, path) do nothing;
  select * into v_row from public.image_hashes where bucket = v_bucket and path = v_path for update;

  if v_row.status = 'hashed' then
    v_blocked := public.image_block_hash(p_request, v_row.sha256, v_row.phash, v_row.dhash);
    v_copies := public.image_block_matches(v_blocked, uid);
    v_state := 'blocked';
  elsif v_row.status = 'blocked' then
    if v_row.sha256 is not null then
      v_blocked := public.image_block_hash(p_request, v_row.sha256, v_row.phash, v_row.dhash);
      v_copies := public.image_block_matches(v_blocked, uid);
    end if;
    v_state := 'blocked';
  elsif v_row.status = 'unreadable' then
    v_state := 'removed';
  else
    update public.image_hashes
       set status = 'pending', block_request_id = p_request, attempts = 1, dispatched_at = now()
     where id = v_row.id;
    perform public.image_guard_dispatch(jsonb_build_object('op', 'check', 'bucket', v_bucket, 'path', v_path));
    v_state := 'hashing';
  end if;
  if v_state <> 'hashing' then
    perform public.image_guard_dispatch(jsonb_build_object('op', 'sweep'));
  end if;

  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, 'image_block', 'takedown', p_request, v_owner,
          left(v_state || ': ' || v_bucket || '/' || v_path || '; copies ' || v_copies || '; references cleared ' || v_cleared, 500));
  return jsonb_build_object('state', v_state, 'copies', v_copies, 'references_cleared', v_cleared);
end $$;

revoke all on function public.mod_takedown_block_image(p_request uuid, p_image_url text) from public, anon;
grant execute on function public.mod_takedown_block_image(p_request uuid, p_image_url text) to authenticated, service_role;

-- mod_takedown_resolve: from 20261216000100_ncii_takedown.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_takedown_resolve(p_request uuid, p_action text, p_note text default null,
                                                       p_target_user uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_req  public.takedown_requests%rowtype;
  v_note text := left(btrim(coalesce(p_note, '')), 1000);
  v_new  text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_action not in ('removed', 'rejected', 'waiting', 'reopen') then
    raise exception 'invalid_action' using errcode = '22023';
  end if;
  if p_action in ('rejected', 'waiting') and v_note = '' then
    raise exception 'note_required' using errcode = '22023';
  end if;
  select * into v_req from public.takedown_requests where id = p_request for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if p_target_user is not null and not exists (select 1 from public.profiles p where p.id = p_target_user) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if coalesce(p_target_user, v_req.target_user_id) = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  if p_action = 'reopen' then
    if v_req.status not in ('removed', 'rejected') then
      raise exception 'request_open' using errcode = 'P0001';
    end if;
  elsif v_req.status not in ('open', 'waiting') then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;
  if v_req.contact_cleared_at is not null then
    raise exception 'request_closed' using errcode = 'P0001';
  end if;

  v_new := case p_action when 'reopen' then 'open' else p_action end;
  update public.takedown_requests
     set status          = v_new,
         target_user_id  = coalesce(p_target_user, target_user_id),
         resolution_note = case when v_note <> '' then v_note else resolution_note end,
         resolved_by     = case when v_new in ('removed', 'rejected') then uid end,
         resolved_at     = case when v_new in ('removed', 'rejected') then now() end,
         updated_at      = now()
   where id = p_request;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, case p_action when 'removed' then 'ncii_remove' when 'rejected' then 'ncii_reject' else 'ncii_update' end,
          'takedown', p_request, coalesce(p_target_user, v_req.target_user_id),
          nullif(left(p_action || case when v_note <> '' then ': ' || v_note else '' end, 500), ''));
  return jsonb_build_object('id', p_request, 'status', v_new);
end $$;

revoke all on function public.mod_takedown_resolve(p_request uuid, p_action text, p_note text, p_target_user uuid) from public, anon;
grant execute on function public.mod_takedown_resolve(p_request uuid, p_action text, p_note text, p_target_user uuid) to authenticated, service_role;

-- mod_unban_user: from 20261215000100_trust_safety.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mod_unban_user(p_user uuid, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_note text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p      public.profiles%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'own_item' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = p_user for update;
  if not found or p.deleted_at is not null or p.status = 'deleted' then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  if p.status <> 'banned' then
    return jsonb_build_object('unbanned', false);
  end if;
  update public.profiles set status = 'active', moderated_at = now() where id = p_user;
  update auth.users set banned_until = null where id = p_user;
  insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, note)
  values (uid, 'unban', 'profile', p_user, p_user, v_note);
  return jsonb_build_object('unbanned', true);
end $$;

revoke all on function public.mod_unban_user(p_user uuid, p_note text) from public, anon;
grant execute on function public.mod_unban_user(p_user uuid, p_note text) to authenticated, service_role;

-- mute_conversation: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mute_conversation(p_conversation uuid, p_until timestamptz)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  insert into public.conversation_members (conversation_id, user_id, muted_until)
  values (p_conversation, uid, case when p_until > now() then p_until end)
  on conflict (conversation_id, user_id) do update set muted_until = excluded.muted_until;
end $$;

revoke all on function public.mute_conversation(p_conversation uuid, p_until timestamptz) from public, anon;
grant execute on function public.mute_conversation(p_conversation uuid, p_until timestamptz) to authenticated, service_role;

-- mute_user: from 20261215000100_trust_safety.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.mute_user(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_user is null or p_user = uid then
    raise exception 'cannot_mute_self' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  if exists (select 1 from public.blocks where blocker_id = uid and blocked_id = p_user) then
    return jsonb_build_object('muted', true, 'already', true);
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('mutes:' || uid::text));
  if not exists (select 1 from public.mutes where muter_id = uid and muted_id = p_user)
     and (select count(*) from public.mutes where muter_id = uid) >= 1000 then
    raise exception 'too_many_mutes' using errcode = 'check_violation', hint = 'Up to 1000 mutes.';
  end if;
  insert into public.mutes (muter_id, muted_id) values (uid, p_user) on conflict do nothing;
  get diagnostics n = row_count;
  return jsonb_build_object('muted', true, 'already', n = 0);
end $$;

revoke all on function public.mute_user(p_user uuid) from public, anon;
grant execute on function public.mute_user(p_user uuid) to authenticated, service_role;

-- organizer_claim_check: from 20261226000100_collector_completion.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.organizer_claim_check(p_claim uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_claim public.organizer_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into v_claim from public.organizer_claims where id = p_claim for update;
  if not found or v_claim.user_id <> uid then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if v_claim.status = 'pending' and v_claim.method <> 'dns_txt' then
    update public.organizer_claims set check_requested_at = now() where id = p_claim;
  end if;
  return jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status, 'method', v_claim.method,
                            'host', v_claim.host,
                            'dns_name', case when v_claim.method = 'dns_txt' and v_claim.status = 'pending'
                                             then '_activityplanet.' || public.registrable_domain(v_claim.host) end,
                            'token', case when v_claim.status = 'pending' then v_claim.token end);
end $$;

revoke all on function public.organizer_claim_check(p_claim uuid) from public, anon;
grant execute on function public.organizer_claim_check(p_claim uuid) to authenticated, service_role;

-- place_apply_changes: from 20261128000100_place_contributions.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.place_apply_changes(p_place uuid, p_changes jsonb, p_via text, p_lock boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  c      jsonb := coalesce(p_changes, '{}'::jsonb);
  p      public.places%rowtype;
  v_lock text[];
  v_hub  uuid;
begin
  select * into p from public.places where id = p_place for update;
  if not found then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  v_lock := p.locked_fields;
  if p_lock then
    v_lock := array(select distinct f from unnest(v_lock || array(
                select k from jsonb_object_keys(c - 'hubs_add') k)) f order by f);
  end if;

  update public.places
     set name          = case when c ? 'name' then c ->> 'name' else name end,
         kind          = case when c ? 'kind' then c ->> 'kind' else kind end,
         location      = case when c ? 'location' then
                           extensions.ST_SetSRID(extensions.ST_MakePoint((c #>> '{location,lng}')::double precision,
                                                                         (c #>> '{location,lat}')::double precision),
                                                 4326)::extensions.geography
                         else location end,
         address_text  = case when c ? 'address_text' then c ->> 'address_text' else address_text end,
         locality      = case when c ? 'locality' then c ->> 'locality' else locality end,
         opening_hours = case when c ? 'opening_hours' then c ->> 'opening_hours' else opening_hours end,
         website       = case when c ? 'website' then c ->> 'website' else website end,
         status        = case when c ? 'closed' and (c ->> 'closed')::boolean and status = 'active'
                                then 'closed'::public.place_status
                              when c ? 'closed' and not (c ->> 'closed')::boolean and status = 'closed'
                                then 'active'::public.place_status
                              else status end,
         locked_fields = v_lock
   where id = p.id;

  if c ? 'hubs_add' then
    for v_hub in select (x #>> '{}')::uuid from jsonb_array_elements(c -> 'hubs_add') x loop
      insert into public.place_hubs (place_id, hub_id, via)
      values (p.id, v_hub, p_via)
      on conflict (place_id, hub_id) do update
         set via = excluded.via, weight = greatest(public.place_hubs.weight, 1)
       where public.place_hubs.via = 'events';   -- an explicit link outranks a plan count
    end loop;
  end if;
end $$;

revoke all on function public.place_apply_changes(p_place uuid, p_changes jsonb, p_via text, p_lock boolean) from public, anon, authenticated;
grant execute on function public.place_apply_changes(p_place uuid, p_changes jsonb, p_via text, p_lock boolean) to service_role;

-- remove_chapter_member: from 20261113000100_chapter_tools.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.remove_chapter_member(p_chapter uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_mod    boolean := public.is_moderator();
  v_mine   public.chapter_role;
  v_target public.chapter_members%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  perform 1 from public.hub_chapters where id = p_chapter for update;
  if not found then
    raise exception 'chapter_not_found' using errcode = 'PT404';
  end if;
  select role into v_mine from public.chapter_members where chapter_id = p_chapter and user_id = uid;
  if not v_mod and (v_mine is null or v_mine = 'member') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_target from public.chapter_members where chapter_id = p_chapter and user_id = p_user for update;
  if not found then
    raise exception 'not_a_member' using errcode = 'PT404';
  end if;
  if v_target.role = 'organizer' then
    if not v_mod and v_mine <> 'organizer' then
      raise exception 'forbidden' using errcode = '42501', hint = 'Captains cannot remove an organizer.';
    end if;
    if not v_mod and p_user <> uid then
      raise exception 'forbidden' using errcode = '42501',
        hint = 'Only a moderator removes another organizer.';
    end if;
    if not exists (select 1 from public.chapter_members
                    where chapter_id = p_chapter and role = 'organizer' and user_id <> p_user) then
      raise exception 'last_organizer' using errcode = 'check_violation',
        hint = 'A chapter keeps at least one organizer.';
    end if;
  end if;
  delete from public.chapter_members where chapter_id = p_chapter and user_id = p_user;
end $$;

revoke all on function public.remove_chapter_member(p_chapter uuid, p_user uuid) from public, anon;
grant execute on function public.remove_chapter_member(p_chapter uuid, p_user uuid) to authenticated, service_role;

-- remove_conversation_member: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.remove_conversation_member(p_conversation uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  c        public.conversations%rowtype;
  v_mine   text;
  v_theirs text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation;
  if not found or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if p_user is null or p_user = uid or c.kind in ('dm', 'hub') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  v_mine := private.chat_role(c.id, uid);
  v_theirs := private.chat_role(c.id, p_user);
  if v_theirs is null then
    return;
  end if;
  if c.kind = 'group' then
    if v_mine not in ('owner', 'admin') or v_theirs = 'owner' or (v_theirs = 'admin' and v_mine <> 'owner') then
      raise exception 'forbidden' using errcode = '42501';
    end if;
  elsif v_mine <> 'admin' or v_theirs = 'admin' then
    -- event and chapter rooms: hosts, captains and organizers remove members, not each other.
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.conversation_members (conversation_id, user_id, removed_at, removed_by)
  values (c.id, p_user, now(), uid)
  on conflict (conversation_id, user_id) do update set removed_at = now(), removed_by = uid;
end $$;

revoke all on function public.remove_conversation_member(p_conversation uuid, p_user uuid) from public, anon;
grant execute on function public.remove_conversation_member(p_conversation uuid, p_user uuid) to authenticated, service_role;

-- remove_rsvp: from 20261117000100_security_fixes.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.remove_rsvp(p_event_id uuid, p_user_id uuid, p_reason text default null)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id = e.host_id then
    raise exception 'cannot_remove_host' using errcode = 'check_violation';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'PT404';
  end if;
  update public.rsvps
     set status            = 'cancelled',
         waitlist_position = null,
         approved_by_host  = false,
         removed_by        = uid,
         removed_at        = now(),
         removed_reason    = left(nullif(btrim(coalesce(p_reason, '')), ''), 200)
   where event_id = p_event_id and user_id = p_user_id
   returning * into r;
  perform public.rsvp_promote_waitlist(p_event_id);
  return r;
end $$;

revoke all on function public.remove_rsvp(p_event_id uuid, p_user_id uuid, p_reason text) from public, anon;
grant execute on function public.remove_rsvp(p_event_id uuid, p_user_id uuid, p_reason text) to authenticated, service_role;

-- rename_group: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.rename_group(p_conversation uuid, p_title text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_title text := btrim(coalesce(p_title, ''));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.conversations c where c.id = p_conversation and c.kind = 'group')
     or not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if private.chat_role(p_conversation, uid) not in ('owner', 'admin') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if char_length(v_title) not between 1 and 60 then
    raise exception 'invalid_title' using errcode = 'check_violation', hint = '1 to 60 characters.';
  end if;
  update public.conversations set title = v_title where id = p_conversation;
end $$;

revoke all on function public.rename_group(p_conversation uuid, p_title text) from public, anon;
grant execute on function public.rename_group(p_conversation uuid, p_title text) to authenticated, service_role;

-- reply_to_review: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.reply_to_review(p_booking uuid, p_text text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  r      public.coach_reviews%rowtype;
  v_text text := btrim(coalesce(p_text, ''));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into r from public.coach_reviews where booking_id = p_booking and coach_id = uid for update;
  if not found or public.users_blocked(r.coach_id, r.client_id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if char_length(v_text) not between 1 and 1000 or not private.review_text_ok(v_text) then
    raise exception 'review_filtered' using errcode = 'check_violation';
  end if;
  if r.reply is not null and r.replied_at < now() - interval '7 days' then
    raise exception 'reply_locked' using errcode = 'check_violation';
  end if;
  update public.coach_reviews set reply = v_text, replied_at = coalesce(replied_at, now()) where booking_id = r.booking_id;
  if r.reply is null then
    perform private.booking_notify(r.booking_id, r.client_id, 'review_reply');
  end if;
  return jsonb_build_object('booking_id', r.booking_id, 'edited', r.reply is not null);
end $$;

revoke all on function public.reply_to_review(p_booking uuid, p_text text) from public, anon;
grant execute on function public.reply_to_review(p_booking uuid, p_text text) to authenticated, service_role;

-- report_content: from 20261224000100_coaching.sql; 8 not-found raise(s) now PT404 (Migration 70).
create or replace function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid           uuid := (select auth.uid());
  v_note        text := left(btrim(coalesce(p_note, '')), 1000);
  v_target_user uuid;
  v_state       text;
  v_id          uuid;
  v_n           integer;
  v_priority    smallint;
  v_due         interval;
  v_hidden      boolean := false;
  v_conv        uuid;          -- Migration 58
  v_deleted_at  timestamptz;
  v_deleted_by  text;
  v_coach       uuid;          -- Migration 60
  v_client      uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  -- Places keep their own reasons, rules and queue (migration 34).
  if p_kind = 'place' then
    return public.report_place(p_id, p_reason, p_note);
  end if;
  if p_kind is null or p_id is null
     or p_kind not in ('profile', 'event', 'chapter', 'hub', 'message',                   -- Migration 58
                       'coach_listing', 'coach_review', 'coach_review_reply', 'booking') then   -- Migration 60
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_reason is null or p_reason not in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam',
                                          'impersonation', 'underage', 'unsafe', 'ncii', 'child_safety', 'other',
                                          'no_show', 'payment')   -- Migration 60: booking reports only
     or (p_reason in ('no_show', 'payment') and p_kind <> 'booking') then
    raise exception 'invalid_reason' using errcode = 'check_violation';
  end if;

  if p_kind = 'profile' then
    select p.id, p.moderation_state into v_target_user, v_state
      from public.profiles p where p.id = p_id and p.deleted_at is null;
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'event' then
    select e.host_id, e.moderation_state into v_target_user, v_state from public.events e where e.id = p_id;
    -- Migration 54: a hidden or removed plan the caller cannot read is not found.
    if not found or not public.can_read_event(p_id) then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'message' then
    -- Migration 58: a message the reporter can read (an author-deleted one
    -- within 30 days, while its text is still kept).
    select m.author_id, m.moderation_state, m.conversation_id, m.deleted_at, m.deleted_by
      into v_target_user, v_state, v_conv, v_deleted_at, v_deleted_by
      from public.messages m where m.id = p_id;
    if not found or not private.chat_can_read(v_conv) or not private.chat_visible_author(v_target_user, uid)
       or (v_deleted_at is not null and (v_deleted_by <> 'author' or v_deleted_at < now() - interval '30 days')) then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind = 'coach_listing' then
    -- Migration 60: a listing the reporter can see (the coach is the target).
    select l.coach_id, l.moderation_state into v_target_user, v_state from public.coach_listings l where l.id = p_id;
    if not found or not private.coach_listing_visible(p_id) then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  elsif p_kind in ('coach_review', 'coach_review_reply') then
    -- Migration 60: a review (target: its author) or a reply (target: the coach) the reporter can see.
    select r.coach_id, r.client_id,
           case when p_kind = 'coach_review' then r.moderation_state else r.reply_moderation_state end
      into v_coach, v_client, v_state
      from public.coach_reviews r
     where r.booking_id = p_id and (p_kind = 'coach_review' or r.reply is not null);
    if not found or not private.coach_visible(v_coach)
       or (v_state is not null and uid not in (v_coach, v_client))
       or (uid <> v_client and private.is_blocked_with(v_client)) then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
    v_target_user := case when p_kind = 'coach_review' then v_client else v_coach end;
  elsif p_kind = 'booking' then
    -- Migration 60: only a party reports a booking; the target is the other party.
    select b.coach_id, b.client_id into v_coach, v_client from public.bookings b
     where b.id = p_id and uid in (b.coach_id, b.client_id);
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
    v_target_user := case when uid = v_coach then v_client else v_coach end;
  elsif p_kind = 'chapter' then
    -- Migration 54: an inactive (hidden or removed) chapter is not found, except for moderators.
    select c.moderation_state into v_state from public.hub_chapters c
     where c.id = p_id and (c.is_active or (c.moderation_state is not null and public.is_moderator()));
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
    if exists (select 1 from public.chapter_members cm
                where cm.chapter_id = p_id and cm.user_id = uid and cm.role in ('captain', 'organizer')) then
      raise exception 'own_item' using errcode = 'check_violation';
    end if;
  else
    -- Migration 54: likewise for hubs.
    select h.moderation_state into v_state from public.hubs h
     where h.id = p_id and (h.is_active or (h.moderation_state is not null and public.is_moderator()));
    if not found then
      raise exception 'target_not_found' using errcode = 'PT404';
    end if;
  end if;
  if v_target_user = uid then
    raise exception 'own_item' using errcode = 'check_violation';
  end if;

  select r.id into v_id from public.reports r
   where r.target_kind = p_kind and r.target_id = p_id and r.reporter_id = uid and r.status = 'open';
  if v_id is not null then
    -- Migration 54: hidden says only whether this report hid it, never the target's state.
    return jsonb_build_object('id', v_id, 'already', true, 'hidden', false);
  end if;

  -- Twenty reports a day across kinds (places count their own).
  if not public.is_moderator() then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('reports:' || uid::text));
    if (select count(*) from public.reports r
         where r.reporter_id = uid and r.created_at > now() - interval '1 day') >= 20 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to twenty reports a day.';
    end if;
  end if;

  v_priority := case when p_reason = 'child_safety' then 0 when p_reason in ('ncii', 'underage') then 1 else 2 end;
  v_due := case when p_reason = 'child_safety' then interval '4 hours' else interval '24 hours' end;
  insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note, priority, due_at)
  values (uid, p_kind, p_id, v_target_user, p_reason, v_note, v_priority, now() + v_due)
  returning id into v_id;

  -- Migration 58: the evidence copy of a reported message, with up to 10
  -- earlier and 5 later messages the reporter could see.
  if p_kind = 'message' then
    insert into public.message_report_evidence (report_id, message_id, conversation_id, conversation_kind,
                                                author_id, body, context)
    select v_id, m.id, m.conversation_id, c.kind, m.author_id,
           case when m.deleted_at is not null then coalesce(m.deleted_body, '') else m.body end,
           coalesce((
             select jsonb_agg(jsonb_build_object('id', x.id, 'seq', x.seq, 'author_id', x.author_id, 'kind', x.kind,
                                                 'body', x.body, 'created_at', x.created_at) order by x.seq)
               from ((select o.* from public.messages o
                       where o.conversation_id = m.conversation_id and o.seq < m.seq
                         and o.deleted_at is null and o.moderation_state is null
                         and private.chat_visible_author(o.author_id, uid)
                         and (o.author_id = uid or o.kind <> 'image' or o.image_state = 'visible')
                       order by o.seq desc limit 10)
                     union all
                     (select o.* from public.messages o
                       where o.conversation_id = m.conversation_id and o.seq > m.seq
                         and o.deleted_at is null and o.moderation_state is null
                         and private.chat_visible_author(o.author_id, uid)
                         and (o.author_id = uid or o.kind <> 'image' or o.image_state = 'visible')
                       order by o.seq asc limit 5)) x), '[]'::jsonb)
      from public.messages m
      join public.conversations c on c.id = m.conversation_id
     where m.id = p_id
    on conflict (report_id) do nothing;
  end if;

  -- Auto-hide at three (see the header): different active accounts older
  -- than a day, never the target; hubs are never auto-hidden.
  -- Migration 54: after a moderator dismissed or restored it in the last 30
  -- days, only a moderator hides it again; and nobody the target (for a
  -- chapter, one of its captains or organizers) blocked counts. The report
  -- itself is still filed.
  if p_kind not in ('hub', 'booking') and v_state is null   -- Migration 60: bookings are decided by mod_booking
     and not exists (select 1 from public.moderation_actions ma
                      where ma.target_kind = p_kind and ma.target_id = p_id
                        and ma.action in ('dismiss', 'restore') and ma.created_at > now() - interval '30 days') then
    select count(distinct r.reporter_id) into v_n
      from public.reports r
      join public.profiles rp on rp.id = r.reporter_id
     where r.target_kind = p_kind and r.target_id = p_id and r.status = 'open'
       and rp.status = 'active' and rp.deleted_at is null
       and rp.created_at <= now() - interval '1 day'
       and r.reporter_id is distinct from v_target_user
       and not exists (select 1 from public.blocks b
                        where b.blocked_id = r.reporter_id
                          and (b.blocker_id = v_target_user
                               or (p_kind = 'chapter' and b.blocker_id in (
                                     select cm.user_id from public.chapter_members cm
                                      where cm.chapter_id = p_id and cm.role in ('captain', 'organizer')))));
    if v_n >= 3 then
      perform public.moderation_set_state(p_kind, p_id, 'hidden');
      insert into public.moderation_actions (moderator_id, action, target_kind, target_id, target_user_id, report_count)
      values (null, 'auto_hide', p_kind, p_id, v_target_user, v_n);
      v_hidden := true;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'already', false, 'hidden', v_hidden);   -- Migration 54
end $$;

revoke all on function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text) from public, anon;
grant execute on function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text) to authenticated, service_role;

-- report_place: from 20261128000100_place_contributions.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.report_place(p_place uuid, p_reason text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  p       public.places%rowtype;
  v_note  text := left(btrim(coalesce(p_note, '')), 500);
  v_id    uuid;
  v_n     integer;
  v_hide  boolean := false;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_reason is null or p_reason not in ('closed', 'wrong_location', 'wrong_info', 'not_public',
                                          'private_residence', 'unsafe', 'spam', 'other') then
    raise exception 'invalid_reason' using errcode = 'check_violation';
  end if;
  if p_place is null or not public.place_caller_can_see(p_place) then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  select * into p from public.places where id = p_place for update;
  if p.status not in ('active', 'closed') then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  if p.created_by = uid then
    raise exception 'own_place' using errcode = 'check_violation',
      hint = 'Edit or delete your own place instead.';
  end if;

  select r.id into v_id from public.place_reports r
   where r.place_id = p.id and r.reporter_id = uid and r.status = 'open';
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'already', true, 'hidden', p.status = 'hidden');
  end if;

  -- Rule 9: twenty reports a day.
  if not public.is_moderator() then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('place_reports:' || uid::text));
    if (select count(*) from public.place_reports r
         where r.reporter_id = uid and r.created_at > now() - interval '1 day') >= 20 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to twenty reports a day.';
    end if;
  end if;

  insert into public.place_reports (place_id, reporter_id, reason, note)
  values (p.id, uid, p_reason, v_note)
  returning id into v_id;

  -- Rule 4.
  if p.status = 'active' then
    if p_reason in ('private_residence', 'unsafe') and p.source in ('user', 'venue') then
      v_hide := true;
    else
      select count(distinct r.reporter_id) into v_n from public.place_reports r
       where r.place_id = p.id and r.status = 'open' and r.reporter_id is not null;
      v_hide := v_n >= 3;
    end if;
    if v_hide then
      update public.places set status = 'hidden' where id = p.id;
    end if;
  end if;

  return jsonb_build_object('id', v_id, 'already', false, 'hidden', v_hide);
end $$;

revoke all on function public.report_place(p_place uuid, p_reason text, p_note text) from public, anon;
grant execute on function public.report_place(p_place uuid, p_reason text, p_note text) to authenticated, service_role;

-- request_booking: from 20261225000100_coaching_review_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
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
    raise exception 'not_found' using errcode = 'PT404';
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

revoke all on function public.request_booking(p_listing uuid, p_starts_at timestamptz, p_note text, p_policy_version text, p_client_request_id uuid) from public, anon;
grant execute on function public.request_booking(p_listing uuid, p_starts_at timestamptz, p_note text, p_policy_version text, p_client_request_id uuid) to authenticated, service_role;

-- respond_message_request: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.respond_message_request(p_conversation uuid, p_action text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_action is null or p_action not in ('accept', 'decline') then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;
  update public.message_requests
     set status = case when p_action = 'accept' then 'accepted' else 'declined' end, decided_at = now()
   where conversation_id = p_conversation and to_user = uid and status = 'pending';
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
end $$;

revoke all on function public.respond_message_request(p_conversation uuid, p_action text) from public, anon;
grant execute on function public.respond_message_request(p_conversation uuid, p_action text) to authenticated, service_role;

-- review_chapter_claim: from 20261114000100_notifications.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.review_chapter_claim(p_claim_id uuid, p_approve boolean, p_note text default null)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.chapter_claims%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_note    text := left(nullif(btrim(coalesce(p_note, '')), ''), 500);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_approve is null then
    raise exception 'invalid_decision' using errcode = 'check_violation';
  end if;
  select * into c from public.chapter_claims where id = p_claim_id for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'PT404';
  end if;
  if c.user_id = uid then
    raise exception 'own_claim' using errcode = '42501', hint = 'Another moderator reviews your claim.';
  end if;
  if c.status <> 'pending' then
    raise exception 'claim_not_pending' using errcode = 'check_violation';
  end if;

  if not p_approve then
    update public.chapter_claims
       set status = 'rejected', reviewed_by = uid, reviewed_at = now(), review_note = v_note
     where id = c.id
     returning * into c;
    perform public.notify_chapter_claim_reviewed(c);
    return c;
  end if;

  if not exists (select 1 from public.profiles
                  where id = c.user_id and status = 'active' and deleted_at is null) then
    raise exception 'claimant_inactive' using errcode = 'check_violation';
  end if;
  if c.kind = 'org' and not exists (
       select 1 from public.org_memberships m
        where m.user_id = c.user_id and m.org_id = c.org_id
          and (m.expires_at is null or m.expires_at > now())
          and (c.campus_id is null or m.campus_id is null or m.campus_id = c.campus_id)) then
    raise exception 'membership_required' using errcode = 'check_violation',
      hint = 'The claimant''s verified membership has lapsed or moved to another campus.';
  end if;

  -- The chapter: the claim's, else the one at this place, else a new row.
  if c.chapter_id is not null then
    select * into v_chapter from public.hub_chapters where id = c.chapter_id for update;
  end if;
  if v_chapter.id is null then
    select * into v_chapter from public.hub_chapters ch
     where ch.hub_id = c.hub_id
       and ch.org_id is not distinct from c.org_id
       and ch.campus_id is not distinct from c.campus_id
       and ch.area_id is not distinct from c.area_id
     for update;
  end if;
  if v_chapter.id is null then
    insert into public.hub_chapters (hub_id, org_id, campus_id, area_id, slug, name, created_by, rso_name, pin_url)
    values (c.hub_id, c.org_id, c.campus_id, c.area_id, public.chapter_slug_for(c.proposed_name), c.proposed_name,
            c.user_id, c.rso_name, c.pin_url)
    returning * into v_chapter;
  end if;
  if exists (select 1 from public.chapter_members
              where chapter_id = v_chapter.id and role = 'organizer' and user_id <> c.user_id) then
    raise exception 'chapter_has_organizer' using errcode = 'check_violation';
  end if;

  insert into public.chapter_members (user_id, chapter_id, role)
  values (c.user_id, v_chapter.id, 'organizer')
  on conflict (user_id, chapter_id) do update set role = 'organizer';

  if c.kind = 'org' then
    update public.org_memberships
       set role = 'officer'
     where user_id = c.user_id and org_id = c.org_id and role < 'officer';
  end if;

  update public.hub_chapters
     set claimed_by  = c.user_id,
         claimed_at  = now(),
         verified_at = now(),
         is_active   = true,
         rso_name    = coalesce(c.rso_name, rso_name),
         pin_url     = coalesce(c.pin_url, pin_url)
   where id = v_chapter.id;

  update public.chapter_claims
     set status = 'approved', chapter_id = v_chapter.id, reviewed_by = uid, reviewed_at = now(), review_note = v_note
   where id = c.id
   returning * into c;
  perform public.notify_chapter_claim_reviewed(c);
  return c;
end $$;

revoke all on function public.review_chapter_claim(p_claim_id uuid, p_approve boolean, p_note text) from public, anon;
grant execute on function public.review_chapter_claim(p_claim_id uuid, p_approve boolean, p_note text) to authenticated, service_role;

-- schedule_group_session: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.schedule_group_session(p_listing uuid, p_starts_at timestamptz)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid  uuid := (select auth.uid());
  l    public.coach_listings%rowtype;
  v_id uuid;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  select * into l from public.coach_listings where id = p_listing and coach_id = uid;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if l.format <> 'group' then
    raise exception 'not_group' using errcode = 'check_violation';
  end if;
  if l.status <> 'active' or l.moderation_state is not null then
    raise exception 'invalid_state' using errcode = 'check_violation';
  end if;
  if p_starts_at is null or p_starts_at <= now() or p_starts_at > now() + interval '180 days' then
    raise exception 'invalid_range' using errcode = 'check_violation';
  end if;
  begin
    insert into public.coach_sessions (coach_id, listing_id, starts_at, ends_at, busy, capacity)
    values (uid, l.id, p_starts_at, p_starts_at + make_interval(mins => l.duration_minutes::integer),
            tstzrange(p_starts_at, p_starts_at, '[]'), l.capacity)
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'slot_taken' using errcode = 'check_violation';
  end;
  return v_id;
end $$;

revoke all on function public.schedule_group_session(p_listing uuid, p_starts_at timestamptz) from public, anon;
grant execute on function public.schedule_group_session(p_listing uuid, p_starts_at timestamptz) to authenticated, service_role;

-- send_message: from 20261223000100_messaging_review_fixes.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.send_message(p_conversation uuid, p_client_id uuid, p_body text,
                                               p_image_path text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.conversations%rowtype;
  r         public.message_requests%rowtype;
  e         public.events%rowtype;
  v_body    text;
  v_err     text;
  v_mod     boolean;
  v_new     boolean;
  v_request boolean;
  v_link    boolean := false;
  v_seq     bigint;
  v_id      uuid;
  v_at      timestamptz;
  v_n       integer;
  v_last    timestamptz;
  v_user    uuid;
  v_title   text;
  v_payload jsonb;
  v_bucket  bigint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_client_id is null then
    raise exception 'client_id_required' using errcode = 'check_violation';
  end if;
  -- Migration 59: one call per client id at a time. A retry that overlaps
  -- the first call waits here, then finds its row below (before, it waited
  -- on the conversation row and failed on messages_client_uq).
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('chat_client:' || uid::text || ':' || p_client_id::text));
  -- A retry of a send that already went through: the same row, free.
  select m.id, m.seq, m.created_at into v_id, v_seq, v_at
    from public.messages m where m.author_id = uid and m.client_id = p_client_id;
  if v_id is not null then
    return jsonb_build_object('id', v_id, 'seq', v_seq, 'created_at', v_at, 'duplicate', true);
  end if;

  select * into c from public.conversations where id = p_conversation;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;

  -- Requests: shared context that appeared since, or the recipient writing back, accepts.
  if c.kind = 'dm' then
    select * into r from public.message_requests where conversation_id = c.id for update;
    if r.conversation_id is not null and r.status <> 'accepted'
       and (r.to_user = uid or private.chat_shared_context(r.from_user, r.to_user)) then
      update public.message_requests set status = 'accepted', decided_at = now() where conversation_id = c.id;
      r.status := 'accepted';
    end if;
  end if;

  v_err := private.chat_can_post(c.id);
  if v_err is not null then
    raise exception '%', v_err using
      errcode = case when v_err in ('not_authenticated', 'forbidden') then '42501'
                     when v_err = 'not_found' then 'PT404' else '23514' end;
  end if;
  v_request := c.kind = 'dm' and r.conversation_id is not null and r.status = 'pending' and r.from_user = uid;

  -- stripControlChars (packages/core) and trim.
  v_body := regexp_replace(regexp_replace(coalesce(p_body, ''), '[\x01-\x08\x0B\x0C\x0E-\x1F\x7F]', '', 'g'),
                           '^\s+|\s+$', '', 'g');
  if char_length(v_body) > 2000 or (p_image_path is null and char_length(v_body) = 0) then
    raise exception 'body_length' using errcode = 'check_violation', hint = '1 to 2000 characters.';
  end if;
  v_mod := public.is_moderator();
  v_new := (select p.created_at from public.profiles p where p.id = uid) > now() - interval '24 hours';

  if p_image_path is not null then
    if not private.chat_images_enabled() then
      raise exception 'images_disabled' using errcode = 'check_violation';
    end if;
    if v_request then
      raise exception 'request_text_only' using errcode = 'check_violation';
    end if;
    if v_new then
      raise exception 'account_too_new' using errcode = 'check_violation';
    end if;
    if p_image_path !~ ('^' || uid::text || '/' || c.id::text
                        || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$')
       or not exists (select 1 from storage.objects o where o.bucket_id = 'chat-images' and o.name = p_image_path)
       or exists (select 1 from public.messages m where m.image_path = p_image_path) then
      raise exception 'image_invalid' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.image_hashes h
                where h.bucket = 'chat-images' and h.path = p_image_path and h.status in ('blocked', 'unreadable')) then
      raise exception 'image_blocked' using errcode = 'check_violation';
    end if;
  end if;

  if char_length(v_body) > 0 and (private.chat_has_link(v_body) or private.chat_link_shortened(v_body)) then
    v_link := true;
    if v_request or v_new or private.chat_link_shortened(v_body) then
      raise exception 'link_not_allowed' using errcode = 'check_violation';
    end if;
  end if;

  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat:' || uid::text));
    -- Three filter refusals in an hour: one hour without sending.
    select min(s.created_at), count(*)::integer into v_last, v_n
      from (select fs.created_at from public.chat_filter_strikes fs
             where fs.user_id = uid and fs.created_at > now() - interval '1 hour'
             order by fs.created_at desc limit 3) s;
    if v_n >= 3 then
      raise exception 'rate_limited' using errcode = 'check_violation',
        hint = greatest(1, ceil(extract(epoch from (v_last + interval '1 hour' - now()))))::text;
    end if;
    if (select count(*) from public.messages m
         where m.author_id = uid and m.created_at > now() - interval '1 minute')
       >= (case when v_new then 10 else 30 end) then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '60';
    end if;
    if (select count(*) from public.messages m
         where m.author_id = uid and m.created_at > now() - interval '1 day')
       >= (case when v_new then 100 else 1000 end) then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '3600';
    end if;
    select max(m.created_at) into v_last from public.messages m
     where m.author_id = uid and m.conversation_id = c.id;
    if c.kind = 'hub' and v_last > now() - interval '10 seconds' then
      raise exception 'slow_mode' using errcode = 'check_violation',
        hint = greatest(1, ceil(extract(epoch from (v_last + interval '10 seconds' - now()))))::text;
    end if;
    if v_last > now() - (case when v_new then interval '5 seconds' else interval '1 second' end) then
      raise exception 'rate_limited' using errcode = 'check_violation',
        hint = case when v_new then '5' else '1' end;
    end if;
    if p_image_path is not null and (select count(*) from public.messages m
                                      where m.author_id = uid and m.kind = 'image'
                                        and m.created_at > now() - interval '1 day') >= 30 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = '86400';
    end if;
  end if;

  -- The filter: refused without raising, so the strike is kept.
  if char_length(v_body) > 0 and private.chat_filtered(v_body, v_request) then
    insert into public.chat_filter_strikes (user_id) values (uid);
    if (select count(*) from public.chat_filter_strikes fs
         where fs.user_id = uid and fs.created_at > now() - interval '1 hour') >= 3
       and not exists (select 1 from public.reports rp
                        where rp.target_kind = 'profile' and rp.target_id = uid and rp.reporter_id is null
                          and rp.status = 'open') then
      insert into public.reports (reporter_id, target_kind, target_id, target_user_id, reason, note)
      values (null, 'profile', uid, uid, 'harassment', 'Automatic: three messages refused by the chat filter within an hour.');
    end if;
    return jsonb_build_object('error', 'message_filtered');
  end if;

  update public.conversations set last_seq = last_seq + 1, last_message_at = now()
   where id = c.id returning last_seq into v_seq;
  insert into public.messages (conversation_id, seq, author_id, client_id, kind, body, image_path, image_state, has_link)
  values (c.id, v_seq, uid, p_client_id, case when p_image_path is null then 'text' else 'image' end, v_body,
          p_image_path, case when p_image_path is not null then 'pending' end, v_link)
  returning id, created_at into v_id, v_at;

  -- The sender has read their own message; a dm the other person left comes back to them.
  insert into public.conversation_members (conversation_id, user_id, last_read_seq, last_read_at)
  values (c.id, uid, v_seq, now())
  on conflict (conversation_id, user_id) do update
     set last_read_seq = greatest(public.conversation_members.last_read_seq, excluded.last_read_seq),
         last_read_at = now();
  if c.kind = 'dm' then
    update public.conversation_members set left_at = null
     where conversation_id = c.id and left_at is not null;
  end if;

  -- Notifications (design section 11): ids and counts only, never the text.
  v_title := case c.kind
               when 'group' then c.title
               when 'event' then (select ev.title from public.events ev where ev.id = c.event_id)
               when 'hub' then (select h.name from public.hubs h where h.id = c.hub_id)
               when 'chapter' then (select ch.name from public.hub_chapters ch where ch.id = c.chapter_id)
             end;
  v_payload := jsonb_build_object('conversation_id', c.id, 'kind', c.kind, 'title', v_title, 'seq', v_seq);
  if v_request then
    v_user := private.chat_dm_other(c.dm_key, uid);
    -- Migration 59: the request's time is in the key, so a new request after
    -- a decline (start_dm resets created_at) is notified again.
    perform public.enqueue_notification(v_user, 'message_request',
                                        'message_request:' || c.id || ':' || v_user || ':'
                                          || floor(extract(epoch from r.created_at))::bigint::text,
                                        null, null, null, uid, v_payload);
  elsif c.kind in ('dm', 'group') then
    v_bucket := floor(extract(epoch from now()) / 600)::bigint;
    for v_user in
      select cm.user_id from public.conversation_members cm
       where cm.conversation_id = c.id and cm.user_id <> uid and cm.left_at is null and cm.removed_at is null
         and (cm.muted_until is null or cm.muted_until <= now()) and coalesce(cm.notify, true)
    loop
      perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                          null, null, null, uid, v_payload, true);
    end loop;
  elsif c.kind = 'event' then
    select * into e from public.events where id = c.event_id;
    if e.ends_at > now() then
      v_bucket := floor(extract(epoch from now()) / 1800)::bigint;
      for v_user in
        select x.user_id
          from (select rr.user_id from public.rsvps rr
                 where rr.event_id = e.id and rr.status in ('going', 'waitlisted') and rr.removed_at is null
                union select e.host_id) x
          left join public.conversation_members cm on cm.conversation_id = c.id and cm.user_id = x.user_id
         where x.user_id is not null and x.user_id <> uid and cm.removed_at is null
           and (cm.muted_until is null or cm.muted_until <= now()) and coalesce(cm.notify, true)
      loop
        perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                            null, null, null, uid, v_payload, true);
      end loop;
    end if;
  else
    -- Hub and chapter chats notify only people who turned it on for the room.
    v_bucket := floor(extract(epoch from now()) / 1800)::bigint;
    for v_user in
      select cm.user_id from public.conversation_members cm
       where cm.conversation_id = c.id and cm.user_id <> uid and cm.notify is true and cm.removed_at is null
         and (cm.muted_until is null or cm.muted_until <= now())
         and private.chat_role(c.id, cm.user_id) is not null
    loop
      perform public.enqueue_notification(v_user, 'message', 'message:' || c.id || ':' || v_user || ':' || v_bucket,
                                          null, null, null, uid, v_payload, true);
    end loop;
  end if;

  return jsonb_build_object('id', v_id, 'seq', v_seq, 'created_at', v_at, 'duplicate', false);
end $$;

revoke all on function public.send_message(p_conversation uuid, p_client_id uuid, p_body text, p_image_path text) from public, anon;
grant execute on function public.send_message(p_conversation uuid, p_client_id uuid, p_body text, p_image_path text) to authenticated, service_role;

-- set_chapter_role: from 20261113000100_chapter_tools.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_chapter_role(p_chapter uuid, p_user uuid, p_role public.chapter_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_mod     boolean := public.is_moderator();
  v_chapter public.hub_chapters%rowtype;
  v_mine    public.chapter_role;
  v_target  public.chapter_members%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_role is null then
    raise exception 'invalid_role' using errcode = 'check_violation';
  end if;
  -- The chapter row lock serializes role changes, so two organizers cannot
  -- demote each other at once.
  select * into v_chapter from public.hub_chapters where id = p_chapter for update;
  if not found then
    raise exception 'chapter_not_found' using errcode = 'PT404';
  end if;
  select role into v_mine from public.chapter_members where chapter_id = p_chapter and user_id = uid;
  if not v_mod then
    if v_mine is distinct from 'organizer' then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    if p_role = 'organizer' then
      raise exception 'organizer_requires_moderator' using errcode = '42501',
        hint = 'Only a moderator can make someone an organizer.';
    end if;
  end if;

  select * into v_target from public.chapter_members where chapter_id = p_chapter and user_id = p_user for update;
  if not found then
    raise exception 'not_a_member' using errcode = 'PT404';
  end if;
  if v_target.role = p_role then
    return;
  end if;
  if v_target.role = 'organizer' then
    if not v_mod and p_user <> uid then
      raise exception 'forbidden' using errcode = '42501',
        hint = 'Only a moderator changes another organizer''s role.';
    end if;
    if not exists (select 1 from public.chapter_members
                    where chapter_id = p_chapter and role = 'organizer' and user_id <> p_user) then
      raise exception 'last_organizer' using errcode = 'check_violation',
        hint = 'A chapter keeps at least one organizer.';
    end if;
  end if;
  if p_role in ('captain', 'organizer') then
    if not exists (select 1 from public.profiles where id = p_user and status = 'active' and onboarding_completed_at is not null) then
      raise exception 'member_inactive' using errcode = 'check_violation';
    end if;
    -- No informal captains on an organization's chapter: verified members only.
    if v_chapter.org_id is not null and not exists (
         select 1 from public.org_memberships m
          where m.user_id = p_user and m.org_id = v_chapter.org_id
            and (m.expires_at is null or m.expires_at > now())) then
      raise exception 'membership_required' using errcode = 'check_violation',
        hint = 'Captains of an organization''s chapter need a verified membership in it.';
    end if;
  end if;

  update public.chapter_members set role = p_role where chapter_id = p_chapter and user_id = p_user;
end $$;

revoke all on function public.set_chapter_role(p_chapter uuid, p_user uuid, p_role public.chapter_role) from public, anon;
grant execute on function public.set_chapter_role(p_chapter uuid, p_user uuid, p_role public.chapter_role) to authenticated, service_role;

-- set_conversation_notify: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_conversation_notify(p_conversation uuid, p_notify boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not private.chat_can_read(p_conversation) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  insert into public.conversation_members (conversation_id, user_id, notify)
  values (p_conversation, uid, p_notify)
  on conflict (conversation_id, user_id) do update set notify = excluded.notify;
end $$;

revoke all on function public.set_conversation_notify(p_conversation uuid, p_notify boolean) from public, anon;
grant execute on function public.set_conversation_notify(p_conversation uuid, p_notify boolean) to authenticated, service_role;

-- set_conversation_role: from 20261222000100_messaging.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_conversation_role(p_conversation uuid, p_user uuid,
                                                        p_role public.conversation_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c   public.conversations%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.conversations where id = p_conversation for update;
  if not found or c.kind <> 'group' or not private.chat_can_read(c.id) then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  if private.chat_role(c.id, uid) <> 'owner' or p_user is null or p_user = uid or p_role is null
     or private.chat_role(c.id, p_user) is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_role = 'owner' then
    -- Handing over: the caller stays as an admin.
    update public.conversation_members set role = 'admin' where conversation_id = c.id and user_id = uid;
  end if;
  update public.conversation_members set role = p_role where conversation_id = c.id and user_id = p_user;
end $$;

revoke all on function public.set_conversation_role(p_conversation uuid, p_user uuid, p_role public.conversation_role) from public, anon;
grant execute on function public.set_conversation_role(p_conversation uuid, p_user uuid, p_role public.conversation_role) to authenticated, service_role;

-- set_home_area: from 20261119000100_location_anywhere.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_home_area(p_area_id uuid, p_radius_km smallint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_area   public.areas%rowtype;
  v_radius smallint;
  v_old    extensions.geography;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_area_id is null then
    raise exception 'area_required' using errcode = 'check_violation';
  end if;
  select * into v_area from public.areas where id = p_area_id;
  if not found then
    raise exception 'area_not_found' using errcode = 'PT404';
  end if;
  if p_radius_km is not null and p_radius_km not between 1 and 50 then
    raise exception 'radius_out_of_range' using errcode = 'check_violation', hint = '1 to 50 km.';
  end if;
  if not exists (select 1 from public.profiles where id = uid and deleted_at is null) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  select pp.home_point into v_old from public.profile_private pp where pp.user_id = uid;

  update public.profile_private
     set home_area_id   = v_area.id,
         feed_radius_km = coalesce(p_radius_km, greatest(1, least(50, v_area.default_radius_km))),
         home_point     = v_area.center,
         home_label     = left(v_area.name, 120),
         home_set_at    = now()
   where user_id = uid
  returning feed_radius_km into v_radius;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  perform public.collector_note_home_point(v_area.center, v_area.name, v_old);

  return jsonb_build_object(
    'area_id', v_area.id, 'slug', v_area.slug, 'name', v_area.name,
    'feed_radius_km', v_radius);
end $$;

revoke all on function public.set_home_area(p_area_id uuid, p_radius_km smallint) from public, anon;
grant execute on function public.set_home_area(p_area_id uuid, p_radius_km smallint) to authenticated, service_role;

-- set_listing_status: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_listing_status(p_id uuid, p_status public.listing_status)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_status is null then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end if;
  perform 1 from public.coach_listings where id = p_id and coach_id = uid for update;
  if not found then
    raise exception 'not_found' using errcode = 'PT404';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('coach_listings:' || uid::text));
  if p_status = 'active'
     and (select count(*) from public.coach_listings x where x.coach_id = uid and x.status = 'active' and x.id <> p_id) >= 20 then
    raise exception 'too_many' using errcode = 'check_violation';
  end if;
  update public.coach_listings set status = p_status where id = p_id;
  return jsonb_build_object('id', p_id, 'status', p_status);
end $$;

revoke all on function public.set_listing_status(p_id uuid, p_status public.listing_status) from public, anon;
grant execute on function public.set_listing_status(p_id uuid, p_status public.listing_status) to authenticated, service_role;

-- set_my_place_visibility: from 20261128000100_place_contributions.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_my_place_visibility(p_place uuid, p_public boolean, p_confirm boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  p     public.places%rowtype;
  v_why text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.places where id = p_place and created_by = uid and source = 'user' for update;
  if not found or p.status not in ('active', 'pending') then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  if p_public is null then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end if;
  if p.is_public and p.status = 'active' then
    raise exception 'reviewed_place' using errcode = 'check_violation',
      hint = 'A reviewed public place stays on the map for everyone. Suggest a correction or report it instead.';
  end if;
  if p_public = p.is_public then
    return jsonb_build_object('id', p.id, 'status', p.status, 'is_public', p.is_public);
  end if;

  if p_public then
    if not coalesce(p_confirm, false) then
      raise exception 'confirm_public_required' using errcode = 'check_violation',
        hint = 'Confirm this is a public place, not a home or private residence.';
    end if;
    if not exists (select 1 from public.place_hubs ph where ph.place_id = p.id) then
      raise exception 'hub_required' using errcode = 'check_violation',
        hint = 'Pick at least one hub this place is for.';
    end if;
    perform public.place_raise_near(public.place_near_private(uid, p.location));
    update public.places
       set is_public = true,
           status    = case when public.is_moderator() then 'active'::public.place_status
                            else 'pending'::public.place_status end
     where id = p.id
     returning * into p;
  else
    update public.places set is_public = false, status = 'active' where id = p.id returning * into p;
  end if;
  return jsonb_build_object('id', p.id, 'status', p.status, 'is_public', p.is_public);
end $$;

revoke all on function public.set_my_place_visibility(p_place uuid, p_public boolean, p_confirm boolean) from public, anon;
grant execute on function public.set_my_place_visibility(p_place uuid, p_public boolean, p_confirm boolean) to authenticated, service_role;

-- set_rsvp: from 20261114000100_notifications.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  e       public.events%rowtype;
  p       public.profiles%rowtype;
  r       public.rsvps%rowtype;
  v_want  public.rsvp_status;
  v_was   public.rsvp_status;
  v_going integer;
  v_age   integer;
  v_mod   boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_status is null then
    raise exception 'invalid_status' using errcode = 'check_violation';
  end if;
  v_want := case when p_status = 'waitlisted' then 'going'::public.rsvp_status else p_status end;

  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  v_was := r.status;   -- null when there is no row yet

  -- Leaving needs nothing but the row.
  if v_want = 'cancelled' then
    if v_was is null then
      return null;
    end if;
    if v_was = 'cancelled' then
      return r;
    end if;
    update public.rsvps
       set status = 'cancelled', waitlist_position = null
     where event_id = p_event_id and user_id = uid
     returning * into r;
    if v_was = 'going' then
      perform public.rsvp_promote_waitlist(p_event_id);
    end if;
    return r;
  end if;

  -- This function bypasses RLS, so the read rules are repeated here.
  v_mod := public.is_moderator();
  select * into p from public.profiles where id = uid;
  if p.status is distinct from 'active' or p.onboarding_completed_at is null then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p.guidelines_accepted_at is null then
    raise exception 'guidelines_required' using errcode = 'check_violation',
      hint = 'Accept the Community Guidelines first (accept_guidelines).';
  end if;
  if r.removed_at is not null and not v_mod then
    raise exception 'removed_by_host' using errcode = '42501',
      hint = 'The host removed you from this event.';
  end if;
  v_age := public.viewer_age();
  if v_age is null or v_age < e.min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;
  if e.visibility = 'campus' and not v_mod and not public.is_campus_org_member(e.campus_id) then
    raise exception 'not_campus_member' using errcode = '42501',
      hint = 'Campus events are for verified members of that campus.';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if e.ends_at < now() then
    raise exception 'event_over' using errcode = 'check_violation';
  end if;
  if e.members_only and uid is distinct from e.host_id and not v_mod then
    if e.kind = 'chapter' then
      if not exists (select 1 from public.chapter_members where chapter_id = e.chapter_id and user_id = uid) then
        raise exception 'not_chapter_member' using errcode = '42501', hint = 'This event is for chapter members.';
      end if;
    elsif not exists (select 1 from public.hub_members where hub_id = e.hub_id and user_id = uid) then
      raise exception 'not_hub_member' using errcode = '42501', hint = 'This event is for hub members.';
    end if;
  end if;

  if v_want = 'interested' then
    if v_was = 'interested' then
      return r;
    end if;
    insert into public.rsvps (event_id, user_id, status)
    values (p_event_id, uid, 'interested')
    on conflict (event_id, user_id) do update set status = 'interested', waitlist_position = null
    returning * into r;
  else
    if v_was in ('going', 'waitlisted') then
      return r;
    end if;
    select count(*) into v_going from public.rsvps where event_id = p_event_id and status = 'going';
    if e.capacity is null or v_going < e.capacity then
      insert into public.rsvps (event_id, user_id, status)
      values (p_event_id, uid, 'going')
      on conflict (event_id, user_id) do update set status = 'going', waitlist_position = null
      returning * into r;
    elsif e.waitlist_enabled then
      insert into public.rsvps (event_id, user_id, status, waitlist_position)
      values (p_event_id, uid, 'waitlisted',
              (select coalesce(max(waitlist_position), 0) + 1 from public.rsvps
                where event_id = p_event_id and status = 'waitlisted'))
      on conflict (event_id, user_id) do update set status = 'waitlisted', waitlist_position = excluded.waitlist_position
      returning * into r;
    else
      raise exception 'event_full' using errcode = 'check_violation';
    end if;
  end if;

  -- Notifications (migration 18): a fresh going or waitlisted RSVP confirms to
  -- the attendee; a going one tells the host and the chapter's captains and
  -- organizers (one row per hour per event, counted).
  if r.status in ('going', 'waitlisted') then
    perform public.enqueue_notification(
      uid, 'rsvp_confirmed', 'rsvp_confirmed:' || p_event_id || ':' || uid,
      p_event_id, e.hub_id, e.chapter_id, null,
      public.notification_event_payload(p_event_id) || jsonb_build_object('status', r.status));
    if r.status = 'going' then
      perform public.notify_event_managers_joined(p_event_id, uid);
    end if;
  end if;

  if v_was = 'going' and r.status <> 'going' then
    perform public.rsvp_promote_waitlist(p_event_id);
  end if;
  return r;
end $$;

revoke all on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) from public, anon;
grant execute on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) to authenticated, service_role;

-- start_dm: from 20261223000100_messaging_review_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.start_dm(p_user uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  v_key text;
  v_ctx boolean;
  c     public.conversations%rowtype;
  r     public.message_requests%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.viewer_is_adult() then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_user = uid then
    raise exception 'cannot_message_self' using errcode = 'check_violation';
  end if;
  -- A blocked pair, a banned, hidden or deleted profile: all the same answer.
  if not private.chat_user_ok(p_user) or public.users_blocked(uid, p_user) then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  if not private.chat_has_photo(uid) then
    raise exception 'photo_required' using errcode = 'check_violation', hint = 'Add a profile photo to send messages.';
  end if;

  v_key := private.chat_dm_key(uid, p_user);
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('chat_dm:' || v_key));
  v_ctx := private.chat_shared_context(uid, p_user);
  select * into c from public.conversations where kind = 'dm' and dm_key = v_key;

  if c.id is not null then
    select * into r from public.message_requests where conversation_id = c.id for update;
    if r.conversation_id is not null and r.status <> 'accepted' then
      if v_ctx or r.to_user = uid then
        -- Shared context appeared, or the recipient writes back: accepted.
        update public.message_requests set status = 'accepted', decided_at = now() where conversation_id = c.id;
      elsif r.status = 'pending' then
        -- Migration 59: a requester who left their pending request is put back
        -- in it (read only until a reply), so the id returned is readable.
        update public.conversation_members set left_at = null
         where conversation_id = c.id and user_id = uid and left_at is not null;
        return jsonb_build_object('conversation_id', c.id, 'state', 'request_pending');
      else
        -- Declined: the requester may ask again after 30 days, under the first-request rules.
        if r.decided_at > now() - interval '30 days' then
          raise exception 'request_cooldown' using errcode = 'check_violation';
        end if;
        perform private.chat_request_checks(uid);
        update public.message_requests
           set status = 'pending', created_at = now(), decided_at = null
         where conversation_id = c.id;
        update public.conversations set closed_at = null where id = c.id;
        update public.conversation_members set left_at = null
         where conversation_id = c.id and user_id = uid;
        return jsonb_build_object('conversation_id', c.id, 'state', 'request');
      end if;
    end if;
    -- Reopened after both unblocked, or after one of them left.
    update public.conversations set closed_at = null where id = c.id and closed_at is not null;
    insert into public.conversation_members (conversation_id, user_id) values (c.id, uid)
    on conflict (conversation_id, user_id) do update set left_at = null;
    insert into public.conversation_members (conversation_id, user_id) values (c.id, p_user)
    on conflict (conversation_id, user_id) do nothing;
    return jsonb_build_object('conversation_id', c.id, 'state', 'open');
  end if;

  if not v_ctx then
    perform private.chat_request_checks(uid);
  end if;
  insert into public.conversations (kind, dm_key, created_by) values ('dm', v_key, uid) returning * into c;
  insert into public.conversation_members (conversation_id, user_id) values (c.id, uid), (c.id, p_user);
  if not v_ctx then
    insert into public.message_requests (conversation_id, from_user, to_user) values (c.id, uid, p_user);
  end if;
  return jsonb_build_object('conversation_id', c.id, 'state', case when v_ctx then 'open' else 'request' end);
end $$;

revoke all on function public.start_dm(p_user uuid) from public, anon;
grant execute on function public.start_dm(p_user uuid) to authenticated, service_role;

-- start_organizer_claim: from 20261230000100_collector_review_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.start_organizer_claim(
  p_source uuid default null, p_event uuid default null, p_host text default null,
  p_method text default 'meta', p_feed_url text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_method text := coalesce(nullif(btrim(coalesce(p_method, '')), ''), 'meta');
  v_src    public.feed_sources%rowtype;
  v_host   text := regexp_replace(regexp_replace(lower(btrim(coalesce(p_host, ''))), '\.+$', ''), '^www\.', '');
  v_feed   text;
  v_chk    jsonb;
  v_hosts  text[];
  v_claim  public.organizer_claims%rowtype;
  v_own    jsonb;   -- Migration 66
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.status = 'active' and p.deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles p where p.id = uid and p.created_at <= now() - interval '24 hours') then
    raise exception 'account_too_new' using errcode = 'P0001';
  end if;
  if v_method not in ('meta', 'well_known', 'dns_txt', 'feed') then
    raise exception 'invalid_method' using errcode = '22023';
  end if;

  if p_event is not null then
    select f.* into v_src
      from public.event_imports ei
      join public.feed_sources f on f.id = ei.source_id
      join public.events e on e.id = ei.event_id and e.kind = 'imported'
     where ei.event_id = p_event
     order by ei.is_primary desc, ei.first_seen_at
     limit 1;
    if not found then
      raise exception 'not_imported' using errcode = '22023';
    end if;
  elsif p_source is not null then
    select * into v_src from public.feed_sources where id = p_source;
    if not found then
      raise exception 'not_found' using errcode = 'PT404';
    end if;
  end if;

  if v_method = 'feed' then
    -- Migration 66: a feed claim on a source proves control of that source's own ICS feed, never
    -- of a calendar the caller names; and the claim's host is always the feed's host.
    if v_src.id is not null then
      v_own := case when v_src.kind = 'ics' then public.source_url_check(v_src.url) end;
      if v_own is null or not coalesce((v_own ->> 'ok')::boolean, false) then
        raise exception 'feed_unavailable' using errcode = '22023';
      end if;
      if nullif(btrim(coalesce(p_feed_url, '')), '') is not null then
        v_chk := public.source_url_check(p_feed_url);
        if not coalesce((v_chk ->> 'ok')::boolean, false) or (v_chk ->> 'url') is distinct from (v_own ->> 'url') then
          raise exception 'feed_mismatch' using errcode = '22023';
        end if;
      end if;
      v_chk := v_own;
    else
      v_chk := public.source_url_check(p_feed_url);
      if not (v_chk ->> 'ok')::boolean then
        raise exception '%', v_chk ->> 'error' using errcode = '22023';
      end if;
    end if;
    v_feed := v_chk ->> 'url';
    if v_host <> '' and v_host <> (v_chk ->> 'host') then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    v_host := v_chk ->> 'host';
  elsif v_src.id is null then
    raise exception 'source_required' using errcode = '22023';
  end if;

  if v_host = '' or v_host !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+([a-z]{2,63}|xn--[a-z0-9-]{1,59})$' then
    raise exception 'invalid_host' using errcode = '22023';
  end if;
  if v_src.id is not null and v_method <> 'feed' then
    v_hosts := array_remove(array[public.source_url_host(v_src.url), public.source_url_host(v_src.homepage_url)], null);
    if not (v_host = any (v_hosts)
            or v_host = any (array(select public.registrable_domain(h) from unnest(v_hosts) h))) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
    if public.collector_shared_host(v_host) then
      raise exception 'host_mismatch' using errcode = '22023';
    end if;
  end if;
  if public.collector_host_denied(v_host) is not null then
    raise exception 'host_denied' using errcode = '22023';
  end if;
  if v_src.id is not null and v_src.organizer_id is not null and v_src.organizer_id <> uid then
    raise exception 'already_claimed' using errcode = 'P0001';
  end if;

  -- One person at a time, so two quick taps cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtextextended('start_organizer_claim:' || uid::text, 0));
  select * into v_claim from public.organizer_claims c
   where c.user_id = uid and c.status = 'pending' and c.host = v_host and c.method = v_method
     and c.source_id is not distinct from v_src.id and c.feed_url is not distinct from v_feed
   order by c.created_at desc limit 1;
  if not found then
    if (select count(*) from public.organizer_claims c
         where c.user_id = uid and c.created_at > now() - interval '1 day') >= 5 then
      raise exception 'rate_limited' using errcode = 'P0001';
    end if;
    insert into public.organizer_claims (user_id, source_id, event_id, host, method, feed_url, token)
    values (uid, v_src.id, p_event, v_host, v_method, v_feed, public.organizer_token())
    returning * into v_claim;
  end if;
  return jsonb_build_object('claim_id', v_claim.id, 'status', v_claim.status, 'method', v_claim.method,
                            'host', v_claim.host, 'token', v_claim.token,
                            'proofs', public.organizer_claim_proofs(v_claim.host, v_claim.token));
end $$;

revoke all on function public.start_organizer_claim(p_source uuid, p_event uuid, p_host text, p_method text, p_feed_url text) from public, anon;
grant execute on function public.start_organizer_claim(p_source uuid, p_event uuid, p_host text, p_method text, p_feed_url text) to authenticated, service_role;

-- submit_attendance: from 20261115000100_attendance.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.submit_attendance(p_event_id uuid, p_attended boolean, p_met uuid[] default '{}')
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  e     public.events%rowtype;
  r     public.rsvps%rowtype;
  v_met uuid[];
  n     integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_attended is null then
    raise exception 'attended_required' using errcode = 'check_violation';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  if not found or r.status <> 'going' then
    raise exception 'not_going' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.ends_at then
    raise exception 'event_not_over' using errcode = 'check_violation';
  end if;
  if now() > e.ends_at + interval '7 days' then
    raise exception 'attendance_window_closed' using errcode = 'check_violation',
      hint = 'Attendance can be reported for 7 days after the event ends.';
  end if;

  select coalesce(array_agg(distinct m), '{}') into v_met
    from unnest(coalesce(p_met, '{}'::uuid[])) as m
   where m is not null;
  if cardinality(v_met) > 30 then
    raise exception 'too_many_met' using errcode = 'check_violation', hint = 'Up to 30 people.';
  end if;
  if cardinality(v_met) > 0 and not p_attended then
    raise exception 'met_requires_attended' using errcode = 'check_violation';
  end if;
  if uid = any (v_met) then
    raise exception 'met_self' using errcode = 'check_violation';
  end if;
  if exists (
    select 1 from unnest(v_met) as m
     where not exists (select 1 from public.rsvps x
                        where x.event_id = p_event_id and x.user_id = m and x.status = 'going')
  ) then
    raise exception 'met_not_going' using errcode = 'check_violation';
  end if;

  insert into public.event_attendance_reports (event_id, user_id, attended, answered_at)
  values (p_event_id, uid, p_attended, now())
  on conflict (event_id, user_id) do update
     set attended = excluded.attended, answered_at = excluded.answered_at;

  delete from public.event_meets where event_id = p_event_id and user_id = uid;
  insert into public.event_meets (event_id, user_id, met_user_id)
  select p_event_id, uid, m from unnest(v_met) as m;
  get diagnostics n = row_count;

  -- Self-reports never overwrite a check-in.
  if p_attended and r.checked_in_at is null and r.attended_self_reported_at is null then
    update public.rsvps set attended_self_reported_at = now()
     where event_id = p_event_id and user_id = uid;
  elsif not p_attended and r.attended_self_reported_at is not null then
    update public.rsvps set attended_self_reported_at = null
     where event_id = p_event_id and user_id = uid;
  end if;

  update public.notifications
     set read_at = now(), seen_at = coalesce(seen_at, now())
   where user_id = uid and event_id = p_event_id and kind = 'checkin_prompt' and read_at is null;

  return jsonb_build_object(
    'event_id', p_event_id,
    'attended', p_attended,
    'met_count', n,
    'checked_in', r.checked_in_at is not null);
end $$;

revoke all on function public.submit_attendance(p_event_id uuid, p_attended boolean, p_met uuid[]) from public, anon;
grant execute on function public.submit_attendance(p_event_id uuid, p_attended boolean, p_met uuid[]) to authenticated, service_role;

-- submit_chapter_claim: from 20261113000100_chapter_tools.sql; 6 not-found raise(s) now PT404 (Migration 70).
create or replace function public.submit_chapter_claim(p_args jsonb)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  a         jsonb := coalesce(p_args, '{}'::jsonb);
  c         public.chapter_claims%rowtype;
  p         public.profiles%rowtype;
  v_hub     public.hubs%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_age     integer;
  v_c       text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = uid;
  if p.status is distinct from 'active' or p.onboarding_completed_at is null or p.deleted_at is not null then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_age := public.viewer_age();
  if v_age is null or v_age < 18 then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  c.user_id           := uid;
  c.hub_id            := (a ->> 'hub_id')::uuid;
  c.chapter_id        := (a ->> 'chapter_id')::uuid;
  c.org_id            := (a ->> 'org_id')::uuid;
  c.campus_id         := (a ->> 'campus_id')::uuid;
  c.area_id           := (a ->> 'area_id')::uuid;
  c.kind              := coalesce(nullif(btrim(coalesce(a ->> 'kind', '')), ''),
                                  case when c.area_id is not null then 'area' else 'org' end);
  c.proposed_name     := nullif(btrim(coalesce(a ->> 'proposed_name', '')), '');
  c.rso_name          := nullif(btrim(coalesce(a ->> 'rso_name', '')), '');
  c.pin_url           := nullif(btrim(coalesce(a ->> 'pin_url', '')), '');
  c.officer_role_text := nullif(btrim(coalesce(a ->> 'officer_role_text', '')), '');
  c.reference_name    := nullif(btrim(coalesce(a ->> 'reference_name', '')), '');
  c.reference_contact := nullif(btrim(coalesce(a ->> 'reference_contact', '')), '');
  c.motivation        := btrim(coalesce(a ->> 'motivation', ''));
  c.agreement_version := nullif(btrim(coalesce(a ->> 'agreement_version', '')), '');

  if c.kind not in ('org', 'area') then
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if c.agreement_version is null then
    raise exception 'agreement_required' using errcode = 'check_violation',
      hint = 'Accept the Captain Program agreement.';
  end if;
  if c.pin_url is not null and c.pin_url !~ '^https://' then
    raise exception 'pin_url_invalid' using errcode = 'check_violation', hint = 'Use an https:// link.';
  end if;

  select * into v_hub from public.hubs where id = c.hub_id;
  if not found then
    raise exception 'hub_not_found' using errcode = 'PT404';
  end if;
  if not v_hub.is_active then
    raise exception 'hub_inactive' using errcode = 'check_violation';
  end if;
  if v_age < v_hub.min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  -- An existing chapter fixes the place; otherwise look it up by place.
  if c.chapter_id is not null then
    select * into v_chapter from public.hub_chapters where id = c.chapter_id;
    if not found or not v_chapter.is_active then
      raise exception 'chapter_not_found' using errcode = 'PT404';
    end if;
    if v_chapter.hub_id <> c.hub_id then
      raise exception 'chapter_mismatch' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.chapter_members where chapter_id = c.chapter_id and role = 'organizer') then
      raise exception 'chapter_has_organizer' using errcode = 'check_violation',
        hint = 'This chapter already has an organizer.';
    end if;
    c.kind      := case when v_chapter.org_id is not null then 'org' else 'area' end;
    c.org_id    := v_chapter.org_id;
    c.campus_id := v_chapter.campus_id;
    c.area_id   := v_chapter.area_id;
  end if;

  if c.kind = 'org' then
    c.area_id := null;
    if c.org_id is null then
      raise exception 'org_required' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.organizations where id = c.org_id) then
      raise exception 'org_not_found' using errcode = 'PT404';
    end if;
    if c.campus_id is not null and not exists (
         select 1 from public.org_campuses where id = c.campus_id and org_id = c.org_id) then
      raise exception 'campus_not_found' using errcode = 'PT404';
    end if;
    if not exists (
         select 1 from public.org_memberships m
          where m.user_id = uid and m.org_id = c.org_id
            and (m.expires_at is null or m.expires_at > now())
            and (c.campus_id is null or m.campus_id is null or m.campus_id = c.campus_id)) then
      raise exception 'membership_required' using errcode = '42501',
        hint = 'Verify your email with this organization first.';
    end if;
  else
    c.org_id    := null;
    c.campus_id := null;
    if c.area_id is null then
      raise exception 'area_required' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.areas where id = c.area_id) then
      raise exception 'area_not_found' using errcode = 'PT404';
    end if;
  end if;

  if c.chapter_id is null then
    select * into v_chapter from public.hub_chapters ch
     where ch.hub_id = c.hub_id
       and ch.org_id is not distinct from c.org_id
       and ch.campus_id is not distinct from c.campus_id
       and ch.area_id is not distinct from c.area_id;
    if found then
      if not v_chapter.is_active then
        raise exception 'chapter_not_found' using errcode = 'PT404';
      end if;
      c.chapter_id := v_chapter.id;
    end if;
  end if;
  if c.chapter_id is not null and exists (
       select 1 from public.chapter_members where chapter_id = c.chapter_id and role = 'organizer') then
    raise exception 'chapter_has_organizer' using errcode = 'check_violation',
      hint = 'This chapter already has an organizer.';
  end if;
  c.proposed_name := coalesce(c.proposed_name, v_chapter.name);
  if c.proposed_name is null then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;

  -- Serialize per user so two concurrent submits cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtext('chapter_claims:' || uid::text));
  if (select count(*) from public.chapter_claims where user_id = uid and status = 'pending') >= 3 then
    raise exception 'too_many_claims' using errcode = 'check_violation', hint = 'Up to three open claims.';
  end if;
  if exists (select 1 from public.chapter_claims
              where user_id = uid and status = 'pending' and hub_id = c.hub_id
                and org_id is not distinct from c.org_id and campus_id is not distinct from c.campus_id
                and area_id is not distinct from c.area_id) then
    raise exception 'claim_pending' using errcode = 'unique_violation',
      hint = 'You already have an open claim for this chapter.';
  end if;

  insert into public.chapter_claims (user_id, hub_id, chapter_id, kind, org_id, campus_id, area_id, proposed_name,
                                     rso_name, pin_url, officer_role_text, reference_name, reference_contact,
                                     motivation, agreement_version)
  values (c.user_id, c.hub_id, c.chapter_id, c.kind, c.org_id, c.campus_id, c.area_id, c.proposed_name,
          c.rso_name, c.pin_url, c.officer_role_text, c.reference_name, c.reference_contact,
          c.motivation, c.agreement_version)
  returning * into c;
  return c;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

revoke all on function public.submit_chapter_claim(p_args jsonb) from public, anon;
grant execute on function public.submit_chapter_claim(p_args jsonb) to authenticated, service_role;

-- suggest_place_edit: from 20261130000100_places_review_fixes.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.suggest_place_edit(p_place uuid, p_changes jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  p       public.places%rowtype;
  v_mod   boolean;
  v_clean jsonb;
  v_note  text := left(btrim(coalesce(p_note, '')), 500);
  v_own   boolean;
  v_id    uuid;
  v_st    text;
  v_why   text;
  v_c     text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place is null or not public.place_caller_can_see(p_place) then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  select * into p from public.places where id = p_place for update;
  if p.status in ('hidden', 'removed') or p.merged_into is not null then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;
  if p.source = 'venue' then
    raise exception 'meeting_spot' using errcode = 'check_violation',
      hint = 'Meeting spots follow their plans'' venue. Report it if something is wrong.';
  end if;
  v_mod := public.is_moderator();
  v_clean := public.place_clean_changes(p_changes);
  if v_clean = '{}'::jsonb then
    raise exception 'no_changes' using errcode = 'check_violation';
  end if;

  -- Rule 9: thirty edits a day (every kind of edit counts).
  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('place_edits:' || uid::text));
    -- Migration 36: counted in place_rate_log (edits of a deleted place still count).
    if (select count(*) from public.place_rate_log l
         where l.user_id = uid and l.kind = 'edit' and l.created_at > now() - interval '1 day') >= 30 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to thirty edits a day.';
    end if;
  end if;

  v_own := p.source = 'user' and p.created_by = uid and (not p.is_public or p.status = 'pending');

  -- Rule 2 for a move of a public member place: refuse it here with a clear
  -- reason (places_guard refuses it again on apply).
  if v_clean ? 'location' and p.source = 'user' and p.is_public and p.created_by is not null then
    v_why := public.place_near_private(p.created_by,
               extensions.ST_SetSRID(extensions.ST_MakePoint((v_clean #>> '{location,lng}')::double precision,
                                                             (v_clean #>> '{location,lat}')::double precision),
                                     4326)::extensions.geography);
    if v_why is not null and (p.created_by = uid or v_mod) then
      perform public.place_raise_near(v_why);
    end if;
  end if;

  if v_own or v_mod then
    perform public.place_apply_changes(p.id, v_clean,
                                       case when v_mod then 'moderator' else 'member' end,
                                       v_mod and p.source in ('osm', 'geoapify'));
    v_st := case when v_own and not v_mod then 'applied' else 'approved' end;
    update public.place_edits set status = 'superseded'
     where place_id = p.id and proposed_by = uid and status = 'pending';
    insert into public.place_edits (place_id, proposed_by, changes, note, status, reviewed_by, reviewed_at)
    values (p.id, uid, v_clean, v_note, v_st, case when v_mod then uid end, now())
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'status', v_st, 'applied', true);
  end if;

  update public.place_edits set status = 'superseded'
   where place_id = p.id and proposed_by = uid and status = 'pending';
  insert into public.place_edits (place_id, proposed_by, changes, note)
  values (p.id, uid, v_clean, v_note)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'applied', false);
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

revoke all on function public.suggest_place_edit(p_place uuid, p_changes jsonb, p_note text) from public, anon;
grant execute on function public.suggest_place_edit(p_place uuid, p_changes jsonb, p_note text) to authenticated, service_role;

-- update_event: from 20261117000100_security_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.update_event(p_event_id uuid, p_args jsonb)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  a         jsonb := coalesce(p_args, '{}'::jsonb);
  e         public.events%rowtype;
  l         public.event_addresses%rowtype;
  v_key     text;
  v_allowed text[] := array['title', 'description', 'cover_url', 'starts_at', 'ends_at', 'timezone', 'min_age',
                            'capacity', 'waitlist_enabled', 'min_headcount', 'members_only', 'is_free', 'price_text',
                            'visibility', 'campus_id', 'address_visibility', 'venue_id', 'location_text',
                            'address_note', 'location_hint', 'external_url'];
  v_address text[] := array['address_visibility', 'venue_id', 'location_text', 'address_note'];
  v_going   integer;
  v_campus  uuid;
  v_hint    text;
  v_narrow  boolean := false;
  v_c       text;
  v_old     public.events%rowtype;
  v_venue   uuid;
  v_text    text;
  v_time    boolean;
  v_place   boolean;
  v_words   boolean;
  v_hour    text := to_char(date_trunc('hour', now() at time zone 'UTC'), 'YYYYMMDDHH24');
  v_changed jsonb;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  for v_key in select jsonb_object_keys(a) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'immutable_field' using errcode = 'check_violation',
        hint = v_key || ' cannot be changed after creation.';
    end if;
  end loop;

  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
  if e.kind = 'imported' then
    raise exception 'kind_not_allowed' using errcode = 'check_violation';
  end if;
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Lowering the age limit widens who sees the event: the host or a moderator only.
  if a ? 'min_age' and (a ->> 'min_age')::smallint < e.min_age
     and not (coalesce(e.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can lower the age limit.';
  end if;
  if a ?| v_address and not (coalesce(e.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can change the address.';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if e.ends_at < now() then
    raise exception 'event_over' using errcode = 'check_violation';
  end if;
  select * into l from public.event_addresses where event_id = e.id;
  v_old   := e;
  v_venue := l.venue_id;
  v_text  := l.location_text;

  if a ? 'title'              then e.title              := btrim(coalesce(a ->> 'title', '')); end if;
  if a ? 'description'        then e.description        := btrim(coalesce(a ->> 'description', '')); end if;
  if a ? 'cover_url'          then e.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), ''); end if;
  if a ? 'starts_at'          then e.starts_at          := (a ->> 'starts_at')::timestamptz; end if;
  if a ? 'ends_at'            then e.ends_at            := (a ->> 'ends_at')::timestamptz; end if;
  if a ? 'timezone'           then e.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), e.timezone); end if;
  if a ? 'min_age'            then e.min_age            := (a ->> 'min_age')::smallint; end if;
  if a ? 'capacity'           then e.capacity           := (a ->> 'capacity')::integer; end if;
  if a ? 'waitlist_enabled'   then e.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, e.waitlist_enabled); end if;
  if a ? 'min_headcount'      then e.min_headcount      := (a ->> 'min_headcount')::integer; end if;
  if a ? 'members_only'       then e.members_only       := coalesce((a ->> 'members_only')::boolean, e.members_only); end if;
  if a ? 'is_free'            then e.is_free            := coalesce((a ->> 'is_free')::boolean, e.is_free); end if;
  if a ? 'price_text'         then e.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), ''); end if;
  if a ? 'visibility'         then e.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, e.visibility); end if;
  if a ? 'campus_id'          then e.campus_id          := (a ->> 'campus_id')::uuid; end if;
  if a ? 'venue_id'           then l.venue_id           := (a ->> 'venue_id')::uuid; end if;
  if a ? 'address_visibility' then e.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, e.address_visibility);
  elsif a ? 'venue_id'        then e.address_visibility := public.default_address_visibility(l.venue_id); end if;
  if a ? 'location_text'      then l.location_text      := btrim(coalesce(a ->> 'location_text', '')); end if;
  if a ? 'address_note'       then l.address_note       := btrim(coalesce(a ->> 'address_note', '')); end if;
  if a ? 'external_url'       then e.external_url       := nullif(btrim(coalesce(a ->> 'external_url', '')), ''); end if;
  -- location_hint: the caller's value when sent (empty asks for the default);
  -- recomputed when any address field changes; otherwise kept as stored.
  v_hint := case
              when a ? 'location_hint' then a ->> 'location_hint'
              when a ?| array['venue_id', 'location_text', 'address_visibility', 'campus_id', 'visibility'] then null
              else e.location_hint
            end;

  if nullif(e.title, '') is null then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(e.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(e.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if e.starts_at is null or e.ends_at is null or e.ends_at <= e.starts_at then
    raise exception 'invalid_time_range' using errcode = 'check_violation';
  end if;
  if e.ends_at > e.starts_at + interval '3 days' then
    raise exception 'duration_too_long' using errcode = 'check_violation', hint = 'Events last up to three days.';
  end if;
  if a ? 'starts_at' and e.starts_at < now() - interval '1 hour' then
    raise exception 'starts_in_past' using errcode = 'check_violation', hint = 'Events start in the future.';
  end if;
  if not public.is_valid_timezone(e.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if e.capacity is not null and e.min_headcount is not null and e.min_headcount > e.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  if e.capacity is not null then
    select count(*) into v_going from public.rsvps where event_id = e.id and status = 'going';
    if v_going > e.capacity then
      raise exception 'capacity_below_going' using errcode = 'check_violation',
        hint = v_going || ' people are already going.';
    end if;
  end if;

  v_campus := public.event_rules_check(
    e.kind, e.hub_id, e.chapter_id, e.visibility, e.campus_id, e.min_age, l.venue_id, l.location_text, e.address_visibility);

  v_narrow := (a ? 'min_age' and e.min_age = 21)
           or (a ? 'visibility' and e.visibility = 'campus')
           or (a ? 'campus_id')
           or (a ? 'members_only' and e.members_only);

  update public.events
     set title              = e.title,
         description        = e.description,
         cover_url          = e.cover_url,
         starts_at          = e.starts_at,
         ends_at            = e.ends_at,
         timezone           = e.timezone,
         min_age            = e.min_age,
         capacity           = e.capacity,
         waitlist_enabled   = e.waitlist_enabled,
         min_headcount      = e.min_headcount,
         members_only       = e.members_only,
         is_free            = e.is_free,
         price_text         = e.price_text,
         visibility         = e.visibility,
         campus_id          = v_campus,
         address_visibility = e.address_visibility,
         external_url       = e.external_url,
         detached_at        = case when e.series_id is not null then coalesce(e.detached_at, now()) else e.detached_at end
   where id = e.id;

  perform public.event_set_location(e.id, l.venue_id, l.location_text, l.address_note,
                                    e.address_visibility, v_hint, v_campus);
  if v_narrow then
    perform public.event_drop_ineligible_rsvps(e.id);
  end if;
  perform public.rsvp_promote_waitlist(e.id);

  select * into e from public.events where id = e.id;

  -- Notifications (migration 22): one event_updated row per attendee per
  -- event per UTC hour. A later edit in the same hour writes no new row; it
  -- refreshes the payload of that hour's rows (latest title, time and place,
  -- every kind of change so far) without resurfacing them. An edit that
  -- changes the title or the place wording (location_hint, location_text)
  -- while someone else is going or waitlisted counts toward the broadcast
  -- cap (3 per event per rolling day, logged in event_broadcasts), so host-
  -- chosen text cannot be pushed to attendees more often than a broadcast.
  v_time  := e.starts_at is distinct from v_old.starts_at or e.ends_at is distinct from v_old.ends_at;
  v_place := e.location_hint is distinct from v_old.location_hint
             or l.venue_id is distinct from v_venue
             or l.location_text is distinct from v_text;
  v_words := e.title is distinct from v_old.title
             or e.location_hint is distinct from v_old.location_hint
             or l.location_text is distinct from v_text;
  if v_words and exists (select 1 from public.rsvps r
                          where r.event_id = e.id and r.status in ('going', 'waitlisted')
                            and r.user_id is distinct from uid) then
    if (select count(*) from public.event_broadcasts
         where event_id = e.id and created_at > now() - interval '1 day') >= 3 then
      raise exception 'broadcast_limit' using errcode = 'check_violation',
        hint = 'Up to 3 messages or title and place changes per event per day.';
    end if;
    insert into public.event_broadcasts (event_id, sender_id, body)
    values (e.id, uid, 'event_updated: ' || array_to_string(array_remove(array[
              case when e.title is distinct from v_old.title then 'title' end,
              case when e.location_hint is distinct from v_old.location_hint
                     or l.location_text is distinct from v_text then 'place' end], null), ', '));
  end if;
  if v_time or v_place then
    v_changed := to_jsonb(array_remove(array[case when v_time then 'time' end,
                                             case when v_place then 'place' end], null));
    perform public.notify_event_audience(
      e.id, 'event_updated', array['going', 'waitlisted']::public.rsvp_status[],
      e.id || ':' || v_hour,
      uid,
      jsonb_build_object('changed', v_changed));
    update public.notifications n
       set payload = n.payload || public.notification_event_payload(e.id)
                     || jsonb_build_object('changed', (
                          select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                            from jsonb_array_elements_text(coalesce(n.payload -> 'changed', '[]'::jsonb) || v_changed) x))
     where n.event_id = e.id and n.kind = 'event_updated'
       and n.dedupe_key like 'event_updated:' || e.id || ':' || v_hour || ':%';
  end if;
  return e;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

revoke all on function public.update_event(p_event_id uuid, p_args jsonb) from public, anon;
grant execute on function public.update_event(p_event_id uuid, p_args jsonb) to authenticated, service_role;

-- update_event_series: from 20261117000100_security_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.update_event_series(p_series_id uuid, p_args jsonb)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  s          public.event_series%rowtype;
  v_old      public.event_series%rowtype;
  v_key      text;
  v_allowed  text[] := array['title', 'description', 'cover_url', 'weekday', 'start_time', 'duration_minutes',
                             'timezone', 'starts_on', 'ends_on', 'max_occurrences', 'min_age', 'capacity',
                             'waitlist_enabled', 'min_headcount', 'members_only', 'is_free', 'price_text',
                             'visibility', 'campus_id', 'address_visibility', 'venue_id', 'location_text',
                             'address_note', 'location_hint'];
  v_schedule text[] := array['weekday', 'start_time', 'duration_minutes', 'timezone', 'starts_on', 'ends_on', 'max_occurrences'];
  v_address  text[] := array['address_visibility', 'venue_id', 'location_text', 'address_note'];
  v_campus   uuid;
  v_narrow   boolean;
  v_max      integer;
  v_occ      record;
  v_date     date;
  v_starts   timestamptz;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  for v_key in select jsonb_object_keys(a) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'immutable_field' using errcode = 'check_violation',
        hint = v_key || ' cannot be changed after creation.';
    end if;
  end loop;

  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'PT404';
  end if;
  v_old := s;
  if not public.viewer_can_manage(s.host_id, s.chapter_id, s.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Lowering the age limit widens who sees the event: the host or a moderator only.
  if a ? 'min_age' and (a ->> 'min_age')::smallint < s.min_age
     and not (coalesce(s.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can lower the age limit.';
  end if;
  if a ?| v_address and not (coalesce(s.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can change the address.';
  end if;
  if s.status = 'cancelled' then
    raise exception 'series_cancelled' using errcode = 'check_violation';
  end if;

  if a ? 'title'              then s.title              := btrim(coalesce(a ->> 'title', '')); end if;
  if a ? 'description'        then s.description        := btrim(coalesce(a ->> 'description', '')); end if;
  if a ? 'cover_url'          then s.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), ''); end if;
  if a ? 'weekday'            then s.weekday            := (a ->> 'weekday')::smallint; end if;
  if a ? 'start_time'         then s.start_time         := (a ->> 'start_time')::time; end if;
  if a ? 'duration_minutes'   then s.duration_minutes   := (a ->> 'duration_minutes')::integer; end if;
  if a ? 'timezone'           then s.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), s.timezone); end if;
  if a ? 'starts_on'          then s.starts_on          := coalesce((a ->> 'starts_on')::date, s.starts_on); end if;
  if a ? 'ends_on'            then s.ends_on            := (a ->> 'ends_on')::date; end if;
  if a ? 'max_occurrences'    then s.max_occurrences    := (a ->> 'max_occurrences')::integer; end if;
  if a ? 'min_age'            then s.min_age            := (a ->> 'min_age')::smallint; end if;
  if a ? 'capacity'           then s.capacity           := (a ->> 'capacity')::integer; end if;
  if a ? 'waitlist_enabled'   then s.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, s.waitlist_enabled); end if;
  if a ? 'min_headcount'      then s.min_headcount      := (a ->> 'min_headcount')::integer; end if;
  if a ? 'members_only'       then s.members_only       := coalesce((a ->> 'members_only')::boolean, s.members_only); end if;
  if a ? 'is_free'            then s.is_free            := coalesce((a ->> 'is_free')::boolean, s.is_free); end if;
  if a ? 'price_text'         then s.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), ''); end if;
  if a ? 'visibility'         then s.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, s.visibility); end if;
  if a ? 'campus_id'          then s.campus_id          := (a ->> 'campus_id')::uuid; end if;
  if a ? 'venue_id'           then s.venue_id           := (a ->> 'venue_id')::uuid; end if;
  if a ? 'address_visibility' then s.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, s.address_visibility);
  elsif a ? 'venue_id'        then s.address_visibility := public.default_address_visibility(s.venue_id); end if;
  if a ? 'location_text'      then s.location_text      := btrim(coalesce(a ->> 'location_text', '')); end if;
  if a ? 'address_note'       then s.address_note       := btrim(coalesce(a ->> 'address_note', '')); end if;
  if a ? 'location_hint'      then s.location_hint      := btrim(coalesce(a ->> 'location_hint', '')); end if;

  if s.title = '' then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(s.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(s.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if s.weekday is null or s.weekday not between 0 and 6 then
    raise exception 'weekday_invalid' using errcode = 'check_violation';
  end if;
  if s.start_time is null then
    raise exception 'start_time_required' using errcode = 'check_violation';
  end if;
  if s.duration_minutes is null or s.duration_minutes not between 15 and 1440 then
    raise exception 'duration_invalid' using errcode = 'check_violation';
  end if;
  if not public.is_valid_timezone(s.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if s.ends_on is not null and s.ends_on < s.starts_on then
    raise exception 'invalid_date_range' using errcode = 'check_violation';
  end if;
  if s.capacity is not null and s.min_headcount is not null and s.min_headcount > s.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  if a ? 'capacity' and s.capacity is not null then
    select max(going_count) into v_max from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;
    if coalesce(v_max, 0) > s.capacity then
      raise exception 'capacity_below_going' using errcode = 'check_violation',
        hint = v_max || ' people are already going to one occurrence.';
    end if;
  end if;

  v_campus := public.event_rules_check(
    s.kind, s.hub_id, s.chapter_id, s.visibility, s.campus_id, s.min_age, s.venue_id, s.location_text, s.address_visibility);

  update public.event_series
     set title = s.title, description = s.description, cover_url = s.cover_url, weekday = s.weekday,
         start_time = s.start_time, duration_minutes = s.duration_minutes, timezone = s.timezone,
         starts_on = s.starts_on, ends_on = s.ends_on, max_occurrences = s.max_occurrences,
         min_age = s.min_age, capacity = s.capacity, waitlist_enabled = s.waitlist_enabled,
         min_headcount = s.min_headcount, members_only = s.members_only, is_free = s.is_free,
         price_text = s.price_text, visibility = s.visibility, campus_id = v_campus,
         address_visibility = s.address_visibility, venue_id = s.venue_id,
         location_text = s.location_text, address_note = s.address_note, location_hint = s.location_hint
   where id = s.id
   returning * into s;

  -- Lock the future occurrences first so a set_rsvp that commits while we
  -- wait is seen by the statements below (they take fresh snapshots).
  perform 1 from public.events
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
   for update;

  if a ?| v_schedule then
    -- Nobody but the host has committed: regenerate from the template.
    delete from public.events e
     where e.series_id = s.id
       and e.status = 'published'
       and e.starts_at > now()
       and e.detached_at is null
       and not exists (
         select 1 from public.rsvps r
          where r.event_id = e.id
            and r.status <> 'cancelled'
            and r.user_id is distinct from e.host_id
       );
    -- Occurrences with attendees move to the new wall-clock slot in their
    -- week, or are cancelled when the new dates no longer cover them.
    for v_occ in
      select id, occurrence_date from public.events
       where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
       order by occurrence_date
    loop
      v_date   := v_occ.occurrence_date + (s.weekday - v_old.weekday);
      v_starts := (v_date + s.start_time) at time zone s.timezone;
      if v_starts <= now() or v_date < s.starts_on or (s.ends_on is not null and v_date > s.ends_on) then
        update public.events
           set status = 'cancelled', cancelled_at = now(), cancel_reason = 'The weekly schedule changed.'
         where id = v_occ.id;
      else
        update public.events
           set occurrence_date = v_date,
               starts_at       = v_starts,
               ends_at         = v_starts + make_interval(mins => s.duration_minutes),
               timezone        = s.timezone
         where id = v_occ.id;
      end if;
    end loop;
  end if;

  -- Template fields reach every remaining future occurrence.
  update public.events
     set title = s.title, description = s.description, cover_url = s.cover_url, min_age = s.min_age,
         capacity = s.capacity, waitlist_enabled = s.waitlist_enabled, min_headcount = s.min_headcount,
         members_only = s.members_only, is_free = s.is_free, price_text = s.price_text,
         visibility = s.visibility, campus_id = s.campus_id, address_visibility = s.address_visibility
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;

  v_narrow := (a ? 'min_age' and s.min_age = 21)
           or (a ? 'visibility' and s.visibility = 'campus')
           or (a ? 'campus_id')
           or (a ? 'members_only' and s.members_only);
  for v_occ in
    select id from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
  loop
    perform public.event_set_location(v_occ.id, s.venue_id, s.location_text, s.address_note,
                                      s.address_visibility, s.location_hint, s.campus_id);
    if v_narrow then
      perform public.event_drop_ineligible_rsvps(v_occ.id);
    end if;
    perform public.rsvp_promote_waitlist(v_occ.id);
  end loop;

  perform public.materialize_event_series(s.id, 8);
  return s;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

revoke all on function public.update_event_series(p_series_id uuid, p_args jsonb) from public, anon;
grant execute on function public.update_event_series(p_series_id uuid, p_args jsonb) to authenticated, service_role;

-- upsert_listing: from 20261224000100_coaching.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.upsert_listing(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid   uuid := (select auth.uid());
  cp    public.coach_profiles%rowtype;
  l     public.coach_listings%rowtype;
  v_new boolean;
  v_hub_age smallint;
  v_link text;
  v_note text;
begin
  perform private.coach_raise(private.coach_member_error(uid));
  select * into cp from public.coach_profiles where user_id = uid;
  if not found then
    raise exception 'coach_profile_required' using errcode = 'P0002';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if p ? 'id' and p ->> 'id' is not null then
    select * into l from public.coach_listings where id = (p ->> 'id')::uuid and coach_id = uid for update;
    if not found then
      raise exception 'not_found' using errcode = 'PT404';
    end if;
    v_new := false;
  else
    v_new := true;
    l.id := gen_random_uuid();
    l.coach_id := uid;
    l.description := '';
    l.capacity := 1;
    l.buffer_minutes := 0;
    l.min_notice_hours := 12;
    l.max_advance_days := 60;
    l.slot_step_minutes := 30;
    l.min_age := 18;
    l.status := 'active';
  end if;
  begin
    if p ? 'title' then l.title := btrim(p ->> 'title'); end if;
    if p ? 'description' then l.description := btrim(coalesce(p ->> 'description', '')); end if;
    if p ? 'delivery' then l.delivery := (p ->> 'delivery')::public.listing_delivery; end if;
    if p ? 'format' then l.format := (p ->> 'format')::public.listing_format; end if;
    if p ? 'capacity' then l.capacity := (p ->> 'capacity')::smallint; end if;
    if p ? 'duration_minutes' then l.duration_minutes := (p ->> 'duration_minutes')::smallint; end if;
    if p ? 'buffer_minutes' then l.buffer_minutes := (p ->> 'buffer_minutes')::smallint; end if;
    if p ? 'min_notice_hours' then l.min_notice_hours := (p ->> 'min_notice_hours')::smallint; end if;
    if p ? 'max_advance_days' then l.max_advance_days := (p ->> 'max_advance_days')::smallint; end if;
    if p ? 'slot_step_minutes' then l.slot_step_minutes := (p ->> 'slot_step_minutes')::smallint; end if;
    if p ? 'min_age' then l.min_age := (p ->> 'min_age')::smallint; end if;
    if p ? 'hub_id' then l.hub_id := (p ->> 'hub_id')::uuid; end if;
  exception when others then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end;
  if p ? 'price_minor' or p ? 'currency' then
    begin
      if p ? 'price_minor' then l.price_minor := (p ->> 'price_minor')::integer; end if;
      if p ? 'currency' then l.currency := lower(btrim(p ->> 'currency')); end if;
    exception when others then
      raise exception 'invalid_price' using errcode = 'check_violation';
    end;
  end if;
  if l.price_minor is null or l.price_minor not between 0 and 10000000
     or l.currency is null or l.currency !~ '^[a-z]{3}$' then
    raise exception 'invalid_price' using errcode = 'check_violation';
  end if;
  if l.title is null or char_length(l.title) not between 3 and 80 or char_length(l.description) > 2000
     or not private.coach_text_ok(l.title || ' ' || l.description) then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;
  if l.delivery is null or l.format is null or l.duration_minutes is null then
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end if;
  -- The launch shape (coach_listings_launch_shape) and the capacity rule, answered by name.
  if l.delivery = 'online' and l.format = 'group' then
    raise exception 'invalid_shape' using errcode = 'check_violation',
      hint = 'Online group sessions are not offered yet.';
  end if;
  if not p ? 'capacity' and l.format = 'one_on_one' then
    l.capacity := 1;
  end if;
  if (l.format = 'one_on_one' and l.capacity <> 1) or (l.format = 'group' and l.capacity not between 2 and 50) then
    raise exception 'invalid_shape' using errcode = 'check_violation';
  end if;
  if (l.delivery = 'in_person' and not cp.in_person) or (l.delivery = 'online' and not cp.online) then
    raise exception 'delivery_not_offered' using errcode = 'check_violation';
  end if;
  if l.hub_id is not null then
    if not private.coach_hub_allowed(l.hub_id) then
      raise exception 'hub_not_allowed' using errcode = 'check_violation';
    end if;
    select h.min_age into v_hub_age from public.hubs h where h.id = l.hub_id;
    if v_hub_age = 21 then
      l.min_age := 21;
    end if;
  end if;
  l.auto_confirm := case when p ? 'auto_confirm' then coalesce((p ->> 'auto_confirm')::boolean, false)
                         when v_new then l.format = 'group'
                         else l.auto_confirm end;
  v_note := case when p ? 'meeting_note' then btrim(coalesce(p ->> 'meeting_note', '')) end;
  v_link := case when p ? 'online_link' then nullif(btrim(coalesce(p ->> 'online_link', '')), '') end;
  if v_link is not null and v_link !~ '^https://[^\s]+$' then
    raise exception 'invalid_link' using errcode = 'check_violation';
  end if;
  if char_length(coalesce(v_note, '')) > 500 then
    raise exception 'invalid_text' using errcode = 'check_violation';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('coach_listings:' || uid::text));
  if l.status = 'active'
     and (select count(*) from public.coach_listings x where x.coach_id = uid and x.status = 'active' and x.id <> l.id) >= 20 then
    raise exception 'too_many' using errcode = 'check_violation', hint = 'Up to 20 active listings.';
  end if;
  begin
    if v_new then
      insert into public.coach_listings (id, coach_id, hub_id, title, description, delivery, format, capacity,
                                         duration_minutes, price_minor, currency, buffer_minutes, min_notice_hours,
                                         max_advance_days, slot_step_minutes, auto_confirm, min_age, status)
      values (l.id, uid, l.hub_id, l.title, l.description, l.delivery, l.format, l.capacity, l.duration_minutes,
              l.price_minor, l.currency, l.buffer_minutes, l.min_notice_hours, l.max_advance_days,
              l.slot_step_minutes, l.auto_confirm, l.min_age, l.status);
    else
      update public.coach_listings
         set hub_id = l.hub_id, title = l.title, description = l.description, delivery = l.delivery,
             format = l.format, capacity = l.capacity, duration_minutes = l.duration_minutes,
             price_minor = l.price_minor, currency = l.currency, buffer_minutes = l.buffer_minutes,
             min_notice_hours = l.min_notice_hours, max_advance_days = l.max_advance_days,
             slot_step_minutes = l.slot_step_minutes, auto_confirm = l.auto_confirm, min_age = l.min_age
       where id = l.id;
    end if;
  exception when check_violation then
    if sqlerrm like '%coach_listings_launch_shape%' or sqlerrm like '%coach_listings_capacity%' then
      raise exception 'invalid_shape' using errcode = 'check_violation';
    end if;
    raise exception 'invalid_listing' using errcode = 'check_violation';
  end;
  insert into public.coach_listing_private (listing_id, meeting_note, online_link)
  values (l.id, coalesce(v_note, ''), v_link)
  on conflict (listing_id) do update
     set meeting_note = case when p ? 'meeting_note' then excluded.meeting_note else public.coach_listing_private.meeting_note end,
         online_link  = case when p ? 'online_link' then excluded.online_link else public.coach_listing_private.online_link end;
  return jsonb_build_object('id', l.id, 'created', v_new, 'payable', private.coach_listing_payable(l.id));
end $$;

revoke all on function public.upsert_listing(p jsonb) from public, anon;
grant execute on function public.upsert_listing(p jsonb) to authenticated, service_role;

-- upsert_venue: from 20261121000100_viewer_timezone.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.upsert_venue(p_args jsonb)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v          public.venues%rowtype;
  v_mod      boolean;
  v_name     text := btrim(coalesce(a ->> 'name', ''));
  v_addr1    text := btrim(coalesce(a ->> 'address_line1', ''));
  v_addr2    text := btrim(coalesce(a ->> 'address_line2', ''));
  v_city     text := btrim(coalesce(a ->> 'city', ''));
  v_state    text := btrim(coalesce(a ->> 'state', ''));
  v_postal   text := btrim(coalesce(a ->> 'postal_code', ''));
  -- Migration 26: no country sent stays null (never assumed to be 'US').
  v_country  text := upper(nullif(btrim(coalesce(a ->> 'country', '')), ''));
  v_place_id text := nullif(btrim(coalesce(a ->> 'place_id', '')), '');
  v_campus   uuid := (a ->> 'campus_id')::uuid;
  v_public   boolean;
  v_lat      double precision := (a ->> 'lat')::double precision;
  v_lng      double precision := (a ->> 'lng')::double precision;
  v_point    extensions.geography;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_mod    := public.is_moderator();
  v_public := coalesce((a ->> 'is_public')::boolean, false);   -- D-038: private unless the caller says so
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'name_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
  end if;
  if v_country is not null and v_country !~ '^[A-Z]{2}$' then
    raise exception 'country_invalid' using errcode = 'check_violation', hint = 'Two-letter country code.';
  end if;
  if (v_lat is null) <> (v_lng is null)
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  if v_campus is not null and not exists (select 1 from public.org_campuses where id = v_campus) then
    raise exception 'campus_not_found' using errcode = 'PT404';
  end if;

  -- Serialize concurrent creates of the same place; hashtext is stable per key.
  perform pg_advisory_xact_lock(hashtext('venue:' || coalesce(v_place_id, lower(v_name) || '|' || v_postal)));

  if v_public then
    -- A place_id is client-supplied, so it never hands over someone else's
    -- row by itself (migration 22): the caller's own public row for the
    -- place, else another public row whose stored point is within 300 m of
    -- the coordinates the caller sent and whose name and address equal the
    -- ones sent (migration 23). Otherwise the caller gets a new row.
    if v_place_id is not null then
      select * into v from public.venues
       where place_id = v_place_id and is_public and created_by = uid
       order by created_at
       limit 1;
      if v.id is null and v_point is not null then
        select * into v from public.venues x
         where x.place_id = v_place_id and x.is_public and x.location is not null
           and extensions.ST_DWithin(x.location, v_point, 300)
           -- Migration 23: the row's content must match what the caller sent.
           and lower(x.name)          = lower(v_name)
           and lower(x.address_line1) = lower(v_addr1)
           and lower(x.address_line2) = lower(v_addr2)
           and lower(x.city)          = lower(v_city)
           and lower(x.state)         = lower(v_state)
           and x.postal_code          = v_postal
           and x.country is not distinct from v_country   -- migration 26: null only matches null
         order by extensions.ST_Distance(x.location, v_point), x.created_at
         limit 1;
      end if;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  else
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and not is_public and created_by = uid
       order by created_at limit 1;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and not is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  end if;

  if v.id is not null then
    -- Migration 23: the creator fills empty fields only while no other
    -- host's event uses the row, so a shared venue's text cannot change
    -- after someone else attached it.
    if v_mod or (v.created_by = uid
                 and not exists (select 1 from public.event_addresses ea
                                   join public.events e on e.id = ea.event_id
                                  where ea.venue_id = v.id and e.host_id is distinct from uid)) then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             country       = coalesce(country, v_country),   -- migration 26: an empty country is filled too
             location      = coalesce(location, v_point),
             campus_id     = coalesce(campus_id, v_campus),
             place_id      = case when place_id is null and v_place_id is not null
                                   and not exists (select 1 from public.venues x where x.place_id = v_place_id and x.is_public)
                                  then v_place_id else place_id end
       where id = v.id
       returning * into v;
    end if;
    return v;
  end if;

  if not v_mod then
    perform pg_advisory_xact_lock(hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, address_line2, city, state, postal_code, country,
                             location, place_id, campus_id, created_by, is_public)
  values (v_name, v_addr1, v_addr2, v_city, v_state, v_postal, v_country,
          v_point, v_place_id, v_campus, uid, v_public)
  returning * into v;
  return v;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

revoke all on function public.upsert_venue(p_args jsonb) from public, anon;
grant execute on function public.upsert_venue(p_args jsonb) to authenticated, service_role;

-- venue_for_place: from 20261127000100_meeting_spots.sql; 2 not-found raise(s) now PT404 (Migration 70).
create or replace function public.venue_for_place(p_place_id uuid)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   record;
  v   public.venues%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place_id is null then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;

  -- What places RLS shows a signed-in caller, limited to active public rows.
  select x.id, x.source, x.source_id, x.name, x.location, x.address_text, x.locality, x.country
    into p
    from public.places x
   where x.id = p_place_id and x.status = 'active' and x.is_public
     and (x.source in ('osm', 'geoapify') or coalesce(public.viewer_is_adult(), false));
  if not found then
    raise exception 'place_not_found' using errcode = 'PT404';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('venue_for_place:' || p.id::text));

  if p.source = 'venue' then
    select * into v from public.venues where id::text = p.source_id and is_public;
    if found then
      return v;
    end if;
  end if;
  select * into v from public.venues where place_ref = p.id and is_public order by created_at, id limit 1;
  if found then
    return v;
  end if;

  if not coalesce(public.is_moderator(), false) then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, city, country, location, created_by, is_public, place_ref)
  values (left(p.name, 120), left(p.address_text, 200), left(p.locality, 80), p.country, p.location,
          uid, true, p.id)
  returning * into v;
  return v;
end $$;

revoke all on function public.venue_for_place(p_place_id uuid) from public, anon;
grant execute on function public.venue_for_place(p_place_id uuid) to authenticated, service_role;

-- withdraw_chapter_claim: from 20261113000100_chapter_tools.sql; 1 not-found raise(s) now PT404 (Migration 70).
create or replace function public.withdraw_chapter_claim(p_claim_id uuid)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c   public.chapter_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.chapter_claims where id = p_claim_id and user_id = uid for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'PT404';
  end if;
  if c.status = 'withdrawn' then
    return c;
  end if;
  if c.status <> 'pending' then
    raise exception 'claim_not_pending' using errcode = 'check_violation';
  end if;
  update public.chapter_claims set status = 'withdrawn' where id = c.id returning * into c;
  return c;
end $$;

revoke all on function public.withdraw_chapter_claim(p_claim_id uuid) from public, anon;
grant execute on function public.withdraw_chapter_claim(p_claim_id uuid) to authenticated, service_role;

-- write_review: from 20261225000100_coaching_review_fixes.sql; 1 not-found raise(s) now PT404 (Migration 70).
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
    raise exception 'not_found' using errcode = 'PT404';
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

revoke all on function public.write_review(p_booking uuid, p_rating integer, p_body text) from public, anon;
grant execute on function public.write_review(p_booking uuid, p_rating integer, p_body text) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- source_candidates_rescore (new): stored discovery scores from the current code.
--   Candidates built while the Wikidata bonus was +25 (COLLECTOR_COMPLETION.md 2.9) keep that
--   score: source_candidates_add keeps the higher of the stored and the new score, so a later
--   build at +10 never lowers it. "discover rescore" (discovery.yml mode rescore) rebuilds each
--   region's candidates with the current code and sends the scores here, through
--   POST /collector/candidates/rescore. Only osm and wikidata candidates of that region that are
--   already stored change; nothing is added. p_dry_run counts without writing. Counts only.
-- ---------------------------------------------------------------------------
create or replace function public.source_candidates_rescore(p_region uuid, p_scores jsonb, p_dry_run boolean default false)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c         jsonb;
  v_chk     jsonb;
  v_score   integer;
  v_id      uuid;
  v_old     integer;
  v_lowered integer := 0;
  v_raised  integer := 0;
  v_same    integer := 0;
  v_missing integer := 0;
  v_bad     integer := 0;
begin
  if not public.is_service_role() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_scores is null or jsonb_typeof(p_scores) <> 'array' or jsonb_array_length(p_scores) > 500 then
    raise exception 'scores_invalid' using errcode = 'check_violation';
  end if;
  if p_region is null or not exists (select 1 from public.collector_regions r where r.id = p_region) then
    raise exception 'region_not_found' using errcode = 'PT404';
  end if;
  for c in select value from jsonb_array_elements(p_scores) loop
    if jsonb_typeof(c) <> 'object' or jsonb_typeof(c -> 'score') is distinct from 'number' then
      v_bad := v_bad + 1;
      continue;
    end if;
    v_chk := public.source_url_check(c ->> 'url');
    if not (v_chk ->> 'ok')::boolean then
      v_bad := v_bad + 1;
      continue;
    end if;
    -- The same clamp and rounding as source_candidates_add.
    v_score := least(100, greatest(0, round((c ->> 'score')::numeric)))::integer;
    select sc.id, sc.score into v_id, v_old
      from public.source_candidates sc
     where sc.host = v_chk ->> 'host' and sc.region_id = p_region and sc.origin in ('osm', 'wikidata')
       for update;
    if not found then
      v_missing := v_missing + 1;
      continue;
    end if;
    if v_old = v_score then
      v_same := v_same + 1;
      continue;
    end if;
    if v_score < v_old then v_lowered := v_lowered + 1; else v_raised := v_raised + 1; end if;
    if not coalesce(p_dry_run, false) then
      update public.source_candidates set score = v_score where id = v_id;
    end if;
  end loop;
  return jsonb_build_object('lowered', v_lowered, 'raised', v_raised, 'unchanged', v_same,
                            'missing', v_missing, 'invalid', v_bad, 'dry_run', coalesce(p_dry_run, false));
end $$;

comment on function public.source_candidates_rescore(uuid, jsonb, boolean) is
  'Service role (migration 70; POST /collector/candidates/rescore): sets the stored score of osm and wikidata candidates of one collector region to the score the current discovery code gives them [{url, score}] (at most 500). Never adds a candidate. p_dry_run counts without writing. Returns counts lowered, raised, unchanged, missing (no stored candidate of that region on the host) and invalid. Errors: forbidden, scores_invalid, region_not_found (PT404).';

revoke all on function public.source_candidates_rescore(uuid, jsonb, boolean) from public, anon, authenticated;
grant execute on function public.source_candidates_rescore(uuid, jsonb, boolean) to service_role;

insert into public.meta (key, value) values ('schema_version', '2.66')
  on conflict (key) do update set value = excluded.value, updated_at = now();
