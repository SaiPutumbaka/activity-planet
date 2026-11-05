-- ============================================================================
-- Staging check for migrations 20261124000100_places_read.sql and
-- 20261124000200_places_read_fixes.sql (D-041, hub map
-- slice 6: map_in_view, places_in_view, place_detail). One transaction with
-- fixture places and events in the Southern Ocean (no real places there) and
-- across the antimeridian, asserts with DO blocks that raise on failure, then
-- rolls everything back. Prints pass/fail only, never rows.
-- Run as the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.26 or later (migration 30, 20261124000200, rebuilt
--     places_in_view); the three RPCs and map_view_hubs run as
--     the caller, the two "mine" helpers as definer; all of them STABLE or
--     IMMUTABLE (so none can write: no viewing logs); anon and
--     authenticated execute them.
--   2 Signed out: every specific hub's places when no hubs are passed;
--     generic spots only for one selected hub with generic set; events-only
--     hubs never; hidden, closed, private, pending and out-of-view places
--     never; hub_idxs and flags; the cap and nearest-first order; zoom_in;
--     the antimeridian split; kinds and name search; plans, shows and the
--     approved-only cells; 21+, cancelled and out-of-window events hidden;
--     errors; place_detail (OSM link, address, hubs, plans_here without
--     approved-only events, no creator, private places not found).
--   3 The creator: joined hubs by default, own private and pending pins
--     flagged, place_detail mine and no address on a private pin.
--   4 An adult with no hubs: no_hubs, plans still shown.
--   5 A moderator and the host of an approved-only event: never a point.
--   6 Nothing was written: place_tiles demand unchanged.
-- ============================================================================
begin;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- Fixture id -> label map, read by a definer helper so every role can turn a
-- response into a sorted label list. Unknown ids come back as '?'.
create table public.prd_test_ids (id uuid primary key, label text not null);
create function public.prd_test_labels(p jsonb)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(string_agg(coalesce(l.label, '?'), ',' order by coalesce(l.label, '?')), '')
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) f
    left join public.prd_test_ids l on l.id::text = f.value ->> 0;
$$;
create function public.prd_test_cell_labels(p jsonb)
returns text language sql stable security definer set search_path = '' as $$
  select coalesce(string_agg(coalesce(l.label, '?'), ',' order by coalesce(l.label, '?')), '')
    from jsonb_array_elements(coalesce(p, '[]'::jsonb)) c
   cross join lateral jsonb_array_elements_text(c.value -> 3) i(id)
    left join public.prd_test_ids l on l.id::text = i.id;
