-- ============================================================================
-- Activity Planet schema v2 — migration 18: jobs and in-app notifications
--   (PLAN.md 4.9; D-031, D-035).
--
--   What this file does
--     * Enums notification_kind and notification_channel_status.
--     * notifications: one row per person per thing that happened. In-app is
--       always recorded; email_status and push_status say what the delivery
--       worker (week 7, not in this file) still has to do: 'pending', or
--       'skipped' when the person opted out. push_after holds a push back
--       until the end of the person's quiet hours (deferred, never dropped).
--       payload carries coarse data only: title, start and end, timezone and
--       the event's location_hint, never an exact address. dedupe_key makes
--       every producer idempotent. Owner-only select; clients may update
--       read_at and seen_at and nothing else. In the supabase_realtime
--       publication when it exists.
--     * enqueue_notification(...) (internal): reads notification_prefs
--       (email_enabled, push_enabled, event_reminders, event_updates,
--       hub_activity, checkin_prompts, unsubscribed_all_at, quiet_start,
--       quiet_end, timezone); no prefs row means the defaults (all on).
--       Nothing is queued for a deleted or inactive profile.
--     * Producers, rebuilt from their latest bodies with only the
--       notification lines added: set_rsvp (rsvp_confirmed to the attendee;
--       attendee_joined to the host and the chapter's captains and organizers,
--       one row per event per hour with a count), rsvp_promote_waitlist
--       (waitlist_promoted), approve_rsvp (rsvp_approved), cancel_event and
--       cancel_event_series (event_cancelled to going, waitlisted and
--       interested; one row per person per series), update_event
--       (event_updated to going and waitlisted when the time or place
--       changes), review_chapter_claim (chapter_claim_update to the claimant).
--       request_account_deletion also tells the attendees of the events it
--       cancels.
--     * RPCs: mark_notifications_read(ids default null), unread_notification_count(),
--       broadcast_to_event(event, body) (host, chapter captains and
--       organizers, moderators; 1 to 500 characters; 3 per event per rolling
--       day; logged in event_broadcasts; reaches going and waitlisted).
--     * enqueue_due_reminders(): day-before and 2-hour reminders to going
--       attendees, and one check-in prompt after an event ends to going
--       attendees who did not check in. Idempotent.
--     * purge_read_notifications(): read rows older than 90 days.
--     * pg_cron jobs (each unscheduled by name first, and only when its
--       function exists): notifications-reminders every 10 minutes,
--       refresh-hub-stats hourly, materialize-event-series daily,
--       purge-read-notifications daily, purge-account-deletions daily.
--     * request_account_deletion: deletes the caller's notifications, clears
--       actor_id and event_broadcasts.sender_id that point at the caller.
--     * meta.schema_version 2.14.
--
--   Not here: email and push delivery (week 7), hub_new_event and message
--   producers (week 5), the weekly digest.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.notification_kind as enum (
    'rsvp_confirmed', 'attendee_joined', 'waitlist_promoted', 'rsvp_approved',
    'event_reminder_day', 'event_reminder_2h', 'event_cancelled', 'event_updated',
    'checkin_prompt', 'hub_new_event', 'broadcast', 'chapter_claim_update');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.notification_channel_status as enum ('pending', 'sent', 'skipped', 'failed');
exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 2. notifications
-- ---------------------------------------------------------------------------
create table if not exists public.notifications (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  kind          public.notification_kind not null,
  event_id      uuid references public.events (id) on delete cascade,
  hub_id        uuid references public.hubs (id) on delete cascade,
  chapter_id    uuid references public.hub_chapters (id) on delete set null,
  actor_id      uuid references public.profiles (id) on delete set null,
  payload       jsonb not null default '{}'::jsonb,
  dedupe_key    text not null,
  created_at    timestamptz not null default now(),
  read_at       timestamptz,
  seen_at       timestamptz,
  email_status  public.notification_channel_status not null default 'pending',
  push_status   public.notification_channel_status not null default 'pending',
  push_after    timestamptz,
  email_sent_at timestamptz,
  push_sent_at  timestamptz,
  attempts      integer not null default 0,
  last_error    text,
  constraint notifications_dedupe_key_unique  unique (dedupe_key),
  constraint notifications_dedupe_key_length  check (char_length(dedupe_key) between 1 and 300),
  constraint notifications_payload_object     check (jsonb_typeof(payload) = 'object'),
  constraint notifications_attempts_positive  check (attempts >= 0),
  constraint notifications_last_error_length  check (last_error is null or char_length(last_error) <= 1000)
);
create index if not exists notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index if not exists notifications_pending_idx on public.notifications (created_at)
  where email_status = 'pending' or push_status = 'pending';
