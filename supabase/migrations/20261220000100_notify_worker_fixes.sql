-- ============================================================================
-- Activity Planet schema v2 — migration 56: notify worker review fixes
--   (PLAN.md 4.9 and 4.10; D-031, D-040). Builds on migration 55
--   (20261219000100_notify_worker.sql), which reached staging and is not
--   edited. Checks: supabase/tests/notify_worker_fixes.sql.
--
--   1. claim_pending_notifications, rebuilt from its migration 55 body with
--      two changes and nothing else:
--        * stale plans: every notice about a plan except event_cancelled is
--          skipped when the plan is missing, moderated or cancelled (before,
--          only reminders, check-in prompts, attendee_joined, broadcast and
--          event_updated were; hub_new_event, rsvp_confirmed, rsvp_approved,
--          waitlist_promoted and blocked_attendee could still carry a removed
--          title by email and push). The already-started check stays for
--          reminders only.
--        * blocks: one rule with enqueue_notification (migration 51). Only
--          attendee_joined and hub_new_event are dropped across a block or a
--          mute; every other notice, broadcast included (it can carry plan
--          logistics), is sent and never names the actor. Before, a broadcast
--          queued before a block was dropped while one queued after it went.
--   2. push_devices: members no longer insert or update rows directly
--      (revoke insert, update from authenticated; insert and update policies
--      dropped). register_push_device and unregister_push_device (security
--      definer) are the only writers, so one live row per endpoint, the key
--      checks and the 20-device trim always hold. Select and delete stay.
--   * meta.schema_version 2.52.
--
--   Account deletion: no new table or column; request_account_deletion still
--   deletes the caller's notifications and push_devices.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Claim
-- ---------------------------------------------------------------------------
create or replace function public.claim_pending_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_limit     integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_cap       integer;
  v_day       date := (now() at time zone 'UTC')::date;
  v_reserved  integer;
  n           public.notifications%rowtype;
  np          public.notification_prefs%rowtype;
  e           public.events%rowtype;
  v_email     boolean;
  v_push      boolean;
  v_email_st  public.notification_channel_status;
  v_push_st   public.notification_channel_status;
  v_push_aft  timestamptz;
  v_err       text;
  v_topic     boolean;
  v_social    boolean;
  v_blocked   boolean;
  v_actor     text;
  v_quiet     timestamptz;
  v_to        text;
  v_devices   jsonb;
  v_out       jsonb := '[]'::jsonb;
