-- ============================================================================
-- Activity Planet schema v2 — migration 55: email and push delivery worker
--   (PLAN.md 4.9 and 4.10; ROADMAP week 7; D-031, D-040). Builds on the queue
--   of migration 18: every notifications row already says email_status and
--   push_status 'pending' or 'skipped' (prefs, topics, unsubscribed_all_at,
--   quiet hours through push_after, blocks and mutes since migration 51).
--   No function from an earlier migration is rebuilt here. Checks:
--   supabase/tests/notify_worker.sql.
--
--   What this file does
--     1. notifications.claimed_at: the worker's lease. A claimed row is not
--        claimed again for 10 minutes; after 5 attempts a channel is failed.
--     2. notification_email_days: one row per UTC day with the emails
--        reserved, so the worker stays under Resend's free tier (100 a day):
--        90 a day by default, meta key notify_email_daily_cap overrides.
--        Over the cap an email is skipped (last_error daily_cap); the inbox
--        and push are unaffected. No user reference.
--     3. claim_pending_notifications(limit) (service role): picks due rows
--        with for update skip locked, so two overlapping runs never take the
--        same row, and re-checks everything at send time:
--          * rows older than 2 days, and rows created before this migration,
--            are skipped (expired), never sent late;
--          * a row already read in the app is not sent again (read_in_app);
--          * the recipient must still be active; prefs are read again
--            (channel and topic switches, unsubscribed_all_at);
--          * quiet hours are evaluated again for push: a push due inside
--            quiet hours gets a new push_after and waits (never dropped);
--          * never across a block: when the recipient and the actor are now
--            in a block (either direction), or the recipient muted the actor,
--            attendee_joined, hub_new_event and broadcast go out by neither
--            channel and no other notice names the actor;
--          * reminders and check-in prompts for a cancelled or moderated plan,
--            and reminders for a plan that already started, are skipped;
--          * email needs a confirmed address; push needs a live web device
--            on an allowed push service (no device: skipped).
--        Returns jsonb [{id, kind, payload, actor_name, hub, chapter,
--        email: {to, unsubscribe_token} | null, push: [{device_id,
--        endpoint, p256dh, auth}] | null}]. Payload stays coarse (D-027).
--     4. complete_notification_delivery(results, devices) (service role):
--        writes sent / skipped / failed per channel ('retry' puts it back to
--        pending), releases the lease, and records device outcomes: gone
--        (the push service answered 404 or 410) revokes the device, failed
--        counts up and revokes at 5, ok resets the count.
--     5. register_push_device(subscription, user_agent, app_version) and
--        unregister_push_device(endpoint) for the signed-in member. One live
--        row per endpoint: registering it takes it from another account on
--        the same browser. Only the push services' hosts are accepted. 20
--        live devices per person (the oldest is revoked).
--     6. Signed unsubscribe: notification_unsubscribe_token(user) (internal)
--        is <user id>.<HMAC-SHA256 with the vault secret
--        notify_unsubscribe_secret, generated inside the database>.
--        unsubscribe_email_with_token(token) (anon and signed-in; the site's
--        /unsubscribe page and its one-click List-Unsubscribe-Post route)
--        turns email off for that person and skips their pending emails.
--     7. send-notifications dispatch: vault secret notify_worker_secret
--        (generated inside the database), notify_worker_verify_secret
--        (service role), notify_worker_dispatch() (pg_net, only when a row
--        is due), pg_cron job send-notifications every 2 minutes.
--     * meta.schema_version 2.51.
--
--   Account deletion: request_account_deletion already deletes the caller's
--   notifications and push_devices (D-031); notification_email_days holds no
--   user, so it is unchanged.
--
--   Not here: the weekly digest and its postal address, native (APNs/FCM)
--   push, message notifications.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Lease column
-- ---------------------------------------------------------------------------
alter table public.notifications add column if not exists claimed_at timestamptz;
comment on column public.notifications.claimed_at is
  'Migration 55: set by claim_pending_notifications while send-notifications works on the row; cleared by complete_notification_delivery. A lease older than 10 minutes is claimable again.';
create index if not exists notifications_push_due_idx on public.notifications (push_after)
  where push_status = 'pending';

