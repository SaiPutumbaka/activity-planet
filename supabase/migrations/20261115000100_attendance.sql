-- ============================================================================
-- Activity Planet schema v2 — migration 20: attendance, the morning-after
--   prompt and the chapter dashboard (PLAN.md 4.9; D-031, D-035 to D-037).
--
--   What this file does
--     * rsvps.attended_self_reported_at: "I went", said by the attendee.
--       Self-reports never touch checked_in_at (a check-in is the stronger
--       signal and only check_in / host_check_in write it). Not
--       client-selectable (rsvps has column grants).
--     * event_attendance_reports (event_id, user_id, attended, answered_at,
--       dismissed_at): one row per going RSVP that answered or dismissed the
--       "did you go?" prompt. Foreign key to rsvps (cascade).
--     * event_meets (event_id, user_id, met_user_id, created_at): who the
--       caller says they met. One-sided picks are private to the picker;
--       nobody else can read them (people_met, later, only shows mutual
--       picks or co-check-ins). Cascades on the event and both users.
--     * Both tables: RLS, owner select only, no client writes.
--     * RPCs:
--         submit_attendance(event, attended, met uuid[]): from the event's
--           end to end + 7 days, for a going RSVP; met people must have been
--           going and not be the caller; at most 30; re-submitting replaces
--           the caller's meets for that event. Marks the caller's
--           checkin_prompt notification for the event read.
--         pending_attendance_prompts(): up to 5 events (not imported) that
--           ended in the last 7 days where the caller was going and has not
--           answered or dismissed, newest first, with the card fields and
--           the other going attendees (id, first name, avatar only).
--         dismiss_attendance_prompt(event).
--         chapter_dashboard(chapter, weeks default 12): organizers, captains
--           and moderators; aggregate counts only, never names.
--     * request_account_deletion: also deletes the caller's reports and every
--       meet naming the caller, either direction (body of migration 18 plus
--       those lines; migration 19 did not change it).
--     * meta.schema_version 2.16.
--
--   Not here: people_met and the morning-after cron job (next slice).
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. rsvps.attended_self_reported_at
-- ---------------------------------------------------------------------------
alter table public.rsvps add column if not exists attended_self_reported_at timestamptz;
comment on column public.rsvps.attended_self_reported_at is
  'When the attendee said they went (submit_attendance). Set only while checked_in_at is null; never overwrites checked_in_at. Cleared when they later say they did not go.';

-- ---------------------------------------------------------------------------
-- 2. event_attendance_reports
-- ---------------------------------------------------------------------------
create table if not exists public.event_attendance_reports (
  event_id     uuid not null,
  user_id      uuid not null,
  attended     boolean,
  answered_at  timestamptz,
  dismissed_at timestamptz,
  primary key (event_id, user_id),
  constraint event_attendance_reports_rsvp_fkey foreign key (event_id, user_id)
    references public.rsvps (event_id, user_id) on delete cascade,
  constraint event_attendance_reports_answer_shape check ((attended is null) = (answered_at is null)),
  constraint event_attendance_reports_not_empty   check (answered_at is not null or dismissed_at is not null)
);
create index if not exists event_attendance_reports_user_idx on public.event_attendance_reports (user_id);
comment on table public.event_attendance_reports is
  'One row per going RSVP that answered ("did you go?") or dismissed the attendance prompt. Owner select only; written by submit_attendance and dismiss_attendance_prompt. Removed with the RSVP and by request_account_deletion.';

alter table public.event_attendance_reports enable row level security;
drop policy if exists "event_attendance_reports_select_own" on public.event_attendance_reports;
create policy "event_attendance_reports_select_own" on public.event_attendance_reports for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.event_attendance_reports from public, anon, authenticated;
grant select on public.event_attendance_reports to authenticated;
grant all on public.event_attendance_reports to service_role;

-- ---------------------------------------------------------------------------
-- 3. event_meets
-- ---------------------------------------------------------------------------
create table if not exists public.event_meets (
  event_id    uuid not null references public.events (id) on delete cascade,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  met_user_id uuid not null references public.profiles (id) on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (event_id, user_id, met_user_id),
  constraint event_meets_not_self check (user_id <> met_user_id)
);
create index if not exists event_meets_met_user_idx on public.event_meets (met_user_id);
create index if not exists event_meets_user_idx     on public.event_meets (user_id);
comment on table public.event_meets is
  '"Who did you meet?" picks: user_id says they met met_user_id at event_id. Private to user_id (one-sided picks are never shown to anyone else). Written only by submit_attendance; removed by request_account_deletion in both directions and by cascade.';

alter table public.event_meets enable row level security;
drop policy if exists "event_meets_select_own" on public.event_meets;
create policy "event_meets_select_own" on public.event_meets for select to authenticated
  using (user_id = (select auth.uid()));
