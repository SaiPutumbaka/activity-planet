-- ============================================================================
-- Activity Planet schema v2 — migration 77: launch audit, operations
--   (docs/ops/launch-audit-2026-11.md, findings H1, H2, H4, H7, H8, M7, M11,
--   L12, L13). Builds on migrations 1 to 76, which reached staging and are
--   not edited. Rebuilt functions start from their latest bodies (named
--   below); each change is marked "Migration 77". Checks:
--   supabase/tests/launch_audit_ops.sql.
--
--     1. notification_kind gains report_new, takedown_new, moderation_due
--        and ops_alert (their own statements, first).
--     2. One account-wide email budget (H1). email_send_days counts every
--        email the database lets out by UTC day and source (notify, staff,
--        verification, scorecard; no user id). meta.email_daily_cap_total
--        and meta.email_monthly_cap_total (defaults 80 and 2,600, below the
--        Resend free plan's 100 and 3,000 so Supabase Auth's own email keeps a
--        reserve) bound them; meta.email_staff_reserve (default 10) of the
--        day is kept for the moderation and operations alerts.
--        email_budget_take(source, n) is the service-role gate the
--        send-verification-code and weekly-scorecard functions call before
--        they send. Staging and production share one Resend account, so each
--        project gets its share once (only where unset): production
--        notify_email_daily_cap 50, total 70 a day and 2,200 a month, staff
--        reserve 10; staging 5, 15, 250 and 5.
--     3. enqueue_notification and claim_pending_notifications (migration 63
--        bodies): the four new kinds go to moderators only, by in-app notice,
--        push and email; their email skips notify_email_daily_cap but counts
--        against the account budget. Everything else also leaves the staff
--        reserve.
--     4. Moderators hear about new work at once (H2): triggers on reports,
--        takedown_requests and listing_removal_requests queue report_new or
--        takedown_new for every active moderator (one per child-safety report
--        and per takedown; the rest at most one an hour per moderator).
--        moderation_due_alerts() (pg_cron hourly at minute 11) sends
--        moderation_due when reports or takedowns are due within 4 hours or
--        overdue, chat photos wait for a moderator over 12 hours, account
--        deletions stay unfinished over an hour, or listing removals wait over
--        3 days; one notice per moderator for each new set of items (counts
--        only).
--     5. ops_health_alerts() (pg_cron daily at 13:17 UTC, M11 and H8): failed
--        pg_net calls and failed pg_cron runs in the last day, and no upcoming
--        published plan at all; an ops_alert per alert, moderator and day.
--     6. Evidence hold on self-deletion (H4): account_deletions gains
--        legal_hold_until; request_account_deletion sets it (and keeps the
--        ledger row a year) while a child-safety or NCII report or takedown
--        of the last year concerns the account. The delete-account function
--        then copies the account's photos into the private legal-hold bucket
--        before it deletes the originals (legal_holds rows, no foreign key,
--        kept a year; moderators may read the objects) and purges expired
--        copies.
--     7. Unfinished deletions are retried (M7): account_deletions gains
--        attempts, last_attempt_at and last_error; account_deletion_dispatch()
--        (pg_cron every 15 minutes) asks the delete-account function, with a
--        secret generated inside the database (vault account_deletion_secret),
--        to finish ledger rows older than 10 minutes and to purge expired
--        legal holds.
--     8. legal_acceptances (H7): which Terms and Privacy Policy version each
--        member accepted and when; accept_legal_terms(terms, privacy) writes
--        the caller's row; owner read. Deleted with the account.
--     9. request_account_deletion (latest body): the hold above; the
--        acceptance row goes; the note on the caller's hub requests is
--        cleared; stamps naming the caller on rows that stay are cleared
--        (user_roles and org_memberships granted_by, hubs and hub_chapters
--        created_by, hub_requests reviewed_by) (L13).
--    10. purge_handle_history() (pg_cron daily at 04:53 UTC, L12): released
--        handles older than 30 days go (the hold is 30 days).
--    11. meta.schema_version 2.73.
--
--   Account deletion: legal_acceptances is deleted with the account;
--   legal_holds is evidence created by the deletion itself and kept a year
--   (Privacy Policy retention table); email_send_days holds no user id.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enum values (their own statements, before anything uses them)
-- ---------------------------------------------------------------------------
alter type public.notification_kind add value if not exists 'report_new';
alter type public.notification_kind add value if not exists 'takedown_new';
alter type public.notification_kind add value if not exists 'moderation_due';
alter type public.notification_kind add value if not exists 'ops_alert';

-- ---------------------------------------------------------------------------
-- 2. The account-wide email budget
-- ---------------------------------------------------------------------------
create table if not exists public.email_send_days (
  day    date not null,
  source text not null,
  sent   integer not null default 0,
  primary key (day, source),
  constraint email_send_days_source check (source in ('notify', 'staff', 'verification', 'scorecard')),
  constraint email_send_days_sent check (sent >= 0)
);
comment on table public.email_send_days is
  'Migration 77: emails the database let out per UTC day and source (notify, staff, verification, scorecard), against meta.email_daily_cap_total and email_monthly_cap_total. No user id. Service role only.';
alter table public.email_send_days enable row level security;
revoke all on public.email_send_days from public, anon, authenticated;
grant all on public.email_send_days to service_role;

create or replace function private.email_meta_int(p_key text, p_default integer)
returns integer language sql stable security definer set search_path = '' as $$
  select coalesce((select case when m.value ~ '^[0-9]{1,7}$' then m.value::integer end
                     from public.meta m where m.key = p_key), p_default);
$$;
comment on function private.email_meta_int(text, integer) is
  'Migration 77, internal: an integer meta value (0 to 9,999,999), else p_default.';

create or replace function private.email_budget_room()
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(0, least(
           private.email_meta_int('email_daily_cap_total', 80)
             - coalesce((select sum(d.sent) from public.email_send_days d
                          where d.day = (now() at time zone 'UTC')::date), 0),
           private.email_meta_int('email_monthly_cap_total', 2600)
             - coalesce((select sum(d.sent) from public.email_send_days d
                          where d.day >= date_trunc('month', now() at time zone 'UTC')::date), 0)))::integer;
$$;
comment on function private.email_budget_room() is
  'Migration 77, internal: emails left today under meta.email_daily_cap_total (default 80) and this UTC month under meta.email_monthly_cap_total (default 2,600), whichever is smaller.';

create or replace function private.email_budget_add(p_source text, p_n integer)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(p_n, 0) <= 0 then
    return;
  end if;
  insert into public.email_send_days as d (day, source, sent)
  values ((now() at time zone 'UTC')::date, p_source, p_n)
  on conflict (day, source) do update set sent = d.sent + excluded.sent;
