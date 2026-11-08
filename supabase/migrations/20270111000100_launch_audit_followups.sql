-- ============================================================================
-- Activity Planet schema v2 — migration 79: launch audit follow-ups
--   (docs/ops/launch-audit-2026-11.md, review of migrations 77 and 78).
--   Builds on migrations 1 to 78, which reached staging and are not edited.
--   Rebuilt functions start from their latest bodies (named below); each
--   change is marked "Migration 79". Checks:
--   supabase/tests/launch_audit_followups.sql.
--
--     1. email_budget_take (migration 77 body): verification codes and the
--        weekly scorecard leave meta.email_staff_reserve of the day for the
--        moderation and operations alerts, as notification email already
--        does. Many code requests can no longer use the whole day's budget.
--     2. event_owner_ok takes the plan's id (event_owner_ok(event)) instead
--        of a hub and a profile id, so it is no longer a public lookup of
--        whether any profile is banned or any hub is active. It answers only
--        for a plan, which the read rules hide in the same cases. The events
--        read policies and can_read_event (migration 78 bodies) use it; the
--        two-argument function is dropped after them.
--     3. set_rsvp (migration 78 body): a plan whose host is banned answers
--        event_not_found (PT404) to everyone but its host and moderators, as
--        the read rules already hide it (the host no longer hears of joins).
--     4. meta.schema_version 2.75.
--
--   Account deletion: no new table and no user-referencing column.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Email budget: the staff reserve (migration 77 body, 20270109000100_launch_audit_ops.sql)
-- ---------------------------------------------------------------------------
create or replace function public.email_budget_take(p_source text, p_n integer default 1)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  v_n integer := greatest(1, least(coalesce(p_n, 1), 10));
begin
  if p_source is null or p_source not in ('verification', 'scorecard') then
    raise exception 'invalid_source' using errcode = 'check_violation';
  end if;
  perform pg_advisory_xact_lock(hashtext('ap.email_budget'));
  -- Migration 79: meta.email_staff_reserve of the day stays for the moderation and operations
  -- alerts, as it does for notification email.
  if private.email_budget_room() - private.email_meta_int('email_staff_reserve', 10) < v_n then
    return false;
  end if;
  perform private.email_budget_add(p_source, v_n);
  return true;
end $$;
comment on function public.email_budget_take(text, integer) is
  'Migration 77, 79, service role (send-verification-code, weekly-scorecard): takes p_n (1 to 10) emails of the account-wide budget for p_source (verification | scorecard), leaving meta.email_staff_reserve of the day for moderation and operations alerts. False, and nothing counted, when the day or month is used up; the caller then sends nothing.';


-- ---------------------------------------------------------------------------
-- 2. event_owner_ok by plan id
-- ---------------------------------------------------------------------------
create or replace function public.event_owner_ok(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((
    select exists (select 1 from public.hubs h where h.id = e.hub_id and h.is_active)
       and (e.host_id is null
            or not exists (select 1 from public.profiles p where p.id = e.host_id and p.status = 'banned'))
      from public.events e
     where e.id = p_event), false);
$$;
comment on function public.event_owner_ok(uuid) is
  'Migration 79: whether plan p_event may be listed: its hub is active and its host (null for imported rows) is not banned. False for an unknown id. Used by the events read policies, can_read_event and set_rsvp. Replaces the migration 78 event_owner_ok(hub, host), which answered for any profile id.';

drop policy if exists "events_select_anon" on public.events;
create policy "events_select_anon" on public.events for select to anon
  using (status = 'published' and visibility = 'public' and min_age = 18
         and moderation_state is null    -- Migration 51
         and public.event_owner_ok(id));   -- Migration 78, 79
drop policy if exists "events_select_authenticated" on public.events;
create policy "events_select_authenticated" on public.events for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      moderation_state is null   -- Migration 51
      and public.event_owner_ok(id)   -- Migration 78, 79
      and ((status = 'published' and (select public.viewer_is_adult())) or public.viewer_has_rsvp(id))
      and min_age <= (select public.viewer_age())
      and (visibility = 'public' or public.is_campus_org_member(campus_id))
    )
  );



-- can_read_event (migration 78 body, 20270110000100_launch_audit_safety.sql)
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
           and public.event_owner_ok(e.id)   -- Migration 78, 79
           and ((e.status = 'published' and public.viewer_is_adult()) or public.viewer_has_rsvp(e.id))
           and e.min_age <= public.viewer_age()
           and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id))
         )
       )
  );
$$;

drop function if exists public.event_owner_ok(uuid, uuid);


-- ---------------------------------------------------------------------------
-- 3. set_rsvp (migration 78 body, 20270110000100_launch_audit_safety.sql)
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
  -- Migration 79: nor does a plan whose host is banned (event_owner_ok, as the read rules).
  if not v_mod and uid is distinct from e.host_id
     and (e.moderation_state is not null
          or not public.event_owner_ok(e.id)) then   -- Migration 79
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
-- Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
-- The read policies call it as the reader, so anon and authenticated keep execute.
revoke all on function public.event_owner_ok(uuid) from public;
grant execute on function public.event_owner_ok(uuid) to anon, authenticated, service_role;
-- Rebuilt.
revoke all on function public.email_budget_take(text, integer) from public, anon, authenticated;
grant execute on function public.email_budget_take(text, integer) to service_role;
revoke all on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) from public, anon;
grant execute on function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status) to authenticated, service_role;
revoke all on function public.can_read_event(uuid) from public, anon;
grant execute on function public.can_read_event(uuid) to authenticated;

insert into public.meta (key, value) values ('schema_version', '2.75')
  on conflict (key) do update set value = excluded.value, updated_at = now();
