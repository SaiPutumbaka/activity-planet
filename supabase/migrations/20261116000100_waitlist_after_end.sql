-- ============================================================================
-- Activity Planet schema v2 — migration 21: no waitlist promotion once an
--   event has ended (review fix for migration 20).
--
--   What this file does
--     * rsvp_promote_waitlist: body of migration 18 (20261114000100; 19 and
--       20 did not change it) with one change: it also returns 0 when the
--       event has ended (ends_at <= now()). Before this, a going attendee
--       cancelling after the end promoted the first waitlisted person to
--       going, which migration 20 reads as "was confirmed going while the
--       event ran" (submit_attendance, pending_attendance_prompts,
--       chapter_dashboard). request_account_deletion already only promotes
--       for events with ends_at > now().
--     * meta.schema_version 2.17.
--
--   Idempotent: safe to re-run.
-- ============================================================================

create or replace function public.rsvp_promote_waitlist(p_event_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e          public.events%rowtype;
  v_going    integer;
  v_user     uuid;
  v_promoted integer := 0;
begin
  select * into e from public.events where id = p_event_id for update;
  if not found or e.status = 'cancelled' or e.ends_at <= now() then
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

revoke all on function public.rsvp_promote_waitlist(uuid) from public, anon, authenticated;

-- Version stamp (last)
insert into public.meta (key, value) values ('schema_version', '2.17')
  on conflict (key) do update set value = excluded.value, updated_at = now();
