-- ============================================================================
-- Activity Planet schema v2 — migration 33: meeting spots and "Start a plan
--   here" (D-041, docs/design/hub-map/HUB_MAP_DESIGN.md sections 3.3, 5 and
--   9; build slice 9). New functions and triggers only; no existing function
--   is rebuilt and no table or column is added. Checks:
--   supabase/tests/meeting_spots.sql (schema_version 2.29).
--
--   What this file does
--     1. meeting_spot_sync_place(place_id), internal: recomputes a place's
--        place_hubs rows with via = 'events' from every public venue that is
--        this place (venues.place_ref, or the venue a source = 'venue' row
--        came from). weight = the published, public-visibility,
--        public-address events there that started in the last 180 days or
--        are still to come, per hub. Hubs that are inactive, events-only
--        (place_mode 'none') or in a sensitive category never get a link
--        (design 7 rule 6). Links a member or moderator made are never
--        changed or removed; only 'events' rows are.
--     2. meeting_spot_refresh(venue_id), internal: the venue-to-place link.
--          * A private venue, a venue with no point or a deleted venue has
--            no place: its place_ref is cleared, its meeting spot row (if
--            any) is deleted and the place it pointed at is re-synced. So a
--            private address or an approved-only event never becomes a
--            place or a link (design 7 rule 5).
--          * A public venue keeps a place_ref that is an active public
--            place from another source; otherwise it is matched to the
--            nearest active public place (OSM, Geoapify, a reviewed member
--            place) within 60 m whose name equals the venue's or is close to
--            it (trigram similarity 0.45 or more), so a plan at a court that
--            is already on the map adds to that place instead of a second
--            pin. Otherwise, while the venue has a qualifying plan, it gets
--            its own row: places(source 'venue', source_id = venue id, kind
--            'spot'), active and public, no user id. A matched place
--            replaces an earlier meeting spot row of the same venue (the
--            weekly refresh does this once OSM arrives).
--          * A meeting spot row whose venue has no qualifying plan left is
--            deleted; a matched place keeps its place_ref (for "Plans
--            here") and loses only its 'events' links.
--     3. Triggers (security definer, so the writes need no client grants):
--          * event_addresses after insert, delete, or update of venue_id:
--            refresh the old and the new venue;
--          * events after update of status, visibility, address_visibility,
--            hub_id or starts_at: refresh the event's venue;
--          * venues before update of is_public: a venue going private loses
--            its place_ref (the venues_place_ref_public check would refuse
--            event_set_location's private flip otherwise);
--          * venues after update of is_public, location or name: refresh,
--            and re-sync the place it pointed at before.
--     4. refresh_meeting_spots(), pg_cron weekly (Monday 04:37 UTC): re-runs
--        the refresh for every venue with a place or a qualifying plan, so
--        weights follow the 180-day window and meeting spots move onto OSM
--        places once the extract has them, then re-syncs every place with
--        'events' links (links of a deleted venue). Also run once here
--        (backfill).
--     5. venue_for_place(place_id), security definer, authenticated:
--        "Start a plan here" (/post?place=). Returns the public venue that
--        is this place (its meeting spot's venue, else a venue with
--        place_ref = it), or creates one from the place's public facts
--        (name, address, locality, country, point) with place_ref set,
--        created_by the caller (so the twenty-new-venues-a-day limit of
--        upsert_venue applies and account deletion clears the link as for
--        any public venue). Only an active public place the caller can read
--        (places RLS: imported rows for every signed-in user, member and
--        meeting spot rows for adults) works; anything else is
--        place_not_found. The plan posted there links the place through 2.
--     * Account deletion: no new table or column refers to a user; the
--       venues venue_for_place creates are public venues, already handled
--       by request_account_deletion (created_by cleared). The triggers fire
--       during deletion too (cancelled events and deleted addresses
--       recompute the links).
--     * Grants: the internal functions are revoked from everyone but
--       service_role; venue_for_place is executable by authenticated and
--       service_role. meta.schema_version 2.29.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. meeting_spot_sync_place
-- ---------------------------------------------------------------------------
create or replace function public.meeting_spot_sync_place(p_place_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_src public.place_source;
  v_sid text;
begin
  if p_place_id is null then
    return;
  end if;
  select p.source, p.source_id into v_src, v_sid from public.places p where p.id = p_place_id;
  if not found then
    return;
  end if;

  -- One statement: the counts, the stale 'events' links removed, the rest
  -- upserted (the deleted and the inserted hubs never overlap).
  with m as (
    select e.hub_id, least(count(*), 100000)::integer as n
      from public.venues v
      join public.event_addresses ea on ea.venue_id = v.id
      join public.events e on e.id = ea.event_id
      join public.hubs h on h.id = e.hub_id
      left join public.hub_categories c on c.slug = h.category_slug
     where (v.place_ref = p_place_id or (v_src = 'venue' and v.id::text = v_sid))
       and v.is_public
       and e.status = 'published'
       and e.visibility = 'public'
       and e.address_visibility = 'public'
       and e.starts_at > now() - interval '180 days'
       and h.is_active
       and h.place_mode <> 'none'
       and not coalesce(c.is_sensitive, false)
     group by e.hub_id
  ), gone as (
    delete from public.place_hubs ph
     where ph.place_id = p_place_id and ph.via = 'events'
       and not exists (select 1 from m where m.hub_id = ph.hub_id)
    returning 1
  )
  insert into public.place_hubs (place_id, hub_id, via, weight)
  select p_place_id, m.hub_id, 'events', m.n from m
  on conflict (place_id, hub_id) do update
     set weight = excluded.weight
   where public.place_hubs.via = 'events' and public.place_hubs.weight <> excluded.weight;
end $$;

comment on function public.meeting_spot_sync_place(uuid) is
  'Hub map meeting spots (D-041, design 3.3), internal: recomputes a place''s place_hubs rows with via = events from the public venues that are this place (place_ref, or the venue a source = venue row came from): weight = published public events with a public address there that started in the last 180 days or are upcoming, per hub. Inactive, events-only and sensitive hubs get no link. Member and moderator links are never touched.';

-- ---------------------------------------------------------------------------
-- 2. meeting_spot_refresh (the venue-to-place link)
-- ---------------------------------------------------------------------------
create or replace function public.meeting_spot_refresh(p_venue_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v        public.venues%rowtype;
  v_old    uuid;
  v_spot   uuid;   -- this venue's own meeting spot row (source 'venue'), if any
  v_target uuid;
  v_has    boolean;
begin
  if p_venue_id is null then
    return;
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('meeting_spot:' || p_venue_id::text));

  select p.id into v_spot from public.places p where p.source = 'venue' and p.source_id = p_venue_id::text;
  select * into v from public.venues where id = p_venue_id;

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
     where ea.venue_id = v.id
       and e.status = 'published' and e.visibility = 'public' and e.address_visibility = 'public'
       and e.starts_at > now() - interval '180 days');
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

comment on function public.meeting_spot_refresh(uuid) is
  'Hub map venue-to-place link (D-041, design 3.3), internal. A private, pointless or deleted venue has no place (place_ref cleared, its meeting spot row deleted). A public venue keeps a place_ref to an active public place from another source, else is matched to the nearest active public non-venue place within 60 m with the same or a close name (trigram 0.45), else gets its own source = venue row (kind spot, no user id) while it has a published public plan with a public address in the last 180 days or upcoming. Then the place''s events links are recomputed (meeting_spot_sync_place).';

-- ---------------------------------------------------------------------------
-- 3. Triggers
-- ---------------------------------------------------------------------------
create or replace function public.meeting_spot_on_event_address()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') and old.venue_id is not null then
    perform public.meeting_spot_refresh(old.venue_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and new.venue_id is not null
     and (tg_op = 'INSERT' or new.venue_id is distinct from old.venue_id) then
    perform public.meeting_spot_refresh(new.venue_id);
  end if;
  return null;
end $$;

comment on function public.meeting_spot_on_event_address() is
  'Trigger on event_addresses (D-041 meeting spots): refreshes the old and the new venue''s place link.';

drop trigger if exists event_addresses_meeting_spot on public.event_addresses;
create trigger event_addresses_meeting_spot after insert or delete or update of venue_id on public.event_addresses
  for each row execute function public.meeting_spot_on_event_address();

create or replace function public.meeting_spot_on_event()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_venue uuid;
begin
  if new.status is distinct from old.status or new.visibility is distinct from old.visibility
     or new.address_visibility is distinct from old.address_visibility or new.hub_id is distinct from old.hub_id
     or new.starts_at is distinct from old.starts_at then
    select ea.venue_id into v_venue from public.event_addresses ea where ea.event_id = new.id;
    if v_venue is not null then
      perform public.meeting_spot_refresh(v_venue);
    end if;
  end if;
  return null;
end $$;

comment on function public.meeting_spot_on_event() is
  'Trigger on events (D-041 meeting spots): a change of status, visibility, address visibility, hub or start refreshes the event''s venue link.';

drop trigger if exists events_meeting_spot on public.events;
create trigger events_meeting_spot
  after update of status, visibility, address_visibility, hub_id, starts_at on public.events
  for each row execute function public.meeting_spot_on_event();

create or replace function public.venues_place_ref_guard()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not new.is_public then
    new.place_ref := null;
  end if;
  return new;
end $$;

comment on function public.venues_place_ref_guard() is
  'Trigger on venues (D-041): a venue that goes private loses its place link (venues_place_ref_public).';

drop trigger if exists venues_place_ref_guard on public.venues;
create trigger venues_place_ref_guard before insert or update of is_public, place_ref on public.venues
  for each row execute function public.venues_place_ref_guard();

create or replace function public.meeting_spot_on_venue()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.is_public is distinct from old.is_public or new.name is distinct from old.name
     or new.location::text is distinct from old.location::text then
    perform public.meeting_spot_refresh(new.id);
    -- A venue going private already lost its place_ref (venues_place_ref_guard),
    -- so the place it pointed at is re-synced here.
    if old.place_ref is not null then
      perform public.meeting_spot_sync_place(old.place_ref);
    end if;
  end if;
  return null;
end $$;

comment on function public.meeting_spot_on_venue() is
  'Trigger on venues (D-041 meeting spots): going private or public, a new name or a new point refreshes the place link.';

drop trigger if exists venues_meeting_spot on public.venues;
create trigger venues_meeting_spot after update of is_public, location, name on public.venues
  for each row execute function public.meeting_spot_on_venue();

-- ---------------------------------------------------------------------------
-- 4. refresh_meeting_spots (weekly, and the backfill)
-- ---------------------------------------------------------------------------
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
               where ea.venue_id = v.id and e.status = 'published' and e.visibility = 'public'
                 and e.address_visibility = 'public' and e.starts_at > now() - interval '180 days'))
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

comment on function public.refresh_meeting_spots() is
  'Hub map meeting spots (D-041), pg_cron weekly: re-runs meeting_spot_refresh for every venue with a place or a qualifying plan, so weights follow the 180-day window and meeting spots move onto OSM places once the extract has them. Returns the number of venues looked at.';

select public.refresh_meeting_spots();

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; refresh-meeting-spots not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'refresh-meeting-spots') then
    perform cron.unschedule('refresh-meeting-spots');
  end if;
  perform cron.schedule('refresh-meeting-spots', '37 4 * * 1', 'select public.refresh_meeting_spots()');
