-- ============================================================================
-- Activity Planet schema v2 — migration 36: hub map review fixes (D-041,
--   fix forward of migrations 33, 34 and 35:
--   20261127000100_meeting_spots.sql, 20261128000100_place_contributions.sql,
--   20261129000100_places_lifecycle_odbl.sql). Every rebuilt function starts
--   from its latest body and changes only the lines marked "Migration 36".
--   Checks: supabase/tests/places_review_fixes.sql (schema_version 2.32).
--
--   What this file does
--     1. mod_resolve_place (migration 34 body): the reports branch refuses
--        own_item when the place is the moderator's own or the moderator
--        filed one of its open reports, as the place and edit branches do.
--     2. retire_place_tiles (migration 35 body): an OSM or Geoapify row a
--        moderator hid or removed (not a merge leftover) is never deleted,
--        so the next extract of the tile cannot bring it back as active
--        (ingest_places skips hidden and removed rows).
--     3. place_rate_log (new table: user_id, kind add or edit, created_at):
--        one row per member place insert and per place edit, written by
--        triggers, pruned past a day per user. add_place, places_guard
--        (migration 27 body) and suggest_place_edit (migration 34 body)
--        count it, so deleting a pin (delete_my_place) or a place (its
--        edits cascade) no longer gives the ten adds or thirty edits a day
--        back. Backfilled from the last day of places and edits. Account
--        deletion removes the caller's rows (request_account_deletion,
--        migration 34 body, one line added); the user_id foreign key
--        cascades too.
--     4. meeting_spot_refresh and refresh_meeting_spots (migration 33
--        bodies): a plan counts for a meeting spot only in an active hub
--        that is not events-only and not in a sensitive category, the same
--        hubs meeting_spot_sync_place links (design 7 rule 6). Run once
--        here, so meeting spots made from sensitive, events-only or
--        inactive hub plans go (and leave places_odbl_export).
--     5. meeting_spot_refresh: a meeting spot a moderator hid or removed is
--        kept (its reports and moderation log stay); the venue loses its
--        place_ref and the spot its 'events' links, so a later plan cannot
--        recreate it as active.
--     6. venue_preview_for_place(place_id), authenticated, read only: what
--        "Start a plan here" (/post?place=) shows on load, the existing
--        public venue of the place, or the place's name with no venue yet.
--        Same visibility rules as venue_for_place, which the app now calls
--        only when the plan is posted (no venue is created on page load).
--     7. Grants (explicit) and meta.schema_version 2.32.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 3a. place_rate_log
-- ---------------------------------------------------------------------------
create table if not exists public.place_rate_log (
  id         bigint generated always as identity primary key,
  user_id    uuid not null references public.profiles (id) on delete cascade,
  kind       text not null,
  created_at timestamptz not null default now(),
  constraint place_rate_log_kind check (kind in ('add', 'edit'))
);
create index if not exists place_rate_log_user_idx on public.place_rate_log (user_id, kind, created_at);
comment on table public.place_rate_log is
  'Hub map rate limits (D-041, design 7 rule 9, migration 36): one row per member place added (add) and per place edit (edit), kept a day. add_place, places_guard and suggest_place_edit count it, so a deleted pin or place still counts. No client access; removed on account deletion.';

alter table public.place_rate_log enable row level security;
revoke all on public.place_rate_log from public, anon, authenticated;
grant all on public.place_rate_log to service_role;

create or replace function public.place_rate_log_on_place()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.place_rate_log
   where user_id = new.created_by and kind = 'add' and created_at < now() - interval '1 day';
  insert into public.place_rate_log (user_id, kind) values (new.created_by, 'add');
  return null;
end $$;
comment on function public.place_rate_log_on_place() is
  'Trigger on places (migration 36): logs a member place insert in place_rate_log (add) and prunes the creator''s add rows older than a day.';

drop trigger if exists places_rate_log on public.places;
create trigger places_rate_log after insert on public.places
  for each row when (new.source = 'user' and new.created_by is not null)
  execute function public.place_rate_log_on_place();

create or replace function public.place_rate_log_on_edit()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  delete from public.place_rate_log
   where user_id = new.proposed_by and kind = 'edit' and created_at < now() - interval '1 day';
  insert into public.place_rate_log (user_id, kind) values (new.proposed_by, 'edit');
  return null;
end $$;
comment on function public.place_rate_log_on_edit() is
  'Trigger on place_edits (migration 36): logs an edit in place_rate_log (edit) and prunes the proposer''s edit rows older than a day.';

