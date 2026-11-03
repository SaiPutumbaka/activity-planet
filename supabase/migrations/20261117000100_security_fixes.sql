-- ============================================================================
-- Activity Planet schema v2 — migration 22: security review fixes
--   (PLAN.md 4.9; D-035 to D-037). Fixes forward; every rebuilt function
--   starts from its latest body (named below) and changes only the lines
--   for its finding. Regression checks: supabase/tests/security_fixes.sql.
--
--   What this file does
--     1. Under-21 captain (high). viewer_can_manage(host, chapter, min_age):
--        a moderator, or the host or a captain/organizer of the chapter whose
--        age is at least the event's min_age. viewer_can_manage_event uses
--        it, so host_check_in and broadcast_to_event (which call it) follow.
--        update_event (mig. 19), update_event_series (mig. 6), cancel_event,
--        cancel_event_series, approve_rsvp (mig. 18), remove_rsvp,
--        event_attendees (mig. 6) use it instead of host/moderator/captain.
--        update_event and update_event_series refuse a lower min_age unless
--        the caller is the host or a moderator. attendee_joined skips managers
--        under the event's min_age (notify_event_managers_joined, mig. 18).
--        The captain branches of event_series_select and
--        event_addresses_select_authenticated use viewer_can_manage.
--     2. upsert_venue (mig. 10): a client-supplied place_id never returns
--        another user's public venue unless its stored point is within 300 m
--        of the lat/lng the caller sent; otherwise the caller gets a new
--        venue. venues_public_place_id_key (one public row per place_id) is
--        replaced by venues_public_place_id_owner_key (one public row per
--        place_id per creator): a squatted place_id can no longer block an
--        honest host from creating the public venue, and duplicates are only
--        shared by proximity. Making colliding rows private was rejected:
--        it would turn a real public place into an approved-only address.
--     3. cover_url / avatar_url: only this project's Storage public URLs
--        (<project_url>/storage/v1/object/public/<bucket>/<path>), or null.
--        project_url lives in public.meta (it is public: it ships in every
--        client bundle), written by set_project_url(), which migrate.yml
--        calls after each push with the project ref it already knows; this
--        file seeds it from the import-feed vault URL when that exists.
--        Avatars must sit in the owner's folder of the avatars bucket.
--        Enforced by triggers on events, event_series (cover_url) and
--        profiles (avatar_url) on insert and on change, so every RPC and the
--        direct profile update go through it; RPCs report the trigger's
--        constraint name (events_cover_url_storage,
--        event_series_cover_url_storage, profiles_avatar_url_storage).
--        Imported events are exempt: only the service-role importer writes
--        them, from moderator-configured sources. Existing bad values are set
--        to null here (exactly when project_url is known, else anything not
--        shaped like a Supabase Storage public URL) and again, exactly, by
--        set_project_url. With no project_url every new non-null URL is
--        refused (fail closed).
--     4. avatars bucket: avatars_public_read (anon and authenticated could
--        list the whole bucket) is dropped; avatars_list_own_folder lets a
--        signed-in user list only their own folder. Public object URLs need
--        no select policy and keep working.
--     5. create_verification_code (mig. 6): an address linked to another
--        account answers {status: sent, own: false, code: null, org...,
--        expires_at} — the same keys and status as a fresh code (which now
--        also carries own: false); only the caller's own address answers
--        already_verified with own true. send-verification-code relays both
--        as {status: sent, expires_at}.
--     6. 18+ at the database: viewer_is_adult() (active, onboarded, birth
--        date at least 18 years ago). Required by the authenticated select
--        policies on profiles (except the own row), rsvps, hub_members and
--        chapter_members (except own rows), event_addresses and events
--        (except the host and own-RSVP branches), and by can_read_event.
--        viewer_age() is no longer coalesced to 18 anywhere (events policy,
--        can_read_event, hub_members_insert_own, chapter_members_insert_own):
--        no birth date means no age. A not-yet-onboarded user still reads
--        their own profile, private row, memberships and RSVPs, and every
--        onboarding input (hubs, hub categories, areas, organizations,
--        campuses, reserved handles); complete_onboarding is a definer RPC.
--     7. event_updated (update_event): one dedupe key per event per UTC hour;
--        a later edit in the hour refreshes that hour's rows instead of adding
--        rows. An edit that changes the title or the place wording while
--        someone else is going or waitlisted counts toward the broadcast cap
--        (3 per event per rolling day, logged in event_broadcasts) and is
--        refused with broadcast_limit beyond it.
--     * meta.schema_version 2.18.
--
--   No new tables; no new user-referencing columns (account deletion
--   coverage is unchanged: event_broadcasts.sender_id is already cleared).
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Helpers: viewer_is_adult, viewer_can_manage
-- ---------------------------------------------------------------------------
create or replace function public.viewer_is_adult()
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1
      from public.profiles p
      join public.profile_private pp on pp.user_id = p.id
     where p.id = (select auth.uid())
       and p.status = 'active'
       and p.deleted_at is null
       and p.onboarding_completed_at is not null
       and pp.birth_date is not null
       and pp.birth_date <= (current_date - interval '18 years')::date
  );
$$;

comment on function public.viewer_is_adult() is
  'True when the caller''s profile is active, not deleted, onboarded and has a birth date at least 18 years ago. The database-side 18+ gate for reads (migration 22).';

create or replace function public.viewer_can_manage(p_host uuid, p_chapter uuid, p_min_age smallint)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and (
    public.is_moderator()
    or (
      (p_host = (select auth.uid()) or public.is_chapter_captain(p_chapter))
      and coalesce(public.viewer_age() >= p_min_age, false)
    )
  );
$$;

comment on function public.viewer_can_manage(uuid, uuid, smallint) is
  'Manager rule for an event or series: a moderator, or the host or a captain/organizer of its chapter who is at least its min_age (migration 22).';