begin
  -- Expire what is too old to be useful (in-app keeps it).
  update public.notifications
     set email_status = case when email_status = 'pending' then 'skipped'::public.notification_channel_status else email_status end,
         push_status  = case when push_status  = 'pending' then 'skipped'::public.notification_channel_status else push_status end,
         last_error   = 'expired',
         claimed_at   = null
   where (email_status = 'pending' or push_status = 'pending')
     and created_at < now() - interval '2 days';

  v_cap := coalesce((select case when value ~ '^\d{1,5}$' then value::integer end
                       from public.meta where key = 'notify_email_daily_cap'), 90);
  insert into public.notification_email_days (day) values (v_day) on conflict (day) do nothing;
  select reserved into v_reserved from public.notification_email_days where day = v_day for update;

  for n in
    select * from public.notifications x
     where (x.email_status = 'pending'
            or (x.push_status = 'pending' and (x.push_after is null or x.push_after <= now())))
       and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
     order by x.created_at
     limit v_limit
     for update skip locked
  loop
    v_email_st := n.email_status;
    v_push_st  := n.push_status;
    v_push_aft := n.push_after;
    v_err := null;
    v_email := n.email_status = 'pending';
    v_push := n.push_status = 'pending' and (n.push_after is null or n.push_after <= now());

    -- Five tries per channel, then failed.
    if n.attempts >= 5 then
      if v_email then v_email_st := 'failed'; end if;
      if v_push then v_push_st := 'failed'; end if;
      v_email := false; v_push := false; v_err := 'too_many_attempts';
    end if;

    -- Seen in the app already: nothing to send.
    if (v_email or v_push) and n.read_at is not null then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'read_in_app';
    end if;

    -- The recipient, and their prefs as they are now.
    if (v_email or v_push) and not exists (
         select 1 from public.profiles p
          where p.id = n.user_id and p.status = 'active' and p.deleted_at is null) then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'inactive_recipient';
    end if;

    if v_email or v_push then
      select * into np from public.notification_prefs where user_id = n.user_id;
      v_topic := case
        when n.kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
        when n.kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
        when n.kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
        when n.kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
        else true
      end;
      if v_email and (np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic) then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      if v_push and (np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic) then
        v_push_st := 'skipped'; v_push := false; v_err := 'prefs';
      end if;
    end if;

    -- Never across a block (or to a muter, for the social notices).
    -- Migration 56: the same rule as enqueue_notification (migration 51). Only
    -- attendee_joined and hub_new_event are social; every other notice,
    -- broadcast included (it may carry plan logistics), still goes across a
    -- block or a mute but never names the actor.
    v_actor := null;
    if (v_email or v_push) and n.actor_id is not null and n.actor_id <> n.user_id then
      v_social := n.kind in ('attendee_joined', 'hub_new_event');
      v_blocked := public.users_blocked(n.user_id, n.actor_id);
      if v_social and (v_blocked or exists (select 1 from public.mutes m
                                             where m.muter_id = n.user_id and m.muted_id = n.actor_id)) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'blocked';
      elsif not v_blocked then
        select p.first_name into v_actor from public.profiles p
         where p.id = n.actor_id and p.status = 'active' and p.deleted_at is null and p.moderation_state is null;
      end if;
    end if;

    -- Stale plan notices. Migration 56: every notice about a plan (all but
    -- event_cancelled, which is the news itself) is skipped once the plan is
    -- gone, moderated or cancelled, so a removed title never goes out; the
    -- already-started check stays for reminders only.
    if (v_email or v_push) and n.event_id is not null and n.kind <> 'event_cancelled' then
      select * into e from public.events where id = n.event_id;
      if not found or e.moderation_state is not null
         or e.status = 'cancelled'
         or (n.kind in ('event_reminder_day', 'event_reminder_2h') and e.starts_at <= now()) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Quiet hours, as set now (push waits, never dropped).
    if v_push then
      v_quiet := public.notification_quiet_until(n.user_id);
      if v_quiet is not null then
        v_push_aft := v_quiet; v_push := false;
      end if;
    end if;

    -- Email: a confirmed address and room under the daily cap.
    v_to := null;
    if v_email then
      select u.email into v_to from auth.users u
       where u.id = n.user_id and u.email_confirmed_at is not null and u.email is not null and u.email <> '';
      if v_to is null then
        v_email_st := 'skipped'; v_email := false; v_err := 'no_confirmed_email';
      elsif v_reserved >= v_cap then
        v_email_st := 'skipped'; v_email := false; v_err := 'daily_cap';
      else
        v_reserved := v_reserved + 1;
      end if;
    end if;

    -- Push: live web devices on an allowed service.
    v_devices := null;
    if v_push then
      select coalesce(jsonb_agg(jsonb_build_object(
               'device_id', d.id,
               'endpoint', d.subscription ->> 'endpoint',
               'p256dh', d.subscription #>> '{keys,p256dh}',
               'auth', d.subscription #>> '{keys,auth}') order by d.last_seen_at desc), '[]'::jsonb)
        into v_devices
        from (select * from public.push_devices pd
               where pd.user_id = n.user_id and pd.revoked_at is null and pd.platform = 'web'
                 and public.push_endpoint_allowed(pd.subscription ->> 'endpoint')
                 and pd.subscription #>> '{keys,p256dh}' is not null
                 and pd.subscription #>> '{keys,auth}' is not null
               order by pd.last_seen_at desc limit 10) d;
      if jsonb_array_length(v_devices) = 0 then
        v_push_st := 'skipped'; v_push := false; v_devices := null;
        v_err := coalesce(v_err, 'no_device');
      end if;
    end if;

    update public.notifications
       set email_status = v_email_st,
           push_status  = v_push_st,
           push_after   = v_push_aft,
           claimed_at   = case when v_email or v_push then now() else null end,
           attempts     = attempts + case when v_email or v_push then 1 else 0 end,
           last_error   = coalesce(v_err, last_error)
     where id = n.id;

    if v_email or v_push then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', n.id,
        'kind', n.kind,
        'created_at', n.created_at,
        'event_id', n.event_id,
        'payload', n.payload - 'joiners',
        'actor_name', v_actor,
        'hub', (select jsonb_build_object('slug', h.slug, 'name', h.name) from public.hubs h where h.id = n.hub_id),
        'chapter', (select jsonb_build_object('slug', c.slug, 'name', c.name) from public.hub_chapters c where c.id = n.chapter_id),
        'email', case when v_email then jsonb_build_object(
                   'to', v_to, 'unsubscribe_token', public.notification_unsubscribe_token(n.user_id)) end,
        'push', case when v_push then v_devices end));
    end if;
  end loop;

  update public.notification_email_days set reserved = v_reserved where day = v_day;
  return v_out;
end $$;
comment on function public.claim_pending_notifications(integer) is
  'Migrations 55 and 56, service role (send-notifications): claims up to p_limit (max 100) due rows with for update skip locked, re-checks prefs, quiet hours, blocks and mutes, staleness, the confirmed address and the daily email cap, writes skipped or deferred channels, and returns what to send now as jsonb. Leased for 10 minutes; 5 attempts. Migration 56: a moderated, cancelled or missing plan stops every notice about it but event_cancelled; blocks and mutes stop only attendee_joined and hub_new_event (others go without the actor''s name), as at queueing.';

-- ---------------------------------------------------------------------------
-- 2. Push devices: written through the RPCs only
-- ---------------------------------------------------------------------------
drop policy if exists "push_devices_insert_own" on public.push_devices;
drop policy if exists "push_devices_update_own" on public.push_devices;
revoke insert, update on public.push_devices from public, anon, authenticated;
grant select, delete on public.push_devices to authenticated;
grant all on public.push_devices to service_role;

-- ---------------------------------------------------------------------------
-- 3. Privileges (explicit; unchanged from migration 55)
-- ---------------------------------------------------------------------------
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 4. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.52')
on conflict (key) do update set value = excluded.value;