drop trigger if exists place_edits_rate_log on public.place_edits;
create trigger place_edits_rate_log after insert on public.place_edits
  for each row when (new.proposed_by is not null)
  execute function public.place_rate_log_on_edit();

-- Backfill the last day once (a re-run finds the log non-empty).
do $$
begin
  if not exists (select 1 from public.place_rate_log) then
    insert into public.place_rate_log (user_id, kind, created_at)
    select x.created_by, 'add', x.created_at from public.places x
     where x.source = 'user' and x.created_by is not null and x.created_at > now() - interval '1 day'
    union all
    select e.proposed_by, 'edit', e.created_at from public.place_edits e
     where e.proposed_by is not null and e.created_at > now() - interval '1 day';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3b. places_guard (migration 27 body, 20261122000100_places_schema.sql)
-- ---------------------------------------------------------------------------
create or replace function public.places_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_mod boolean := false;
  v_n   integer;
begin
  if new.source = 'user' then
    v_mod := coalesce(public.is_moderator(), false);
  end if;
  if tg_op = 'UPDATE' then
    if new.source is distinct from old.source then
      raise exception 'place_source_immutable' using errcode = 'check_violation';
    end if;
    if new.created_by is distinct from old.created_by and new.created_by is not null then
      raise exception 'place_creator_immutable' using errcode = 'check_violation';
    end if;
  end if;

  if new.source = 'user' and tg_op = 'INSERT' and new.created_by is not null then
    if not exists (select 1 from public.profiles p
                    where p.id = new.created_by and p.status = 'active' and p.deleted_at is null
                      and p.onboarding_completed_at is not null) then
      raise exception 'not_onboarded' using errcode = 'check_violation';
    end if;
    if v_uid is not null and not v_mod then
      if new.created_by <> v_uid then
        raise exception 'place_creator_mismatch' using errcode = 'check_violation';
      end if;
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('places_new:' || new.created_by::text));
      -- Migration 36: counted in place_rate_log (deleted pins still count).
      select count(*) into v_n from public.place_rate_log l
       where l.user_id = new.created_by and l.kind = 'add' and l.created_at > now() - interval '1 day';
      if v_n >= 10 then
        raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to ten new places a day.';
      end if;
    end if;
  end if;

  -- Rules 1 and 3: a member's public place waits for a moderator.
  if new.source = 'user' and new.is_public and new.status = 'active' and v_uid is not null and not v_mod
     and (tg_op = 'INSERT' or not old.is_public or old.status <> 'active') then
    if tg_op = 'UPDATE' and old.is_public and old.status in ('pending', 'hidden', 'removed') then
      raise exception 'moderator_required' using errcode = 'insufficient_privilege';
    end if;
    new.status := 'pending';
  end if;

  -- Rule 2: never a public pin at or beside the member's home.
  if new.source = 'user' and new.is_public and new.created_by is not null
     and new.status in ('pending', 'active')
     and (tg_op = 'INSERT' or new.location is distinct from old.location
          or not old.is_public or old.status is distinct from new.status) then
    if exists (select 1 from public.profile_private pp
                where pp.user_id = new.created_by
                  and ((pp.home_point is not null and extensions.ST_DWithin(pp.home_point, new.location, 150))
                    or (pp.location is not null and extensions.ST_DWithin(pp.location, new.location, 150)))) then
      raise exception 'near_your_home' using errcode = 'check_violation',
        hint = 'A public place cannot be within 150 m of your saved home. Keep it as a private pin instead.';
    end if;
    if exists (select 1 from public.venues v
                where v.created_by = new.created_by and not v.is_public and v.location is not null
                  and extensions.ST_DWithin(v.location, new.location, 50)) then
      raise exception 'near_private_venue' using errcode = 'check_violation',
        hint = 'A public place cannot be within 50 m of one of your private addresses.';
    end if;
  end if;

  -- Rule 5: only public venues become meeting spots.
  if new.source = 'venue' and new.status = 'active'
     and (tg_op = 'INSERT' or new.source_id is distinct from old.source_id or old.status <> 'active') then
    if not exists (select 1 from public.venues v where v.id::text = new.source_id and v.is_public) then
      raise exception 'venue_not_public' using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

