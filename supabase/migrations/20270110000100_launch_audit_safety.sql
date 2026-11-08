-- ============================================================================
-- Activity Planet schema v2 — migration 78: launch audit, safety
--   (docs/ops/launch-audit-2026-11.md, findings M1, M2, M3, M12, M14, L1).
--   Builds on migrations 1 to 77, which reached staging (77 with this file)
--   and are not edited. Rebuilt functions start from their latest bodies
--   (named below); each change is marked "Migration 78". Checks:
--   supabase/tests/launch_audit_safety.sql.
--
--     1. private.chat_shared_context (migration 60 body): a shared chapter
--        counts only when both joins are a day old and the hub is active and
--        not sensitive (the hub rule); a shared plan counts only through
--        RSVPs a day old or approved by the host. A new account can no longer
--        skip message requests by joining a chapter or RSVPing (M1).
--     2. set_rsvp (migration 70 body): a plan a moderator hid or removed, or
--        one in an inactive hub, answers event_not_found (PT404) to everyone
--        but its host and moderators (M2). Leaving still works.
--     3. event_owner_ok(hub, host): the hub is active and the host is not
--        banned. events_select_anon, events_select_authenticated and
--        can_read_event (migration 51 bodies) require it for everyone but the
--        host and moderators (L1). A deleted host's past plans stay readable
--        as history under "Deleted user" (D-031).
--     4. chat_classifier_reserve (migration 73 body): at most
--        meta.chat_classifier_user_daily (default 5) of one sender's photos a
--        day reach Sightengine and at most meta.chat_classifier_daily_cap
--        (default 60) operations a UTC day (collector_budget source
--        sightengine_ops_day, reservations, no user id); past either the photo
--        waits for a moderator, as past the monthly cap (M3). Staging's caps
--        are lowered once (monthly 200, daily 20) where still at defaults.
--     5. export_my_data() (M12, GDPR and UK GDPR portability): the caller's
--        own rows as one JSON document, never another person's data beyond
--        ids the caller already holds.
--     6. Copyright (M14): reports.reason gains copyright; report_content
--        (migration 70 body) takes it; mod_copyright_strikes(user) counts the
--        upheld copyright reports about a person in the last 3 years (repeat
--        infringer policy, Terms).
--     7. meta.schema_version 2.74.
--
--   Account deletion: no new table and no user-referencing column.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Shared context for direct messages
-- ---------------------------------------------------------------------------