$$;
create function public.prd_test_feature(p jsonb, p_label text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select f.value from jsonb_array_elements(coalesce(p, '[]'::jsonb)) f
    join public.prd_test_ids l on l.id::text = f.value ->> 0 and l.label = p_label
   limit 1;
$$;
grant execute on function public.prd_test_labels(jsonb), public.prd_test_cell_labels(jsonb),
  public.prd_test_feature(jsonb, text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_u   uuid := gen_random_uuid();   -- creator: joins hubs A and A2, owns member places
  v_h   uuid := gen_random_uuid();   -- host of the plans
  v_v   uuid := gen_random_uuid();   -- adult with no hubs
  v_m   uuid := gen_random_uuid();   -- moderator
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_a   uuid;  v_a2 uuid;  v_b uuid;  v_n uuid;
  v_ven uuid;
  v_id  uuid;
  v_e   uuid;
begin
  if exists (select 1 from public.places
              where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-151, -61, -149, -59, 4326)
                 or geom operator(extensions.&&) extensions.ST_MakeEnvelope(179.5, -61, 180, -59, 4326)
                 or geom operator(extensions.&&) extensions.ST_MakeEnvelope(-180, -61, -179.5, -59, 4326))
     or exists (select 1 from public.events
                 where approx_point is not null
                   and (approx_point::extensions.geometry) operator(extensions.&&)
                       extensions.ST_MakeEnvelope(-151, -61, -149, -59, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;
  if exists (select 1 from public.place_rules where id between 32001 and 32004) then
    raise exception 'setup: fixture rule ids are taken';
  end if;
  perform set_config('test.demand', (select coalesce(sum(demand), 0)::text from public.place_tiles), true);

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'prd-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_u, v_h, v_v, v_m]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (v_u, v_h, v_v, v_m);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_u, v_h, v_v, v_m);
  insert into public.user_roles (user_id, role) values (v_m, 'moderator');

  -- Hubs: two specific (A, A2), one generic (B), one events-only (N), none sensitive.
  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' order by h.slug limit 1;
  select h.id into v_a2 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and h.id <> v_a order by h.slug limit 1;
  select h.id into v_b from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'generic' order by h.slug limit 1;
  select h.id into v_n from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'none' order by h.slug limit 1;
  if v_a is null or v_a2 is null or v_b is null or v_n is null then
    raise exception 'setup: missing a specific, generic or events-only hub';
  end if;
  insert into public.hub_members (hub_id, user_id, joined_at) values
    (v_a, v_u, now() - interval '2 days'), (v_a2, v_u, now() - interval '1 day');

  -- Fixture rules: 32001 for A, 32002 for B, 32003 for N, 32004 for A2.
  insert into public.place_rules (id, osm_key, osm_value, kind, verified, rules_version) values
    (32001, 'prd_test', 'a', 'court_field', true, 1), (32002, 'prd_test', 'b', 'park', true, 1),
    (32003, 'prd_test', 'n', 'court_field', true, 1), (32004, 'prd_test', 'a2', 'court_field', true, 1);
  insert into public.hub_place_rules (hub_id, rule_id) values
    (v_a, 32001), (v_b, 32002), (v_n, 32003), (v_a2, 32004);

  insert into public.venues (name, location, created_by, is_public)
  values ('Read test hall', pg_temp.pt(-150.24, -60.24), v_h, true) returning id into v_ven;

  -- Places
  insert into public.places (source, source_id, osm_ref, name, kind, location, is_public, status, attribution,
                             rule_ids, address_text)
  values ('osm', 'n9100000001', 'n9100000001', 'Read test court', 'court_field', pg_temp.pt(-150.20, -60.20),
          true, 'active', '© OpenStreetMap contributors', '{32001}', '1 Test Street')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pa1');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000002', 'Second field', 'court_field', pg_temp.pt(-150.30, -60.30), true, 'active', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pa2');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('geoapify', 'gx-prd-1', 'Centre field', 'court_field', pg_temp.pt(-150.25, -60.25), true, 'active', 'x', '{32001,32004}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pa3');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000003', 'Generic park', 'park', pg_temp.pt(-150.22, -60.22), true, 'active', 'x', '{32002}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pg1');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000004', 'Events only spot', 'court_field', pg_temp.pt(-150.21, -60.21), true, 'active', 'x', '{32003}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pn1');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000005', 'Linked to events only', 'court_field', pg_temp.pt(-150.21, -60.29), true, 'active', 'x', '{}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pnl');
  insert into public.place_hubs (place_id, hub_id, via) values (v_id, v_n, 'moderator');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000006', 'Hidden court', 'court_field', pg_temp.pt(-150.23, -60.21), true, 'hidden', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'ph1');
  perform set_config('test.ph1', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000007', 'Closed court', 'court_field', pg_temp.pt(-150.23, -60.22), true, 'closed', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pc1');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000008', 'Far court', 'court_field', pg_temp.pt(-140.20, -60.20), true, 'active', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pfar');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('venue', v_ven::text, 'Read test hall', 'spot', pg_temp.pt(-150.24, -60.24), true, 'active', 'x', '{}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pv1');
  perform set_config('test.pv1', v_id::text, true);
  insert into public.place_hubs (place_id, hub_id, via) values (v_id, v_a, 'events');
  update public.venues set place_ref = v_id where id = v_ven;
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by, address_text)
  values ('user', 'My private pin', 'spot', pg_temp.pt(-150.26, -60.26), false, 'active', 'x', v_u, '2 Pin Road')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pu1');
  perform set_config('test.pu1', v_id::text, true);
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'My pending spot', 'spot', pg_temp.pt(-150.27, -60.27), true, 'pending', 'x', v_u)
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pu2');
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Reviewed member spot', 'spot', pg_temp.pt(-150.35, -60.35), true, 'active', 'x', v_u)
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pu3');
  insert into public.place_hubs (place_id, hub_id, via) values (v_id, v_a, 'member');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000009', 'East of the line', 'court_field', pg_temp.pt(179.95, -60.2), true, 'active', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pe1');
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9100000010', 'West of the line', 'court_field', pg_temp.pt(-179.95, -60.2), true, 'active', 'x', '{32001}')
  returning id into v_id;
  insert into public.prd_test_ids values (v_id, 'pw1');

  -- Events (all overlap the default window unless noted)
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'Read test pickup', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-150.23, -60.23)) returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e1');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_b, v_h, 'Read test approved only', now() + interval '1 day', now() + interval '1 day 2 hours', 'Near here',
          pg_temp.pt(-150.2, -60.2), 'approved_only') returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e2');
  perform set_config('test.e2', v_e::text, true);
  insert into public.events (kind, hub_id, title, starts_at, ends_at, location_hint, approx_point, listing_kind,
                             external_url, source_name)
  values ('imported', v_a2, 'Read test show', now() + interval '2 days', now() + interval '2 days 3 hours', 'Arena',
          pg_temp.pt(-150.28, -60.28), 'show', 'https://example.com/prd-show', 'Test') returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e3');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, min_age)
  values (v_a, v_h, 'Read test 21 plus', now() + interval '1 day', now() + interval '1 day 2 hours', 'Bar',
          pg_temp.pt(-150.29, -60.29), 21) returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e4');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'Read test far future', now() + interval '20 days', now() + interval '20 days 2 hours', 'Here',
          pg_temp.pt(-150.21, -60.21)) returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e5');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'Read test at the hall', now() + interval '2 days', now() + interval '2 days 2 hours', 'Hall',
          pg_temp.pt(-150.24, -60.24)) returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e6');
  insert into public.event_addresses (event_id, venue_id, location_text) values (v_e, v_ven, 'Read test hall');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_a, v_h, 'Read test hall approved only', now() + interval '3 days', now() + interval '3 days 2 hours',
          'Near here', pg_temp.pt(-150.2, -60.2), 'approved_only') returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e7');
  insert into public.event_addresses (event_id, venue_id, location_text) values (v_e, v_ven, 'Read test hall');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, status,
                             cancelled_at, cancel_reason)
  values (v_a, v_h, 'Read test cancelled', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-150.22, -60.23), 'cancelled', now(), 'test') returning id into v_e;
  insert into public.prd_test_ids values (v_e, 'e8');

  perform set_config('test.u', v_u::text, true);
  perform set_config('test.h', v_h::text, true);
  perform set_config('test.v', v_v::text, true);
  perform set_config('test.m', v_m::text, true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.a2', v_a2::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.n', v_n::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 26] then
    raise exception 'FAIL schema_version is older than 2.26';
  end if;
  for r in
    select p.oid::regprocedure as sig, p.proname, p.prosecdef, p.provolatile
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('map_in_view', 'places_in_view', 'place_detail', 'map_view_box', 'map_view_hubs',
                         'places_own_in_view', 'place_is_mine')
  loop
    if r.provolatile not in ('s', 'i') then
      raise exception 'FAIL % is volatile (could write a viewing log)', r.proname;
    end if;
    if r.prosecdef <> (r.proname in ('places_own_in_view', 'place_is_mine')) then
      raise exception 'FAIL % has the wrong security mode', r.proname;
    end if;
    if not has_function_privilege('anon', r.sig, 'execute')
       or not has_function_privilege('authenticated', r.sig, 'execute') then
      raise exception 'FAIL % is not executable by anon and authenticated', r.proname;
    end if;
  end loop;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public'
         and p.proname in ('map_in_view', 'places_in_view', 'place_detail', 'map_view_box', 'map_view_hubs',
                           'places_own_in_view', 'place_is_mine')) <> 7 then
    raise exception 'FAIL expected exactly one version of each read function';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Signed out
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_a2 uuid := current_setting('test.a2')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_n  uuid := current_setting('test.n')::uuid;
  r    jsonb;
  f    jsonb;
  s    text;
  v_c  jsonb;