end $$;
comment on function private.email_budget_add(text, integer) is
  'Migration 77, internal: counts p_n emails of p_source today.';

create or replace function public.email_budget_take(p_source text, p_n integer default 1)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_n integer := greatest(1, least(coalesce(p_n, 1), 10));
begin
  if p_source is null or p_source not in ('verification', 'scorecard') then
    raise exception 'invalid_source' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('ap.email_budget'));
  if private.email_budget_room() < v_n then
    return false;
  end if;
  perform private.email_budget_add(p_source, v_n);
  return true;
end $$;
comment on function public.email_budget_take(text, integer) is
  'Migration 77, service role (send-verification-code, weekly-scorecard): takes p_n (1 to 10) emails of the account-wide budget for p_source (verification | scorecard). False, and nothing counted, when the day or month is used up; the caller then sends nothing.';

-- Each project's share of the one Resend account (only where unset). project_url is set on both
-- projects by migrate.yml; a fresh database (the rehearsal) keeps the defaults.
do $$
declare
  v_url  text := public.project_url();
  v_vals text[][];
  i      integer;
begin
  if v_url like '%gzrscndzzggxmcwnvvcq%' then
    v_vals := array[array['notify_email_daily_cap', '5'], array['email_daily_cap_total', '15'],
                    array['email_monthly_cap_total', '250'], array['email_staff_reserve', '5']];
  elsif v_url like '%gtesfiqxqontescqpllo%' then
    v_vals := array[array['notify_email_daily_cap', '50'], array['email_daily_cap_total', '70'],
                    array['email_monthly_cap_total', '2200'], array['email_staff_reserve', '10']];
  else
    return;
  end if;
  for i in 1 .. array_length(v_vals, 1) loop
    insert into public.meta (key, value) values (v_vals[i][1], v_vals[i][2]) on conflict (key) do nothing;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Rebuilt: enqueue_notification and claim_pending_notifications
-- ---------------------------------------------------------------------------

-- enqueue_notification (migration 63 body, 20261227000100_collector_health_geocode.sql)
create or replace function public.enqueue_notification(
  p_user_id    uuid,
  p_kind       public.notification_kind,
  p_dedupe_key text,
  p_event_id   uuid default null,
  p_hub_id     uuid default null,
  p_chapter_id uuid default null,
  p_actor_id   uuid default null,
  p_payload    jsonb default '{}'::jsonb,
  p_batch      boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  np           public.notification_prefs%rowtype;
  v_topic      boolean;
  v_email      public.notification_channel_status;
  v_push       public.notification_channel_status;
  v_push_after timestamptz;
  v_tz         text;
  v_now_local  timestamp;
  v_local      time;
  v_quiet      boolean;
  v_id         uuid;
  v_joiner     text;
begin
  if p_user_id is null or p_kind is null or nullif(btrim(coalesce(p_dedupe_key, '')), '') is null then
    return null;
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_user_id and status = 'active' and deleted_at is null) then
    return null;
  end if;
  -- Migration 63: collector alerts go to moderators only.
  -- Migration 77: so do the moderation and operations alerts.
  if p_kind::text in ('collector_alert', 'report_new', 'takedown_new', 'moderation_due', 'ops_alert') and not exists (
       select 1 from public.user_roles r where r.user_id = p_user_id and r.role in ('moderator', 'admin')) then
    return null;
  end if;
  -- Migration 51: across a block, social notices are dropped and every other
  -- notice loses its actor; a mute drops the social notices.
  if p_actor_id is not null and p_actor_id <> p_user_id then
    if public.users_blocked(p_user_id, p_actor_id) then
      -- Migration 58: message and message_request are social too.
      if p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request') then
        return null;
      end if;
      p_actor_id := null;
    elsif p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request')
          and exists (select 1 from public.mutes m where m.muter_id = p_user_id and m.muted_id = p_actor_id) then
      return null;
    end if;
  end if;

  select * into np from public.notification_prefs where user_id = p_user_id;
  -- Topic switches; confirmations of the person's own actions and claim
  -- reviews are transactional and follow only the channel switches.
  v_topic := case
    when p_kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
    when p_kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
    when p_kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
    when p_kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
    when p_kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
    -- Migration 60: booking reminders, review prompts and review notices follow bookings;
    -- confirmations, declines, cancellations and payment due are transactional.
    when p_kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
                       -- Migration 58: chat notices never go by email (the daily cap is for plans).
                       or p_kind in ('message', 'message_request')
                       -- Migration 60: of the booking kinds only requested, confirmed, cancelled and
                       -- payment due are emailed (logistics).
                       or p_kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action')
                       -- Migration 63: collector alerts are in-app only (moderators).
                       or p_kind = 'collector_alert'
                  then 'skipped' else 'pending' end;
  -- Migration 77: report_new, takedown_new, moderation_due and ops_alert are emailed and pushed
  -- (moderators only, above), following only the channel switches; their email does not count
  -- against meta.notify_email_daily_cap, only against the account-wide email budget.
  v_push  := case when np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic
                       or p_kind = 'collector_alert'   -- Migration 63
                  then 'skipped' else 'pending' end;

  if v_push = 'pending' and np.quiet_start is not null and np.quiet_end is not null
     and np.quiet_start <> np.quiet_end then
    v_tz := case when public.is_valid_timezone(np.timezone) then np.timezone else 'America/New_York' end;
    v_now_local := now() at time zone v_tz;
    v_local := v_now_local::time;
    v_quiet := case when np.quiet_start < np.quiet_end
                    then v_local >= np.quiet_start and v_local < np.quiet_end
                    else v_local >= np.quiet_start or v_local < np.quiet_end end;
    if v_quiet then
      v_push_after := ((v_now_local::date + np.quiet_end)
                       + case when np.quiet_end <= v_local then interval '1 day' else interval '0' end)
                      at time zone v_tz;
    end if;
  end if;

  if p_batch and p_kind = 'message' then
    -- Migration 58: a burst of messages is one row; count is the number of
    -- messages, seq the newest, actor the latest sender. Seen again on news.
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('count', 1),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'count', coalesce((n.payload ->> 'count')::integer, 1) + 1,
                        'seq', coalesce(p_payload -> 'seq', n.payload -> 'seq')),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
    returning n.id into v_id;
  elsif p_batch then
    -- joiners: md5(dedupe_key || ':' || actor) per distinct actor, so the set
    -- never stores a user id (account deletion needs no payload scrub).
    v_joiner := md5(p_dedupe_key || ':' || coalesce(p_actor_id::text, ''));
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb)
              || jsonb_build_object('count', 1, 'joiners', jsonb_build_array(v_joiner)),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'joiners', coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))
                                   || to_jsonb(v_joiner),
                        'count', jsonb_array_length(coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))) + 1),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
     where p_actor_id is not null
       and not (coalesce(n.payload -> 'joiners',
                         jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, '')))) ? v_joiner)
    returning n.id into v_id;
  else
    insert into public.notifications
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id, coalesce(p_payload, '{}'::jsonb),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
  end if;
  return v_id;
