-- ============================================================================
-- Activity Planet schema v2 — migration 19: notifications review fixes
--   (PLAN.md 4.9; D-035 to D-037). Fixes forward on migration 18
--   (20261114000100_notifications.sql), which already reached staging.
--
--   What this file does
--     * update_event: the event_updated key is unique per edit, so a move
--       back to an earlier time or place is announced again (the old key
--       hashed the new time and place, and a repeat was dropped). The
--       "time or place changed" guard still stops edits that change neither.
--       Body otherwise as in migration 18.
--     * enqueue_notification (p_batch, attendee_joined): payload.joiners
--       holds one hash per distinct joiner (md5 of dedupe_key and user id,
--       never a raw id) and payload.count is their number, so a person who
--       leaves and rejoins within the hour is not counted twice. Rows written
--       before this file seed the set from their last actor_id.
--     * enqueue_due_reminders: the day-before (2-hour) reminder is skipped
--       only when the RSVP row was created, or the person got an
--       rsvp_confirmed or waitlist_promoted row for that event, inside the
--       last 24 (2) hours before the start; no longer whenever
--       rsvps.updated_at moved (a host approval changes it too).
--     * pg_cron job purge-cron-run-details: daily, deletes
--       cron.job_run_details older than 7 days. Unscheduled by name first.
--     * meta.schema_version 2.15.
--
--   No new tables or columns; account deletion coverage is unchanged.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. enqueue_notification: distinct joiners for batched rows
-- ---------------------------------------------------------------------------
-- Records one notification. In-app always; email and push 'skipped' when the
-- person turned the channel off, turned the topic off or unsubscribed from
-- everything, else 'pending'. During quiet hours push stays pending with
-- push_after set to the end of the quiet window. Returns the row id, or null
-- when nothing was written (dedupe hit, missing or deleted profile).
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

comment on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) is
  'Internal. Records one notification honoring notification_prefs (channels, topics, unsubscribed_all_at, quiet hours via push_after). Idempotent by dedupe_key; p_batch keeps a hash per distinct actor in payload.joiners and their number in payload.count. Returns the id, or null when nothing was written.';

-- ---------------------------------------------------------------------------
-- 2. update_event: one event_updated per edit that changes time or place
--    (body of migration 18, only the dedupe key and its comment changed)
-- ---------------------------------------------------------------------------
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

  -- Notifications (migrations 18, 19): every edit that changes the time or
  -- place reaches going and waitlisted attendees, including a move back to an
  -- earlier time or place (the key is unique per edit).
  v_time  := e.starts_at is distinct from v_old.starts_at or e.ends_at is distinct from v_old.ends_at;
  v_place := e.location_hint is distinct from v_old.location_hint
             or l.venue_id is distinct from v_venue
             or l.location_text is distinct from v_text;
  if v_time or v_place then
    perform public.notify_event_audience(
      e.id, 'event_updated', array['going', 'waitlisted']::public.rsvp_status[],
      e.id || ':' || replace(gen_random_uuid()::text, '-', ''),
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


-- ---------------------------------------------------------------------------
-- 3. enqueue_due_reminders: skip only people confirmed inside the window
-- ---------------------------------------------------------------------------
-- Day-before: events starting in (12 h, 24 h] for going attendees, except
-- those whose RSVP row was created after the 24-hour mark (a fresh RSVP, or
-- the host's own RSVP on an event made that late) or whose rsvp_confirmed or
-- waitlist_promoted row was (they just got their confirmation). 2-hour:
-- events starting in (0, 2 h], same rule with the 2-hour mark. rsvps.updated_at
-- is not used: a host approval changes it and is not joining. Keys carry the start time, so a moved event reminds again.
-- Check-in prompt: events that ended in the last 6 hours (the check_in
-- window) for going attendees other than the host who did not check in; once
-- per event. Returns the number of rows written.
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
       and r.created_at < e.starts_at - interval '24 hours'
       and not exists (
             select 1 from public.notifications c
              where c.event_id = e.id and c.user_id = r.user_id
                and c.kind in ('rsvp_confirmed', 'waitlist_promoted')
                and c.created_at >= e.starts_at - interval '24 hours')
    union all
    select r.user_id, e.id, e.hub_id, e.chapter_id, e.starts_at,
           'event_reminder_2h'::public.notification_kind
      from public.events e
      join public.rsvps r on r.event_id = e.id and r.status = 'going'
     where e.status = 'published'
       and e.starts_at > now()
       and e.starts_at <= now() + interval '2 hours'
       and r.created_at < e.starts_at - interval '2 hours'
       and not exists (
             select 1 from public.notifications c
              where c.event_id = e.id and c.user_id = r.user_id
                and c.kind in ('rsvp_confirmed', 'waitlist_promoted')
                and c.created_at >= e.starts_at - interval '2 hours')
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
  'Queues event_reminder_day, event_reminder_2h and checkin_prompt rows that are due; reminders skip people whose confirmation or waitlist promotion came inside the reminder window. Idempotent (dedupe keys). Returns the number written. pg_cron every 10 minutes; service role only.';

-- ---------------------------------------------------------------------------
-- 4. Grants (unchanged from migration 18, restated for create or replace)
-- ---------------------------------------------------------------------------
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean) from public, anon, authenticated;
revoke all on function public.enqueue_due_reminders() from public, anon, authenticated;
grant execute on function public.enqueue_due_reminders() to service_role;
revoke all on function public.update_event(uuid, jsonb) from public, anon;
grant execute on function public.update_event(uuid, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- 5. pg_cron: keep cron.job_run_details to 7 days (the 10-minute reminder job
--    alone adds about 144 rows a day). Unscheduled by name first.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null or to_regclass('cron.job_run_details') is null then
    raise notice 'pg_cron is not installed; purge-cron-run-details not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'purge-cron-run-details') then
    perform cron.unschedule('purge-cron-run-details');
  end if;
  perform cron.schedule('purge-cron-run-details', '7 8 * * *',
                        $job$delete from cron.job_run_details where end_time < now() - interval '7 days'$job$);
end $$;

-- ---------------------------------------------------------------------------
-- 6. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.15')
  on conflict (key) do update set value = excluded.value, updated_at = now();
