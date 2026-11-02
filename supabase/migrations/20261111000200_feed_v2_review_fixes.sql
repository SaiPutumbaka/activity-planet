-- ============================================================================
-- Activity Planet schema v2 — migration 11: Feed v2 review fixes
--   (follow-up to 20261111000100_everyone_feed_v2.sql, which is on staging and
--   is not edited; D-035, D-036).
--
--   What this file does
--     * Home area moves to profile_private.home_area_id (owner-only, D-036 "not
--       shown publicly"). Values are copied from profiles.home_area_id, every
--       onboarded profile without one gets Atlanta, and profiles.home_area_id
--       is dropped (it was readable by every signed-in user).
--     * complete_onboarding and set_home_area write the area to
--       profile_private; a new or changed area resets feed_radius_km to that
--       area's default_radius_km unless a radius is passed, so the per-area
--       radii are reachable.
--     * feed_events_v2: origin is the device point, else the home area, else
--       Atlanta (the declared campus is never the origin); human-hosted rows
--       are ordered by start time, with hub or campus matches first only on a
--       tie, so busy hubs cannot push every nearby event past the limit.
--     * request_account_deletion: same body, without profiles.home_area_id
--       (profile_private is deleted whole).
--     * chapter_members_insert_own: every chapter, area chapters included,
--       also requires the hub to be active and not above the viewer's age
--       (as hub_members_insert_own does).
--     * hub_chapters: exactly one of org_id and area_id.
--     * meta.schema_version stays 2.10 (same release).
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Home area becomes owner-only
-- ---------------------------------------------------------------------------
alter table public.profile_private
  add column if not exists home_area_id uuid references public.areas (id) on delete set null;
create index if not exists profile_private_home_area_idx on public.profile_private (home_area_id);
comment on column public.profile_private.home_area_id is
  'Saved feed origin (D-036), owner-only. Set by complete_onboarding and set_home_area; clients cannot update it directly.';

-- Copy the saved areas while the old column still exists (dynamic SQL, so a
-- re-run after the drop does not fail to parse).
do $$
begin
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'profiles' and column_name = 'home_area_id') then
    execute $q$
      update public.profile_private pp
         set home_area_id = p.home_area_id
        from public.profiles p
       where p.id = pp.user_id and pp.home_area_id is null and p.home_area_id is not null
    $q$;
  end if;
end $$;

-- Profiles onboarded before areas existed get Atlanta, never their campus.
update public.profile_private pp
   set home_area_id = (select a.id from public.areas a where a.slug = 'atlanta')
  from public.profiles p
 where p.id = pp.user_id
   and p.onboarding_completed_at is not null
   and p.deleted_at is null
   and pp.home_area_id is null;

drop index if exists public.profiles_home_area_idx;
alter table public.profiles drop column if exists home_area_id;

comment on table public.profile_private is
  'Owner-only data: login email (synced from auth, not client-writable), birth date (18+ enforced by trigger, write-once), home area and feed radius (complete_onboarding, set_home_area). The location columns are unused: a device point is sent per feed request and never stored (D-036); clients cannot update them.';