create index if not exists notifications_actor_idx on public.notifications (actor_id) where actor_id is not null;
create index if not exists notifications_event_idx on public.notifications (event_id) where event_id is not null;
create index if not exists notifications_read_idx on public.notifications (read_at) where read_at is not null;

comment on table public.notifications is
  'In-app inbox and delivery queue (PLAN 4.9). Written only by enqueue_notification. Owners select their rows and may update read_at and seen_at. email_status / push_status: pending (the week 7 worker sends it), skipped (opted out), sent, failed. payload is coarse: title, starts_at, ends_at, timezone, location_hint, plus kind-specific keys; never an exact address.';
comment on column public.notifications.push_after is
  'Quiet hours: the push is held until this time (null = no hold). In-app and email are not held.';
comment on column public.notifications.dedupe_key is
  'Idempotency key, <kind>:<scope>:<recipient>[:<bucket>]. attendee_joined uses an hourly bucket and counts joins in payload.count.';

alter table public.notifications enable row level security;

drop policy if exists "notifications_select_own" on public.notifications;
create policy "notifications_select_own" on public.notifications for select to authenticated
  using (user_id = (select auth.uid()));
drop policy if exists "notifications_update_own" on public.notifications;
create policy "notifications_update_own" on public.notifications for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

revoke all on public.notifications from public, anon, authenticated;
grant select on public.notifications to authenticated;
grant update (read_at, seen_at) on public.notifications to authenticated;
grant all on public.notifications to service_role;

do $$ begin
  if exists (select 1 from pg_catalog.pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_catalog.pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. event_broadcasts: the log behind broadcast_to_event (and its daily cap)
-- ---------------------------------------------------------------------------
create table if not exists public.event_broadcasts (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references public.events (id) on delete cascade,
  sender_id       uuid references public.profiles (id) on delete set null,
  body            text not null,
  recipient_count integer not null default 0,
  created_at      timestamptz not null default now(),
  constraint event_broadcasts_body_length check (char_length(body) between 1 and 500)
);
create index if not exists event_broadcasts_event_created_idx on public.event_broadcasts (event_id, created_at desc);
create index if not exists event_broadcasts_sender_idx on public.event_broadcasts (sender_id) where sender_id is not null;
comment on table public.event_broadcasts is
  'One row per "message everyone" sent through broadcast_to_event. No client access; recipients read the text from their notification payload.';

alter table public.event_broadcasts enable row level security;
revoke all on public.event_broadcasts from public, anon, authenticated;
grant all on public.event_broadcasts to service_role;

-- ---------------------------------------------------------------------------
-- 4. Internal helpers: payload, enqueue, fan-out
-- ---------------------------------------------------------------------------
-- Coarse event data for a payload (D-027: never an exact address).
create or replace function public.notification_event_payload(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce((
    select jsonb_build_object(
             'title', e.title,
             'starts_at', e.starts_at,
             'ends_at', e.ends_at,
             'timezone', e.timezone,
             'location_hint', e.location_hint)
      from public.events e
     where e.id = p_event_id), '{}'::jsonb);
$$;

-- Records one notification. In-app always; email and push 'skipped' when the
-- person turned the channel off, turned the topic off or unsubscribed from
-- everything, else 'pending'. During quiet hours push stays pending with
-- push_after set to the end of the quiet window. Returns the row id, or null
-- when nothing was written (dedupe hit, missing or deleted profile).
-- p_batch: on a dedupe hit with a different actor, bump payload.count and
-- surface the row again (attendee_joined).
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
begin
  if p_user_id is null or p_kind is null or nullif(btrim(coalesce(p_dedupe_key, '')), '') is null then
    return null;
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_user_id and status = 'active' and deleted_at is null) then
    return null;
  end if;

  select * into np from public.notification_prefs where user_id = p_user_id;
  -- Topic switches; confirmations of the person's own actions and claim
  -- reviews are transactional and follow only the channel switches.
  v_topic := case
    when p_kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
    when p_kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
    when p_kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
    when p_kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
                  then 'skipped' else 'pending' end;
  v_push  := case when np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic
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

  if p_batch then
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('count', 1),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object('count', coalesce((n.payload ->> 'count')::integer, 1) + 1),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
     where n.actor_id is distinct from excluded.actor_id
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

comment on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) is
  'Internal. Records one notification honoring notification_prefs (channels, topics, unsubscribed_all_at, quiet hours via push_after). Idempotent by dedupe_key; p_batch counts repeats in payload.count. Returns the id, or null when nothing was written.';