begin
  -- Every specific hub when none are passed.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0);
  s := public.prd_test_labels(r -> 'places');
  if s <> 'pa1,pa2,pa3,pu3,pv1' then raise exception 'FAIL anon all-specific saw %', s; end if;
  if jsonb_array_length(r -> 'hubs') <> 0 or (r ->> 'zoom_in')::boolean or (r ->> 'no_hubs')::boolean
     or (r ->> 'truncated')::boolean then
    raise exception 'FAIL anon all-specific flags %', r - 'places';
  end if;
  f := public.prd_test_feature(r -> 'places', 'pa1');
  if jsonb_array_length(f) <> 8 or f -> 4 <> 'null'::jsonb or f -> 7 <> '[]'::jsonb
     or (f ->> 1)::numeric <> -150.2 or (f ->> 2)::numeric <> -60.2 or f ->> 3 <> 'court_field'
     or f ->> 6 <> 'Read test court' or (f ->> 5)::integer <> 0 then
    raise exception 'FAIL pa1 encoding %', f;
  end if;

  -- A generic hub: only alone and with generic set.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_b]);
  if public.prd_test_labels(r -> 'places') <> '' then raise exception 'FAIL generic hub without generic set'; end if;
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_b], true);
  if public.prd_test_labels(r -> 'places') <> 'pg1' or not (r ->> 'generic')::boolean then
    raise exception 'FAIL generic hub alone saw %', public.prd_test_labels(r -> 'places');
  end if;
  f := public.prd_test_feature(r -> 'places', 'pg1');
  if (f ->> 5)::integer <> 1 or (f ->> 4)::integer <> 0 then raise exception 'FAIL general spot flags %', f; end if;
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a, v_b], true);
  if public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu3,pv1' or (r ->> 'generic')::boolean then
    raise exception 'FAIL generic set with two hubs saw %', public.prd_test_labels(r -> 'places');
  end if;

  -- An events-only hub never shows places, not even linked ones.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_n], true);
  if public.prd_test_labels(r -> 'places') <> '' then raise exception 'FAIL events-only hub showed places'; end if;

  -- Two hubs: hub_idxs and flags.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a, v_a2, v_a]);
  if public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu3,pv1' or jsonb_array_length(r -> 'hubs') <> 2
     or r -> 'hubs' -> 0 ->> 0 <> v_a::text or r -> 'hubs' -> 1 ->> 0 <> v_a2::text then
    raise exception 'FAIL two hubs saw % with hubs %', public.prd_test_labels(r -> 'places'), r -> 'hubs';
  end if;
  f := public.prd_test_feature(r -> 'places', 'pa3');
  if f -> 7 <> '[0, 1]'::jsonb or (f ->> 4)::integer <> 0 or (f ->> 5)::integer <> 32 then
    raise exception 'FAIL pa3 (Geoapify, two hubs) encoding %', f;
  end if;
  if (public.prd_test_feature(r -> 'places', 'pv1') ->> 5)::integer <> 16
     or public.prd_test_feature(r -> 'places', 'pv1') -> 7 <> '[0]'::jsonb
     or (public.prd_test_feature(r -> 'places', 'pu3') ->> 5)::integer <> 8 then
    raise exception 'FAIL meeting spot or member place flags';
  end if;
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a2]);
  if public.prd_test_labels(r -> 'places') <> 'pa3' then
    raise exception 'FAIL hub A2 saw %', public.prd_test_labels(r -> 'places');
  end if;

  -- Cap and nearest-first order.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a], false, null, null, 2);
  if jsonb_array_length(r -> 'places') <> 2 or not (r ->> 'truncated')::boolean
     or not (r -> 'more' ->> 'places')::boolean
     or public.prd_test_labels(jsonb_build_array(r -> 'places' -> 0)) <> 'pa3'
     or public.prd_test_labels(jsonb_build_array(r -> 'places' -> 1)) <> 'pv1' then
    raise exception 'FAIL cap and order: %', public.prd_test_labels(r -> 'places');
  end if;

  -- zoom_in above 1.0 x 1.5 degrees; exactly 1.0 x 1.5 is fine.
  r := public.places_in_view(-151.0, -61.0, -149.0, -59.5, array[v_a]);
  if not (r ->> 'zoom_in')::boolean or r -> 'places' <> 'null'::jsonb then raise exception 'FAIL zoom_in'; end if;
  r := public.places_in_view(-151.0, -61.0, -149.5, -60.0, array[v_a]);
  if (r ->> 'zoom_in')::boolean or public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu3,pv1' then
    raise exception 'FAIL a 1.0 x 1.5 view';
  end if;

  -- The antimeridian: west > east is split in two.
  r := public.places_in_view(179.9, -60.3, -179.9, -60.1, array[v_a]);
  if public.prd_test_labels(r -> 'places') <> 'pe1,pw1' then
    raise exception 'FAIL antimeridian saw %', public.prd_test_labels(r -> 'places');
  end if;
  r := public.places_in_view(-179.9, -60.3, 179.9, -60.1, array[v_a]);
  if not (r ->> 'zoom_in')::boolean then raise exception 'FAIL a world-wide view was not zoom_in'; end if;

  -- Kinds and name search.
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a], false, array['spot']);
  if public.prd_test_labels(r -> 'places') <> 'pu3,pv1' then
    raise exception 'FAIL kinds saw %', public.prd_test_labels(r -> 'places');
  end if;
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a], false, null, ' read TEST ');
  if public.prd_test_labels(r -> 'places') <> 'pa1,pv1' then
    raise exception 'FAIL search saw %', public.prd_test_labels(r -> 'places');
  end if;
  r := public.places_in_view(-150.5, -60.5, -150.0, -60.0, array[v_a], false, null, '%_');
  if public.prd_test_labels(r -> 'places') <> '' then raise exception 'FAIL a %% search matched everything'; end if;

  -- map_in_view: places, plans, shows and approved-only cells.
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0);
  if public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu3,pv1' then
    raise exception 'FAIL map places %', public.prd_test_labels(r -> 'places');
  end if;
  if public.prd_test_labels(r -> 'plans') <> 'e1,e6' then
    raise exception 'FAIL anon plans %', public.prd_test_labels(r -> 'plans');
  end if;
  if public.prd_test_labels(r -> 'shows') <> 'e3' then
    raise exception 'FAIL anon shows %', public.prd_test_labels(r -> 'shows');
  end if;
  if public.prd_test_cell_labels(r -> 'cells') <> 'e2,e7' or jsonb_array_length(r -> 'cells') <> 1 then
    raise exception 'FAIL anon cells %', public.prd_test_cell_labels(r -> 'cells');
  end if;
  v_c := r -> 'cells' -> 0;
  if (v_c ->> 0)::numeric <> -150.2 or (v_c ->> 1)::numeric <> -60.2 or (v_c ->> 2)::integer <> 2
     or jsonb_array_length(v_c -> 4) <> 2 then
    raise exception 'FAIL cell encoding %', v_c;
  end if;
  f := public.prd_test_feature(r -> 'plans', 'e1');
  if jsonb_array_length(f) <> 8 or (f ->> 1)::numeric <> -150.23 or (f ->> 2)::numeric <> -60.23
     or f ->> 3 <> 'member' or f ->> 6 <> 'Read test pickup' or (f ->> 7)::bigint < extract(epoch from now())::bigint
     or ((f ->> 5)::integer & 2) <> 0 or r -> 'hubs' -> (f ->> 4)::integer ->> 0 <> v_a::text then
    raise exception 'FAIL plan encoding % hubs %', f, r -> 'hubs';
  end if;
  f := public.prd_test_feature(r -> 'shows', 'e3');
  if ((f ->> 5)::integer & 1) <> 1 or r -> 'hubs' -> (f ->> 4)::integer ->> 0 <> v_a2::text then
    raise exception 'FAIL show encoding %', f;
  end if;
  if exists (select 1 from jsonb_array_elements(coalesce(r -> 'plans', '[]') || coalesce(r -> 'shows', '[]')) x
              where public.prd_test_labels(jsonb_build_array(x.value)) in ('e2', 'e7')) then
    raise exception 'FAIL an approved-only event came back as a point';
  end if;
  -- Window and layers.
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, array['plans'], now(), now() + interval '30 days');
  if r -> 'places' <> 'null'::jsonb or r -> 'shows' <> 'null'::jsonb
     or public.prd_test_labels(r -> 'plans') <> 'e1,e5,e6' then
    raise exception 'FAIL plans-only 30 days %', public.prd_test_labels(r -> 'plans');
  end if;
  r := public.map_in_view(-152.0, -62.0, -149.0, -59.0, array[v_a]);
  if not (r ->> 'zoom_in')::boolean or r -> 'places' <> 'null'::jsonb or public.prd_test_labels(r -> 'plans') <> 'e1,e6' then
    raise exception 'FAIL zoomed-out map %', r - 'plans' - 'shows' - 'cells';
  end if;

  -- Errors
  begin perform public.map_in_view(-150.0, -60.0, -150.5, -60.0); raise exception 'FAIL flat bbox';
  exception when check_violation then if sqlerrm <> 'invalid_bbox' then raise; end if; end;
  begin perform public.map_in_view(-150.5, -60.0, -150.0, -60.5); raise exception 'FAIL south > north';
  exception when check_violation then if sqlerrm <> 'invalid_bbox' then raise; end if; end;
  begin perform public.map_in_view(-190, -60.5, -150.0, -60.0); raise exception 'FAIL lng -190';
  exception when check_violation then if sqlerrm <> 'invalid_bbox' then raise; end if; end;
  begin perform public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, null, now(), now() + interval '32 days');
    raise exception 'FAIL window_too_long';
  exception when check_violation then if sqlerrm <> 'window_too_long' then raise; end if; end;
  begin perform public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, null, now(), now() - interval '1 hour');
    raise exception 'FAIL invalid_window';
  exception when check_violation then if sqlerrm <> 'invalid_window' then raise; end if; end;
  begin perform public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, array['people']);
    raise exception 'FAIL layers_invalid';
  exception when check_violation then if sqlerrm <> 'layers_invalid' then raise; end if; end;
  begin perform public.places_in_view(-150.5, -60.5, -150.0, -60.0, null, false, null, 'a');
    raise exception 'FAIL query_length';
  exception when check_violation then if sqlerrm <> 'query_length' then raise; end if; end;

  -- place_detail
  r := public.place_detail((select public.prd_test_feature(public.places_in_view(-150.5, -60.5, -150.0, -60.0) -> 'places', 'pa1') ->> 0)::uuid);
  if r ->> 'name' <> 'Read test court' or r ->> 'osm_url' <> 'https://www.openstreetmap.org/node/9100000001'
     or r ->> 'address_text' <> '1 Test Street' or (r ->> 'mine')::boolean or r ? 'created_by'
     or r ->> 'source' <> 'osm' or r ->> 'checked_at' is null or r ->> 'kind_icon' is null
     or not exists (select 1 from jsonb_array_elements(r -> 'hubs') h where h.value ->> 'id' = v_a::text) then
    raise exception 'FAIL place_detail pa1 %', r - 'plans_here';
  end if;
  r := public.place_detail(current_setting('test.pv1')::uuid);
  if public.prd_test_labels((select jsonb_agg(jsonb_build_array(x.value ->> 'id')) from jsonb_array_elements(r -> 'plans_here') x)) <> 'e6'
     or r ->> 'checked_at' is not null or r ->> 'osm_url' is not null then
    raise exception 'FAIL place_detail pv1 plans_here %', r -> 'plans_here';
  end if;
  begin perform public.place_detail(current_setting('test.pu1')::uuid); raise exception 'FAIL anon read a private pin';
  exception when sqlstate 'PT404' then if sqlerrm <> 'place_not_found' then raise; end if; end;
  begin perform public.place_detail(current_setting('test.ph1')::uuid); raise exception 'FAIL anon read a hidden place';
  exception when sqlstate 'PT404' then if sqlerrm <> 'place_not_found' then raise; end if; end;
  begin perform public.place_detail(null); raise exception 'FAIL null id';
  exception when sqlstate 'PT404' then if sqlerrm <> 'place_not_found' then raise; end if; end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. The creator
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_a2 uuid := current_setting('test.a2')::uuid;
  r    jsonb;
  f    jsonb;