-- ---------------------------------------------------------------------------
-- 2. complete_onboarding: home area in profile_private
-- ---------------------------------------------------------------------------
create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null,
  p_org_id     uuid default null,
  p_area_id    uuid default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid    uuid := (select auth.uid());
  v_org  uuid;
  v_age  integer;
  v_area uuid;
  result public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_birth_date is null then
    raise exception 'birth_date_required' using errcode = 'check_violation';
  end if;
  if nullif(btrim(coalesce(p_first_name, '')), '') is null then
    raise exception 'first_name_required' using errcode = 'check_violation';
  end if;
  if p_hub_ids is null or array_length(p_hub_ids, 1) is null then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;
  if array_length(p_hub_ids, 1) > 25 then
    raise exception 'too_many_hubs' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.reserved_handles where handle = lower(p_handle)) then
    raise exception 'handle_reserved' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.profiles where lower(handle) = lower(p_handle) and id <> uid) then
    raise exception 'handle_taken' using errcode = 'unique_violation';
  end if;

  if p_campus_id is not null then
    select org_id into v_org from public.org_campuses where id = p_campus_id;
    if v_org is null then
      raise exception 'campus_not_found' using errcode = 'foreign_key_violation';
    end if;
  elsif p_org_id is not null then
    if not exists (select 1 from public.organizations where id = p_org_id) then
      raise exception 'org_not_found' using errcode = 'foreign_key_violation';
    end if;
    v_org := p_org_id;
  end if;

  -- Home area (D-036): a passed id must exist; none keeps the saved area or
  -- falls back to Atlanta, so every onboarded profile has a feed origin.
  if p_area_id is not null then
    select id into v_area from public.areas where id = p_area_id;
    if v_area is null then
      raise exception 'area_not_found' using errcode = 'foreign_key_violation';
    end if;
  end if;

  -- Birth date first (write-once), so the age trigger aborts before anything else changes.
  update public.profile_private
     set birth_date = p_birth_date
   where user_id = uid
     and (birth_date is null or birth_date = p_birth_date);
  if not found then
    raise exception 'birth_date_locked' using errcode = 'check_violation',
      hint = 'The birth date is recorded once; contact support to correct it.';
  end if;
  v_age := extract(year from age(current_date::timestamp, p_birth_date::timestamp))::integer;
  if exists (select 1 from public.hubs h where h.id = any (p_hub_ids) and h.is_active and h.min_age > v_age) then
    raise exception 'hub_min_age' using errcode = 'check_violation',
      hint = 'One of the picked hubs is 21+.';
  end if;

  update public.profiles
     set handle = p_handle,
         first_name = btrim(p_first_name),
         home_org_id = coalesce(v_org, home_org_id),
         home_campus_id = coalesce(p_campus_id, home_campus_id),
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  -- Home area and radius are owner-only (profile_private). A new or changed
  -- area resets the radius to that area's default; an unchanged one keeps it.
  update public.profile_private pp
     set home_area_id   = n.area_id,
         feed_radius_km = case when pp.home_area_id is distinct from n.area_id
                               then n.default_radius_km else pp.feed_radius_km end
    from (select a.id as area_id, a.default_radius_km
            from public.areas a
           where a.id = coalesce(v_area,
                                 (select x.home_area_id from public.profile_private x where x.user_id = uid),
                                 (select y.id from public.areas y where y.slug = 'atlanta'))) n
   where pp.user_id = uid;

  insert into public.hub_members (user_id, hub_id)
  select uid, h.id
    from public.hubs h
   where h.id = any (p_hub_ids) and h.is_active and h.min_age <= v_age
  on conflict do nothing;

  if not exists (select 1 from public.hub_members where user_id = uid) then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;

  return result;
end $$;

comment on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) is
  'Finishes onboarding: write-once birth date (18+), handle, first name, optional declared campus or organization, home area in profile_private (p_area_id must exist; null keeps the saved area or falls back to Atlanta; a new area resets feed_radius_km to its default), and at least one hub (21+ hubs refused under 21). Errors: not_authenticated, birth_date_required, first_name_required, pick_at_least_one_hub, too_many_hubs, handle_reserved, handle_taken, campus_not_found, org_not_found, area_not_found, birth_date_locked, hub_min_age, profile_missing.';