revoke all on public.event_meets from public, anon, authenticated;
grant select on public.event_meets to authenticated;
grant all on public.event_meets to service_role;

-- ---------------------------------------------------------------------------
-- 4. submit_attendance, dismiss_attendance_prompt, pending_attendance_prompts
-- ---------------------------------------------------------------------------
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
    raise exception 'event_not_found' using errcode = 'P0002';
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

comment on function public.submit_attendance(uuid, boolean, uuid[]) is
  'Morning-after answer: did the caller go, and who did they meet. Needs a going RSVP; open from the event''s end to 7 days after. p_met: up to 30 distinct people who were going, not the caller, only when attended. Idempotent: replaces the caller''s answer and meets for the event. Sets rsvps.attended_self_reported_at when attended and not checked in (never touches checked_in_at); clears it on "did not go". Marks the caller''s checkin_prompt for the event read. Returns {event_id, attended, met_count, checked_in}. Errors: not_authenticated, attended_required, event_not_found, not_going, event_cancelled, event_not_over, attendance_window_closed, too_many_met, met_requires_attended, met_self, met_not_going.';

create or replace function public.dismiss_attendance_prompt(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rsvps
                  where event_id = p_event_id and user_id = uid and status = 'going') then
    raise exception 'not_going' using errcode = '42501';
  end if;
  insert into public.event_attendance_reports (event_id, user_id, dismissed_at)
  values (p_event_id, uid, now())
  on conflict (event_id, user_id) do update
     set dismissed_at = coalesce(public.event_attendance_reports.dismissed_at, excluded.dismissed_at);
  update public.notifications
     set read_at = now(), seen_at = coalesce(seen_at, now())
   where user_id = uid and event_id = p_event_id and kind = 'checkin_prompt' and read_at is null;
end $$;

comment on function public.dismiss_attendance_prompt(uuid) is
  'Hides the "did you go?" prompt for the event (the caller can still answer from the event page within the window). Marks the caller''s checkin_prompt for the event read. Idempotent. Errors: not_authenticated, not_going.';

create or replace function public.pending_attendance_prompts()
returns table (
  event_id      uuid,
  title         text,
  starts_at     timestamptz,
  ends_at       timestamptz,
  timezone      text,
  location_hint text,
  cover_url     text,
  hub_id        uuid,
  hub_slug      text,
  hub_name      text,
  hub_emoji     text,
  chapter_id    uuid,
  chapter_name  text,
  going_count   integer,
  checked_in    boolean,
  attendees     jsonb
)
language sql stable security definer set search_path = '' as $$
  select e.id, e.title, e.starts_at, e.ends_at, e.timezone, e.location_hint, e.cover_url,
         h.id, h.slug, h.name, h.emoji, e.chapter_id, ch.name, e.going_count,
         r.checked_in_at is not null,
         coalesce((
           select jsonb_agg(jsonb_build_object('id', p.id, 'first_name', p.first_name, 'avatar_url', p.avatar_url)
                            order by (o.checked_in_at is null), p.first_name, p.id)
             from public.rsvps o
             join public.profiles p on p.id = o.user_id and p.status = 'active'
            where o.event_id = e.id and o.status = 'going' and o.user_id <> r.user_id
         ), '[]'::jsonb)
    from public.rsvps r
    join public.events e on e.id = r.event_id
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
   where r.user_id = (select auth.uid())
     and r.status = 'going'
     and e.status = 'published'
     and e.kind <> 'imported'
     and e.host_id is distinct from r.user_id
     and e.ends_at <= now()
     and e.ends_at > now() - interval '7 days'
     and not exists (select 1 from public.event_attendance_reports a
                      where a.event_id = r.event_id and a.user_id = r.user_id)
   order by e.ends_at desc, e.id
   limit 5;
$$;

comment on function public.pending_attendance_prompts() is
  'Up to 5 events (not imported, not hosted by the caller) that ended in the last 7 days where the caller was going and has neither answered nor dismissed, newest first. attendees: the other going people with an active profile, [{id, first_name, avatar_url}], checked-in first.';