-- Rows queued before the worker existed are never sent late. Once only: a
-- re-run must not skip rows queued after the first run.
do $$
begin
  if not exists (select 1 from public.meta where key = 'notify_worker_started_at') then
    update public.notifications
       set email_status = case when email_status = 'pending' then 'skipped'::public.notification_channel_status else email_status end,
           push_status  = case when push_status  = 'pending' then 'skipped'::public.notification_channel_status else push_status end,
           last_error   = 'before_worker'
     where email_status = 'pending' or push_status = 'pending';
    insert into public.meta (key, value) values ('notify_worker_started_at', now()::text);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Daily email counter
-- ---------------------------------------------------------------------------
create table if not exists public.notification_email_days (
  day      date primary key,
  reserved integer not null default 0,
  constraint notification_email_days_reserved check (reserved >= 0)
);
comment on table public.notification_email_days is
  'Migration 55: emails reserved per UTC day by claim_pending_notifications (cap: meta notify_email_daily_cap, default 90, under Resend''s free 100 a day). No user data. Service role only.';
alter table public.notification_email_days enable row level security;
revoke all on public.notification_email_days from public, anon, authenticated;
grant all on public.notification_email_days to service_role;

-- ---------------------------------------------------------------------------
-- 3. Helpers
-- ---------------------------------------------------------------------------
-- The end of the person's current quiet window, or null when push may go now.
-- Same rule as enqueue_notification (migration 18).
create or replace function public.notification_quiet_until(p_user_id uuid, p_at timestamptz default now())
returns timestamptz language plpgsql stable security definer set search_path = '' as $$
declare
  np          public.notification_prefs%rowtype;
  v_tz        text;
  v_now_local timestamp;
  v_local     time;
begin
  select * into np from public.notification_prefs where user_id = p_user_id;
  if not found or np.quiet_start is null or np.quiet_end is null or np.quiet_start = np.quiet_end then
    return null;
  end if;
  v_tz := case when public.is_valid_timezone(np.timezone) then np.timezone else 'America/New_York' end;
  v_now_local := p_at at time zone v_tz;
  v_local := v_now_local::time;
  if (np.quiet_start < np.quiet_end and v_local >= np.quiet_start and v_local < np.quiet_end)
     or (np.quiet_start > np.quiet_end and (v_local >= np.quiet_start or v_local < np.quiet_end)) then
    return ((v_now_local::date + np.quiet_end)
            + case when np.quiet_end <= v_local then interval '1 day' else interval '0' end)
           at time zone v_tz;
  end if;
  return null;
end $$;
comment on function public.notification_quiet_until(uuid, timestamptz) is
  'Migration 55, internal: when the person''s quiet hours (notification_prefs, their timezone) cover p_at, the end of that window; else null.';

-- Hosts of the browsers' push services. Anything else is refused at
-- registration and again by the worker (no requests to arbitrary hosts).
create or replace function public.push_endpoint_allowed(p_endpoint text)
returns boolean language sql immutable set search_path = '' as $$
  select p_endpoint is not null and char_length(p_endpoint) <= 1000
     and p_endpoint ~ '^https://(fcm\.googleapis\.com|android\.googleapis\.com|updates\.push\.services\.mozilla\.com|push\.services\.mozilla\.com|([a-z0-9-]+\.)*push\.apple\.com|([a-z0-9-]+\.)*notify\.windows\.com)/';
$$;
comment on function public.push_endpoint_allowed(text) is
  'Migration 55: true for an https endpoint on a known web push service (FCM, Mozilla, Apple, Windows).';

-- vault secret for the unsubscribe links, generated here and in no file.
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; notify_unsubscribe_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'notify_unsubscribe_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_unsubscribe_secret',
                                'Signs the unsubscribe links in notification emails (migration 55)');
  end if;
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; notify_worker_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'notify_worker_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'notify_worker_secret',
                                'Shared secret between the database and the send-notifications Edge Function (migration 55)');
  end if;
end $$;

create or replace function public.notify_vault_secret(p_name text)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if to_regclass('vault.decrypted_secrets') is null then
    return null;
  end if;
  select ds.decrypted_secret into v_secret from vault.decrypted_secrets ds where ds.name = p_name limit 1;
  return v_secret;