-- private.chat_shared_context (migration 60 body, 20261224000100_coaching.sql)
create or replace function private.chat_shared_context(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_a is not null and p_b is not null and p_a <> p_b and (
    exists (
      select 1
        -- Migration 78: an RSVP counts once it is a day old or the host approved it.
        from (select r.event_id from public.rsvps r
               where r.user_id = p_a and r.status in ('going', 'waitlisted') and r.removed_at is null
                 and (r.created_at <= now() - interval '24 hours' or r.approved_by_host)
              union select e.id from public.events e where e.host_id = p_a) xa
        join (select r.event_id from public.rsvps r
               where r.user_id = p_b and r.status in ('going', 'waitlisted') and r.removed_at is null
                 and (r.created_at <= now() - interval '24 hours' or r.approved_by_host)
              union select e.id from public.events e where e.host_id = p_b) xb on xb.event_id = xa.event_id
        join public.events e on e.id = xa.event_id
       where e.kind <> 'imported' and e.ends_at > now() - interval '180 days')
    or exists (
      select 1 from public.hub_members ha
        join public.hub_members hb on hb.hub_id = ha.hub_id and hb.user_id = p_b
        join public.hubs h on h.id = ha.hub_id
        join public.hub_categories c on c.slug = h.category_slug
       where ha.user_id = p_a and h.is_active and not c.is_sensitive
         and ha.joined_at <= now() - interval '24 hours' and hb.joined_at <= now() - interval '24 hours')
    or exists (
      select 1 from public.chapter_members ca
        join public.chapter_members cb on cb.chapter_id = ca.chapter_id and cb.user_id = p_b
        join public.hub_chapters ch on ch.id = ca.chapter_id
        -- Migration 78: the same rules as hubs: both joins a day old, never a sensitive hub.
        join public.hubs h on h.id = ch.hub_id
        join public.hub_categories c on c.slug = h.category_slug
       where ca.user_id = p_a and ch.is_active and h.is_active and not c.is_sensitive
         and ca.joined_at <= now() - interval '24 hours' and cb.joined_at <= now() - interval '24 hours')
    or exists (
      select 1 from public.event_meets m1
        join public.event_meets m2 on m2.event_id = m1.event_id and m2.user_id = p_b and m2.met_user_id = p_a
       where m1.user_id = p_a and m1.met_user_id = p_b)
    or exists (
      select 1 from public.conversations c
       where c.kind = 'dm' and c.dm_key = private.chat_dm_key(p_a, p_b)
         and not exists (select 1 from public.message_requests r
                          where r.conversation_id = c.id and r.status <> 'accepted'))
    -- Migration 60: a booking between them (open, or ended in the last 180 days).
    or exists (
      select 1 from public.bookings b
       where ((b.coach_id = p_a and b.client_id = p_b) or (b.coach_id = p_b and b.client_id = p_a))
         and (b.status in ('requested', 'confirmed')
              or (b.status in ('completed', 'no_show') and b.ends_at > now() - interval '180 days')))
  );
$$;


-- ---------------------------------------------------------------------------
-- 2. set_rsvp (migration 70 body, 20270102000100_write_not_found_404.sql)
-- ---------------------------------------------------------------------------
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
  -- Migration 78: a plan a moderator hid or removed, or one in a hub that is no longer active,
  -- does not exist for anyone but its host and moderators.
  if not v_mod and uid is distinct from e.host_id
     and (e.moderation_state is not null
          or not exists (select 1 from public.hubs h where h.id = e.hub_id and h.is_active)) then
    raise exception 'event_not_found' using errcode = 'PT404';
  end if;
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


-- ---------------------------------------------------------------------------
-- 3. Events of a removed hub or a banned host
-- ---------------------------------------------------------------------------
create or replace function public.event_owner_ok(p_hub uuid, p_host uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.hubs h where h.id = p_hub and h.is_active)
     and (p_host is null
          or not exists (select 1 from public.profiles p where p.id = p_host and p.status = 'banned'));
$$;
comment on function public.event_owner_ok(uuid, uuid) is
  'Migration 78: whether a plan of hub p_hub hosted by p_host may be listed: the hub is active and the host (null for imported rows) is not banned. Used by the events read policies and can_read_event.';

drop policy if exists "events_select_anon" on public.events;
create policy "events_select_anon" on public.events for select to anon
  using (status = 'published' and visibility = 'public' and min_age = 18
         and moderation_state is null    -- Migration 51
         and public.event_owner_ok(hub_id, host_id));   -- Migration 78
drop policy if exists "events_select_authenticated" on public.events;
create policy "events_select_authenticated" on public.events for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      moderation_state is null   -- Migration 51
      and public.event_owner_ok(hub_id, host_id)   -- Migration 78
      and ((status = 'published' and (select public.viewer_is_adult())) or public.viewer_has_rsvp(id))
      and min_age <= (select public.viewer_age())
      and (visibility = 'public' or public.is_campus_org_member(campus_id))
    )
  );


-- can_read_event (migration 51 body, 20261215000100_trust_safety.sql)
create or replace function public.can_read_event(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events e
     where e.id = p_event
       and (
         e.host_id = (select auth.uid())
         or public.is_moderator()
         or (
           e.moderation_state is null   -- Migration 51
           and public.event_owner_ok(e.hub_id, e.host_id)   -- Migration 78
           and ((e.status = 'published' and public.viewer_is_adult()) or public.viewer_has_rsvp(e.id))
           and e.min_age <= public.viewer_age()
           and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id))
         )
       )
  );
$$;