-- ---------------------------------------------------------------------------
-- 5. chapter_dashboard: aggregates only
-- ---------------------------------------------------------------------------
-- Weeks start Monday in America/New_York. An event is held when it is
-- published and has ended; it belongs to the week of its start. Attended =
-- a going RSVP that checked in or self-reported. Returning = attended an
-- earlier event of the same chapter (any time, not just inside the window).
create or replace function public.chapter_dashboard(p_chapter uuid, p_weeks integer default 12)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_tz     constant text := 'America/New_York';
  v_last   date;
  v_first  date;
  v_weeks  jsonb;
  v_totals jsonb;
  v_members integer;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.hub_chapters where id = p_chapter) then
    raise exception 'chapter_not_found' using errcode = 'P0002';
  end if;
  if not (public.is_chapter_captain(p_chapter) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_weeks is null or p_weeks not between 1 and 52 then
    raise exception 'weeks_range' using errcode = 'check_violation', hint = '1 to 52 weeks.';
  end if;

  v_last  := date_trunc('week', now() at time zone v_tz)::date;
  v_first := v_last - 7 * (p_weeks - 1);

  with held as (
    select e.id, e.starts_at, date_trunc('week', e.starts_at at time zone v_tz)::date as week
      from public.events e
     where e.chapter_id = p_chapter and e.status = 'published' and e.ends_at <= now()
  ),
  going as (
    select h.id as event_id, h.starts_at, h.week, r.user_id,
           r.checked_in_at is not null as checked_in,
           r.checked_in_at is null and r.attended_self_reported_at is not null as self_reported,
           (r.checked_in_at is not null or r.attended_self_reported_at is not null) as attended
      from held h
      join public.rsvps r on r.event_id = h.id and r.status = 'going'
  ),
  att as (
    select g.*, exists (select 1 from going g2
                         where g2.attended and g2.user_id = g.user_id and g2.starts_at < g.starts_at) as is_returning
      from going g
     where g.attended and g.week between v_first and v_last
  ),
  weeks as (
    select v_first + 7 * i as week from generate_series(0, p_weeks - 1) as i
  ),
  per_week as (
    select w.week,
           (select count(*) from held h where h.week = w.week)::integer                       as events_held,
           (select count(*) from going g where g.week = w.week)::integer                      as going,
           (select count(*) from going g where g.week = w.week and g.checked_in)::integer     as checked_in,
           (select count(*) from going g where g.week = w.week and g.self_reported)::integer  as self_reported,
           (select count(distinct a.user_id) from att a where a.week = w.week)::integer       as distinct_attendees,
           (select count(distinct a.user_id) from att a where a.week = w.week and a.is_returning)::integer as returning_attendees
      from weeks w
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'week_start', pw.week, 'events_held', pw.events_held, 'going', pw.going,
           'checked_in', pw.checked_in, 'self_reported', pw.self_reported,
           'distinct_attendees', pw.distinct_attendees, 'returning_attendees', pw.returning_attendees)
           order by pw.week), '[]'::jsonb),
         jsonb_build_object(
           'events_held',   coalesce(sum(pw.events_held), 0),
           'going',         coalesce(sum(pw.going), 0),
           'checked_in',    coalesce(sum(pw.checked_in), 0),
           'self_reported', coalesce(sum(pw.self_reported), 0),
           'distinct_attendees',  (select count(distinct a.user_id) from att a),
           'returning_attendees', (select count(distinct a.user_id) from att a where a.is_returning))
    into v_weeks, v_totals
    from per_week pw;

  select count(*)::integer into v_members
    from public.chapter_members cm
    join public.profiles p on p.id = cm.user_id and p.status <> 'deleted'
   where cm.chapter_id = p_chapter;

  return jsonb_build_object(
    'chapter_id', p_chapter,
    'weeks', p_weeks,
    'timezone', v_tz,
    'from', v_first,
    'to', v_last + 6,
    'members_count', v_members,
    'totals', v_totals,
    'by_week', v_weeks);
end $$;

comment on function public.chapter_dashboard(uuid, integer) is
  'Attendance numbers for a chapter''s organizers, captains and moderators; counts only, never names. by_week (Monday weeks in America/New_York, oldest first, p_weeks 1 to 52): events_held (published and ended), going, checked_in, self_reported (attended without a check-in), distinct_attendees (checked in or self-reported), returning_attendees (attended an earlier chapter event). Plus totals over the window and members_count. Errors: not_authenticated, chapter_not_found, forbidden, weeks_range.';

-- ---------------------------------------------------------------------------
-- 6. request_account_deletion: attendance reports and meets
--    (body of migration 18, 20261114000100, plus the attendance lines)
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
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships, chapter claims, notifications, attendance reports, meets naming the caller (either direction) and the city waitlist row removed, claimed_by / reviewed_by / checked_in_by / notification actor / broadcast sender references cleared, hosted series and future events cancelled with their addresses (attendees notified), private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 7. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.submit_attendance(uuid, boolean, uuid[]) from public, anon;
grant execute on function public.submit_attendance(uuid, boolean, uuid[]) to authenticated;
revoke all on function public.dismiss_attendance_prompt(uuid) from public, anon;
grant execute on function public.dismiss_attendance_prompt(uuid) to authenticated;
revoke all on function public.pending_attendance_prompts() from public, anon;
grant execute on function public.pending_attendance_prompts() to authenticated;
revoke all on function public.chapter_dashboard(uuid, integer) from public, anon;
grant execute on function public.chapter_dashboard(uuid, integer) to authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.16')
  on conflict (key) do update set value = excluded.value, updated_at = now();