-- Everyone on an event with one of p_statuses, except p_actor. Dedupe key
-- <kind>:<p_key>:<user>. Returns the number of rows written.
create or replace function public.notify_event_audience(
  p_event_id uuid,
  p_kind     public.notification_kind,
  p_statuses public.rsvp_status[],
  p_key      text,
  p_actor    uuid,
  p_extra    jsonb default '{}'::jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e         public.events%rowtype;
  v_payload jsonb;
  v_user    uuid;
  n         integer := 0;
begin
  select * into e from public.events where id = p_event_id;
  if not found then
    return 0;
  end if;
  v_payload := public.notification_event_payload(p_event_id) || coalesce(p_extra, '{}'::jsonb);
  for v_user in
    select r.user_id from public.rsvps r
     where r.event_id = p_event_id and r.status = any (p_statuses)
       and r.user_id is distinct from p_actor
     order by r.user_id
  loop
    if public.enqueue_notification(v_user, p_kind, p_kind::text || ':' || p_key || ':' || v_user,
                                   p_event_id, e.hub_id, e.chapter_id, p_actor, v_payload) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- attendee_joined for the host and, on a chapter event, its captains and
-- organizers; one row per recipient per event per UTC hour.
create or replace function public.notify_event_managers_joined(p_event_id uuid, p_joiner uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e         public.events%rowtype;
  v_payload jsonb;
  v_hour    text := to_char(date_trunc('hour', now() at time zone 'UTC'), 'YYYYMMDDHH24');
  v_user    uuid;
  n         integer := 0;
begin
  select * into e from public.events where id = p_event_id;
  if not found then
    return 0;
  end if;
  v_payload := public.notification_event_payload(p_event_id);
  for v_user in
    select x.user_id from (
      select e.host_id as user_id where e.host_id is not null
      union
      select cm.user_id from public.chapter_members cm
       where e.chapter_id is not null and cm.chapter_id = e.chapter_id and cm.role in ('captain', 'organizer')
    ) x
     where x.user_id is distinct from p_joiner
  loop
    if public.enqueue_notification(v_user, 'attendee_joined',
                                   'attendee_joined:' || p_event_id || ':' || v_user || ':' || v_hour,
                                   p_event_id, e.hub_id, e.chapter_id, p_joiner, v_payload, true) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- chapter_claim_update for the claimant after a review. The reviewer is not
-- named (actor_id stays null).
create or replace function public.notify_chapter_claim_reviewed(p_claim public.chapter_claims)
returns uuid language plpgsql security definer set search_path = '' as $$
begin
  return public.enqueue_notification(
    p_claim.user_id, 'chapter_claim_update',
    'chapter_claim_update:' || p_claim.id || ':' || p_claim.status,
    null, p_claim.hub_id, p_claim.chapter_id, null,
    jsonb_strip_nulls(jsonb_build_object(
      'status', p_claim.status,
      'claim_kind', p_claim.kind,
      'proposed_name', p_claim.proposed_name,
      'hub_name', (select h.name from public.hubs h where h.id = p_claim.hub_id),
      'chapter_slug', (select ch.slug from public.hub_chapters ch where ch.id = p_claim.chapter_id),
      'note', p_claim.review_note)));
end $$;

-- ---------------------------------------------------------------------------
-- 5. Producers (latest bodies plus the notification lines)
-- ---------------------------------------------------------------------------
-- set_rsvp: body of migration 7 (20261026000100).
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
    raise exception 'event_not_found' using errcode = 'P0002';
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

comment on function public.set_rsvp(uuid, public.rsvp_status) is
  'Sets the caller''s RSVP on one occurrence: going (or waitlisted when full and the waitlist is on), interested, cancelled (always allowed; returns null when there was no row). Atomic against capacity; promotes the waitlist when a going seat frees up. A new going or waitlisted RSVP queues rsvp_confirmed for the caller and, when going, attendee_joined for the host and chapter captains and organizers. Errors: not_authenticated, invalid_status, event_not_found, onboarding_required, guidelines_required, removed_by_host, age_restricted, not_campus_member, event_cancelled, event_over, not_chapter_member, not_hub_member, event_full.';

-- rsvp_promote_waitlist: body of migration 6 (20261025000100).
create or replace function public.rsvp_promote_waitlist(p_event_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e          public.events%rowtype;
  v_going    integer;
  v_user     uuid;
  v_promoted integer := 0;
begin
  select * into e from public.events where id = p_event_id for update;
  if not found or e.status = 'cancelled' then
    return 0;
  end if;
  loop
    select count(*) into v_going from public.rsvps where event_id = p_event_id and status = 'going';
    exit when e.capacity is not null and v_going >= e.capacity;
    select user_id into v_user
      from public.rsvps
     where event_id = p_event_id and status = 'waitlisted'
     order by waitlist_position
     limit 1;
    exit when v_user is null;
    update public.rsvps
       set status = 'going', waitlist_position = null
     where event_id = p_event_id and user_id = v_user;
    perform public.enqueue_notification(
      v_user, 'waitlist_promoted',
      'waitlist_promoted:' || p_event_id || ':' || v_user || ':' || floor(extract(epoch from now()))::bigint,
      p_event_id, e.hub_id, e.chapter_id, null, public.notification_event_payload(p_event_id));
    v_promoted := v_promoted + 1;
  end loop;
  return v_promoted;
end $$;

-- approve_rsvp: body of migration 6.
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
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'P0002';
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

comment on function public.approve_rsvp(uuid, uuid, boolean) is
  'Host, chapter captain or moderator approves (or un-approves) a going attendee, which reveals an approved-only address to them; a new approval queues rsvp_approved. Errors: not_authenticated, event_not_found, forbidden, rsvp_not_found, not_going.';

-- update_event: body of migration 6.
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
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if e.kind = 'imported' then
    raise exception 'kind_not_allowed' using errcode = 'check_violation';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
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

  -- Notifications (migration 18): a change of time or place reaches going and
  -- waitlisted attendees once per distinct new time and place.
  v_time  := e.starts_at is distinct from v_old.starts_at or e.ends_at is distinct from v_old.ends_at;
  v_place := e.location_hint is distinct from v_old.location_hint
             or l.venue_id is distinct from v_venue
             or l.location_text is distinct from v_text;
  if v_time or v_place then
    perform public.notify_event_audience(
      e.id, 'event_updated', array['going', 'waitlisted']::public.rsvp_status[],
      e.id || ':' || md5(concat_ws('|', e.starts_at, e.ends_at, e.location_hint, l.venue_id, l.location_text)),
      uid,
      jsonb_build_object('changed', to_jsonb(array_remove(array[case when v_time then 'time' end,
                                                                case when v_place then 'place' end], null))));
  end if;
  return e;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.update_event(uuid, jsonb) is
  'Patches an event (keys present in p_args). Host, chapter captains and moderators; address keys are host/moderator only. Narrowing eligibility cancels attendees who no longer qualify. A change of time or place queues event_updated for going and waitlisted attendees. Errors: not_authenticated, immutable_field, event_not_found, kind_not_allowed, forbidden, event_cancelled, event_over, capacity_below_going, plus the create_event validation codes.';

-- cancel_event: body of migration 6.
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
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
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

comment on function public.cancel_event(uuid, text) is
  'Cancels an event (host, chapter captains, moderators) and queues event_cancelled for going, waitlisted and interested people. Idempotent. Errors: not_authenticated, event_not_found, forbidden.';

-- cancel_event_series: body of migration 6.
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
    raise exception 'series_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(s.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(s.chapter_id)) then
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

comment on function public.cancel_event_series(uuid, text) is
  'Cancels a weekly series and every future published occurrence; queues one event_cancelled per person across the series. Idempotent. Errors: not_authenticated, series_not_found, forbidden.';

-- review_chapter_claim: body of migration 17 (20261113000200).
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
    raise exception 'claim_not_found' using errcode = 'P0002';
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

comment on function public.review_chapter_claim(uuid, boolean, text) is
  'Moderators approve or reject a pending claim (never their own). Approval, in one transaction: re-checks the claimant''s verified membership (organization and campus, as at submit), creates the chapter when absent, makes the claimant its organizer, raises org_memberships.role to officer for org claims, stamps claimed_by, claimed_at and verified_at. Either decision queues chapter_claim_update for the claimant. Errors: not_authenticated, forbidden, invalid_decision, claim_not_found, own_claim, claim_not_pending, claimant_inactive, membership_required, chapter_has_organizer.';

-- ---------------------------------------------------------------------------
-- 6. Client RPCs: inbox, broadcast
-- ---------------------------------------------------------------------------
-- Marks the caller's notifications read (all unread when p_ids is null) and
-- stamps seen_at when missing. Returns the number of rows changed.
create or replace function public.mark_notifications_read(p_ids uuid[] default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  n   integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.notifications
     set read_at = now(), seen_at = coalesce(seen_at, now())
   where user_id = uid and read_at is null
     and (p_ids is null or id = any (p_ids));
  get diagnostics n = row_count;
  return n;
end $$;

comment on function public.mark_notifications_read(uuid[]) is
  'Marks the caller''s notifications read (every unread one when p_ids is null). Returns the count. Errors: not_authenticated.';

create or replace function public.unread_notification_count()
returns integer language sql stable security definer set search_path = '' as $$
  select count(*)::integer from public.notifications
   where user_id = (select auth.uid()) and read_at is null;
$$;

comment on function public.unread_notification_count() is
  'Number of the caller''s unread notifications (0 when signed out).';

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
    raise exception 'event_not_found' using errcode = 'P0002';
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

comment on function public.broadcast_to_event(uuid, text) is
  'Message everyone: the host, a captain or organizer of the event''s chapter, or a moderator sends 1 to 500 characters to going and waitlisted attendees (kind broadcast). At most 3 per event per rolling day; until a day after the end. Returns {broadcast_id, recipients}. Errors: not_authenticated, event_not_found, forbidden, event_cancelled, event_over, body_length, broadcast_limit.';

-- ---------------------------------------------------------------------------
-- 7. Jobs: reminders and check-in prompts, purge
-- ---------------------------------------------------------------------------
-- Day-before: events starting in (12 h, 24 h] for going attendees whose RSVP
-- predates the 24-hour mark. 2-hour: events starting in (0, 2 h] for going
-- attendees whose RSVP predates the 2-hour mark (people who just joined have
-- their confirmation). Keys carry the start time, so a moved event reminds
-- again. Check-in prompt: events that ended in the last 6 hours (the check_in
-- window) for going attendees other than the host who did not check in;
-- once per event. Returns the number of rows written.
create or replace function public.enqueue_due_reminders()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v record;
  n integer := 0;
begin
  for v in
    select r.user_id, e.id as event_id, e.hub_id, e.chapter_id, e.starts_at,
           'event_reminder_day'::public.notification_kind as kind
      from public.events e
      join public.rsvps r on r.event_id = e.id and r.status = 'going'
     where e.status = 'published'
       and e.starts_at > now() + interval '12 hours'
       and e.starts_at <= now() + interval '24 hours'
       and r.updated_at < e.starts_at - interval '24 hours'
    union all
    select r.user_id, e.id, e.hub_id, e.chapter_id, e.starts_at,
           'event_reminder_2h'::public.notification_kind
      from public.events e
      join public.rsvps r on r.event_id = e.id and r.status = 'going'
     where e.status = 'published'
       and e.starts_at > now()
       and e.starts_at <= now() + interval '2 hours'
       and r.updated_at < e.starts_at - interval '2 hours'
  loop
    if public.enqueue_notification(
         v.user_id, v.kind,
         v.kind::text || ':' || v.event_id || ':' || v.user_id || ':' || floor(extract(epoch from v.starts_at))::bigint,
         v.event_id, v.hub_id, v.chapter_id, null, public.notification_event_payload(v.event_id)) is not null then
      n := n + 1;
    end if;
  end loop;

  for v in
    select r.user_id, e.id as event_id, e.hub_id, e.chapter_id
      from public.events e
      join public.rsvps r on r.event_id = e.id and r.status = 'going'
     where e.status = 'published'
       and e.kind <> 'imported'
       and e.ends_at <= now()
       and e.ends_at > now() - interval '6 hours'
       and r.checked_in_at is null
       and r.user_id is distinct from e.host_id
  loop
    if public.enqueue_notification(
         v.user_id, 'checkin_prompt', 'checkin_prompt:' || v.event_id || ':' || v.user_id,
         v.event_id, v.hub_id, v.chapter_id, null, public.notification_event_payload(v.event_id)) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

comment on function public.enqueue_due_reminders() is
  'Queues event_reminder_day, event_reminder_2h and checkin_prompt rows that are due. Idempotent (dedupe keys). Returns the number written. pg_cron every 10 minutes; service role only.';

create or replace function public.purge_read_notifications()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  delete from public.notifications
   where read_at is not null and read_at < now() - interval '90 days';
  get diagnostics n = row_count;
  return n;
end $$;

comment on function public.purge_read_notifications() is
  'Deletes notifications read more than 90 days ago. Returns the count. pg_cron daily; service role only.';

-- ---------------------------------------------------------------------------
-- 8. request_account_deletion: notifications and broadcasts
--    (body of migration 16, 20261113000100, plus the notification lines)
-- ---------------------------------------------------------------------------
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
    now() + interval '30 days',
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

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
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;

comment on function public.request_account_deletion(text) is
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships, chapter claims, notifications and the city waitlist row removed, claimed_by / reviewed_by / checked_in_by / notification actor / broadcast sender references cleared, hosted series and future events cancelled with their addresses (attendees notified), private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 9. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.notification_event_payload(uuid) from public, anon, authenticated;
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.notify_event_audience(uuid, public.notification_kind, public.rsvp_status[], text, uuid, jsonb) from public, anon, authenticated;
revoke all on function public.notify_event_managers_joined(uuid, uuid) from public, anon, authenticated;
revoke all on function public.notify_chapter_claim_reviewed(public.chapter_claims) from public, anon, authenticated;
revoke all on function public.rsvp_promote_waitlist(uuid) from public, anon, authenticated;

revoke all on function public.enqueue_due_reminders() from public, anon, authenticated;
grant execute on function public.enqueue_due_reminders() to service_role;
revoke all on function public.purge_read_notifications() from public, anon, authenticated;
grant execute on function public.purge_read_notifications() to service_role;

revoke all on function public.mark_notifications_read(uuid[]) from public, anon;
grant execute on function public.mark_notifications_read(uuid[]) to authenticated;
revoke all on function public.unread_notification_count() from public, anon;
grant execute on function public.unread_notification_count() to authenticated;
revoke all on function public.broadcast_to_event(uuid, text) from public, anon;
grant execute on function public.broadcast_to_event(uuid, text) to authenticated;

revoke all on function public.set_rsvp(uuid, public.rsvp_status) from public, anon;
grant execute on function public.set_rsvp(uuid, public.rsvp_status) to authenticated;
revoke all on function public.approve_rsvp(uuid, uuid, boolean) from public, anon;
grant execute on function public.approve_rsvp(uuid, uuid, boolean) to authenticated;
revoke all on function public.update_event(uuid, jsonb) from public, anon;
grant execute on function public.update_event(uuid, jsonb) to authenticated;
revoke all on function public.cancel_event(uuid, text) from public, anon;
grant execute on function public.cancel_event(uuid, text) to authenticated;
revoke all on function public.cancel_event_series(uuid, text) from public, anon;
grant execute on function public.cancel_event_series(uuid, text) to authenticated;
revoke all on function public.review_chapter_claim(uuid, boolean, text) from public, anon;
grant execute on function public.review_chapter_claim(uuid, boolean, text) to authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 10. pg_cron jobs. Each job is unscheduled by name before it is scheduled,
--     and only scheduled when its function exists (a missing one is reported
--     with a notice and skipped). Nothing runs when pg_cron is absent.
-- ---------------------------------------------------------------------------
do $$
declare
  v_jobs text[][] := array[
    array['notifications-reminders',  '*/10 * * * *', 'public.enqueue_due_reminders()',        'select public.enqueue_due_reminders()'],
    array['refresh-hub-stats',        '17 * * * *',   'public.refresh_hub_stats()',            'select public.refresh_hub_stats()'],
    array['materialize-event-series', '23 9 * * *',   'public.materialize_all_event_series(integer)', 'select public.materialize_all_event_series()'],
    array['purge-read-notifications', '41 8 * * *',   'public.purge_read_notifications()',     'select public.purge_read_notifications()'],
    array['purge-account-deletions',  '53 8 * * *',   'public.purge_account_deletions()',      'select public.purge_account_deletions()']
  ];
  i integer;
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; no jobs scheduled';
    return;
  end if;
  for i in 1 .. array_length(v_jobs, 1) loop
    if exists (select 1 from cron.job where jobname = v_jobs[i][1]) then
      perform cron.unschedule(v_jobs[i][1]);
    end if;
    if to_regprocedure(v_jobs[i][3]) is null then
      raise notice 'skipping job %: % does not exist', v_jobs[i][1], v_jobs[i][3];
    else
      perform cron.schedule(v_jobs[i][1], v_jobs[i][2], v_jobs[i][4]);
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.14')
  on conflict (key) do update set value = excluded.value, updated_at = now();