-- ---------------------------------------------------------------------------
-- 3c. add_place (migration 34 body, 20261128000100_place_contributions.sql)
-- ---------------------------------------------------------------------------
create or replace function public.add_place(p_args jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  v_mod    boolean;
  v_public boolean;
  v_clean  jsonb;
  v_kind   text := a ->> 'kind';
  v_lat    double precision;
  v_lng    double precision;
  v_point  extensions.geography;
  v_hubs   uuid[];
  v_why    text;
  v_dups   jsonb;
  v_id     uuid;
  v_status public.place_status;
  v_hub    uuid;
  v_c      text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(a) <> 'object' then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end if;
  v_mod := public.is_moderator();
  begin
    v_public := coalesce((a ->> 'is_public')::boolean, false);   -- "Only me" unless asked (design 7 rule 1)
    v_lat := (a ->> 'lat')::double precision;
    v_lng := (a ->> 'lng')::double precision;
  exception when invalid_text_representation then
    raise exception 'invalid_args' using errcode = 'check_violation';
  end;
  if v_lat is null or v_lng is null or v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_kind is null then
    raise exception 'kind_not_found' using errcode = 'check_violation';
  end if;
  v_clean := public.place_clean_changes(jsonb_strip_nulls(jsonb_build_object(
    'name', coalesce(a ->> 'name', ''), 'kind', v_kind,
    'address_text', a ->> 'address_text', 'locality', a ->> 'locality',
    'opening_hours', a ->> 'opening_hours', 'website', a ->> 'website')));
  v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  v_hubs := public.place_check_hubs(a -> 'hub_ids', v_kind, true);

  if v_public then
    if coalesce((a ->> 'confirm_public')::boolean, false) is not true then
      raise exception 'confirm_public_required' using errcode = 'check_violation',
        hint = 'Confirm this is a public place, not a home or private residence.';
    end if;
    if cardinality(v_hubs) = 0 then
      raise exception 'hub_required' using errcode = 'check_violation',
        hint = 'Pick at least one hub this place is for.';
    end if;
  end if;

  -- Rule 9: ten new places a day (places_guard counts the same rows).
  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('places_new:' || uid::text));
    -- Migration 36: counted in place_rate_log, so deleting a pin does not give the add back.
    if (select count(*) from public.place_rate_log l
         where l.user_id = uid and l.kind = 'add' and l.created_at > now() - interval '1 day') >= 10 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to ten new places a day.';
    end if;
  end if;

  -- Rule 2: never a public pin at or beside the member's home.
  if v_public then
    perform public.place_raise_near(public.place_near_private(uid, v_point));
  end if;

  -- Duplicate check (design 9 step 4): the client shows the candidates and
  -- can send allow_duplicate after the member says theirs is different.
  if coalesce((a ->> 'allow_duplicate')::boolean, false) is not true then
    v_dups := public.place_duplicates(v_kind, v_clean ->> 'name', v_point, null);
    if jsonb_array_length(v_dups) > 0 then
      raise exception 'duplicate_candidates' using errcode = 'check_violation',
        detail = v_dups::text, hint = 'A place like this is already here.';
    end if;
  end if;

  v_status := case when v_public and not v_mod then 'pending'::public.place_status
                   else 'active'::public.place_status end;
  insert into public.places (source, name, kind, location, address_text, locality, opening_hours, website,
                             is_public, status, created_by, attribution)
  values ('user', v_clean ->> 'name', v_kind, v_point,
          coalesce(v_clean ->> 'address_text', ''), coalesce(v_clean ->> 'locality', ''),
          v_clean ->> 'opening_hours', v_clean ->> 'website',
          v_public, v_status, uid, 'Added by an Activity Planet member')
  returning id, status into v_id, v_status;

  foreach v_hub in array v_hubs loop
    insert into public.place_hubs (place_id, hub_id, via)
    values (v_id, v_hub, case when v_mod then 'moderator' else 'member' end)
    on conflict (place_id, hub_id) do nothing;
  end loop;

  return jsonb_build_object('id', v_id, 'status', v_status, 'is_public', v_public, 'hub_ids', to_jsonb(v_hubs));
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