end $$;
comment on function public.notify_vault_secret(text) is
  'Migration 55, internal: a vault secret by name, or null.';

create or replace function public.notification_unsubscribe_token(p_user_id uuid)
returns text language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text := public.notify_vault_secret('notify_unsubscribe_secret');
begin
  if p_user_id is null or v_secret is null then
    return null;
  end if;
  return p_user_id::text || '.' || encode(extensions.hmac('unsubscribe:' || p_user_id::text, v_secret, 'sha256'), 'hex');
end $$;
comment on function public.notification_unsubscribe_token(uuid) is
  'Migration 55, internal: <user id>.<hex HMAC-SHA256 of "unsubscribe:<user id>" with vault notify_unsubscribe_secret>. Put in email unsubscribe links by claim_pending_notifications.';

-- Turns email off for the token's person. Anon may call it: the token is the
-- authority (a 256-bit HMAC nobody can guess). Same answer for a person who
-- is already unsubscribed; invalid_token for anything that does not verify.
create or replace function public.unsubscribe_email_with_token(p_token text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_user  uuid;
  v_parts text[];
begin
  if p_token is null or char_length(p_token) <> 101 or p_token !~ '^[0-9a-f-]{36}\.[0-9a-f]{64}$' then
    raise exception 'invalid_token' using errcode = '22023';
  end if;
  v_parts := string_to_array(p_token, '.');
  begin
    v_user := v_parts[1]::uuid;
  exception when invalid_text_representation then
    raise exception 'invalid_token' using errcode = '22023';
  end;
  if public.notification_unsubscribe_token(v_user) is distinct from p_token then
    raise exception 'invalid_token' using errcode = '22023';
  end if;
  update public.notification_prefs set email_enabled = false
   where user_id = v_user and email_enabled;
  update public.notifications set email_status = 'skipped', last_error = 'unsubscribed'
   where user_id = v_user and email_status = 'pending';
  return jsonb_build_object('ok', true);
end $$;
comment on function public.unsubscribe_email_with_token(text) is
  'Migration 55: verifies an unsubscribe token from a notification email and turns email off for that person (notification_prefs.email_enabled = false; pending emails skipped). invalid_token otherwise. Callable by anon (the site''s /unsubscribe page and one-click route).';

-- ---------------------------------------------------------------------------
-- 4. Claim
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
    v_actor := null;
    if (v_email or v_push) and n.actor_id is not null and n.actor_id <> n.user_id then
      v_social := n.kind in ('attendee_joined', 'hub_new_event', 'broadcast');
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

    -- Stale plan notices.
    if (v_email or v_push) and n.event_id is not null
       and n.kind in ('event_reminder_day', 'event_reminder_2h', 'checkin_prompt', 'attendee_joined', 'broadcast', 'event_updated') then
      select * into e from public.events where id = n.event_id;
      if not found or e.moderation_state is not null
         or (e.status = 'cancelled' and n.kind <> 'event_cancelled')
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
  'Migration 55, service role (send-notifications): claims up to p_limit (max 100) due rows with for update skip locked, re-checks prefs, quiet hours, blocks and mutes, staleness, the confirmed address and the daily email cap, writes skipped or deferred channels, and returns what to send now as jsonb. Leased for 10 minutes; 5 attempts.';

-- ---------------------------------------------------------------------------
-- 5. Complete
-- ---------------------------------------------------------------------------
-- p_results: [{id, email?: sent|skipped|failed|retry, push?: same, error?}]
-- p_devices: {gone: [device ids], failed: [...], ok: [...]}
create or replace function public.complete_notification_delivery(p_results jsonb, p_devices jsonb default '{}'::jsonb)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_r  jsonb;
  v_id uuid;
  v_e  text;
  v_p  text;
  n    integer := 0;
  v_ok constant text[] := array['sent', 'skipped', 'failed', 'retry'];
begin
  if p_results is not null and jsonb_typeof(p_results) = 'array' then
    for v_r in select * from jsonb_array_elements(p_results) loop
      begin
        v_id := (v_r ->> 'id')::uuid;
      exception when invalid_text_representation then
        continue;
      end;
      v_e := v_r ->> 'email';
      v_p := v_r ->> 'push';
      if v_e is not null and not (v_e = any (v_ok)) then v_e := null; end if;
      if v_p is not null and not (v_p = any (v_ok)) then v_p := null; end if;
      update public.notifications
         set email_status  = case when email_status = 'pending' and v_e is not null and v_e <> 'retry'
                                  then v_e::public.notification_channel_status else email_status end,
             email_sent_at = case when email_status = 'pending' and v_e = 'sent' then now() else email_sent_at end,
             push_status   = case when push_status = 'pending' and v_p is not null and v_p <> 'retry'
                                  then v_p::public.notification_channel_status else push_status end,
             push_sent_at  = case when push_status = 'pending' and v_p = 'sent' then now() else push_sent_at end,
             claimed_at    = null,
             last_error    = coalesce(left(nullif(v_r ->> 'error', ''), 1000), last_error)
       where id = v_id;
      if found then n := n + 1; end if;
    end loop;
  end if;

  if p_devices is not null and jsonb_typeof(p_devices) = 'object' then
    update public.push_devices
       set revoked_at = coalesce(revoked_at, now()), last_failure_at = now()
     where id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p_devices -> 'gone') = 'array' then p_devices -> 'gone' else '[]'::jsonb end));
    update public.push_devices
       set failure_count = failure_count + 1,
           last_failure_at = now(),
           revoked_at = case when failure_count + 1 >= 5 then coalesce(revoked_at, now()) else revoked_at end
     where id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p_devices -> 'failed') = 'array' then p_devices -> 'failed' else '[]'::jsonb end));
    update public.push_devices
       set failure_count = 0
     where failure_count <> 0
       and id::text in (select jsonb_array_elements_text(case when jsonb_typeof(p_devices -> 'ok') = 'array' then p_devices -> 'ok' else '[]'::jsonb end));
  end if;
  return n;