end $$;

-- ---------------------------------------------------------------------------
-- 5. venue_for_place ("Start a plan here")
-- ---------------------------------------------------------------------------
create or replace function public.venue_for_place(p_place_id uuid)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  p   record;
  v   public.venues%rowtype;
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

  -- What places RLS shows a signed-in caller, limited to active public rows.
  select x.id, x.source, x.source_id, x.name, x.location, x.address_text, x.locality, x.country
    into p
    from public.places x
   where x.id = p_place_id and x.status = 'active' and x.is_public
     and (x.source in ('osm', 'geoapify') or coalesce(public.viewer_is_adult(), false));
  if not found then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('venue_for_place:' || p.id::text));

  if p.source = 'venue' then
    select * into v from public.venues where id::text = p.source_id and is_public;
    if found then
      return v;
    end if;
  end if;
  select * into v from public.venues where place_ref = p.id and is_public order by created_at, id limit 1;
  if found then
    return v;
  end if;

  if not coalesce(public.is_moderator(), false) then
    perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, city, country, location, created_by, is_public, place_ref)
  values (left(p.name, 120), left(p.address_text, 200), left(p.locality, 80), p.country, p.location,
          uid, true, p.id)
  returning * into v;
  return v;
end $$;

comment on function public.venue_for_place(uuid) is
  'Hub map "Start a plan here" (D-041, design 9): the public venue that is this place (its meeting spot''s venue, else one with place_ref = it), or a new public venue made from the place''s public facts with place_ref set and the caller as creator (twenty new venues a day, as upsert_venue). Only an active public place the caller can read. A plan posted there makes the place a meeting spot for its hub. Errors: not_authenticated, onboarding_required, place_not_found, too_many_venues.';

-- ---------------------------------------------------------------------------
-- 6. Grants (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.meeting_spot_sync_place(uuid) from public, anon, authenticated;
revoke all on function public.meeting_spot_refresh(uuid) from public, anon, authenticated;
revoke all on function public.meeting_spot_on_event_address() from public, anon, authenticated;
revoke all on function public.meeting_spot_on_event() from public, anon, authenticated;
revoke all on function public.meeting_spot_on_venue() from public, anon, authenticated;
revoke all on function public.venues_place_ref_guard() from public, anon, authenticated;
revoke all on function public.refresh_meeting_spots() from public, anon, authenticated;
revoke all on function public.venue_for_place(uuid) from public, anon;

grant execute on function public.meeting_spot_sync_place(uuid) to service_role;
grant execute on function public.meeting_spot_refresh(uuid) to service_role;
grant execute on function public.refresh_meeting_spots() to service_role;
grant execute on function public.venue_for_place(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.29')
  on conflict (key) do update set value = excluded.value, updated_at = now();
