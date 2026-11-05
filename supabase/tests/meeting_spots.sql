-- ============================================================================
-- Staging check for migration 20261127000100_meeting_spots.sql (D-041, hub
-- map slice 9: meeting spots, the venue-to-place link and venue_for_place).
-- One transaction, asserts in DO blocks that raise on failure, rolled back at
-- the end. Prints pass/fail and counts only, never names, ids or points (the
-- repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run. The fixture sits in the Southern Ocean,
-- where no real data is.
--   1 Static: schema_version 2.29 or later; the triggers exist; venue_for_place is
--     definer and executable by authenticated only (not anon); the internal
--     functions are not executable by anon or authenticated; the weekly
--     cron job exists when pg_cron does.
--   2 Links: a public plan at a public venue beside an OSM place of the
--     same name links that place to the plan's hub (no second pin); a public
--     plan at a public venue with no place nearby makes a 'venue' meeting
--     spot (kind spot, active, public, no user id); a private venue and an
--     approved-only plan at a public venue make nothing; a sensitive hub's
--     plan adds no link; a moderator link is never touched.
--   3 Reads: signed out, map_in_view for the hub returns both places (the
--     spot with flag 16) and place_detail lists the plan under plans_here;
--     the approved-only plan is never in plans_here.
--   4 Changes: cancelling the only plan deletes the spot; an approved-only
--     switch removes the events link; a venue going private loses its
--     place_ref without an error; the weekly refresh moves a spot onto an
--     OSM place that appears later.
--   5 venue_for_place: as a signed-in adult, an OSM place gives a public
--     venue with place_ref set, the same one on a second call; a missing
--     place, a private pin and anon are refused; a plan there links it.
-- ============================================================================
begin;

create temp table msp_lines (n serial, line text);
grant insert, select on msp_lines to anon, authenticated;
grant usage on sequence msp_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- The venue's meeting spot row (source 'venue'), or null.
create function pg_temp.spot(p_venue uuid) returns uuid language sql stable as $$
  select p.id from public.places p where p.source = 'venue' and p.source_id = p_venue::text;
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_h   uuid := gen_random_uuid();   -- host of the fixture plans
  v_u   uuid := gen_random_uuid();   -- signed-in adult for venue_for_place
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_a   uuid;   -- a specific hub
  v_b   uuid;   -- another specific hub (moderator link)
  v_s   uuid;   -- a sensitive hub
  v_osm uuid;
  v_pin uuid;
  v1 uuid; v2 uuid; v3 uuid; v4 uuid; v5 uuid;
  e1 uuid; e2 uuid; e4 uuid;
begin
  if exists (select 1 from public.places
              where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-141, -62, -139, -60, 4326))
     or exists (select 1 from public.venues
                 where location is not null
                   and (location::extensions.geometry) operator(extensions.&&)
                       extensions.ST_MakeEnvelope(-141, -62, -139, -60, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'msp-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_h, v_u]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (v_h, v_u);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_h, v_u);

  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and coalesce(h.min_age, 0) < 21
   order by h.slug limit 1;
  select h.id into v_b from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and coalesce(h.min_age, 0) < 21
     and h.id <> v_a
   order by h.slug limit 1;
  select h.id into v_s from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive and h.place_mode <> 'none' and coalesce(h.min_age, 0) < 21
   order by h.slug limit 1;
  if v_a is null or v_b is null or v_s is null then raise exception 'setup: hubs missing'; end if;

  -- An OSM place with no rules (it shows only through links).
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-msp-' || v_tag, 'MSP Court Alpha',
          'court_field', pg_temp.pt(-140.2300, -61.2300), true, 'active', '© OpenStreetMap contributors')
  returning id into v_osm;
  insert into public.place_hubs (place_id, hub_id, via) values (v_osm, v_b, 'moderator');

  insert into public.venues (name, location, is_public, created_by)
  values ('MSP Court Alpha', pg_temp.pt(-140.2302, -61.2301), true, v_h) returning id into v1;    -- about 15 m away
  insert into public.venues (name, address_line1, city, location, is_public, created_by)
  values ('MSP Corner Hall', '1 Fixture Way', 'Nowhere', pg_temp.pt(-140.3000, -61.3000), true, v_h) returning id into v2;
  insert into public.venues (name, location, is_public, created_by)
  values ('MSP Home', pg_temp.pt(-140.3500, -61.3500), false, v_h) returning id into v3;
  insert into public.venues (name, location, is_public, created_by)
  values ('MSP Quiet Room', pg_temp.pt(-140.4000, -61.4000), true, v_h) returning id into v4;
  insert into public.venues (name, location, is_public, created_by)
  values ('MSP Library Nook', pg_temp.pt(-140.4500, -61.4500), true, v_h) returning id into v5;

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'MSP plan at the court', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-140.2302, -61.2301)) returning id into e1;
  insert into public.event_addresses (event_id, venue_id) values (e1, v1);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'MSP plan at the hall', now() + interval '2 days', now() + interval '2 days 2 hours', 'Here',
          pg_temp.pt(-140.3, -61.3)) returning id into e2;
  insert into public.event_addresses (event_id, venue_id) values (e2, v2);
  -- A sensitive hub's plan at the same hall: no link for that hub.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_s, v_h, 'MSP sensitive plan', now() + interval '3 days', now() + interval '3 days 2 hours', 'Here',
          pg_temp.pt(-140.3, -61.3)) returning id into e4;
  insert into public.event_addresses (event_id, venue_id) values (e4, v2);

  -- Approved-only at a private venue, and approved-only at a public venue.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_a, v_h, 'MSP approved at home', now() + interval '1 day', now() + interval '1 day 2 hours', 'Near',
          pg_temp.pt(-140.4, -61.4), 'approved_only') returning id into e4;
  insert into public.event_addresses (event_id, venue_id) values (e4, v3);
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_a, v_h, 'MSP approved quiet', now() + interval '1 day', now() + interval '1 day 2 hours', 'Near',
          pg_temp.pt(-140.4, -61.4), 'approved_only') returning id into e4;
  insert into public.event_addresses (event_id, venue_id) values (e4, v4);
  perform set_config('test.e_appr', e4::text, true);

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'MSP plan at the nook', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-140.45, -61.45)) returning id into e4;
  insert into public.event_addresses (event_id, venue_id) values (e4, v5);

  -- The signed-in adult's private pin.
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'MSP my pin', 'spot', pg_temp.pt(-140.5, -61.5), false, 'active', v_u, 'Added by a member')
  returning id into v_pin;

  perform set_config('test.h', v_h::text, true);
  perform set_config('test.u', v_u::text, true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.s', v_s::text, true);
  perform set_config('test.osm', v_osm::text, true);
  perform set_config('test.pin', v_pin::text, true);
  perform set_config('test.v1', v1::text, true);
  perform set_config('test.v2', v2::text, true);
  perform set_config('test.v3', v3::text, true);
  perform set_config('test.v4', v4::text, true);
  perform set_config('test.v5', v5::text, true);
  perform set_config('test.e1', e1::text, true);
  perform set_config('test.e2', e2::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 29] then
    raise exception 'FAIL schema_version is older than 2.29';
  end if;
  if (select count(*) from pg_trigger
       where not tgisinternal and tgname in ('event_addresses_meeting_spot', 'events_meeting_spot',
                                             'venues_meeting_spot', 'venues_place_ref_guard')) <> 4 then
    raise exception 'FAIL a meeting spot trigger is missing';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.venue_for_place(uuid)'::regprocedure) then
    raise exception 'FAIL venue_for_place is not security definer';
  end if;
  if has_function_privilege('anon', 'public.venue_for_place(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.venue_for_place(uuid)', 'execute') then
    raise exception 'FAIL venue_for_place grants';
  end if;
  foreach f in array array['public.meeting_spot_sync_place(uuid)', 'public.meeting_spot_refresh(uuid)',
                           'public.refresh_meeting_spots()', 'public.meeting_spot_on_event_address()',
                           'public.meeting_spot_on_event()', 'public.meeting_spot_on_venue()'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL % is executable by a client role', f;
    end if;
  end loop;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'refresh-meeting-spots') then
    raise exception 'FAIL refresh-meeting-spots is not scheduled';
  end if;
  insert into msp_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Links (as the owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_osm uuid := current_setting('test.osm')::uuid;
  v_a   uuid := current_setting('test.a')::uuid;
  v_sp  uuid;
begin
  if (select place_ref from public.venues where id = current_setting('test.v1')::uuid) is distinct from v_osm then
    raise exception 'FAIL the venue beside an OSM place of the same name is not linked to it';
  end if;
  if pg_temp.spot(current_setting('test.v1')::uuid) is not null then
    raise exception 'FAIL a second pin was made for a venue that matched an OSM place';
  end if;
  if not exists (select 1 from public.place_hubs where place_id = v_osm and hub_id = v_a and via = 'events' and weight = 1) then
    raise exception 'FAIL the OSM place has no events link to the plan''s hub';
  end if;
  if not exists (select 1 from public.place_hubs where place_id = v_osm and hub_id = current_setting('test.b')::uuid
                    and via = 'moderator') then
    raise exception 'FAIL the moderator link was touched';
  end if;

  v_sp := pg_temp.spot(current_setting('test.v2')::uuid);
  if v_sp is null then raise exception 'FAIL no meeting spot for a public venue with a public plan'; end if;
  if not exists (select 1 from public.places
                  where id = v_sp and kind = 'spot' and status = 'active' and is_public and created_by is null
                    and osm_ref is null and address_text = '1 Fixture Way' and locality = 'Nowhere') then
    raise exception 'FAIL the meeting spot row has the wrong shape';
  end if;
  if (select place_ref from public.venues where id = current_setting('test.v2')::uuid) is distinct from v_sp then
    raise exception 'FAIL the venue does not point at its meeting spot';
  end if;
  if not exists (select 1 from public.place_hubs where place_id = v_sp and hub_id = v_a and via = 'events') then
    raise exception 'FAIL the meeting spot has no link to the plan''s hub';
  end if;
  if exists (select 1 from public.place_hubs where place_id = v_sp and hub_id = current_setting('test.s')::uuid) then
    raise exception 'FAIL a sensitive hub got a meeting spot link';
  end if;
  perform set_config('test.sp', v_sp::text, true);

  if pg_temp.spot(current_setting('test.v3')::uuid) is not null
     or (select place_ref from public.venues where id = current_setting('test.v3')::uuid) is not null then
    raise exception 'FAIL a private venue became a place';
  end if;
  if pg_temp.spot(current_setting('test.v4')::uuid) is not null
     or (select place_ref from public.venues where id = current_setting('test.v4')::uuid) is not null then
    raise exception 'FAIL an approved-only plan made a place';
  end if;
  if pg_temp.spot(current_setting('test.v5')::uuid) is null then
    raise exception 'FAIL no meeting spot for the nook';
  end if;
  insert into msp_lines (line) values ('links: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Reads, signed out
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  r     jsonb;
  d     jsonb;
  v_ids text[];
  v_fl  integer;
begin
  foreach r in array array[
      public.map_in_view(-140.6, -61.6, -140.1, -61.1, array[current_setting('test.a')::uuid]),
      public.map_in_view(-140.6, -61.6, -140.1, -61.1)] loop
    v_ids := array(select p.value ->> 0 from jsonb_array_elements(r -> 'places') p);
    if not (current_setting('test.osm') = any (v_ids)) or not (current_setting('test.sp') = any (v_ids)) then
      raise exception 'FAIL map_in_view is missing a meeting spot (% places)', cardinality(v_ids);
    end if;
    select (p.value ->> 5)::integer into v_fl from jsonb_array_elements(r -> 'places') p
     where p.value ->> 0 = current_setting('test.sp');
    if (v_fl & 16) = 0 then raise exception 'FAIL the meeting spot lacks flag 16'; end if;
  end loop;

  d := public.place_detail(current_setting('test.sp')::uuid);
  if not exists (select 1 from jsonb_array_elements(d -> 'plans_here') q where q.value ->> 'id' = current_setting('test.e2')) then
    raise exception 'FAIL plans_here of the meeting spot misses its plan';
  end if;
  if d ->> 'source' <> 'venue' or d ->> 'kind' <> 'spot' then raise exception 'FAIL meeting spot detail'; end if;
  if not exists (select 1 from jsonb_array_elements(d -> 'hubs') h where h.value ->> 'id' = current_setting('test.a')) then
    raise exception 'FAIL the meeting spot card does not list the hub';
  end if;
  d := public.place_detail(current_setting('test.osm')::uuid);
  if not exists (select 1 from jsonb_array_elements(d -> 'plans_here') q where q.value ->> 'id' = current_setting('test.e1')) then
    raise exception 'FAIL plans_here of the OSM place misses the plan at its venue';
  end if;
  if exists (select 1 from jsonb_array_elements(d -> 'plans_here') q where q.value ->> 'id' = current_setting('test.e_appr')) then
    raise exception 'FAIL an approved-only plan is in plans_here';
  end if;

  begin
    perform public.venue_for_place(current_setting('test.osm')::uuid);
    raise exception 'FAIL anon called venue_for_place';
  exception when insufficient_privilege then null;
  end;
  insert into msp_lines (line) values ('reads: ok');
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 4. Changes (as the owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_osm  uuid := current_setting('test.osm')::uuid;
  v_osm2 uuid;
  v_n    integer;
begin
  -- Cancelling the hall's only public plan (the sensitive one adds no link
  -- but still counts as a plan there, so cancel both).
  update public.events set status = 'cancelled', cancelled_at = now()
   where id in (select ea.event_id from public.event_addresses ea where ea.venue_id = current_setting('test.v2')::uuid);
  if pg_temp.spot(current_setting('test.v2')::uuid) is not null
     or (select place_ref from public.venues where id = current_setting('test.v2')::uuid) is not null then
    raise exception 'FAIL the meeting spot outlived its last plan';
  end if;

  -- Approved-only now: the events link goes, the moderator link and place_ref stay.
  update public.events set address_visibility = 'approved_only' where id = current_setting('test.e1')::uuid;
  if exists (select 1 from public.place_hubs where place_id = v_osm and via = 'events') then
    raise exception 'FAIL an approved-only plan still links the OSM place';
  end if;
  if not exists (select 1 from public.place_hubs where place_id = v_osm and via = 'moderator') then
    raise exception 'FAIL the moderator link went with the events link';
  end if;
  if (select place_ref from public.venues where id = current_setting('test.v1')::uuid) is distinct from v_osm then
    raise exception 'FAIL place_ref was dropped for a public venue';
  end if;

  -- The venue goes private (event_set_location's flip): no error, no link.
  update public.venues set is_public = false where id = current_setting('test.v1')::uuid;
  if (select place_ref from public.venues where id = current_setting('test.v1')::uuid) is not null then
    raise exception 'FAIL a private venue kept its place_ref';
  end if;

  -- OSM arrives at the nook: the weekly refresh moves the spot onto it.
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-msp2-' || current_setting('test.osm'), 'MSP Library Nook',
          'library', pg_temp.pt(-140.4501, -61.4500), true, 'active', '© OpenStreetMap contributors')
  returning id into v_osm2;
  v_n := public.refresh_meeting_spots();
  if v_n < 1 then raise exception 'FAIL refresh_meeting_spots looked at no venue'; end if;
  if pg_temp.spot(current_setting('test.v5')::uuid) is not null
     or (select place_ref from public.venues where id = current_setting('test.v5')::uuid) is distinct from v_osm2
     or not exists (select 1 from public.place_hubs where place_id = v_osm2 and via = 'events'
                       and hub_id = current_setting('test.a')::uuid) then
    raise exception 'FAIL the refresh did not move the spot onto the OSM place';
  end if;
  insert into msp_lines (line) values ('changes: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. venue_for_place, signed in
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
do $$
declare
  v1 public.venues;
  v2 public.venues;
begin
  v1 := public.venue_for_place(current_setting('test.osm')::uuid);
  if not v1.is_public or v1.place_ref is distinct from current_setting('test.osm')::uuid
     or v1.name <> 'MSP Court Alpha' or v1.location is null
     or v1.created_by is distinct from current_setting('test.u')::uuid then
    raise exception 'FAIL venue_for_place made the wrong venue';
  end if;
  v2 := public.venue_for_place(current_setting('test.osm')::uuid);
  if v2.id <> v1.id then raise exception 'FAIL venue_for_place made a second venue'; end if;
  perform set_config('test.vp', v1.id::text, true);

  begin
    perform public.venue_for_place(gen_random_uuid());
    raise exception 'FAIL a missing place gave a venue';
  exception when no_data_found then null;
  end;
  begin
    perform public.venue_for_place(current_setting('test.pin')::uuid);
    raise exception 'FAIL a private pin gave a venue';
  exception when no_data_found then null;
  end;
  insert into msp_lines (line) values ('venue_for_place: ok');
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  e uuid;
begin
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (current_setting('test.a')::uuid, current_setting('test.u')::uuid, 'MSP plan from the map',
          now() + interval '4 days', now() + interval '4 days 2 hours', 'Here', pg_temp.pt(-140.23, -61.23))
  returning id into e;
  insert into public.event_addresses (event_id, venue_id) values (e, current_setting('test.vp')::uuid);
  if not exists (select 1 from public.place_hubs where place_id = current_setting('test.osm')::uuid
                    and hub_id = current_setting('test.a')::uuid and via = 'events') then
    raise exception 'FAIL a plan at the venue from venue_for_place did not link the place';
  end if;
  insert into msp_lines (line) values ('start a plan here: ok');
end $$;

select line as meeting_spots from (
  select 0 as n, 'meeting_spots: all assertions passed' as line
  union all
  select n, line from msp_lines) x
order by n;

rollback;