end $$;


-- claim_pending_notifications (migration 63 body, same file)
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
  v_conv      uuid;   -- Migration 58
  v_bk        uuid;   -- Migration 60
  v_room      integer;            -- Migration 77: the account-wide email budget left
  v_keep      integer;            -- Migration 77: kept back for moderation and operations alerts
  v_staff     boolean;
  v_notify_n  integer := 0;
  v_staff_n   integer := 0;
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
  -- Migration 77: one account-wide budget (meta email_daily_cap_total, email_monthly_cap_total)
  -- shared with verification codes and the scorecard, below Resend's free plan so Auth email keeps
  -- a reserve; meta.email_staff_reserve of it is kept for the moderation and operations alerts.
  perform pg_advisory_xact_lock(hashtext('ap.email_budget'));
  v_room := private.email_budget_room();
  v_keep := private.email_meta_int('email_staff_reserve', 10);

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

    -- Migration 63: collector alerts are in-app only; never email or push, whatever the row says.
    if (v_email or v_push) and n.kind = 'collector_alert' then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'in_app_only';
    end if;

    -- Migration 77: moderation and operations alerts reach moderators only.
    v_staff := n.kind::text in ('report_new', 'takedown_new', 'moderation_due', 'ops_alert');
    if (v_email or v_push) and v_staff and not exists (
         select 1 from public.user_roles r where r.user_id = n.user_id and r.role in ('moderator', 'admin')) then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'not_moderator';
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
        when n.kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
        when n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)   -- Migration 60
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
      v_social := n.kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request');   -- Migration 58
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

    -- Migration 58: chat notices. Never email; nothing once the conversation
    -- is gone, closed or muted now, or the member has read up to its seq.
    if (v_email or v_push) and n.kind in ('message', 'message_request') then
      if v_email then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      v_conv := case when n.payload ->> 'conversation_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                     then (n.payload ->> 'conversation_id')::uuid end;
      if v_push and (
           not exists (select 1 from public.conversations c where c.id = v_conv and c.closed_at is null)
           or exists (select 1 from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id = n.user_id
                         and (cm.muted_until > now() or cm.removed_at is not null or cm.left_at is not null
                              or (n.kind = 'message' and n.payload ->> 'seq' ~ '^\d{1,18}$'
                                  and cm.last_read_seq >= (n.payload ->> 'seq')::bigint)))) then
        v_push_st := 'skipped'; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Migration 60: booking notices. Email only for requested, confirmed, cancelled and payment
    -- due; reminders, payment due and review prompts are skipped once the booking moved on.
    if v_email and n.kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action') then
      v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
    end if;
    if (v_email or v_push) and n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_payment_due',
                                          'booking_review_prompt') then
      v_bk := case when n.payload ->> 'booking_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then (n.payload ->> 'booking_id')::uuid end;
      if not exists (
           select 1 from public.bookings b
            where b.id = v_bk
              and ((n.kind in ('booking_reminder_day', 'booking_reminder_2h') and b.status = 'confirmed' and b.starts_at > now())
                   or (n.kind = 'booking_payment_due'
                       and (n.payload ? 'fallback' or (b.status = 'confirmed' and b.payment_state in ('due', 'processing'))))
                   or (n.kind = 'booking_review_prompt' and b.status = 'completed'
                       and not exists (select 1 from public.coach_reviews r where r.booking_id = b.id)))) then
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
      -- Migration 77: alerts need only the account-wide budget; everything else also needs its
      -- daily cap and leaves the alerts' reserve.
      elsif v_staff and v_room > 0 then
        v_room := v_room - 1; v_staff_n := v_staff_n + 1;
      elsif v_staff then
        v_email_st := 'skipped'; v_email := false; v_err := 'email_budget';
      elsif v_reserved >= v_cap then
        v_email_st := 'skipped'; v_email := false; v_err := 'daily_cap';
      elsif v_room <= v_keep then
        v_email_st := 'skipped'; v_email := false; v_err := 'email_budget';
      else
        v_reserved := v_reserved + 1;
        v_room := v_room - 1; v_notify_n := v_notify_n + 1;
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
  perform private.email_budget_add('notify', v_notify_n);   -- Migration 77
  perform private.email_budget_add('staff', v_staff_n);
  return v_out;
end $$;


-- ---------------------------------------------------------------------------
-- 4. Moderators hear about new work at once
-- ---------------------------------------------------------------------------
create or replace function private.notify_moderators(p_kind text, p_key text, p_payload jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_mod uuid;
  v_n   integer := 0;
begin
  for v_mod in select distinct r.user_id from public.user_roles r
                 join public.profiles p on p.id = r.user_id and p.status = 'active' and p.deleted_at is null
                where r.role in ('moderator', 'admin') loop
    if public.enqueue_notification(v_mod, p_kind::public.notification_kind, p_key || ':' || v_mod::text,
                                   null, null, null, null, coalesce(p_payload, '{}'::jsonb)) is not null then
      v_n := v_n + 1;
    end if;
  end loop;
  return v_n;
end $$;
comment on function private.notify_moderators(text, text, jsonb) is
  'Migration 77, internal: queues a p_kind notice (report_new, takedown_new, moderation_due, ops_alert) for every active moderator and admin with dedupe key p_key:<moderator>. Returns the notices added.';

create or replace function private.reports_alert_moderators()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.status = 'open' then
    -- A child-safety report (4 hours) is its own notice; the rest at most one an hour.
    perform private.notify_moderators('report_new',
      case when new.priority = 0 then 'report_new:' || new.id::text
           else 'report_new:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24') end,
      jsonb_build_object('queue', 'reports', 'priority', new.priority, 'reason', new.reason, 'due_at', new.due_at));
  end if;
  return null;
exception when others then
  -- An alert never stops a report from being filed.
  raise warning 'reports_alert_moderators: %', sqlstate;
  return null;
end $$;
drop trigger if exists reports_alert_moderators on public.reports;
create trigger reports_alert_moderators after insert on public.reports
  for each row execute function private.reports_alert_moderators();