-- viewer_can_manage_event: body of migration 16 with the shared rule.
create or replace function public.viewer_can_manage_event(p_event_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.events e
     where e.id = p_event_id
       and public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age)
  );
$$;

comment on function public.viewer_can_manage_event(uuid) is
  'True when the caller is a moderator, or the host or a captain or organizer of the event''s chapter who is at least the event''s min_age (migration 22).';

-- can_read_event: body of migration 6; published events need an adult viewer
-- (the own-RSVP branch does not), and no birth date means no age.
create or replace function public.can_read_event(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events e
     where e.id = p_event
       and (
         e.host_id = (select auth.uid())
         or public.is_moderator()
         or (
           ((e.status = 'published' and public.viewer_is_adult()) or public.viewer_has_rsvp(e.id))
           and e.min_age <= public.viewer_age()
           and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id))
         )
       )
  );
$$;

-- ---------------------------------------------------------------------------
-- 2. Manager paths (finding 1)
-- ---------------------------------------------------------------------------
-- update_event: body of migration 19 (20261114000200). Changes: the shared
-- manager rule; only the host or a moderator lowers min_age; the
-- event_updated hourly key and the broadcast cap (finding 7).
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
  v_words   boolean;
  v_hour    text := to_char(date_trunc('hour', now() at time zone 'UTC'), 'YYYYMMDDHH24');
  v_changed jsonb;
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
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Lowering the age limit widens who sees the event: the host or a moderator only.
  if a ? 'min_age' and (a ->> 'min_age')::smallint < e.min_age
     and not (coalesce(e.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can lower the age limit.';
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

  -- Notifications (migration 22): one event_updated row per attendee per
  -- event per UTC hour. A later edit in the same hour writes no new row; it
  -- refreshes the payload of that hour's rows (latest title, time and place,
  -- every kind of change so far) without resurfacing them. An edit that
  -- changes the title or the place wording (location_hint, location_text)
  -- while someone else is going or waitlisted counts toward the broadcast
  -- cap (3 per event per rolling day, logged in event_broadcasts), so host-
  -- chosen text cannot be pushed to attendees more often than a broadcast.
  v_time  := e.starts_at is distinct from v_old.starts_at or e.ends_at is distinct from v_old.ends_at;
  v_place := e.location_hint is distinct from v_old.location_hint
             or l.venue_id is distinct from v_venue
             or l.location_text is distinct from v_text;
  v_words := e.title is distinct from v_old.title
             or e.location_hint is distinct from v_old.location_hint
             or l.location_text is distinct from v_text;
  if v_words and exists (select 1 from public.rsvps r
                          where r.event_id = e.id and r.status in ('going', 'waitlisted')
                            and r.user_id is distinct from uid) then
    if (select count(*) from public.event_broadcasts
         where event_id = e.id and created_at > now() - interval '1 day') >= 3 then
      raise exception 'broadcast_limit' using errcode = 'check_violation',
        hint = 'Up to 3 messages or title and place changes per event per day.';
    end if;
    insert into public.event_broadcasts (event_id, sender_id, body)
    values (e.id, uid, 'event_updated: ' || array_to_string(array_remove(array[
              case when e.title is distinct from v_old.title then 'title' end,
              case when e.location_hint is distinct from v_old.location_hint
                     or l.location_text is distinct from v_text then 'place' end], null), ', '));
  end if;
  if v_time or v_place then
    v_changed := to_jsonb(array_remove(array[case when v_time then 'time' end,
                                             case when v_place then 'place' end], null));
    perform public.notify_event_audience(
      e.id, 'event_updated', array['going', 'waitlisted']::public.rsvp_status[],
      e.id || ':' || v_hour,
      uid,
      jsonb_build_object('changed', v_changed));
    update public.notifications n
       set payload = n.payload || public.notification_event_payload(e.id)
                     || jsonb_build_object('changed', (
                          select coalesce(jsonb_agg(distinct x), '[]'::jsonb)
                            from jsonb_array_elements_text(coalesce(n.payload -> 'changed', '[]'::jsonb) || v_changed) x))
     where n.event_id = e.id and n.kind = 'event_updated'
       and n.dedupe_key like 'event_updated:' || e.id || ':' || v_hour || ':%';
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
  'Patches an event (keys present in p_args). Host, chapter captains and organizers at least the event''s min_age, and moderators; address keys and lowering min_age are host/moderator only. Narrowing eligibility cancels attendees who no longer qualify. A change of time or place queues event_updated for going and waitlisted attendees, one row per person per event per hour (later edits in the hour refresh it). A title or place-wording change with an audience counts toward the 3-per-day broadcast cap. Errors: not_authenticated, immutable_field, event_not_found, kind_not_allowed, forbidden, event_cancelled, event_over, capacity_below_going, broadcast_limit, events_cover_url_storage, plus the create_event validation codes.';

-- update_event_series: body of migration 6 (20261025000100). Changes: the
-- shared manager rule; only the host or a moderator lowers min_age.
create or replace function public.update_event_series(p_series_id uuid, p_args jsonb)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  s          public.event_series%rowtype;
  v_old      public.event_series%rowtype;
  v_key      text;
  v_allowed  text[] := array['title', 'description', 'cover_url', 'weekday', 'start_time', 'duration_minutes',
                             'timezone', 'starts_on', 'ends_on', 'max_occurrences', 'min_age', 'capacity',
                             'waitlist_enabled', 'min_headcount', 'members_only', 'is_free', 'price_text',
                             'visibility', 'campus_id', 'address_visibility', 'venue_id', 'location_text',
                             'address_note', 'location_hint'];
  v_schedule text[] := array['weekday', 'start_time', 'duration_minutes', 'timezone', 'starts_on', 'ends_on', 'max_occurrences'];
  v_address  text[] := array['address_visibility', 'venue_id', 'location_text', 'address_note'];
  v_campus   uuid;
  v_narrow   boolean;
  v_max      integer;
  v_occ      record;
  v_date     date;
  v_starts   timestamptz;
  v_c        text;
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

  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'P0002';
  end if;
  v_old := s;
  if not public.viewer_can_manage(s.host_id, s.chapter_id, s.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  -- Lowering the age limit widens who sees the event: the host or a moderator only.
  if a ? 'min_age' and (a ->> 'min_age')::smallint < s.min_age
     and not (coalesce(s.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can lower the age limit.';
  end if;
  if a ?| v_address and not (coalesce(s.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can change the address.';
  end if;
  if s.status = 'cancelled' then
    raise exception 'series_cancelled' using errcode = 'check_violation';
  end if;

  if a ? 'title'              then s.title              := btrim(coalesce(a ->> 'title', '')); end if;
  if a ? 'description'        then s.description        := btrim(coalesce(a ->> 'description', '')); end if;
  if a ? 'cover_url'          then s.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), ''); end if;
  if a ? 'weekday'            then s.weekday            := (a ->> 'weekday')::smallint; end if;
  if a ? 'start_time'         then s.start_time         := (a ->> 'start_time')::time; end if;
  if a ? 'duration_minutes'   then s.duration_minutes   := (a ->> 'duration_minutes')::integer; end if;
  if a ? 'timezone'           then s.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), s.timezone); end if;
  if a ? 'starts_on'          then s.starts_on          := coalesce((a ->> 'starts_on')::date, s.starts_on); end if;
  if a ? 'ends_on'            then s.ends_on            := (a ->> 'ends_on')::date; end if;
  if a ? 'max_occurrences'    then s.max_occurrences    := (a ->> 'max_occurrences')::integer; end if;
  if a ? 'min_age'            then s.min_age            := (a ->> 'min_age')::smallint; end if;
  if a ? 'capacity'           then s.capacity           := (a ->> 'capacity')::integer; end if;
  if a ? 'waitlist_enabled'   then s.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, s.waitlist_enabled); end if;
  if a ? 'min_headcount'      then s.min_headcount      := (a ->> 'min_headcount')::integer; end if;
  if a ? 'members_only'       then s.members_only       := coalesce((a ->> 'members_only')::boolean, s.members_only); end if;
  if a ? 'is_free'            then s.is_free            := coalesce((a ->> 'is_free')::boolean, s.is_free); end if;
  if a ? 'price_text'         then s.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), ''); end if;
  if a ? 'visibility'         then s.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, s.visibility); end if;
  if a ? 'campus_id'          then s.campus_id          := (a ->> 'campus_id')::uuid; end if;
  if a ? 'venue_id'           then s.venue_id           := (a ->> 'venue_id')::uuid; end if;
  if a ? 'address_visibility' then s.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, s.address_visibility);
  elsif a ? 'venue_id'        then s.address_visibility := public.default_address_visibility(s.venue_id); end if;
  if a ? 'location_text'      then s.location_text      := btrim(coalesce(a ->> 'location_text', '')); end if;
  if a ? 'address_note'       then s.address_note       := btrim(coalesce(a ->> 'address_note', '')); end if;
  if a ? 'location_hint'      then s.location_hint      := btrim(coalesce(a ->> 'location_hint', '')); end if;

  if s.title = '' then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(s.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(s.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if s.weekday is null or s.weekday not between 0 and 6 then
    raise exception 'weekday_invalid' using errcode = 'check_violation';
  end if;
  if s.start_time is null then
    raise exception 'start_time_required' using errcode = 'check_violation';
  end if;
  if s.duration_minutes is null or s.duration_minutes not between 15 and 1440 then
    raise exception 'duration_invalid' using errcode = 'check_violation';
  end if;
  if not public.is_valid_timezone(s.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if s.ends_on is not null and s.ends_on < s.starts_on then
    raise exception 'invalid_date_range' using errcode = 'check_violation';
  end if;
  if s.capacity is not null and s.min_headcount is not null and s.min_headcount > s.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  if a ? 'capacity' and s.capacity is not null then
    select max(going_count) into v_max from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;
    if coalesce(v_max, 0) > s.capacity then
      raise exception 'capacity_below_going' using errcode = 'check_violation',
        hint = v_max || ' people are already going to one occurrence.';
    end if;
  end if;

  v_campus := public.event_rules_check(
    s.kind, s.hub_id, s.chapter_id, s.visibility, s.campus_id, s.min_age, s.venue_id, s.location_text, s.address_visibility);

  update public.event_series
     set title = s.title, description = s.description, cover_url = s.cover_url, weekday = s.weekday,
         start_time = s.start_time, duration_minutes = s.duration_minutes, timezone = s.timezone,
         starts_on = s.starts_on, ends_on = s.ends_on, max_occurrences = s.max_occurrences,
         min_age = s.min_age, capacity = s.capacity, waitlist_enabled = s.waitlist_enabled,
         min_headcount = s.min_headcount, members_only = s.members_only, is_free = s.is_free,
         price_text = s.price_text, visibility = s.visibility, campus_id = v_campus,
         address_visibility = s.address_visibility, venue_id = s.venue_id,
         location_text = s.location_text, address_note = s.address_note, location_hint = s.location_hint
   where id = s.id
   returning * into s;

  -- Lock the future occurrences first so a set_rsvp that commits while we
  -- wait is seen by the statements below (they take fresh snapshots).
  perform 1 from public.events
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
   for update;

  if a ?| v_schedule then
    -- Nobody but the host has committed: regenerate from the template.
    delete from public.events e
     where e.series_id = s.id
       and e.status = 'published'
       and e.starts_at > now()
       and e.detached_at is null
       and not exists (
         select 1 from public.rsvps r
          where r.event_id = e.id
            and r.status <> 'cancelled'
            and r.user_id is distinct from e.host_id
       );
    -- Occurrences with attendees move to the new wall-clock slot in their
    -- week, or are cancelled when the new dates no longer cover them.
    for v_occ in
      select id, occurrence_date from public.events
       where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
       order by occurrence_date
    loop
      v_date   := v_occ.occurrence_date + (s.weekday - v_old.weekday);
      v_starts := (v_date + s.start_time) at time zone s.timezone;
      if v_starts <= now() or v_date < s.starts_on or (s.ends_on is not null and v_date > s.ends_on) then
        update public.events
           set status = 'cancelled', cancelled_at = now(), cancel_reason = 'The weekly schedule changed.'
         where id = v_occ.id;
      else
        update public.events
           set occurrence_date = v_date,
               starts_at       = v_starts,
               ends_at         = v_starts + make_interval(mins => s.duration_minutes),
               timezone        = s.timezone
         where id = v_occ.id;
      end if;
    end loop;
  end if;

  -- Template fields reach every remaining future occurrence.
  update public.events
     set title = s.title, description = s.description, cover_url = s.cover_url, min_age = s.min_age,
         capacity = s.capacity, waitlist_enabled = s.waitlist_enabled, min_headcount = s.min_headcount,
         members_only = s.members_only, is_free = s.is_free, price_text = s.price_text,
         visibility = s.visibility, campus_id = s.campus_id, address_visibility = s.address_visibility
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;

  v_narrow := (a ? 'min_age' and s.min_age = 21)
           or (a ? 'visibility' and s.visibility = 'campus')
           or (a ? 'campus_id')
           or (a ? 'members_only' and s.members_only);
  for v_occ in
    select id from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
  loop
    perform public.event_set_location(v_occ.id, s.venue_id, s.location_text, s.address_note,
                                      s.address_visibility, s.location_hint, s.campus_id);
    if v_narrow then
      perform public.event_drop_ineligible_rsvps(v_occ.id);
    end if;
    perform public.rsvp_promote_waitlist(v_occ.id);
  end loop;

  perform public.materialize_event_series(s.id, 8);
  return s;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.update_event_series(uuid, jsonb) is
  'Patches a weekly series: template fields are pushed to every future non-detached occurrence; a schedule change regenerates occurrences without attendees and shifts the others in place. Host, captains and organizers at least the series'' min_age, and moderators; lowering min_age is host/moderator only. Errors: not_authenticated, immutable_field, series_not_found, forbidden, series_cancelled, capacity_below_going, event_series_cover_url_storage, plus the create_event_series validation codes.';

-- cancel_event: body of migration 18 (20261114000100); the shared manager rule.
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
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
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

-- cancel_event_series: body of migration 18; the shared manager rule.
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
  if not public.viewer_can_manage(s.host_id, s.chapter_id, s.min_age) then
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

-- approve_rsvp: body of migration 18; the shared manager rule.
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
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
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

-- remove_rsvp: body of migration 6; the shared manager rule.
create or replace function public.remove_rsvp(p_event_id uuid, p_user_id uuid, p_reason text default null)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id = e.host_id then
    raise exception 'cannot_remove_host' using errcode = 'check_violation';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'P0002';
  end if;
  update public.rsvps
     set status            = 'cancelled',
         waitlist_position = null,
         approved_by_host  = false,
         removed_by        = uid,
         removed_at        = now(),
         removed_reason    = left(nullif(btrim(coalesce(p_reason, '')), ''), 200)
   where event_id = p_event_id and user_id = p_user_id
   returning * into r;
  perform public.rsvp_promote_waitlist(p_event_id);
  return r;
end $$;

-- event_attendees: body of migration 6; the full list follows the shared
-- manager rule.
create or replace function public.event_attendees(p_event_id uuid)
returns setof public.rsvps language sql stable security definer set search_path = '' as $$
  select r.*
    from public.rsvps r
    join public.events e on e.id = r.event_id
   where r.event_id = p_event_id
     and (select auth.uid()) is not null
     and public.can_read_event(p_event_id)
     and (
       r.user_id = (select auth.uid())
       or (
         r.status <> 'cancelled'
         and public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age)
       )
     )
   order by r.status, r.waitlist_position nulls first, r.created_at;
$$;

-- notify_event_managers_joined: body of migration 18; managers below the
-- event's min_age get nothing about it.
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
       -- Never a manager below the event's age limit (migration 22).
       and exists (select 1 from public.profile_private pp
                    where pp.user_id = x.user_id
                      and pp.birth_date <= (current_date - make_interval(years => e.min_age))::date)
  loop
    if public.enqueue_notification(v_user, 'attendee_joined',
                                   'attendee_joined:' || p_event_id || ':' || v_user || ':' || v_hour,
                                   p_event_id, e.hub_id, e.chapter_id, p_joiner, v_payload, true) is not null then
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Venues: no place_id takeover (finding 2)
-- ---------------------------------------------------------------------------
-- One public row per place_id per creator. The old index (one public row per
-- place_id) let whoever saved a place first own it for everyone.
create unique index if not exists venues_public_place_id_owner_key
  on public.venues (place_id, created_by) where place_id is not null and is_public;
drop index if exists public.venues_public_place_id_key;

-- upsert_venue: body of migration 10 (20261111000100); only the public
-- place_id lookup changed.
create or replace function public.upsert_venue(p_args jsonb)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v          public.venues%rowtype;
  v_mod      boolean;
  v_name     text := btrim(coalesce(a ->> 'name', ''));
  v_addr1    text := btrim(coalesce(a ->> 'address_line1', ''));
  v_addr2    text := btrim(coalesce(a ->> 'address_line2', ''));
  v_city     text := btrim(coalesce(a ->> 'city', ''));
  v_state    text := btrim(coalesce(a ->> 'state', ''));
  v_postal   text := btrim(coalesce(a ->> 'postal_code', ''));
  v_country  text := upper(coalesce(nullif(btrim(coalesce(a ->> 'country', '')), ''), 'US'));
  v_place_id text := nullif(btrim(coalesce(a ->> 'place_id', '')), '');
  v_campus   uuid := (a ->> 'campus_id')::uuid;
  v_public   boolean;
  v_lat      double precision := (a ->> 'lat')::double precision;
  v_lng      double precision := (a ->> 'lng')::double precision;
  v_point    extensions.geography;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_mod    := public.is_moderator();
  v_public := coalesce((a ->> 'is_public')::boolean, false);   -- D-038: private unless the caller says so
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'name_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    raise exception 'country_invalid' using errcode = 'check_violation', hint = 'Two-letter country code.';
  end if;
  if (v_lat is null) <> (v_lng is null)
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  if v_campus is not null and not exists (select 1 from public.org_campuses where id = v_campus) then
    raise exception 'campus_not_found' using errcode = 'P0002';
  end if;

  -- Serialize concurrent creates of the same place; hashtext is stable per key.
  perform pg_advisory_xact_lock(hashtext('venue:' || coalesce(v_place_id, lower(v_name) || '|' || v_postal)));

  if v_public then
    -- A place_id is client-supplied, so it never hands over someone else's
    -- row by itself (migration 22): the caller's own public row for the
    -- place, else another public row whose stored point is within 300 m of
    -- the coordinates the caller sent. Otherwise the caller gets a new row.
    if v_place_id is not null then
      select * into v from public.venues
       where place_id = v_place_id and is_public and created_by = uid
       order by created_at
       limit 1;
      if v.id is null and v_point is not null then
        select * into v from public.venues x
         where x.place_id = v_place_id and x.is_public and x.location is not null
           and extensions.ST_DWithin(x.location, v_point, 300)
         order by extensions.ST_Distance(x.location, v_point), x.created_at
         limit 1;
      end if;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  else
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and not is_public and created_by = uid
       order by created_at limit 1;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and not is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  end if;

  if v.id is not null then
    if v.created_by = uid or v_mod then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             location      = coalesce(location, v_point),
             campus_id     = coalesce(campus_id, v_campus),
             place_id      = case when place_id is null and v_place_id is not null
                                   and not exists (select 1 from public.venues x where x.place_id = v_place_id and x.is_public)
                                  then v_place_id else place_id end
       where id = v.id
       returning * into v;
    end if;
    return v;
  end if;

  if not v_mod then
    perform pg_advisory_xact_lock(hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, address_line2, city, state, postal_code, country,
                             location, place_id, campus_id, created_by, is_public)
  values (v_name, v_addr1, v_addr2, v_city, v_state, v_postal, v_country,
          v_point, v_place_id, v_campus, uid, v_public)
  returning * into v;
  return v;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.upsert_venue(jsonb) is
  'Finds or creates a venue for the caller. New venues are private unless is_public = true is passed (D-038). Public requests match place_id among the caller''s own public venues, then among other public venues whose point is within 300 m of the lat/lng sent (never by place_id alone), then (name, postal code) among the caller''s own; private requests match the caller''s own private rows. Twenty new venues a day. Errors: not_authenticated, onboarding_required, name_required, name_length, country_invalid, invalid_coordinates, campus_not_found, too_many_venues, or a table constraint name.';

-- ---------------------------------------------------------------------------
-- 4. Image URLs: this project's Storage only (finding 3)
-- ---------------------------------------------------------------------------
-- The project's base URL (https://<ref>.supabase.co), or null when unknown.
create or replace function public.project_url()
returns text language sql stable security definer set search_path = '' as $$
  select nullif(value, '') from public.meta where key = 'project_url';
$$;

-- True for null, or for <project_url>/storage/v1/object/public/<bucket>/<path>
-- (p_bucket and p_owner, when given, pin the bucket and the first folder).
-- False for anything else, and for every URL while project_url is unknown.
create or replace function public.is_own_storage_url(p_url text, p_bucket text default null, p_owner uuid default null)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_base   text := public.project_url();
  v_prefix text;
  v_rest   text;
begin
  if p_url is null then
    return true;
  end if;
  if v_base is null then
    return false;
  end if;
  v_prefix := v_base || '/storage/v1/object/public/';
  if char_length(p_url) > 500 or left(p_url, char_length(v_prefix)) <> v_prefix then
    return false;
  end if;
  v_rest := substr(p_url, char_length(v_prefix) + 1);
  if v_rest !~ '^[a-z0-9][a-z0-9_-]{0,62}(/[A-Za-z0-9._~-]+)+$' or v_rest ~ '(^|/)\.\.?(/|$)' then
    return false;
  end if;
  if p_bucket is not null and split_part(v_rest, '/', 1) <> p_bucket then
    return false;
  end if;
  if p_owner is not null and (split_part(v_rest, '/', 2) <> p_owner::text or split_part(v_rest, '/', 3) = '') then
    return false;
  end if;
  return true;
end $$;

comment on function public.is_own_storage_url(text, text, uuid) is
  'True for null or a public object URL of this project''s Storage (meta.project_url), optionally in bucket p_bucket and folder p_owner. Every URL is refused while project_url is unknown (migration 22).';

-- Trigger: cover_url on events (not imported) and event_series.
create or replace function public.guard_cover_url()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.cover_url is not null
     and (tg_op = 'INSERT' or new.cover_url is distinct from old.cover_url)
     and not (tg_table_name = 'events' and new.kind = 'imported')
     and not public.is_own_storage_url(new.cover_url) then
    raise exception '%', tg_table_name || '_cover_url_storage'
      using errcode = 'check_violation', constraint = tg_table_name || '_cover_url_storage',
            hint = 'Cover images are uploaded to Activity Planet.';
  end if;
  return new;
end $$;

-- Trigger: profiles.avatar_url must be in the owner's avatars folder.
create or replace function public.guard_avatar_url()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.avatar_url is not null
     and (tg_op = 'INSERT' or new.avatar_url is distinct from old.avatar_url)
     and not public.is_own_storage_url(new.avatar_url, 'avatars', new.id) then
    raise exception 'profiles_avatar_url_storage'
      using errcode = 'check_violation', constraint = 'profiles_avatar_url_storage',
            hint = 'Profile photos are uploaded to Activity Planet.';
  end if;
  return new;
end $$;

drop trigger if exists events_guard_cover_url on public.events;
create trigger events_guard_cover_url before insert or update of cover_url on public.events
  for each row execute function public.guard_cover_url();
drop trigger if exists event_series_guard_cover_url on public.event_series;
create trigger event_series_guard_cover_url before insert or update of cover_url on public.event_series
  for each row execute function public.guard_cover_url();
drop trigger if exists profiles_guard_avatar_url on public.profiles;
create trigger profiles_guard_avatar_url before insert or update of avatar_url on public.profiles
  for each row execute function public.guard_avatar_url();

-- Nulls every stored image URL that is not under the project's Storage.
-- Exact when project_url is known; otherwise anything not shaped like a
-- Supabase Storage public URL (set_project_url then runs the exact pass).
create or replace function public.clear_foreign_image_urls()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_shape text := '^https://[a-z0-9]{20}\.supabase\.co/storage/v1/object/public/';
  v_known boolean := public.project_url() is not null;
  n_p integer;
  n_e integer;
  n_s integer;
begin
  update public.profiles p set avatar_url = null
   where p.avatar_url is not null
     and case when v_known then not public.is_own_storage_url(p.avatar_url, 'avatars', p.id)
              else p.avatar_url !~ (v_shape || 'avatars/' || p.id::text || '/') end;
  get diagnostics n_p = row_count;
  update public.events e set cover_url = null
   where e.cover_url is not null and e.kind <> 'imported'
     and case when v_known then not public.is_own_storage_url(e.cover_url)
              else e.cover_url !~ v_shape end;
  get diagnostics n_e = row_count;
  update public.event_series s set cover_url = null
   where s.cover_url is not null
     and case when v_known then not public.is_own_storage_url(s.cover_url)
              else s.cover_url !~ v_shape end;
  get diagnostics n_s = row_count;
  return jsonb_build_object('profiles', n_p, 'events', n_e, 'event_series', n_s);
end $$;

-- Written by migrate.yml for each project after the push (it knows the
-- project ref); also accepts a local stack URL. Only the migration owner can
-- call it. Clears every image URL that is not under the new base.
create or replace function public.set_project_url(p_url text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_url text := rtrim(btrim(coalesce(p_url, '')), '/');
begin
  if v_url !~ '^https://[a-z0-9]{20}\.supabase\.co$' and v_url !~ '^http://(127\.0\.0\.1|localhost):[0-9]{2,5}$' then
    raise exception 'invalid_project_url' using errcode = 'check_violation';
  end if;
  insert into public.meta (key, value) values ('project_url', v_url)
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return public.clear_foreign_image_urls();
end $$;

comment on function public.set_project_url(text) is
  'Migration owner only (migrate.yml). Stores this project''s base URL in meta.project_url, the root of the only image URLs accepted, and clears stored image URLs outside it. Returns the cleared counts.';

-- Seed project_url from the import-feed URL migrate.yml already wrote to the
-- vault (https://<ref>.supabase.co/functions/v1/import-feed), when present.
do $$
declare
  v_url text;
begin
  if public.project_url() is null and to_regclass('vault.decrypted_secrets') is not null then
    execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'import_feed_url' limit 1$q$
      into v_url;
    v_url := substring(v_url from '^(https://[a-z0-9]{20}\.supabase\.co)/functions/v1/import-feed$');
    if v_url is not null then
      insert into public.meta (key, value) values ('project_url', v_url)
        on conflict (key) do update set value = excluded.value, updated_at = now();
    end if;
  end if;
end $$;

select public.clear_foreign_image_urls();

-- ---------------------------------------------------------------------------
-- 5. avatars bucket: no public listing (finding 4)
-- ---------------------------------------------------------------------------
drop policy if exists "avatars_public_read" on storage.objects;
drop policy if exists "avatars_list_own_folder" on storage.objects;
create policy "avatars_list_own_folder" on storage.objects for select to authenticated
  using (bucket_id = 'avatars' and name like (select auth.uid())::text || '/%');

-- ---------------------------------------------------------------------------
-- 6. create_verification_code: one answer shape (finding 5)
-- ---------------------------------------------------------------------------
-- Body of migration 6 (20261025000100); only the already-verified branch and
-- the own key changed.
create or replace function public.create_verification_code(p_user_id uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_domain text;
  v_org    public.organizations%rowtype;
  v_last   timestamptz;
  v_hour   integer;
  v_addr   integer;
  v_owner  uuid;
  v_code   text;
  v_id     uuid;
  v_row    public.email_verification_codes%rowtype;
begin
  if not public.is_service_role() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id is null or v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 254 then
    raise exception 'invalid_email' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id and status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  -- Throttle before anything that could reveal state.
  perform pg_advisory_xact_lock(hashtext('verification:' || p_user_id::text));
  select max(last_sent_at),
         coalesce(sum(send_count) filter (where last_sent_at > now() - interval '1 hour'), 0)::integer
    into v_last, v_hour
    from public.email_verification_codes
   where user_id = p_user_id;
  select coalesce(sum(send_count), 0)::integer into v_addr
    from public.email_verification_codes
   where lower(email) = v_email and last_sent_at > now() - interval '1 hour';
  if v_last is not null and v_last > now() - interval '1 minute' then
    raise exception 'too_many_sends' using errcode = 'check_violation',
      hint = 'Wait a minute before asking for another code.';
  end if;
  if v_hour >= 3 or v_addr >= 3 then
    raise exception 'too_many_sends' using errcode = 'check_violation',
      hint = 'Three codes an hour. Try again later.';
  end if;

  v_domain := split_part(v_email, '@', 2);
  select o.* into v_org from public.organizations o
    join public.org_email_domains d on d.org_id = o.id
   where d.domain = v_domain;
  if v_org.id is null then
    raise exception 'domain_not_recognized' using errcode = 'check_violation',
      hint = 'Use the email address your school gave you.';
  end if;

  -- Already verified: write a dead, consumed row so the throttle still
  -- counts the request, and answer without a code. Only the caller's own
  -- address gets a distinct answer (already_verified, own true). Someone
  -- else's address gets exactly the shape of a fresh send (status sent, own
  -- false, an expiry) with no code (migration 22), so the Edge Function's
  -- response cannot tell a linked address from a free one; the email itself
  -- tells the address owner it is already linked.
  select user_id into v_owner from public.verified_emails where lower(email) = v_email;
  if v_owner is not null then
    insert into public.email_verification_codes
      (user_id, email, org_id, code_hmac, attempts, send_count, last_sent_at, expires_at, consumed_at)
    values
      (p_user_id, v_email, v_org.id, 'already-verified', 0, 1, now(), now(), now());
    if v_owner = p_user_id then
      return jsonb_build_object(
        'status', 'already_verified',
        'own', true,
        'code', null,
        'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
        'expires_at', null);
    end if;
    return jsonb_build_object(
      'status', 'sent',
      'own', false,
      'code', null,
      'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
      'expires_at', now() + interval '15 minutes');
  end if;

  -- Six digits from pgcrypto; the bias from % 1000000 on 32 random bits is negligible.
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');

  select * into v_row from public.email_verification_codes
   where user_id = p_user_id and lower(email) = v_email and consumed_at is null
   for update;
  if found then
    update public.email_verification_codes
       set code_hmac    = encode(extensions.digest(v_code || v_row.id::text, 'sha256'), 'hex'),
           org_id       = v_org.id,
           attempts     = 0,
           send_count   = case when last_sent_at > now() - interval '1 hour' then send_count + 1 else 1 end,
           last_sent_at = now(),
           expires_at   = now() + interval '15 minutes'
     where id = v_row.id
     returning * into v_row;
  else
    v_id := gen_random_uuid();
    insert into public.email_verification_codes
      (id, user_id, email, org_id, code_hmac, attempts, send_count, last_sent_at, expires_at)
    values
      (v_id, p_user_id, v_email, v_org.id, encode(extensions.digest(v_code || v_id::text, 'sha256'), 'hex'),
       0, 1, now(), now() + interval '15 minutes')
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'status', 'sent',
    'own', false,
    'code', v_code,
    'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
    'expires_at', v_row.expires_at);
end $$;

comment on function public.create_verification_code(uuid, text) is
  'Service role only. Issues a 6-digit code for a campus email (domain must be in org_email_domains), throttled to one send a minute and three an hour per user and per address, valid 15 minutes. Returns {status: sent, own: false, code, org_id, org_slug, org_name, expires_at}; for an address verified by another account the same shape with code null (the caller cannot tell it from a free address); only the caller''s own verified address returns {status: already_verified, own: true, code: null, ...}. Errors: forbidden, invalid_email, user_not_found, too_many_sends, domain_not_recognized.';

-- ---------------------------------------------------------------------------
-- 7. 18+ at the database (finding 6) and captain age in policies (finding 1)
-- ---------------------------------------------------------------------------
-- profiles: own row always (onboarding needs it); others only for adults.
drop policy if exists "profiles_read_authenticated" on public.profiles;
create policy "profiles_read_authenticated" on public.profiles for select to authenticated
  using (
    id = (select auth.uid())
    or (select public.is_moderator())
    or (deleted_at is null and (select public.viewer_is_adult()))
  );

-- hub_members: own rows always; others only for adults, and never in a
-- sensitive hub category.
drop policy if exists "hub_members_read" on public.hub_members;
create policy "hub_members_read" on public.hub_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      (select public.viewer_is_adult())
      and not exists (
        select 1 from public.hubs h
        join public.hub_categories c on c.slug = h.category_slug
        where h.id = hub_members.hub_id and c.is_sensitive
      )
    )
  );

-- chapter_members: same rule as hub_members.
drop policy if exists "chapter_members_read" on public.chapter_members;
create policy "chapter_members_read" on public.chapter_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      (select public.viewer_is_adult())
      and not exists (
        select 1 from public.hub_chapters ch
        join public.hubs h on h.id = ch.hub_id
        join public.hub_categories c on c.slug = h.category_slug
        where ch.id = chapter_members.chapter_id and c.is_sensitive
      )
    )
  );