-- ---------------------------------------------------------------------------
-- 4. chat_classifier_reserve (migration 73 body, 20270105000100_chat_image_evidence_fixes.sql)
-- ---------------------------------------------------------------------------
create or replace function public.chat_classifier_reserve(p_path text, p_operations integer)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_month   date := date_trunc('month', now() at time zone 'utc')::date;
  v_cap     integer := private.chat_classifier_cap();
  v_n       integer := greatest(1, least(coalesce(p_operations, 1), 50));
  v_used    integer;
  v_pending boolean;
  v_today   date := (now() at time zone 'utc')::date;   -- Migration 78
  v_author  uuid;
begin
  v_pending := p_path is not null
    and exists (select 1 from public.messages m
                 where m.image_path = p_path and m.image_state in ('pending', 'classifying'))
    and exists (select 1 from public.image_hashes h
                 where h.bucket = 'chat-images' and h.path = p_path and h.status = 'hashed');
  if not v_pending then
    return jsonb_build_object('pending', false, 'allowed', false, 'cap', v_cap);
  end if;
  -- Migration 78: at most meta.chat_classifier_user_daily (default 5) of one sender's photos a
  -- day reach the classifier; the rest wait for a moderator, like photos past the cap.
  select m.author_id into v_author from public.messages m
   where m.image_path = p_path and m.image_state in ('pending', 'classifying') limit 1;
  if (select count(*) from public.messages m
       where m.author_id = v_author and m.kind = 'image' and m.image_path <> p_path
         and m.image_state is distinct from 'pending' and m.created_at > now() - interval '1 day')
     >= private.email_meta_int('chat_classifier_user_daily', 5) then
    return jsonb_build_object('pending', true, 'allowed', false, 'cap', v_cap, 'limit', 'user_daily');
  end if;
  insert into public.collector_budget (day, source, used) values (v_month, 'sightengine_ops', 0)
    on conflict (day, source) do nothing;
  update public.collector_budget set used = used + v_n
   where day = v_month and source = 'sightengine_ops' and used + v_n <= v_cap
  returning used into v_used;
  if not found then
    select b.used into v_used from public.collector_budget b
     where b.day = v_month and b.source = 'sightengine_ops';
    return jsonb_build_object('pending', true, 'allowed', false, 'used', v_used, 'cap', v_cap);
  end if;
  -- Migration 78: and under the day's share (meta.chat_classifier_daily_cap, default 60 operations),
  -- so a few senders cannot spend the month; past it the month's reservation is given back.
  insert into public.collector_budget (day, source, used) values (v_today, 'sightengine_ops_day', 0)
    on conflict (day, source) do nothing;
  update public.collector_budget set used = used + v_n
   where day = v_today and source = 'sightengine_ops_day'
     and used + v_n <= private.email_meta_int('chat_classifier_daily_cap', 60);
  if not found then
    update public.collector_budget set used = greatest(0, used - v_n)
     where day = v_month and source = 'sightengine_ops'
    returning used into v_used;
    return jsonb_build_object('pending', true, 'allowed', false, 'used', v_used, 'cap', v_cap, 'limit', 'daily');
  end if;
  -- Migration 73: the month, for chat_classifier_settle.
  return jsonb_build_object('pending', true, 'allowed', true, 'used', v_used, 'cap', v_cap, 'month', v_month);
end $$;


-- Staging's caps, once (staging and production share one Sightengine account until Sai says
-- otherwise). project_url is set on both projects by migrate.yml.
do $$
begin
  if public.project_url() like '%gzrscndzzggxmcwnvvcq%' then
    update public.meta set value = '200', updated_at = now()
     where key = 'chat_classifier_monthly_cap' and value = '1800';
    insert into public.meta (key, value) values ('chat_classifier_daily_cap', '20') on conflict (key) do nothing;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. export_my_data