create or replace function private.takedowns_alert_moderators()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'takedown_requests' then
    perform private.notify_moderators('takedown_new', 'takedown_new:' || new.id::text,
      jsonb_build_object('queue', 'ncii', 'minor', new.involves_minor, 'due_at', new.due_at));
  else
    perform private.notify_moderators('takedown_new',
      'listing_removal_new:' || to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24'),
      jsonb_build_object('queue', 'listing_removal'));
  end if;
  return null;
exception when others then
  raise warning 'takedowns_alert_moderators: %', sqlstate;
  return null;
end $$;
drop trigger if exists takedown_requests_alert_moderators on public.takedown_requests;
create trigger takedown_requests_alert_moderators after insert on public.takedown_requests
  for each row execute function private.takedowns_alert_moderators();
drop trigger if exists listing_removal_requests_alert_moderators on public.listing_removal_requests;
create trigger listing_removal_requests_alert_moderators after insert on public.listing_removal_requests
  for each row execute function private.takedowns_alert_moderators();

create or replace function public.moderation_due_alerts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_soon      timestamptz := now() + interval '4 hours';
  v_r_due     integer;
  v_r_over    integer;
  v_t_due     integer;
  v_t_over    integer;
  v_images    integer;
  v_deletions integer;
  v_removals  integer;
  v_set       text;
begin
  select count(*) filter (where r.due_at > now()), count(*) filter (where r.due_at <= now())
    into v_r_due, v_r_over
    from public.reports r where r.status = 'open' and r.due_at <= v_soon;
  select count(*) filter (where t.due_at > now()), count(*) filter (where t.due_at <= now())
    into v_t_due, v_t_over
    from public.takedown_requests t where t.status in ('open', 'waiting') and t.due_at <= v_soon;
  select count(*) into v_images from public.messages m
   where m.kind = 'image' and m.image_state = 'queued' and m.deleted_at is null
     and m.created_at < now() - interval '12 hours';
  select count(*) into v_deletions from public.account_deletions d
   where d.completed_at is null and d.requested_at < now() - interval '1 hour';
  select count(*) into v_removals from public.listing_removal_requests l
   where l.status = 'open' and l.created_at < now() - interval '3 days';
  if v_r_due + v_r_over + v_t_due + v_t_over + v_images + v_deletions + v_removals = 0 then
    return 0;
  end if;
  -- One notice per moderator for each new set of items: the key is a hash of the items' ids
  -- (never stored in the clear), so an item that stays overdue is not sent again every hour.
  select md5(coalesce(string_agg(x.k, ',' order by x.k), '')) into v_set from (
    select 'r' || r.id::text as k from public.reports r where r.status = 'open' and r.due_at <= v_soon
    union all
    select 't' || t.id::text from public.takedown_requests t where t.status in ('open', 'waiting') and t.due_at <= v_soon
    union all
    select 'm' || m.id::text from public.messages m
     where m.kind = 'image' and m.image_state = 'queued' and m.deleted_at is null and m.created_at < now() - interval '12 hours'
    union all
    select 'd' || d.user_id::text from public.account_deletions d
     where d.completed_at is null and d.requested_at < now() - interval '1 hour'
    union all
    select 'l' || l.id::text from public.listing_removal_requests l
     where l.status = 'open' and l.created_at < now() - interval '3 days') x;
  return private.notify_moderators('moderation_due', 'moderation_due:' || v_set,
    jsonb_build_object('reports_due', v_r_due, 'reports_overdue', v_r_over,
                       'takedowns_due', v_t_due, 'takedowns_overdue', v_t_over,
                       'images_waiting', v_images, 'deletions_stuck', v_deletions,
                       'listing_removals_waiting', v_removals));
end $$;
comment on function public.moderation_due_alerts() is
  'Migration 77, pg_cron moderation-due-alerts hourly at minute 11: reports and takedowns due within 4 hours or overdue, chat photos queued for a moderator over 12 hours, account deletions unfinished over an hour and listing removals open over 3 days, as one moderation_due notice (counts only) per active moderator for each new set of items. Returns the notices added.';

-- ---------------------------------------------------------------------------
-- 5. Daily operations health
-- ---------------------------------------------------------------------------
create or replace function public.ops_health_alerts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_day    text := to_char((now() at time zone 'UTC')::date, 'YYYY-MM-DD');
  v_http   integer := 0;
  v_cron   integer := 0;
  v_alerts jsonb := '{}'::jsonb;
  v_kind   text;
  v_cnt    integer;
  v_n      integer := 0;