-- events: host and moderators always; a published event needs an adult
-- viewer at least its min_age; the own-RSVP branch keeps a cancelled event
-- visible to its attendees. No birth date, no age (no coalesce to 18).
-- Mirrored by can_read_event().
drop policy if exists "events_select_authenticated" on public.events;
create policy "events_select_authenticated" on public.events for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      ((status = 'published' and (select public.viewer_is_adult())) or public.viewer_has_rsvp(id))
      and min_age <= (select public.viewer_age())
      and (visibility = 'public' or public.is_campus_org_member(campus_id))
    )
  );

-- event_addresses: host, moderators and approved going RSVPs; a public
-- address or a captain's view needs an adult (and for captains, the event's
-- min_age, via viewer_can_manage).
drop policy if exists "event_addresses_select_authenticated" on public.event_addresses;
create policy "event_addresses_select_authenticated" on public.event_addresses for select to authenticated
  using (exists (
    select 1 from public.events e
     where e.id = event_addresses.event_id
       and (
         e.host_id = (select auth.uid())
         or (select public.is_moderator())
         or public.viewer_is_approved(e.id)
         or (
           (select public.viewer_is_adult())
           and (e.address_visibility = 'public'
                or public.viewer_can_manage(e.host_id, e.chapter_id, e.min_age))
         )
       )
  ));