-- ---------------------------------------------------------------------------
-- 3d. suggest_place_edit (migration 34 body)
-- ---------------------------------------------------------------------------
create or replace function public.suggest_place_edit(p_place uuid, p_changes jsonb, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  p       public.places%rowtype;
  v_mod   boolean;
  v_clean jsonb;
  v_note  text := left(btrim(coalesce(p_note, '')), 500);
  v_own   boolean;
  v_id    uuid;
  v_st    text;
  v_why   text;
  v_c     text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and deleted_at is null
                    and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place is null or not public.place_caller_can_see(p_place) then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  select * into p from public.places where id = p_place for update;
  if p.status in ('hidden', 'removed') or p.merged_into is not null then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if p.source = 'venue' then
    raise exception 'meeting_spot' using errcode = 'check_violation',
      hint = 'Meeting spots follow their plans'' venue. Report it if something is wrong.';
  end if;
  v_mod := public.is_moderator();
  v_clean := public.place_clean_changes(p_changes);
  if v_clean = '{}'::jsonb then
    raise exception 'no_changes' using errcode = 'check_violation';
  end if;

  -- Rule 9: thirty edits a day (every kind of edit counts).
  if not v_mod then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('place_edits:' || uid::text));
    -- Migration 36: counted in place_rate_log (edits of a deleted place still count).
    if (select count(*) from public.place_rate_log l
         where l.user_id = uid and l.kind = 'edit' and l.created_at > now() - interval '1 day') >= 30 then
      raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to thirty edits a day.';
    end if;
  end if;

  v_own := p.source = 'user' and p.created_by = uid and (not p.is_public or p.status = 'pending');

  -- Rule 2 for a move of a public member place: refuse it here with a clear
  -- reason (places_guard refuses it again on apply).
  if v_clean ? 'location' and p.source = 'user' and p.is_public and p.created_by is not null then
    v_why := public.place_near_private(p.created_by,
               extensions.ST_SetSRID(extensions.ST_MakePoint((v_clean #>> '{location,lng}')::double precision,
                                                             (v_clean #>> '{location,lat}')::double precision),
                                     4326)::extensions.geography);
    if v_why is not null and (p.created_by = uid or v_mod) then
      perform public.place_raise_near(v_why);
    end if;
  end if;

  if v_own or v_mod then
    perform public.place_apply_changes(p.id, v_clean,
                                       case when v_mod then 'moderator' else 'member' end,
                                       v_mod and p.source in ('osm', 'geoapify'));
    v_st := case when v_own and not v_mod then 'applied' else 'approved' end;
    update public.place_edits set status = 'superseded'
     where place_id = p.id and proposed_by = uid and status = 'pending';
    insert into public.place_edits (place_id, proposed_by, changes, note, status, reviewed_by, reviewed_at)
    values (p.id, uid, v_clean, v_note, v_st, case when v_mod then uid end, now())
    returning id into v_id;
    return jsonb_build_object('id', v_id, 'status', v_st, 'applied', true);
  end if;

  update public.place_edits set status = 'superseded'
   where place_id = p.id and proposed_by = uid and status = 'pending';
  insert into public.place_edits (place_id, proposed_by, changes, note)
  values (p.id, uid, v_clean, v_note)
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending', 'applied', false);
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

-- ---------------------------------------------------------------------------
-- 3e. request_account_deletion (migration 34 body)
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

-- ---------------------------------------------------------------------------
-- 1. mod_resolve_place (migration 34 body)
-- ---------------------------------------------------------------------------
create or replace function public.mod_resolve_place(p_kind text, p_id uuid, p_action text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_note  text := nullif(left(btrim(coalesce(p_note, '')), 500), '');
  p       public.places%rowtype;
  e       public.place_edits%rowtype;
  v_clean jsonb;
  v_c     text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_kind is null or p_kind not in ('place', 'edit', 'reports') or p_id is null then
    raise exception 'invalid_item' using errcode = 'check_violation';
  end if;
  if p_action is null or not (
       (p_kind = 'place'   and p_action in ('approve', 'reject', 'remove'))
    or (p_kind = 'edit'    and p_action in ('approve', 'reject'))
    or (p_kind = 'reports' and p_action in ('dismiss', 'hide', 'remove', 'close'))) then
    raise exception 'invalid_action' using errcode = 'check_violation';
  end if;

  if p_kind = 'edit' then
    select * into e from public.place_edits where id = p_id for update;
    if not found or e.status <> 'pending' then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    if e.proposed_by = uid then
      raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews your own suggestion.';
    end if;
    select * into p from public.places where id = e.place_id for update;
  else
    select * into p from public.places where id = p_id for update;
    if not found then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
  end if;

  if p_kind = 'place' then
    if not (p.source = 'user' and p.is_public and p.status = 'pending') then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    if p.created_by = uid then
      raise exception 'own_item' using errcode = '42501', hint = 'Another moderator reviews your own place.';
    end if;
    if p_action = 'approve' then
      -- places_guard re-checks rule 2 against the creator's home and private venues.
      update public.places set status = 'active' where id = p.id returning * into p;
    elsif p_action = 'reject' and p.created_by is not null then
      -- Not on the map for everyone; it stays the member's own private pin.
      update public.places set is_public = false, status = 'active' where id = p.id returning * into p;
    else
      update public.places set status = 'removed' where id = p.id returning * into p;
    end if;

  elsif p_kind = 'edit' then
    if p_action = 'approve' then
      if p.status in ('hidden', 'removed') then
        raise exception 'place_not_editable' using errcode = 'check_violation',
          hint = 'The place is hidden or removed; reject the edit or restore the place first.';
      end if;
      v_clean := public.place_clean_changes(e.changes);   -- hubs may have changed since
      perform public.place_apply_changes(p.id, v_clean, 'member', p.source in ('osm', 'geoapify'));
      select * into p from public.places where id = p.id;
    end if;
    update public.place_edits
       set status = case when p_action = 'approve' then 'approved' else 'rejected' end,
           reviewed_by = uid, reviewed_at = now(), review_note = v_note
     where id = e.id;

  else
    if not exists (select 1 from public.place_reports r where r.place_id = p.id and r.status = 'open') then
      raise exception 'item_not_pending' using errcode = 'check_violation';
    end if;
    -- Migration 36: never on reports against one's own place, or reports one filed.
    if p.created_by = uid or exists (select 1 from public.place_reports r
                                      where r.place_id = p.id and r.status = 'open' and r.reporter_id = uid) then
      raise exception 'own_item' using errcode = '42501',
        hint = 'Another moderator reviews reports on your own place or reports you filed.';
    end if;
    if p_action = 'dismiss' then
      -- The reports were wrong: a place they hid comes back.
      if p.status = 'hidden' then
        update public.places set status = 'active' where id = p.id returning * into p;
      end if;
    elsif p_action = 'hide' then
      update public.places set status = 'hidden' where id = p.id returning * into p;
    elsif p_action = 'remove' then
      update public.places set status = 'removed' where id = p.id returning * into p;
    else
      update public.places
         set status = 'closed',
             locked_fields = case when source in ('osm', 'geoapify') and not ('closed' = any (locked_fields))
                                  then array_append(locked_fields, 'closed') else locked_fields end
       where id = p.id
       returning * into p;
    end if;
    update public.place_reports
       set status = case when p_action = 'dismiss' then 'dismissed' else 'actioned' end,
           resolved_by = uid, resolved_at = now()
     where place_id = p.id and status = 'open';
  end if;

  -- A removed place takes its open items with it.
  if p.status = 'removed' then
    update public.place_edits set status = 'superseded', reviewed_by = uid, reviewed_at = now()
     where place_id = p.id and status = 'pending';
    update public.place_reports set status = 'actioned', resolved_by = uid, resolved_at = now()
     where place_id = p.id and status = 'open';
  end if;

  insert into public.place_mod_actions (place_id, item_kind, item_id, action, moderator_id, note)
  values (p.id, p_kind, p_id, p_action, uid, v_note);

  return jsonb_build_object('kind', p_kind, 'id', p_id, 'action', p_action,
                            'place_id', p.id, 'place_status', p.status, 'is_public', p.is_public,
                            'locked_fields', to_jsonb(p.locked_fields));
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

-- ---------------------------------------------------------------------------
-- 2. retire_place_tiles (migration 35 body, 20261129000100_places_lifecycle_odbl.sql)
-- ---------------------------------------------------------------------------
create or replace function public.retire_place_tiles()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_today    timestamptz := date_trunc('day', now());
  v_cut      timestamptz := now() - interval '90 days';
  v_stamped  integer := 0;
  v_idled    integer := 0;
  v_woken    integer := 0;
  v_retired  integer := 0;
  v_deleted  integer := 0;
  v_kept     integer := 0;
  v_wanted   integer := 0;
  v_tiles    integer[];
  v_members  integer[];
  v_size     jsonb;
  v_stats    jsonb;
begin
  -- Tiles with an active member's home in them, as tile ids only.
  select coalesce(array_agg(distinct public.place_tile_id_of(coalesce(pp.home_point, a.center))), '{}')
    into v_members
    from public.profile_private pp
    join public.profiles p on p.id = pp.user_id
    left join public.areas a on a.id = pp.home_area_id
   where p.status = 'active' and p.deleted_at is null
     and pp.last_seen_at >= v_cut
     and coalesce(pp.home_point, a.center) is not null;

  update public.place_tiles t
     set last_member_at = v_today
   where t.id = any (v_members)
     and t.last_member_at is distinct from v_today;
  get diagnostics v_stamped = row_count;

  -- An idle tile whose member came back: active again (filling without an OSM run).
  update public.place_tiles t
     set status = case when t.osm_run_at is not null then 'active'::public.place_tile_status
                       else 'filling'::public.place_tile_status end,
         idle_since = null
   where t.status = 'idle' and t.last_member_at >= v_cut;
  get diagnostics v_woken = row_count;

  -- A retired tile with an active member again: wanted, so the extract job picks it up.
  update public.place_tiles t
     set status = 'wanted', idle_since = null
   where t.status = 'retired' and t.last_member_at >= v_cut;
  get diagnostics v_wanted = row_count;

  -- No active member for 90 days (and, when none was ever seen, no run for 90 days): idle.
  update public.place_tiles t
     set status = 'idle', idle_since = now()
   where t.status in ('active', 'filling') and not t.keep
     and coalesce(t.last_member_at,
                  greatest(t.osm_run_at, t.geoapify_run_at, t.created_at)) < v_cut;
  get diagnostics v_idled = row_count;

  -- Idle for 7 days: retired.
  select coalesce(array_agg(t.id order by t.id), '{}') into v_tiles
    from public.place_tiles t
   where t.status = 'idle' and not t.keep and t.idle_since < now() - interval '7 days';

  if cardinality(v_tiles) > 0 then
    with gone as (
      delete from public.places p
       where p.tile_id = any (v_tiles)
         and p.source in ('osm', 'geoapify')
         and p.locked_fields = '{}'
         -- Migration 36: a row a moderator hid or removed stays, so the extract cannot re-add it.
         and (p.status in ('active', 'closed') or p.merged_into is not null)
         and not exists (select 1 from public.venues v where v.place_ref = p.id)
         and not exists (select 1 from public.place_hubs ph where ph.place_id = p.id and ph.via in ('member', 'moderator'))
         and not exists (select 1 from public.place_edits pe where pe.place_id = p.id and pe.status = 'pending')
         and not exists (select 1 from public.place_reports pr where pr.place_id = p.id and pr.status = 'open')
         and not exists (select 1 from public.places m where m.merged_into = p.id)
      returning 1
    )
    select count(*) into v_deleted from gone;

    update public.place_tiles t
       set status = 'retired',
           row_count = (select count(*) from public.places p where p.tile_id = t.id and p.source in ('osm', 'geoapify')),
           idle_since = null
     where t.id = any (v_tiles);
    v_retired := cardinality(v_tiles);

    select count(*) into v_kept from public.places p where p.tile_id = any (v_tiles);
  end if;

  v_size := public.place_size_status();
  v_stats := jsonb_build_object(
    'member_tiles', cardinality(v_members),
    'stamped', v_stamped, 'woken', v_woken, 'wanted', v_wanted, 'idled', v_idled,
    'retired', v_retired, 'deleted_rows', v_deleted, 'kept_rows', v_kept,
    'size_level', v_size->>'level', 'places_bytes', (v_size->>'places_bytes')::bigint);

  insert into public.place_ops_runs (job, stats) values ('retire', v_stats);
  insert into public.place_ops_runs (job, stats) values ('size', v_size);
  if v_size->>'level' <> 'ok' then
    raise warning 'place_size_%: places % bytes, database % bytes', v_size->>'level',
      v_size->>'places_bytes', v_size->>'db_bytes';
  end if;

  delete from public.place_ops_runs r
   where r.id in (select x.id from (
           select o.id, row_number() over (partition by o.job order by o.ran_at desc, o.id desc) as n
             from public.place_ops_runs o) x
          where x.n > 400);

  return v_stats;
end $$;

-- ---------------------------------------------------------------------------
-- 4 and 5. meeting_spot_refresh and refresh_meeting_spots (migration 33
--   bodies, 20261127000100_meeting_spots.sql), then one run
-- ---------------------------------------------------------------------------
create or replace function public.meeting_spot_refresh(p_venue_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v        public.venues%rowtype;
  v_old    uuid;
  v_spot   uuid;   -- this venue's own meeting spot row (source 'venue'), if any
  v_target uuid;
  v_has    boolean;
  v_spot_st public.place_status;
begin
  if p_venue_id is null then
    return;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('meeting_spot:' || p_venue_id::text));

  select p.id, p.status into v_spot, v_spot_st
    from public.places p where p.source = 'venue' and p.source_id = p_venue_id::text;
  select * into v from public.venues where id = p_venue_id;

  -- Migration 36: a meeting spot a moderator hid or removed stays (with its
  -- reports and moderation log), so a later plan cannot bring it back; the
  -- venue only loses its place link and the spot its 'events' links.
  if v_spot is not null and v_spot_st in ('hidden', 'removed') then
    v_old := v.place_ref;
    if v.id is not null and v.place_ref is not null then
      update public.venues set place_ref = null where id = v.id;
    end if;
    delete from public.place_hubs where place_id = v_spot and via = 'events';
    if v_old is not null and v_old is distinct from v_spot then
      perform public.meeting_spot_sync_place(v_old);
    end if;
    return;
  end if;

  -- No place for a deleted or private venue or one with no point.
  if v.id is null or not v.is_public or v.location is null then
    v_old := v.place_ref;
    if v.id is not null and v.place_ref is not null then
      update public.venues set place_ref = null where id = v.id;
    end if;
    if v_spot is not null then
      delete from public.places where id = v_spot;
    end if;
    if v_old is not null and v_old is distinct from v_spot then
      perform public.meeting_spot_sync_place(v_old);
    end if;
    return;
  end if;

  v_old := v.place_ref;
  v_has := exists (
    select 1 from public.event_addresses ea
      join public.events e on e.id = ea.event_id
      join public.hubs h on h.id = e.hub_id
      left join public.hub_categories c on c.slug = h.category_slug
     where ea.venue_id = v.id
       and e.status = 'published' and e.visibility = 'public' and e.address_visibility = 'public'
       and e.starts_at > now() - interval '180 days'
       -- Migration 36: the hubs meeting_spot_sync_place links (design 7 rule 6).
       and h.is_active and h.place_mode <> 'none' and not coalesce(c.is_sensitive, false));
  if not v_has and v_old is null and v_spot is null then
    return;   -- nothing to link and nothing to undo
  end if;

  -- Keep a place_ref that is an active public place from another source.
  if v_old is not null and v_old is distinct from v_spot and exists (
       select 1 from public.places p
        where p.id = v_old and p.status = 'active' and p.is_public and p.source <> 'venue') then
    v_target := v_old;
  else
    select p.id into v_target
      from public.places p
     where p.status = 'active' and p.is_public and p.source <> 'venue'
       and p.geom operator(extensions.&&)
           extensions.ST_Expand(v.location::extensions.geometry, 0.01)   -- index box; the 60 m test follows
       and extensions.ST_DWithin(p.location, v.location, 60)
       and (lower(p.name) = lower(v.name)
            or extensions.similarity(lower(p.name), lower(v.name)) >= 0.45)
     order by (lower(p.name) = lower(v.name)) desc,
              extensions.ST_Distance(p.location, v.location), p.id
     limit 1;
  end if;

  if v_target is null and v_has then
    insert into public.places (source, source_id, name, kind, location, address_text, locality, country,
                               is_public, status, attribution, last_seen_at)
    values ('venue', v.id::text, left(v.name, 120), 'spot', v.location,
            left(btrim(concat_ws(', ', nullif(v.address_line1, ''), nullif(v.address_line2, ''))), 200),
            left(v.city, 120), v.country, true, 'active', 'Meeting spot from public plans', now())
    on conflict (source, source_id) do update
       set name         = excluded.name,
           location     = excluded.location,
           address_text = excluded.address_text,
           locality     = excluded.locality,
           country      = excluded.country,
           -- A moderator's hide or removal stands.
           status       = case when public.places.status in ('hidden', 'removed') then public.places.status
                               else 'active'::public.place_status end,
           last_seen_at = now()
    returning id into v_target;
  end if;

  -- A matched place replaces this venue's own row; a row with no plans left goes.
  if v_spot is not null and (v_target is distinct from v_spot) then
    delete from public.places where id = v_spot;
    v_spot := null;
  end if;

  if v.place_ref is distinct from v_target then
    update public.venues set place_ref = v_target where id = v.id;
  end if;
  if v_target is not null then
    perform public.meeting_spot_sync_place(v_target);
  end if;
  if v_old is not null and v_old is distinct from v_target then
    perform public.meeting_spot_sync_place(v_old);
  end if;
end $$;

create or replace function public.refresh_meeting_spots()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
  v_n  integer := 0;
begin
  for v_id in
    select v.id from public.venues v
     where v.place_ref is not null
        or exists (select 1 from public.places p where p.source = 'venue' and p.source_id = v.id::text)
        or (v.is_public and exists (
              select 1 from public.event_addresses ea
                join public.events e on e.id = ea.event_id
                join public.hubs h on h.id = e.hub_id
                left join public.hub_categories c on c.slug = h.category_slug
               where ea.venue_id = v.id and e.status = 'published' and e.visibility = 'public'
                 and e.address_visibility = 'public' and e.starts_at > now() - interval '180 days'
                 -- Migration 36: only hubs that get meeting spot links.
                 and h.is_active and h.place_mode <> 'none' and not coalesce(c.is_sensitive, false)))
     order by v.id
  loop
    perform public.meeting_spot_refresh(v_id);
    v_n := v_n + 1;
  end loop;
  -- Links left behind by a venue that was deleted.
  for v_id in
    select distinct ph.place_id from public.place_hubs ph where ph.via = 'events' order by ph.place_id
  loop
    perform public.meeting_spot_sync_place(v_id);
  end loop;
  return v_n;
end $$;

comment on function public.meeting_spot_refresh(uuid) is
  'Hub map venue-to-place link (D-041, design 3.3), internal. A meeting spot a moderator hid or removed stays: the venue loses its place_ref and the spot its events links (migration 36). A private, pointless or deleted venue has no place (place_ref cleared, its meeting spot row deleted). A public venue keeps a place_ref to an active public place from another source, else is matched to the nearest active public non-venue place within 60 m with the same or a close name (trigram 0.45), else gets its own source = venue row (kind spot, no user id) while it has a published public plan with a public address in the last 180 days or upcoming, in an active hub that is not events-only or sensitive (migration 36). Then the place''s events links are recomputed (meeting_spot_sync_place).';

select public.refresh_meeting_spots();

-- ---------------------------------------------------------------------------
-- 6. venue_preview_for_place ("Start a plan here", read only)
-- ---------------------------------------------------------------------------
create or replace function public.venue_preview_for_place(p_place_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   record;
  v_id   uuid;
  v_name text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p_place_id is null then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;

  -- The same rows venue_for_place accepts.
  select x.id, x.source, x.source_id, x.name
    into p
    from public.places x
   where x.id = p_place_id and x.status = 'active' and x.is_public
     and (x.source in ('osm', 'geoapify') or coalesce(public.viewer_is_adult(), false));
  if not found then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;

  if p.source = 'venue' then
    select x.id, x.name into v_id, v_name from public.venues x where x.id::text = p.source_id and x.is_public;
  end if;
  if v_id is null then
    select x.id, x.name into v_id, v_name
      from public.venues x where x.place_ref = p.id and x.is_public order by x.created_at, x.id limit 1;
  end if;
  if v_id is not null then
    return jsonb_build_object('place_id', p.id, 'venue_id', v_id, 'name', v_name);
  end if;
  return jsonb_build_object('place_id', p.id, 'venue_id', null, 'name', left(p.name, 120));
end $$;
comment on function public.venue_preview_for_place(uuid) is
  'Hub map "Start a plan here" (D-041, design 9, migration 36), read only: {place_id, venue_id, name}, the public venue that is this place (its meeting spot''s venue, else one with place_ref = it), else venue_id null and the place''s name. Creates nothing; the app calls venue_for_place when the plan is posted. Same places as venue_for_place. Errors: not_authenticated, onboarding_required, place_not_found.';

-- ---------------------------------------------------------------------------
-- 7. Grants (explicit) and the version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.place_rate_log_on_place() from public, anon, authenticated;
revoke all on function public.place_rate_log_on_edit() from public, anon, authenticated;
revoke all on function public.places_guard() from public, anon, authenticated, service_role;
revoke all on function public.add_place(jsonb) from public, anon;
grant execute on function public.add_place(jsonb) to authenticated, service_role;
revoke all on function public.suggest_place_edit(uuid, jsonb, text) from public, anon;
grant execute on function public.suggest_place_edit(uuid, jsonb, text) to authenticated, service_role;
revoke all on function public.mod_resolve_place(text, uuid, text, text) from public, anon;
grant execute on function public.mod_resolve_place(text, uuid, text, text) to authenticated, service_role;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;
revoke all on function public.retire_place_tiles() from public, anon, authenticated;
grant execute on function public.retire_place_tiles() to service_role;
revoke all on function public.meeting_spot_refresh(uuid) from public, anon, authenticated;
grant execute on function public.meeting_spot_refresh(uuid) to service_role;
revoke all on function public.refresh_meeting_spots() from public, anon, authenticated;
grant execute on function public.refresh_meeting_spots() to service_role;
revoke all on function public.venue_preview_for_place(uuid) from public, anon;
grant execute on function public.venue_preview_for_place(uuid) to authenticated, service_role;

insert into public.meta (key, value) values ('schema_version', '2.32')
  on conflict (key) do update set value = excluded.value, updated_at = now();