-- ---------------------------------------------------------------------------
-- 3. set_home_area: area in profile_private; no radius means the area default
-- ---------------------------------------------------------------------------
create or replace function public.set_home_area(p_area_id uuid, p_radius_km smallint default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_area   public.areas%rowtype;
  v_radius smallint;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_area_id is null then
    raise exception 'area_required' using errcode = 'check_violation';
  end if;
  select * into v_area from public.areas where id = p_area_id;
  if not found then
    raise exception 'area_not_found' using errcode = 'P0002';
  end if;
  if p_radius_km is not null and p_radius_km not between 1 and 50 then
    raise exception 'radius_out_of_range' using errcode = 'check_violation', hint = '1 to 50 km.';
  end if;
  if not exists (select 1 from public.profiles where id = uid and deleted_at is null) then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  update public.profile_private
     set home_area_id   = v_area.id,
         feed_radius_km = coalesce(p_radius_km, greatest(1, least(50, v_area.default_radius_km)))
   where user_id = uid
  returning feed_radius_km into v_radius;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  return jsonb_build_object(
    'area_id', v_area.id, 'slug', v_area.slug, 'name', v_area.name,
    'feed_radius_km', v_radius);
end $$;
comment on function public.set_home_area(uuid, smallint) is
  'Saves the caller''s home area (profile_private.home_area_id) and the feed radius: p_radius_km (1 to 50 km) when given, else the area''s default_radius_km. Returns {area_id, slug, name, feed_radius_km}. Errors: not_authenticated, area_required, area_not_found, radius_out_of_range, profile_missing.';

-- ---------------------------------------------------------------------------
-- 4. feed_events_v2: no campus origin; start time before match kind
-- ---------------------------------------------------------------------------
create or replace function public.feed_events_v2(
  p_from      timestamptz,
  p_to        timestamptz,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_hub_ids   uuid[] default null,
  p_free_only boolean default false,
  p_limit     integer default 60
)
returns table (
  id                 uuid,
  kind               public.event_kind,
  hub_id             uuid,
  hub_slug           text,
  hub_name           text,
  hub_emoji          text,
  chapter_id         uuid,
  campus_id          uuid,
  host_id            uuid,
  series_id          uuid,
  occurrence_date    date,
  title              text,
  description        text,
  cover_url          text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  timezone           text,
  min_age            smallint,
  capacity           integer,
  waitlist_enabled   boolean,
  min_headcount      integer,
  members_only       boolean,
  is_free            boolean,
  price_text         text,
  status             public.event_status,
  visibility         public.event_visibility,
  address_visibility public.address_visibility,
  location_hint      text,
  going_count        integer,
  waitlist_count     integer,
  interested_count   integer,
  external_url       text,
  source_name        text,
  created_at         timestamptz,
  updated_at         timestamptz,
  distance_band      text,
  section            text,
  is_imported        boolean,
  matched_by         text
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_origin   extensions.geography;
  v_radius_m double precision;
  v_today    date := (now() at time zone 'America/New_York')::date;
  v_limit    integer := greatest(1, least(coalesce(p_limit, 60), 200));
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_window' using errcode = 'check_violation';
  end if;
  if p_to - p_from > interval '93 days' then
    raise exception 'window_too_long' using errcode = 'check_violation', hint = 'Up to 93 days.';
  end if;
  if (p_lat is null) <> (p_lng is null)
     or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;

  -- Origin: the device point (about 1 km, never stored), else the home area,
  -- else Atlanta. A declared campus is never the origin (D-036).
  v_origin := coalesce(
    case when p_lat is not null then
      extensions.ST_SetSRID(extensions.ST_MakePoint(
        round(p_lng::numeric, 2)::double precision,
        round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography
    end,
    (select a.center from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.center from public.areas a where a.slug = 'atlanta'));

  v_radius_m := 1000.0 * greatest(1, least(50, coalesce(
    p_radius_km,
    (select pp.feed_radius_km::integer from public.profile_private pp where pp.user_id = uid),
    (select a.default_radius_km::integer from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.default_radius_km::integer from public.areas a where a.slug = 'atlanta'),
    10)));

  return query
  with my_hubs as (
    select hm.hub_id from public.hub_members hm where hm.user_id = uid
  ), my_campuses as (
    select m.campus_id from public.org_memberships m
     where m.user_id = uid and m.campus_id is not null
       and (m.expires_at is null or m.expires_at > now())
  ), cand as (
    select e.*,
           h.slug  as h_slug,
           h.name  as h_name,
           h.emoji as h_emoji,
           (e.hub_id in (select hub_id from my_hubs)) as by_hub,
           (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses)) as by_campus
      from public.events e
      join public.hubs h on h.id = e.hub_id
     where e.status = 'published'
       and e.starts_at >= p_from and e.starts_at < p_to
       and (p_hub_ids is null or e.hub_id = any (p_hub_ids))
       and (not coalesce(p_free_only, false) or e.is_free)
       and (
         e.hub_id in (select hub_id from my_hubs)
         or (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses))
         or (
           e.visibility = 'public'
           and e.approx_point is not null
           and extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m + 8000)
           and (e.address_visibility = 'approved_only'
                or extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m))
         )
       )
  ), banded as (
    select c.*,
           case when c.approx_point is null then null::double precision
                else extensions.ST_Distance(c.approx_point, v_origin) end as dist_m,
           (c.starts_at at time zone 'America/New_York')::date as local_day
      from cand c
  )
  select b.id, b.kind, b.hub_id, b.h_slug, b.h_name, b.h_emoji, b.chapter_id, b.campus_id, b.host_id,
         b.series_id, b.occurrence_date, b.title, b.description, b.cover_url, b.starts_at, b.ends_at,
         b.timezone, b.min_age, b.capacity, b.waitlist_enabled, b.min_headcount, b.members_only,
         b.is_free, b.price_text, b.status, b.visibility, b.address_visibility, b.location_hint,
         b.going_count, b.waitlist_count, b.interested_count, b.external_url, b.source_name,
         b.created_at, b.updated_at,
         case
           when b.dist_m is null then null::text
           when b.address_visibility = 'approved_only' then 'approximate'
           when b.dist_m < 1609.344  then '<1 mi'
           when b.dist_m < 8046.72   then '1-5 mi'
           when b.dist_m < 16093.44  then '5-10 mi'
           when b.dist_m < 40233.6   then '10-25 mi'
           else '25+ mi'
         end,
         case
           when b.local_day <= v_today     then 'today'
           when b.local_day <  v_today + 7 then 'this_week'
           else 'later'
         end,
         (b.kind = 'imported'),
         case when b.by_hub then 'hub' when b.by_campus then 'campus' else 'nearby' end
    from banded b
   -- Human-hosted rows by start time (hub or campus matches first only on a
   -- tie), so a busy hub list cannot push every nearby event past the limit.
   order by (b.kind = 'imported'), b.starts_at, (not (b.by_hub or b.by_campus)), b.id
   limit v_limit;