-- ---------------------------------------------------------------------------
create or replace function public.export_my_data()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles where id = uid and status <> 'deleted' and deleted_at is null) then
    raise exception 'user_not_found' using errcode = 'PT404';
  end if;
  return jsonb_build_object(
    'format', 'activity-planet-export-1',
    'exported_at', now(),
    'profile', (select to_jsonb(p) from public.profiles p where p.id = uid),
    'private', (select (to_jsonb(pp) - 'location')
                       || jsonb_build_object('location', case when pp.location is not null
                                                               then extensions.st_astext(pp.location) end)
                  from public.profile_private pp where pp.user_id = uid),
    'legal_acceptance', (select to_jsonb(a) from public.legal_acceptances a where a.user_id = uid),
    'notification_prefs', (select to_jsonb(n) from public.notification_prefs n where n.user_id = uid),
    'recommendation_prefs', (select to_jsonb(r) from public.rec_prefs r where r.user_id = uid),
    'roles', (select coalesce(jsonb_agg(r.role), '[]'::jsonb) from public.user_roles r where r.user_id = uid),
    'verified_emails', (select coalesce(jsonb_agg(to_jsonb(v)), '[]'::jsonb) from public.verified_emails v where v.user_id = uid),
    'organizations', (select coalesce(jsonb_agg(to_jsonb(o) - 'granted_by'), '[]'::jsonb) from public.org_memberships o where o.user_id = uid),
    'hubs', (select coalesce(jsonb_agg(to_jsonb(h)), '[]'::jsonb) from public.hub_members h where h.user_id = uid),
    'chapters', (select coalesce(jsonb_agg(to_jsonb(c)), '[]'::jsonb) from public.chapter_members c where c.user_id = uid),
    'hub_requests', (select coalesce(jsonb_agg(to_jsonb(q) - 'reviewed_by'), '[]'::jsonb) from public.hub_requests q where q.user_id = uid),
    'rsvps', (select coalesce(jsonb_agg(to_jsonb(r) - 'removed_by' - 'checked_in_by'), '[]'::jsonb) from public.rsvps r where r.user_id = uid),
    'plans_hosted', (select coalesce(jsonb_agg(to_jsonb(e)), '[]'::jsonb) from public.events e where e.host_id = uid),
    'series_hosted', (select coalesce(jsonb_agg(to_jsonb(s)), '[]'::jsonb) from public.event_series s where s.host_id = uid),
    'attendance_reports', (select coalesce(jsonb_agg(to_jsonb(a)), '[]'::jsonb) from public.event_attendance_reports a where a.user_id = uid),
    'people_met', (select coalesce(jsonb_agg(to_jsonb(m)), '[]'::jsonb) from public.event_meets m where m.user_id = uid),
    'conversations', (select coalesce(jsonb_agg(to_jsonb(cm) - 'removed_by'), '[]'::jsonb) from public.conversation_members cm where cm.user_id = uid),
    'messages_sent', (select coalesce(jsonb_agg(to_jsonb(m) - 'client_id' - 'deleted_body' order by m.created_at desc), '[]'::jsonb)
                        from (select * from public.messages x where x.author_id = uid
                               order by x.created_at desc limit 5000) m),
    'bookings', (select coalesce(jsonb_agg(to_jsonb(b)), '[]'::jsonb) from public.bookings b
                  where b.client_id = uid or b.coach_id = uid),
    'coach_profile', (select to_jsonb(c) from public.coach_profiles c where c.user_id = uid),
    'reviews_written', (select coalesce(jsonb_agg(to_jsonb(r)), '[]'::jsonb) from public.coach_reviews r where r.client_id = uid),
    'places_added', (select coalesce(jsonb_agg(to_jsonb(p)), '[]'::jsonb) from public.places p where p.created_by = uid),
    'place_edits', (select coalesce(jsonb_agg(to_jsonb(p) - 'reviewed_by'), '[]'::jsonb) from public.place_edits p where p.proposed_by = uid),
    'reports_filed', (select coalesce(jsonb_agg(jsonb_build_object('target_kind', r.target_kind, 'reason', r.reason,
                                                                   'note', r.note, 'status', r.status, 'created_at', r.created_at)), '[]'::jsonb)
                        from public.reports r where r.reporter_id = uid),
    'blocked', (select coalesce(jsonb_agg(jsonb_build_object('user_id', b.blocked_id, 'created_at', b.created_at)), '[]'::jsonb)
                  from public.blocks b where b.blocker_id = uid),
    'muted', (select coalesce(jsonb_agg(jsonb_build_object('user_id', m.muted_id, 'created_at', m.created_at)), '[]'::jsonb)
                from public.mutes m where m.muter_id = uid),
    'devices', (select coalesce(jsonb_agg(jsonb_build_object('platform', d.platform, 'user_agent', d.user_agent,
                                                             'created_at', d.created_at, 'last_seen_at', d.last_seen_at,
                                                             'revoked_at', d.revoked_at)), '[]'::jsonb)
                  from public.push_devices d where d.user_id = uid),
    'notifications', (select coalesce(jsonb_agg(jsonb_build_object('kind', n.kind, 'created_at', n.created_at,
                                                                   'read_at', n.read_at, 'payload', n.payload - 'joiners')), '[]'::jsonb)
                        from public.notifications n where n.user_id = uid));
