-- ============================================================================
-- Activity Planet schema v2 — migration 7: RSVP without the photo gate (D-032)
--
--   set_rsvp from migration 6 refused the first RSVP until the profile had a
--   photo (PLAN 4.1's photo rule). D-032 keeps that rule for messaging
--   (week 5): the first RSVP only needs the Community Guidelines accepted.
--   This file re-creates public.set_rsvp exactly as migration 6 wrote it minus
--   the photo_required check; guidelines_required, the age, campus, membership,
--   capacity and waitlist rules are unchanged. Grants on the function survive
--   create or replace. Bumps meta.schema_version to 2.7.
-- ============================================================================

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

  if v_was = 'going' and r.status <> 'going' then
    perform public.rsvp_promote_waitlist(p_event_id);
  end if;
  return r;
end $$;

comment on function public.set_rsvp(uuid, public.rsvp_status) is
  'Sets the caller''s RSVP on one occurrence: going (or waitlisted when full and the waitlist is on), interested, cancelled (always allowed; returns null when there was no row). Atomic against capacity; promotes the waitlist when a going seat frees up. Errors: not_authenticated, invalid_status, event_not_found, onboarding_required, guidelines_required, removed_by_host, age_restricted, not_campus_member, event_cancelled, event_over, not_chapter_member, not_hub_member, event_full.';

insert into public.meta (key, value) values ('schema_version', '2.7')
  on conflict (key) do update set value = excluded.value, updated_at = now();