end $$;

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) is
  'Feed v2 (D-036): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public within the radius of the origin (p_lat/p_lng rounded to 0.01 degree, else profile_private.home_area_id, else Atlanta, never the declared campus; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km). Events without a point come only through hubs or campus. Approved-only events get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, then start time, hub or campus matches first on a tie. Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates.';

-- ---------------------------------------------------------------------------
-- 5. Chapters: exactly one owner; joining respects the hub's age limit
-- ---------------------------------------------------------------------------
alter table public.hub_chapters drop constraint if exists hub_chapters_owner_required;
do $$ begin
  alter table public.hub_chapters
    add constraint hub_chapters_one_owner check (num_nonnulls(org_id, area_id) = 1);
exception when duplicate_object then null; end $$;

-- An organization's chapter still needs a verified membership in it; an area
-- chapter has no organization to verify against. Either way the hub must be
-- active and not above the viewer's age (pre-onboarding counts as 18, as in
-- hub_members_insert_own), so a 21+ hub's area chapter is closed to under-21s.
drop policy if exists "chapter_members_insert_own" on public.chapter_members;
create policy "chapter_members_insert_own" on public.chapter_members for insert to authenticated
  with check (
    user_id = (select auth.uid()) and role = 'member'
    and exists (
      select 1
        from public.hub_chapters c
        join public.hubs h on h.id = c.hub_id
       where c.id = chapter_id and c.is_active
         and h.is_active
         and h.min_age <= coalesce((select public.viewer_age()), 18)
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
-- 6. request_account_deletion: profiles.home_area_id is gone
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
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
   where host_id = uid and status = 'published' and starts_at > now();
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
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships and the city waitlist row removed, hosted series and future events cancelled with their addresses, private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';


-- ---------------------------------------------------------------------------
-- 7. Privileges (explicit; unchanged signatures, restated)
-- ---------------------------------------------------------------------------
revoke update (home_area_id, feed_radius_km) on public.profile_private from authenticated;
revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid, uuid) to authenticated;
revoke all on function public.set_home_area(uuid, smallint) from public, anon;
grant execute on function public.set_home_area(uuid, smallint) to authenticated;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer) to authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 8. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.10')
  on conflict (key) do update set value = excluded.value, updated_at = now();