begin
  if to_regclass('net._http_response') is not null then
    execute $q$select count(*)::integer from net._http_response r
                where r.created > now() - interval '1 day'
                  and (r.timed_out or r.error_msg is not null or r.status_code >= 400)$q$ into v_http;
  end if;
  if to_regclass('cron.job_run_details') is not null then
    execute $q$select count(*)::integer from cron.job_run_details d
                where d.start_time > now() - interval '1 day' and d.status = 'failed'$q$ into v_cron;
  end if;
  if v_http > 0 then v_alerts := v_alerts || jsonb_build_object('http_errors', v_http); end if;
  if v_cron > 0 then v_alerts := v_alerts || jsonb_build_object('cron_failures', v_cron); end if;
  if not exists (select 1 from public.events e
                  where e.status = 'published' and e.starts_at > now() and e.moderation_state is null) then
    v_alerts := v_alerts || jsonb_build_object('no_upcoming_events', 1);
  end if;
  for v_kind, v_cnt in select a.key, (a.value #>> '{}')::integer from jsonb_each(v_alerts) a loop
    v_n := v_n + private.notify_moderators('ops_alert', 'ops_alert:' || v_kind || ':' || v_day,
                                           jsonb_build_object('alert', v_kind, 'count', v_cnt));
  end loop;
  return v_n;
end $$;
comment on function public.ops_health_alerts() is
  'Migration 77, pg_cron ops-health-alerts daily at 13:17 UTC: failed pg_net calls (timeout, error or HTTP 400 and over) and failed pg_cron runs in the last day, and no upcoming published plan; each alert is one ops_alert (payload {alert, count}) per active moderator and UTC day. Returns the notices added.';

-- ---------------------------------------------------------------------------
-- 6. Evidence hold and 7. retried deletions: the ledger
-- ---------------------------------------------------------------------------
alter table public.account_deletions add column if not exists legal_hold_until timestamptz;
alter table public.account_deletions add column if not exists attempts integer not null default 0;
alter table public.account_deletions add column if not exists last_attempt_at timestamptz;
alter table public.account_deletions add column if not exists last_error text;
comment on column public.account_deletions.legal_hold_until is
  'Migration 77: set when a child-safety or NCII report or takedown of the last year concerned the account; the delete-account function copies the account''s photos into legal-hold until then.';

create table if not exists public.legal_holds (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null,
  source_bucket text not null,
  source_path   text not null,
  path          text not null,
  byte_size     integer,
  created_at    timestamptz not null default now(),
  retain_until  timestamptz not null,
  purged_at     timestamptz,
  constraint legal_holds_source unique (source_bucket, source_path),
  constraint legal_holds_bucket check (source_bucket in ('avatars', 'chat-images')),
  constraint legal_holds_path check (path = user_id::text || '/' || source_bucket || '/' || substr(source_path, 38)
                                     and source_path like user_id::text || '/%')
);
create index if not exists legal_holds_user_idx on public.legal_holds (user_id);
create index if not exists legal_holds_purge_idx on public.legal_holds (retain_until) where purged_at is null;
comment on table public.legal_holds is
  'Migration 77: copies, in the private legal-hold bucket, of a deleted account''s photos taken because a child-safety or NCII report or takedown concerned it (path <user id>/<source bucket>/<source path without the user id>). No foreign key: evidence outlives the account. Kept until retain_until (a year), then the delete-account sweep deletes the object and stamps purged_at. Moderators read; service role writes.';
alter table public.legal_holds enable row level security;
revoke all on public.legal_holds from public, anon, authenticated;
grant select on public.legal_holds to authenticated;
grant all on public.legal_holds to service_role;
drop policy if exists "legal_holds_select_mod" on public.legal_holds;
create policy "legal_holds_select_mod" on public.legal_holds for select to authenticated
  using ((select public.is_moderator()));

do $$
begin
  if to_regclass('storage.buckets') is null then
    raise notice 'storage is missing; legal-hold bucket not created';
    return;
  end if;
  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('legal-hold', 'legal-hold', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
  on conflict (id) do update set public = false;
  execute 'drop policy if exists "legal_hold_select_mod" on storage.objects';
  execute $p$
    create policy "legal_hold_select_mod" on storage.objects for select to authenticated
      using (bucket_id = 'legal-hold' and (select public.is_moderator()))
  $p$;
end $$;

create or replace function public.legal_hold_for(p_user uuid)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select d.legal_hold_until from public.account_deletions d
   where d.user_id = p_user and d.legal_hold_until > now();
$$;
comment on function public.legal_hold_for(uuid) is
  'Migration 77, service role (delete-account): until when the account''s photos must be held, or null.';

create or replace function public.legal_hold_saved(p_user uuid, p_source_bucket text, p_source_path text, p_bytes integer default null)
returns text language plpgsql security definer set search_path = '' as $$
declare
  v_until timestamptz := public.legal_hold_for(p_user);
  v_path  text;
begin
  if v_until is null or p_source_bucket not in ('avatars', 'chat-images')
     or p_source_path is null or p_source_path not like p_user::text || '/%' or p_source_path like '%..%' then
    return null;
  end if;
  v_path := p_user::text || '/' || p_source_bucket || '/' || substr(p_source_path, 38);
  insert into public.legal_holds (user_id, source_bucket, source_path, path, byte_size, retain_until)
  values (p_user, p_source_bucket, p_source_path, v_path, p_bytes, v_until)
  on conflict (source_bucket, source_path) do nothing;
  return v_path;
end $$;
comment on function public.legal_hold_saved(uuid, text, text, integer) is
  'Migration 77, service role (delete-account): records the legal-hold copy of one of a held account''s objects; returns the path it is stored at (null when the account is not held or the path is not the account''s).';

create or replace function public.legal_hold_purge_list(p_limit integer default 100)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', h.id, 'path', h.path)), '[]'::jsonb)
    from (select id, path from public.legal_holds
           where purged_at is null and retain_until < now()
           order by retain_until limit greatest(1, least(coalesce(p_limit, 100), 500))) h;
$$;
comment on function public.legal_hold_purge_list(integer) is
  'Migration 77, service role (delete-account sweep): expired legal-hold copies to delete: [{id, path}].';

create or replace function public.legal_hold_purged(p_ids uuid[])
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  update public.legal_holds set purged_at = now()
   where id = any (coalesce(p_ids, '{}')) and purged_at is null and retain_until < now();
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function public.legal_hold_purged(uuid[]) is
  'Migration 77, service role (delete-account sweep): stamps purged_at on expired copies whose objects were deleted.';

-- The sweep's secret, generated here; it never leaves the database except in the pg_net header.
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; account_deletion_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'account_deletion_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'account_deletion_secret',
                                'Shared secret between the database and the delete-account sweep (migration 77)');
  end if;
end $$;

create or replace function public.account_deletion_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if p_secret is null or char_length(p_secret) < 32 or to_regclass('vault.decrypted_secrets') is null then
    return false;
  end if;
  select ds.decrypted_secret into v_secret
    from vault.decrypted_secrets ds where ds.name = 'account_deletion_secret' limit 1;
  return v_secret is not null and v_secret = p_secret;
end $$;
comment on function public.account_deletion_verify_secret(text) is
  'Migration 77: true when p_secret is the vault secret account_deletion_secret. Service role only; used by the delete-account function''s sweep.';

create or replace function public.account_deletion_sweep_claim(p_limit integer default 5)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_ids jsonb;
begin
  with c as (
    select d.user_id from public.account_deletions d
      join public.profiles p on p.id = d.user_id and p.status = 'deleted'
     where d.completed_at is null and d.requested_at < now() - interval '10 minutes'
       and d.attempts < 20 and (d.last_attempt_at is null or d.last_attempt_at < now() - interval '30 minutes')
     order by d.requested_at
     limit greatest(1, least(coalesce(p_limit, 5), 20))
     for update of d skip locked
  ), u as (
    update public.account_deletions d set attempts = d.attempts + 1, last_attempt_at = now()
      from c where d.user_id = c.user_id
    returning d.user_id
  )
  select coalesce(jsonb_agg(u.user_id), '[]'::jsonb) into v_ids from u;
  return v_ids;
end $$;
comment on function public.account_deletion_sweep_claim(integer) is
  'Migration 77, service role (delete-account sweep): claims up to p_limit (1 to 20) unfinished deletions requested over 10 minutes ago (at most 20 tries, 30 minutes apart) and returns their user ids.';

create or replace function public.account_deletion_failed(p_user uuid, p_error text)
returns void language sql security definer set search_path = '' as $$
  update public.account_deletions
     set last_error = nullif(left(regexp_replace(coalesce(p_error, ''), '[^a-z0-9_:]', '', 'g'), 60), '')
   where user_id = p_user and completed_at is null;
$$;
comment on function public.account_deletion_failed(uuid, text) is
  'Migration 77, service role (delete-account sweep): records the error code (letters, digits, _ and : only) of a failed try.';

create or replace function public.account_deletion_dispatch(p_force boolean default false)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_secret text;
begin
  if not coalesce(p_force, false)
     and not exists (select 1 from public.account_deletions d
                      where d.completed_at is null and d.requested_at < now() - interval '10 minutes'
                        and d.attempts < 20
                        and (d.last_attempt_at is null or d.last_attempt_at < now() - interval '30 minutes'))
     and not exists (select 1 from public.legal_holds h where h.purged_at is null and h.retain_until < now()) then
    return null;
  end if;
  if v_base is null then
    raise notice 'delete-account sweep: project_url not set; nothing sent';
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'account_deletion_secret' limit 1;
  end if;
  if v_secret is null or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'delete-account sweep: secret or pg_net missing; nothing sent';
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/delete-account',
    body := jsonb_build_object('op', 'sweep'),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-deletion-secret', v_secret),
    timeout_milliseconds := 120000);