end $$;
comment on function public.export_my_data() is
  'Migration 78 (GDPR and UK GDPR art. 15 and 20): the caller''s own data as one JSON document: profile, private details, acceptance, settings, roles, verified emails, memberships, requests, RSVPs, plans and series hosted, attendance, conversations and the newest 5,000 messages sent, bookings, coach profile, reviews written, places and edits, reports filed (without the target), blocks, mutes, devices (no push keys) and notifications. Errors: not_authenticated, user_not_found.';

-- ---------------------------------------------------------------------------
-- 6. Copyright reports and strikes
-- ---------------------------------------------------------------------------
alter table public.reports drop constraint if exists reports_reason;
alter table public.reports add constraint reports_reason
  check (reason in ('harassment', 'hate', 'sexual_content', 'violence', 'spam', 'scam', 'impersonation',
                    'underage', 'unsafe', 'ncii', 'child_safety', 'other', 'no_show', 'payment', 'copyright'));

create or replace function public.mod_copyright_strikes(p_user uuid)
returns integer language plpgsql stable security definer set search_path = '' as $$
begin
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return (select count(distinct (r.target_kind, r.target_id))::integer from public.reports r
           where r.target_user_id = p_user and r.reason = 'copyright' and r.status = 'actioned'
             and r.created_at > now() - interval '3 years');
end $$;
comment on function public.mod_copyright_strikes(uuid) is
  'Migration 78, moderators: the person''s upheld copyright reports (distinct items) in the last 3 years, for the repeat-infringer policy (Terms: an account with 3 is closed). Errors: forbidden.';


-- report_content (migration 70 body, 20270102000100_write_not_found_404.sql)
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
                                          'no_show', 'payment',   -- Migration 60: booking reports only
                                          'copyright')            -- Migration 78
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

-- ---------------------------------------------------------------------------
-- Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.event_owner_ok(uuid, uuid) from public;
grant execute on function public.event_owner_ok(uuid, uuid) to anon, authenticated, service_role;
revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;
revoke all on function public.mod_copyright_strikes(uuid) from public, anon;
grant execute on function public.mod_copyright_strikes(uuid) to authenticated;
-- Rebuilt.
revoke all on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) from public, anon;
grant execute on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) to authenticated, service_role;
revoke all on function public.can_read_event(uuid) from public, anon;
grant execute on function public.can_read_event(uuid) to authenticated;
revoke all on function public.chat_classifier_reserve(text, integer) from public, anon, authenticated;
grant execute on function public.chat_classifier_reserve(text, integer) to service_role;
revoke all on function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text) from public, anon;
grant execute on function public.report_content(p_kind text, p_id uuid, p_reason text, p_note text) to authenticated, service_role;

insert into public.meta (key, value) values ('schema_version', '2.74')
  on conflict (key) do update set value = excluded.value, updated_at = now();