-- event_series: host and moderators; captains only at the series' min_age.
drop policy if exists "event_series_select" on public.event_series;
create policy "event_series_select" on public.event_series for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or public.viewer_can_manage(host_id, chapter_id, min_age)
  );

-- rsvps: own rows always; the attendee list only for adults (events is read
-- under its own policy here, so the event's age rule applies too).
drop policy if exists "rsvps_select" on public.rsvps;
create policy "rsvps_select" on public.rsvps for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      status <> 'cancelled'
      and (select public.viewer_is_adult())
      and exists (
        select 1 from public.events e
          join public.hubs h on h.id = e.hub_id
          join public.hub_categories c on c.slug = h.category_slug
         where e.id = rsvps.event_id
           and (
             not c.is_sensitive
             or e.host_id = (select auth.uid())
             or public.is_chapter_captain(e.chapter_id)
             or public.viewer_is_attending(e.id)
           )
      )
    )
  );

-- hub_members_insert_own: body of migration 6 without the coalesce to 18
-- (onboarding joins hubs through complete_onboarding, a definer RPC).
drop policy if exists "hub_members_insert_own" on public.hub_members;
create policy "hub_members_insert_own" on public.hub_members for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and (select public.viewer_is_adult())
    and exists (
      select 1 from public.hubs h
       where h.id = hub_id and h.is_active
         and h.min_age <= (select public.viewer_age())
    )
  );