end $$;
comment on function public.account_deletion_dispatch(boolean) is
  'Migration 77, pg_cron account-deletion-sweep every 15 minutes: when an unfinished deletion is due a retry or a legal-hold copy has expired (or p_force), POSTs {op: sweep} to the delete-account function through pg_net with the account_deletion_secret header. Returns the request id or null.';

-- ---------------------------------------------------------------------------
-- 8. legal_acceptances
-- ---------------------------------------------------------------------------
create table if not exists public.legal_acceptances (
  user_id         uuid primary key references public.profiles (id) on delete cascade,
  terms_version   text not null,
  privacy_version text not null,
  accepted_at     timestamptz not null default now(),
  constraint legal_acceptances_terms check (terms_version ~ '^terms [0-9]{4}-[0-9]{2}\.[0-9]{1,3}$'),
  constraint legal_acceptances_privacy check (privacy_version ~ '^privacy [0-9]{4}-[0-9]{2}\.[0-9]{1,3}$')
);
comment on table public.legal_acceptances is
  'Migration 77: the Terms of Service and Privacy Policy versions the member last accepted, and when (accept_legal_terms). Owner read; deleted with the account.';
alter table public.legal_acceptances enable row level security;
revoke all on public.legal_acceptances from public, anon, authenticated;
grant select on public.legal_acceptances to authenticated;
grant all on public.legal_acceptances to service_role;
drop policy if exists "legal_acceptances_select_own" on public.legal_acceptances;
create policy "legal_acceptances_select_own" on public.legal_acceptances for select to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.accept_legal_terms(p_terms text, p_privacy text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  a   public.legal_acceptances%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  if p_terms is null or p_terms !~ '^terms [0-9]{4}-[0-9]{2}\.[0-9]{1,3}$'
     or p_privacy is null or p_privacy !~ '^privacy [0-9]{4}-[0-9]{2}\.[0-9]{1,3}$' then
    raise exception 'invalid_version' using errcode = 'check_violation';
  end if;
  insert into public.legal_acceptances as l (user_id, terms_version, privacy_version, accepted_at)
  values (uid, p_terms, p_privacy, now())
  on conflict (user_id) do update
     set terms_version = excluded.terms_version, privacy_version = excluded.privacy_version,
         accepted_at = excluded.accepted_at
  returning * into a;
  return jsonb_build_object('terms_version', a.terms_version, 'privacy_version', a.privacy_version,
                            'accepted_at', a.accepted_at);
end $$;
comment on function public.accept_legal_terms(text, text) is
  'Migration 77: records that the caller accepted Terms version p_terms ("terms YYYY-MM.N") and Privacy Policy version p_privacy ("privacy YYYY-MM.N") now. Errors: not_authenticated, user_not_found, invalid_version.';

-- ---------------------------------------------------------------------------
-- 10. purge_handle_history
-- ---------------------------------------------------------------------------
create or replace function public.purge_handle_history()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  delete from public.handle_history where released_at < now() - interval '30 days';
  get diagnostics v_n = row_count;
  return v_n;
end $$;
comment on function public.purge_handle_history() is
  'Migration 77, pg_cron purge-handle-history daily at 04:53 UTC: released handles older than the 30-day hold. Returns the rows deleted.';

-- ---------------------------------------------------------------------------
-- 9. Rebuilt: request_account_deletion
-- ---------------------------------------------------------------------------

-- request_account_deletion (latest body, 20261231000200_recommendations_review_fixes.sql)
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_event   uuid;
  v_ids     uuid[];
  v_conv    uuid;   -- Migration 58
  v_b       record; -- Migration 60
  v_src     uuid;   -- Migration 62
  v_hold    boolean;   -- Migration 77
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    -- Migration 51: a banned account's ledger row is kept for a year.
    now() + case when v_profile.status = 'banned' then interval '365 days' else interval '30 days' end,
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null,
         attempts              = 0,      -- Migration 77
         last_error            = null;

  -- Migration 77: an evidence hold. While a child-safety or intimate-image report (not dismissed)
  -- or an NCII takedown (not rejected) of the last year concerns the caller, the delete-account
  -- function copies the caller's photos into the private legal-hold bucket before it deletes them,
  -- and the ledger row is kept a year (18 U.S.C. 2258A; Take It Down Act).
  v_hold := exists (select 1 from public.reports r
                     where r.target_user_id = uid and r.reason in ('child_safety', 'ncii')
                       and r.status <> 'dismissed' and r.created_at > now() - interval '365 days')
         or exists (select 1 from public.takedown_requests t
                     where t.target_user_id = uid and t.status <> 'rejected'
                       and t.created_at > now() - interval '365 days');
  if v_hold then
    update public.account_deletions
       set legal_hold_until      = now() + interval '365 days',
           retain_evidence_until = greatest(coalesce(retain_evidence_until, now()), now() + interval '365 days')
     where user_id = uid;
  end if;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
     where host_id = uid and status = 'published' and starts_at > now()
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  -- Their attendees hear about it (migration 18); the caller's own profile is
  -- already a tombstone, so nothing is queued for the caller.
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'host_deleted'));
  end loop;
  v_event := null;
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- Places (migration 27): the caller's private pins and still-pending
  -- requests go; places a moderator reviewed stay as ODbL place facts with
  -- no creator link (D-041).
  delete from public.places
   where created_by = uid and source = 'user' and (not is_public or status = 'pending');
  update public.places set created_by = null where created_by = uid;

  -- Place corrections and reports (migration 34): pending edits go; the
  -- rest of the caller's edits and every report they made lose the author
  -- and the note (a report keeps its reason, so a place it hid stays in the
  -- moderation queue); reviewer stamps and moderation log entries naming the caller are
  -- cleared.
  delete from public.place_edits where proposed_by = uid and status = 'pending';
  update public.place_edits set proposed_by = null, note = '' where proposed_by = uid;
  update public.place_edits set reviewed_by = null where reviewed_by = uid;
  update public.place_reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.place_reports set resolved_by = null where resolved_by = uid;
  update public.place_mod_actions set moderator_id = null where moderator_id = uid;
  -- Migration 36: the caller's add and edit rate log.
  delete from public.place_rate_log where user_id = uid;

  -- Attendance (migration 20): the caller's reports and every meet that
  -- names the caller, in either direction. (Reports would also go with the
  -- RSVP rows below; deleted here so the order does not matter.)
  delete from public.event_meets              where user_id = uid or met_user_id = uid;
  delete from public.event_attendance_reports where user_id = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;
  update public.rsvps set checked_in_by = null where checked_in_by = uid;

  -- Chapters: the caller's claims (reference contacts included) go; stamps
  -- that point at the caller are cleared. The chapter_members row goes below
  -- (the last-organizer guard lets a deleted profile leave).
  delete from public.chapter_claims where user_id = uid;
  update public.chapter_claims set reviewed_by = null where reviewed_by = uid;
  update public.hub_chapters set claimed_by = null where claimed_by = uid;

  -- Notifications (migration 18): the caller's inbox goes; rows that name the
  -- caller as the actor keep their text and lose the link; broadcasts the
  -- caller sent stay with the event, unattributed.
  delete from public.notifications where user_id = uid;
  update public.notifications set actor_id = null where actor_id = uid;
  update public.event_broadcasts set sender_id = null where sender_id = uid;

  -- Trust and safety (migration 51): blocks and mutes in either direction
  -- go; reports the caller filed lose the reporter and the note; resolver
  -- and moderator stamps naming the caller are cleared, and so are profile
  -- snapshots about the caller. Reports about the caller and the action log
  -- stay as moderation evidence.
  delete from public.blocks where blocker_id = uid or blocked_id = uid;
  delete from public.mutes  where muter_id = uid or muted_id = uid;
  update public.reports set reporter_id = null, note = '' where reporter_id = uid;
  update public.reports set resolved_by = null where resolved_by = uid;
  update public.moderation_actions set moderator_id = null where moderator_id = uid;
  update public.moderation_actions set snapshot = null where target_user_id = uid and snapshot is not null;

  -- Migration 52: NCII takedowns. Resolver stamps naming the caller are
  -- cleared; the caller's image hashes go, except blocked ones (evidence of
  -- who uploaded a removed image). Requests about the caller stay, like
  -- reports.
  update public.takedown_requests set resolved_by = null where resolved_by = uid;
  delete from public.image_hashes where owner_id = uid and status <> 'blocked';

  -- Migration 53: admin panel lookups the caller made lose the moderator
  -- link; lookups about the caller stay (a year, like the rest of the log).
  update public.admin_lookups set moderator_id = null where moderator_id = uid;

  -- Migration 58: messaging. Pending requests the caller sent go with their
  -- one message (the DM existed only for them); requests to the caller go.
  -- Groups the caller owns pass to the oldest admin, else the oldest member.
  -- DMs with the caller close. The caller's member rows go; a dm or group
  -- nobody is left in goes with its messages. Messages others received stay
  -- under the tombstone ("Deleted user"), without the device key or a kept
  -- deleted text; images are removed (the Edge Function deletes the files).
  -- Report evidence stays until its retain_until.
  delete from public.conversations c
   using public.message_requests r
   where r.conversation_id = c.id and r.from_user = uid and r.status = 'pending';
  for v_conv in
    select cm.conversation_id from public.conversation_members cm
      join public.conversations c on c.id = cm.conversation_id
     where cm.user_id = uid and c.kind = 'group' and cm.role = 'owner' and cm.left_at is null
  loop
    update public.conversation_members set role = 'owner'
     where conversation_id = v_conv
       and user_id = (select cm.user_id from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id <> uid
                         and cm.left_at is null and cm.removed_at is null
                       order by (cm.role = 'admin') desc, cm.joined_at, cm.user_id
                       limit 1);
  end loop;
  update public.conversations set closed_at = coalesce(closed_at, now())
   where kind = 'dm' and (split_part(dm_key, ':', 1) = uid::text or split_part(dm_key, ':', 2) = uid::text);
  delete from public.message_requests where from_user = uid or to_user = uid;
  delete from public.conversation_members where user_id = uid;
  update public.conversation_members set removed_by = null where removed_by = uid;
  update public.conversations set created_by = null where created_by = uid;
  delete from public.conversations c
   where c.kind in ('dm', 'group')
     and not exists (select 1 from public.conversation_members cm
                      where cm.conversation_id = c.id and cm.left_at is null and cm.removed_at is null);
  update public.messages
     set client_id = null, deleted_body = null,
         image_state = case when kind = 'image' then 'removed' else image_state end
   where author_id = uid;
  delete from public.chat_filter_strikes where user_id = uid;

  -- Migration 60: coaching (design section 13). Open requests and upcoming confirmed bookings
  -- end: as the coach with full refunds, as the client as a client cancellation now; the other
  -- side is told. Reports on reviews by or about the caller keep the text in the report note;
  -- those reviews go (ratings are recomputed). Bookings with the caller lose the client note and
  -- the meeting details. The coach profile goes with its credentials, photo rows, hubs, listings
  -- and their private notes, availability, exceptions and sessions; past bookings keep their own
  -- snapshot (listing_id and session_id are set null) under "Deleted user", as payment and tax
  -- records. booking_payments and coach_stripe_accounts stay (the delete-account function closes
  -- the Stripe account). Photo files go with the avatars/<uid>/ folder.
  for v_b in select b.id, b.coach_id from public.bookings b
              where (b.coach_id = uid or b.client_id = uid)
                and (b.status = 'requested' or (b.status = 'confirmed' and b.starts_at > now())) loop
    perform private.booking_cancel(v_b.id, 'system', 'account_deleted',
                                   case when v_b.coach_id = uid then 'full' else 'policy' end, true);
  end loop;
  update public.reports r
     set note = left(btrim(r.note || ' [text] ' || case when r.target_kind = 'coach_review' then cr.body
                                                         else coalesce(cr.reply, '') end), 1000)
    from public.coach_reviews cr
   where r.target_id = cr.booking_id and r.target_kind in ('coach_review', 'coach_review_reply')
     and (cr.client_id = uid or cr.coach_id = uid);
  delete from public.coach_reviews where client_id = uid or coach_id = uid;
  update public.bookings set client_note = '' where (coach_id = uid or client_id = uid) and client_note <> '';
  delete from public.booking_private bp using public.bookings b
   where b.id = bp.booking_id and (b.coach_id = uid or b.client_id = uid);
  delete from public.coach_profiles where user_id = uid;

  -- Migration 62: organizer claims and connected feeds. Feeds the caller connected (organizer
  -- origin) stop, their upcoming items are withdrawn, and they lose the owner; claimed sources the
  -- collector found itself stay on without an owner. Claims, OAuth states and the Eventbrite token
  -- in the vault go. Listing removal requests hold no account link; resolver stamps are cleared.
  for v_src in
    select f.id from public.feed_sources f
     where f.origin = 'organizer'
       and (f.organizer_id = uid
            or f.organizer_claim_id in (select c.id from public.organizer_claims c where c.user_id = uid))
  loop
    perform public.feed_source_withdraw(v_src, 'stop');
    update public.feed_sources
       set enabled = false, organizer_stopped_at = coalesce(organizer_stopped_at, now()),
           organizer_id = null, organizer_verified_at = null
     where id = v_src;
  end loop;
  update public.feed_sources
     set organizer_id = null, organizer_verified_at = null, organizer_hub_id = null
   where organizer_id = uid;
  delete from public.organizer_claims where user_id = uid;
  delete from public.organizer_oauth_states where user_id = uid;
  begin
    delete from vault.secrets where name = 'eventbrite:' || uid::text;
  exception when insufficient_privilege then
    -- Where the definer may not delete vault rows, the token is overwritten instead.
    perform vault.update_secret(s.id, 'revoked') from vault.secrets s where s.name = 'eventbrite:' || uid::text;
  end;
  update public.listing_removal_requests set resolved_by = null where resolved_by = uid;

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  delete from public.area_waitlist            where user_id = uid;
  -- Migration 67: recommendations. The caller's taste vector, prefs and dismissals go (after
  -- the hub_members delete above, whose trigger marks the taste stale), and so does every other
  -- member's "Not interested" in the caller.
  delete from public.rec_taste                where user_id = uid;
  delete from public.rec_prefs                where user_id = uid;
  delete from public.rec_dismissals           where user_id = uid;
  delete from public.rec_dismissals           where subject_kind = 'person' and subject_id = uid;
  -- Migration 68: coach dismissals are keyed by the coach's user id too.
  delete from public.rec_dismissals           where subject_kind = 'coach' and subject_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").
  -- Migration 77: the record of which Terms and Privacy Policy the caller accepted goes; so does
  -- the free-text note on the caller's hub requests, and every stamp naming the caller on rows
  -- that stay (roles and memberships the caller granted, hubs and chapters the caller created,
  -- hub requests the caller reviewed).
  delete from public.legal_acceptances        where user_id = uid;
  update public.hub_requests set note = '' where user_id = uid and note <> '';
  update public.hub_requests set reviewed_by = null where reviewed_by = uid;
  update public.user_roles set granted_by = null where granted_by = uid;
  update public.org_memberships set granted_by = null where granted_by = uid;
  update public.hubs set created_by = null where created_by = uid;
  update public.hub_chapters set created_by = null where created_by = uid;

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;