end $$;
comment on function public.complete_notification_delivery(jsonb, jsonb) is
  'Migration 55, service role (send-notifications): records each channel''s outcome (retry returns it to pending), releases the lease, and records device outcomes (gone revokes; failed counts up and revokes at 5; ok resets). Returns the rows updated.';

-- ---------------------------------------------------------------------------
-- 6. Push devices (member RPCs)
-- ---------------------------------------------------------------------------
create or replace function public.register_push_device(
  p_subscription jsonb,
  p_user_agent   text default null,
  p_app_version  text default null)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  v_endpoint text := p_subscription ->> 'endpoint';
  v_p256dh   text := p_subscription #>> '{keys,p256dh}';
  v_auth     text := p_subscription #>> '{keys,auth}';
  v_hash     text;
  v_id       uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status = 'active' and deleted_at is null) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_subscription is null or jsonb_typeof(p_subscription) <> 'object'
     or not public.push_endpoint_allowed(v_endpoint)
     or v_p256dh is null or v_p256dh !~ '^[A-Za-z0-9_-]{80,100}={0,2}$'
     or v_auth is null or v_auth !~ '^[A-Za-z0-9_-]{16,32}={0,2}$' then
    raise exception 'invalid_subscription' using errcode = '22023';
  end if;
  v_hash := encode(extensions.digest(v_endpoint, 'sha256'), 'hex');

  -- One live row per endpoint: a browser shared between accounts pushes only
  -- for the account that registered it last.
  update public.push_devices set revoked_at = now()
   where token_hash = v_hash and user_id <> uid and revoked_at is null;

  insert into public.push_devices as d (user_id, platform, subscription, token_hash, user_agent, app_version)
  values (uid, 'web',
          jsonb_build_object('endpoint', v_endpoint, 'keys', jsonb_build_object('p256dh', v_p256dh, 'auth', v_auth)),
          v_hash, left(p_user_agent, 300), left(p_app_version, 40))
  on conflict (user_id, token_hash) do update
     set subscription = excluded.subscription,
         user_agent = coalesce(excluded.user_agent, d.user_agent),
         app_version = coalesce(excluded.app_version, d.app_version),
         revoked_at = null,
         failure_count = 0,
         last_seen_at = now()
  returning d.id into v_id;

  -- 20 live devices per person: the least recently seen go first.
  update public.push_devices set revoked_at = now()
   where id in (select pd.id from public.push_devices pd
                 where pd.user_id = uid and pd.revoked_at is null
                 order by pd.last_seen_at desc, pd.created_at desc
                 offset 20);
  return v_id;