-- chapter_members_insert_own: body of migration 11 without the coalesce to 18.
drop policy if exists "chapter_members_insert_own" on public.chapter_members;
create policy "chapter_members_insert_own" on public.chapter_members for insert to authenticated
  with check (
    user_id = (select auth.uid()) and role = 'member'
    and (select public.viewer_is_adult())
    and exists (
      select 1
        from public.hub_chapters c
        join public.hubs h on h.id = c.hub_id
       where c.id = chapter_id and c.is_active
         and h.is_active
         and h.min_age <= (select public.viewer_age())
         and (
           c.org_id is null
           or exists (
             select 1 from public.org_memberships m
              where m.org_id = c.org_id and m.user_id = (select auth.uid())
                and (m.expires_at is null or m.expires_at > now())
           )
         )
    )
  );

-- ---------------------------------------------------------------------------
-- 8. Privileges
-- ---------------------------------------------------------------------------
revoke all on function public.viewer_is_adult() from public, anon;
grant execute on function public.viewer_is_adult() to authenticated, service_role;
revoke all on function public.viewer_can_manage(uuid, uuid, smallint) from public, anon;
grant execute on function public.viewer_can_manage(uuid, uuid, smallint) to authenticated, service_role;
revoke all on function public.viewer_can_manage_event(uuid) from public, anon;
grant execute on function public.viewer_can_manage_event(uuid) to authenticated;
revoke all on function public.can_read_event(uuid) from public, anon;
grant execute on function public.can_read_event(uuid) to authenticated;
revoke all on function public.update_event(uuid, jsonb) from public, anon;
grant execute on function public.update_event(uuid, jsonb) to authenticated;
revoke all on function public.update_event_series(uuid, jsonb) from public, anon;
grant execute on function public.update_event_series(uuid, jsonb) to authenticated;
revoke all on function public.cancel_event(uuid, text) from public, anon;
grant execute on function public.cancel_event(uuid, text) to authenticated;
revoke all on function public.cancel_event_series(uuid, text) from public, anon;
grant execute on function public.cancel_event_series(uuid, text) to authenticated;
revoke all on function public.approve_rsvp(uuid, uuid, boolean) from public, anon;
grant execute on function public.approve_rsvp(uuid, uuid, boolean) to authenticated;
revoke all on function public.remove_rsvp(uuid, uuid, text) from public, anon;
grant execute on function public.remove_rsvp(uuid, uuid, text) to authenticated;
revoke all on function public.event_attendees(uuid) from public, anon;
grant execute on function public.event_attendees(uuid) to authenticated;
revoke all on function public.notify_event_managers_joined(uuid, uuid) from public, anon, authenticated;
revoke all on function public.upsert_venue(jsonb) from public, anon;
grant execute on function public.upsert_venue(jsonb) to authenticated;
revoke all on function public.create_verification_code(uuid, text) from public, anon, authenticated;
grant execute on function public.create_verification_code(uuid, text) to service_role;
revoke all on function public.project_url() from public, anon;
grant execute on function public.project_url() to authenticated, service_role;
revoke all on function public.is_own_storage_url(text, text, uuid) from public, anon;
grant execute on function public.is_own_storage_url(text, text, uuid) to authenticated, service_role;
revoke all on function public.guard_cover_url() from public, anon, authenticated;
revoke all on function public.guard_avatar_url() from public, anon, authenticated;
revoke all on function public.clear_foreign_image_urls() from public, anon, authenticated, service_role;
revoke all on function public.set_project_url(text) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.18')
  on conflict (key) do update set value = excluded.value, updated_at = now();