-- ---------------------------------------------------------------------------
-- pg_cron
-- ---------------------------------------------------------------------------
do $$
declare
  v_jobs text[][] := array[
    array['moderation-due-alerts', '11 * * * *', 'select public.moderation_due_alerts()'],
    array['ops-health-alerts', '17 13 * * *', 'select public.ops_health_alerts()'],
    array['account-deletion-sweep', '*/15 * * * *', 'select public.account_deletion_dispatch()'],
    array['purge-handle-history', '53 4 * * *', 'select public.purge_handle_history()']];
  i integer;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; migration 77 jobs not scheduled';
    return;
  end if;
  for i in 1 .. array_length(v_jobs, 1) loop
    if exists (select 1 from cron.job where jobname = v_jobs[i][1]) then
      perform cron.unschedule(v_jobs[i][1]);
    end if;
    perform cron.schedule(v_jobs[i][1], v_jobs[i][2], v_jobs[i][3]);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function private.email_meta_int(text, integer) from public, anon, authenticated;
revoke all on function private.email_budget_room() from public, anon, authenticated;
revoke all on function private.email_budget_add(text, integer) from public, anon, authenticated;
revoke all on function public.email_budget_take(text, integer) from public, anon, authenticated;
grant execute on function public.email_budget_take(text, integer) to service_role;
revoke all on function private.notify_moderators(text, text, jsonb) from public, anon, authenticated;
revoke all on function private.reports_alert_moderators() from public, anon, authenticated;
revoke all on function private.takedowns_alert_moderators() from public, anon, authenticated;
revoke all on function public.moderation_due_alerts() from public, anon, authenticated;
grant execute on function public.moderation_due_alerts() to service_role;
revoke all on function public.ops_health_alerts() from public, anon, authenticated;
grant execute on function public.ops_health_alerts() to service_role;
revoke all on function public.legal_hold_for(uuid) from public, anon, authenticated;
grant execute on function public.legal_hold_for(uuid) to service_role;
revoke all on function public.legal_hold_saved(uuid, text, text, integer) from public, anon, authenticated;
grant execute on function public.legal_hold_saved(uuid, text, text, integer) to service_role;
revoke all on function public.legal_hold_purge_list(integer) from public, anon, authenticated;
grant execute on function public.legal_hold_purge_list(integer) to service_role;
revoke all on function public.legal_hold_purged(uuid[]) from public, anon, authenticated;
grant execute on function public.legal_hold_purged(uuid[]) to service_role;
revoke all on function public.account_deletion_verify_secret(text) from public, anon, authenticated;
grant execute on function public.account_deletion_verify_secret(text) to service_role;
revoke all on function public.account_deletion_sweep_claim(integer) from public, anon, authenticated;
grant execute on function public.account_deletion_sweep_claim(integer) to service_role;
revoke all on function public.account_deletion_failed(uuid, text) from public, anon, authenticated;
grant execute on function public.account_deletion_failed(uuid, text) to service_role;
revoke all on function public.account_deletion_dispatch(boolean) from public, anon, authenticated;
grant execute on function public.account_deletion_dispatch(boolean) to service_role;
revoke all on function public.accept_legal_terms(text, text) from public, anon;
grant execute on function public.accept_legal_terms(text, text) to authenticated, service_role;
revoke all on function public.purge_handle_history() from public, anon, authenticated;
grant execute on function public.purge_handle_history() to service_role;
-- Rebuilt.
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.73')
  on conflict (key) do update set value = excluded.value, updated_at = now();