begin
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0);
  if public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu1,pu2,pu3,pv1' or (r ->> 'no_hubs')::boolean
     or r -> 'hubs' -> 0 ->> 0 <> v_a::text or r -> 'hubs' -> 1 ->> 0 <> v_a2::text then
    raise exception 'FAIL creator saw % hubs %', public.prd_test_labels(r -> 'places'), r -> 'hubs';
  end if;
  -- Own pins first.
  if public.prd_test_labels(jsonb_build_array(r -> 'places' -> 0, r -> 'places' -> 1, r -> 'places' -> 2)) <> 'pu1,pu2,pu3' then
    raise exception 'FAIL own pins are not first';
  end if;
  if (public.prd_test_feature(r -> 'places', 'pu1') ->> 5)::integer <> 4 + 8 + 64
     or (public.prd_test_feature(r -> 'places', 'pu2') ->> 5)::integer <> 2 + 8 + 64
     or (public.prd_test_feature(r -> 'places', 'pu3') ->> 5)::integer <> 8 + 64
     or (public.prd_test_feature(r -> 'places', 'pa1') ->> 5)::integer <> 0 then
    raise exception 'FAIL own pin flags';
  end if;
  f := public.prd_test_feature(r -> 'plans', 'e1');
  if ((f ->> 5)::integer & 2) <> 2 then raise exception 'FAIL a plan in a joined hub is not flagged'; end if;
  if public.prd_test_labels(r -> 'plans') <> 'e1,e4,e6' or public.prd_test_cell_labels(r -> 'cells') <> 'e2,e7' then
    raise exception 'FAIL creator plans % cells %', public.prd_test_labels(r -> 'plans'), public.prd_test_cell_labels(r -> 'cells');
  end if;
  r := public.place_detail(current_setting('test.pu1')::uuid);
  if not (r ->> 'mine')::boolean or r ->> 'address_text' is not null or (r ->> 'is_public')::boolean
     or r ? 'created_by' then
    raise exception 'FAIL creator place_detail of a private pin %', r;
  end if;
  r := public.place_detail(current_setting('test.pv1')::uuid);
  if (r ->> 'mine')::boolean or not (r -> 'hubs' -> 0 ->> 'joined')::boolean then
    raise exception 'FAIL place_detail joined hubs first %', r -> 'hubs';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. An adult with no hubs
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.v'), 'role', 'authenticated')::text, true);
do $$
declare
  r jsonb;