end $$;
comment on function public.register_push_device(jsonb, text, text) is
  'Migration 55: saves the caller''s web push subscription ({endpoint, keys: {p256dh, auth}}, a known push service only), takes the endpoint from any other account, keeps 20 live devices. Returns the device id.';

create or replace function public.unregister_push_device(p_endpoint text)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_endpoint is null or char_length(p_endpoint) > 1000 then
    return false;
  end if;
  update public.push_devices set revoked_at = now()
   where user_id = uid and revoked_at is null
     and token_hash = encode(extensions.digest(p_endpoint, 'sha256'), 'hex');
  return found;
end $$;
comment on function public.unregister_push_device(text) is
  'Migration 55: revokes the caller''s device with this endpoint (Turn off on this device). True when one was live.';

-- ---------------------------------------------------------------------------
-- 7. Dispatch to send-notifications
-- ---------------------------------------------------------------------------
create or replace function public.notify_worker_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text := public.notify_vault_secret('notify_worker_secret');
begin
  return p_secret is not null and char_length(p_secret) >= 32 and v_secret is not null and v_secret = p_secret;
end $$;
comment on function public.notify_worker_verify_secret(text) is
  'Migration 55: true when p_secret is the vault secret notify_worker_secret (generated in the database). Service role only; used by send-notifications.';

-- pg_cron every 2 minutes. Sends nothing (no Edge Function call) when no row
-- is due, so a quiet project costs one indexed query.
create or replace function public.notify_worker_dispatch(p_force boolean default false)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_secret text := public.notify_vault_secret('notify_worker_secret');
begin
  if not coalesce(p_force, false) and not exists (
       select 1 from public.notifications x
        where (x.email_status = 'pending'
               or (x.push_status = 'pending' and (x.push_after is null or x.push_after <= now())))
          and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')) then
    return null;
  end if;
  if v_base is null or v_secret is null
     or to_regprocedure('net.http_post(text,jsonb,jsonb,jsonb,integer)') is null then
    raise notice 'send-notifications: project_url, secret or pg_net missing; nothing sent';
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/send-notifications',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-notify-secret', v_secret),
    timeout_milliseconds := 60000);
end $$;
comment on function public.notify_worker_dispatch(boolean) is
  'Migration 55, internal (pg_cron send-notifications every 2 minutes): POSTs to the send-notifications Edge Function through pg_net with the notify_worker_secret header when a row is due (or p_force). Returns the request id or null.';

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; send-notifications not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'send-notifications') then
    perform cron.unschedule('send-notifications');
  end if;
  perform cron.schedule('send-notifications', '*/2 * * * *', 'select public.notify_worker_dispatch()');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.notification_quiet_until(uuid, timestamptz) from public, anon, authenticated;
grant execute on function public.notification_quiet_until(uuid, timestamptz) to service_role;
revoke all on function public.push_endpoint_allowed(text) from public, anon;
grant execute on function public.push_endpoint_allowed(text) to authenticated, service_role;
revoke all on function public.notify_vault_secret(text) from public, anon, authenticated, service_role;
revoke all on function public.notification_unsubscribe_token(uuid) from public, anon, authenticated;
grant execute on function public.notification_unsubscribe_token(uuid) to service_role;
revoke all on function public.unsubscribe_email_with_token(text) from public;
grant execute on function public.unsubscribe_email_with_token(text) to anon, authenticated, service_role;
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;
revoke all on function public.complete_notification_delivery(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.complete_notification_delivery(jsonb, jsonb) to service_role;
revoke all on function public.register_push_device(jsonb, text, text) from public, anon;
grant execute on function public.register_push_device(jsonb, text, text) to authenticated;
revoke all on function public.unregister_push_device(text) from public, anon;
grant execute on function public.unregister_push_device(text) to authenticated;
revoke all on function public.notify_worker_verify_secret(text) from public, anon, authenticated;
grant execute on function public.notify_worker_verify_secret(text) to service_role;
revoke all on function public.notify_worker_dispatch(boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 9. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.51')
on conflict (key) do update set value = excluded.value;