begin
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0);
  if not (r ->> 'no_hubs')::boolean or jsonb_array_length(r -> 'places') <> 0
     or public.prd_test_labels(r -> 'plans') <> 'e1,e4,e6' then
    raise exception 'FAIL no-hubs adult saw places % plans %', public.prd_test_labels(r -> 'places'),
      public.prd_test_labels(r -> 'plans');
  end if;
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, array['plans', 'shows']);
  if not (r ->> 'no_hubs')::boolean then raise exception 'FAIL no_hubs without the places layer'; end if;
  begin perform public.place_detail(current_setting('test.pu1')::uuid); raise exception 'FAIL another adult read a private pin';
  exception when sqlstate 'PT404' then if sqlerrm <> 'place_not_found' then raise; end if; end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 5. A moderator and the host: approved-only is never a point
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
do $$
declare
  r jsonb;
begin
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0, array[current_setting('test.a')::uuid]);
  if public.prd_test_labels(r -> 'places') <> 'pa1,pa2,pa3,pu3,pv1' then
    raise exception 'FAIL moderator map places %', public.prd_test_labels(r -> 'places');
  end if;
  if public.prd_test_labels(r -> 'plans') <> 'e1,e4,e6' or public.prd_test_cell_labels(r -> 'cells') <> 'e2,e7' then
    raise exception 'FAIL moderator plans % cells %', public.prd_test_labels(r -> 'plans'),
      public.prd_test_cell_labels(r -> 'cells');
  end if;
  r := public.place_detail(current_setting('test.ph1')::uuid);
  if r ->> 'status' <> 'hidden' or (r ->> 'mine')::boolean then raise exception 'FAIL moderator place_detail'; end if;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
do $$
declare
  r jsonb;
begin
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0);
  if public.prd_test_cell_labels(r -> 'cells') <> 'e2,e7'
     or public.prd_test_labels(r -> 'plans') <> 'e1,e4,e6' then
    raise exception 'FAIL host plans % cells %', public.prd_test_labels(r -> 'plans'),
      public.prd_test_cell_labels(r -> 'cells');
  end if;
  r := public.place_detail(current_setting('test.pv1')::uuid);
  if public.prd_test_labels((select jsonb_agg(jsonb_build_array(x.value ->> 'id')) from jsonb_array_elements(r -> 'plans_here') x)) <> 'e6' then
    raise exception 'FAIL the host saw an approved-only event in plans_here';
  end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 6. Nothing was written
-- ---------------------------------------------------------------------------
do $$
begin
  if (select coalesce(sum(demand), 0)::text from public.place_tiles) <> current_setting('test.demand') then
    raise exception 'FAIL a read changed place_tiles demand';
  end if;
end $$;

select 'places_read: all assertions passed' as result;

rollback;
