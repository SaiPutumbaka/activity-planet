-- ============================================================================
-- Staging check for migration 20261130000100_places_review_fixes.sql (D-041,
-- fix forward of migrations 33 to 35). One transaction, asserts in DO blocks
-- that raise on failure, rolled back at the end. Prints pass/fail lines only,
-- never names, ids or points (the repo and its Action logs are public). Run
-- as the staging_file of a staging_only migrate.yml run. The fixtures sit in
-- the Southern Ocean (lng -131 to -127, lat -65 to -63), where no real data is.
--
-- Checks:
--   0 version 2.32; no client reaches place_rate_log or its trigger
--     functions; venue_preview_for_place is for signed-in users only.
--   1 mod_resolve_place reports: a moderator cannot dismiss reports against
--     their own place, nor remove a place on their own report (own_item);
--     another moderator can.
--   2 retire_place_tiles keeps OSM rows a moderator hid or removed and still
--     deletes plain rows and merge leftovers.
--   3 deleting a pin does not give an add back (10 a day) and deleting a
--     place does not give its edits back (30 a day); account deletion
--     removes the caller's rate log.
--   4 a venue whose only plans are in a sensitive or events-only hub gets
--     no meeting spot; an existing one goes on refresh_meeting_spots and
--     leaves places_odbl_export.
--   5 a meeting spot a moderator hid stays hidden through new plans and a
--     plan-less venue (place_ref cleared, no events links); dismissed, it
--     comes back on the next refresh.
--   6 venue_preview_for_place creates no venue and returns the venue once
--     venue_for_place made it.
-- ============================================================================
begin;

create temp table prf_lines (n serial, line text);
grant insert, select on prf_lines to anon, authenticated;
grant usage on sequence prf_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

create function pg_temp.spot(p_venue uuid) returns uuid language sql stable as $$
  select p.id from public.places p where p.source = 'venue' and p.source_id = p_venue::text;
$$;

grant execute on function pg_temp.as_user(uuid) to anon, authenticated;
grant execute on function pg_temp.try(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 0. Version and grants
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 32] then
    raise exception 'FAIL schema_version is older than 2.32';
  end if;
  if has_table_privilege('anon', 'public.place_rate_log', 'select')
     or has_table_privilege('authenticated', 'public.place_rate_log', 'select')
     or has_table_privilege('authenticated', 'public.place_rate_log', 'insert')
     or has_table_privilege('authenticated', 'public.place_rate_log', 'delete') then
    raise exception 'FAIL a client can reach place_rate_log';
  end if;
  foreach f in array array['public.place_rate_log_on_place()', 'public.place_rate_log_on_edit()'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL a client can execute %', f;
    end if;
  end loop;
  if has_function_privilege('anon', 'public.venue_preview_for_place(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.venue_preview_for_place(uuid)', 'execute') then
    raise exception 'FAIL venue_preview_for_place grants';
  end if;
  insert into prf_lines (line) values ('version and grants: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  u1  uuid := gen_random_uuid();   -- member (adds)
  u2  uuid := gen_random_uuid();   -- member (reports, edits)
  u3  uuid := gen_random_uuid();   -- member (Start a plan here)
  um  uuid := gen_random_uuid();   -- moderator
  um2 uuid := gen_random_uuid();   -- second moderator
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_a uuid; v_s uuid; v_n uuid;
begin
  if exists (select 1 from public.places
              where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-131, -65, -127, -63, 4326))
     or exists (select 1 from public.venues
                 where location is not null
                   and (location::extensions.geometry) operator(extensions.&&)
                       extensions.ST_MakeEnvelope(-131, -65, -127, -63, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'prf-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2, u3, um, um2]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2, u3, um, um2);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (u1, u2, u3, um, um2);
  insert into public.user_roles (user_id, role) values (um, 'moderator'), (um2, 'moderator');

  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and coalesce(h.min_age, 0) < 21
     and exists (select 1 from public.hub_place_rules hr join public.place_rules r on r.id = hr.rule_id
                  where hr.hub_id = h.id and r.kind = 'court_field')
   order by h.slug limit 1;
  select h.id into v_s from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive and h.place_mode <> 'none' and coalesce(h.min_age, 0) < 21
   order by h.slug limit 1;
  select h.id into v_n from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'none' and coalesce(h.min_age, 0) < 21
   order by h.slug limit 1;
  if v_a is null or v_s is null then raise exception 'setup: hubs missing'; end if;
  insert into public.hub_members (user_id, hub_id) values (u1, v_a), (u2, v_a), (um, v_a);

  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.u3', u3::text, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.um2', um2::text, true);
  perform set_config('t.a', v_a::text, true);
  perform set_config('t.s', v_s::text, true);
  perform set_config('t.n', coalesce(v_n::text, ''), true);
  perform set_config('t.tag', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. own_item on reports
-- ---------------------------------------------------------------------------
do $$
declare
  v_osm uuid;
begin
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-1-' || current_setting('t.tag'), 'PRF Field', 'park', pg_temp.pt(-130.8, -63.2),
          true, 'active', '© OpenStreetMap contributors')
  returning id into v_osm;
  perform set_config('t.osm1', v_osm::text, true);
end $$;

set local role authenticated;
do $$
declare
  r   jsonb;
  v_p uuid;
  t   text;
begin
  -- The moderator's own place, hidden by another member's report.
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  r := public.add_place(jsonb_build_object('name', 'PRF Mod Spot', 'kind', 'court_field',
         'lat', -63.3, 'lng', -130.7, 'is_public', true, 'confirm_public', true,
         'hub_ids', jsonb_build_array(current_setting('t.a'))));
  v_p := (r ->> 'id')::uuid;
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  r := public.report_place(v_p, 'private_residence', null);
  if (r ->> 'hidden')::boolean is not true then raise exception 'FAIL setup: the report did not hide the place'; end if;

  perform pg_temp.as_user(current_setting('t.um')::uuid);
  t := pg_temp.try(format('select public.mod_resolve_place(%L, %L::uuid, %L, null)', 'reports', v_p, 'dismiss'));
  if t <> 'own_item' then raise exception 'FAIL a moderator dismissed reports on their own place: %', t; end if;
  perform pg_temp.as_user(current_setting('t.um2')::uuid);
  r := public.mod_resolve_place('reports', v_p, 'dismiss', null);
  if r ->> 'place_status' <> 'active' then raise exception 'FAIL another moderator could not dismiss'; end if;

  -- A place the moderator reported themselves.
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  perform public.report_place(current_setting('t.osm1')::uuid, 'spam', null);
  t := pg_temp.try(format('select public.mod_resolve_place(%L, %L::uuid, %L, null)',
                          'reports', current_setting('t.osm1'), 'remove'));
  if t <> 'own_item' then raise exception 'FAIL a moderator removed a place on their own report: %', t; end if;
  perform pg_temp.as_user(current_setting('t.um2')::uuid);
  r := public.mod_resolve_place('reports', current_setting('t.osm1')::uuid, 'remove', null);
  if r ->> 'place_status' <> 'removed' then raise exception 'FAIL another moderator could not remove'; end if;
  insert into prf_lines (line) values ('own_item on reports: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 2. Retirement keeps moderated OSM rows
-- ---------------------------------------------------------------------------
do $$
declare
  v_tile   integer := public.place_tile_id_of(pg_temp.pt(-129.7, -64.7));
  v_plain  uuid; v_hid uuid; v_rem uuid; v_mrg uuid; v_target uuid;
  v_tag    text := current_setting('t.tag');
begin
  if public.place_tile_id_of(pg_temp.pt(-130.9, -63.1)) = v_tile then
    raise exception 'setup: the merge target shares the tile';
  end if;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-t-' || v_tag, 'PRF Target', 'park', pg_temp.pt(-130.9, -63.1), true, 'active',
          '© OpenStreetMap contributors') returning id into v_target;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-p-' || v_tag, 'PRF Plain', 'park', pg_temp.pt(-129.70, -64.70), true, 'active',
          '© OpenStreetMap contributors') returning id into v_plain;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-h-' || v_tag, 'PRF Hidden', 'park', pg_temp.pt(-129.71, -64.71), true, 'hidden',
          '© OpenStreetMap contributors') returning id into v_hid;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-r-' || v_tag, 'PRF Removed', 'park', pg_temp.pt(-129.72, -64.72), true, 'removed',
          '© OpenStreetMap contributors') returning id into v_rem;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, merged_into)
  values ('geoapify', 'test-prf-m-' || v_tag, 'PRF Merged', 'park', pg_temp.pt(-129.73, -64.73), true, 'removed',
          'Geoapify', v_target) returning id into v_mrg;
  insert into public.place_tiles (id, status, idle_since, osm_run_at)
  values (v_tile, 'idle', now() - interval '8 days', now() - interval '200 days')
  on conflict (id) do update set status = 'idle', idle_since = excluded.idle_since, keep = false;

  perform public.retire_place_tiles();

  if exists (select 1 from public.places where id = v_plain) then
    raise exception 'FAIL a plain OSM row survived retirement';
  end if;
  if exists (select 1 from public.places where id = v_mrg) then
    raise exception 'FAIL a merge leftover survived retirement';
  end if;
  if not exists (select 1 from public.places where id = v_hid and status = 'hidden') then
    raise exception 'FAIL a hidden OSM row was deleted on retirement';
  end if;
  if not exists (select 1 from public.places where id = v_rem and status = 'removed') then
    raise exception 'FAIL a removed OSM row was deleted on retirement';
  end if;
  if (select count(distinct tile_id) from public.places where id in (v_hid, v_rem)) <> 1
     or (select min(tile_id) from public.places where id in (v_hid, v_rem)) <> v_tile then
    raise exception 'setup: the fixture rows are not in the fixture tile';
  end if;
  if (select status from public.place_tiles where id = v_tile) <> 'retired' then
    raise exception 'FAIL the fixture tile did not retire';
  end if;
  insert into prf_lines (line) values ('retirement keeps hidden and removed rows: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Rate limits survive deletes; account deletion clears the log
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  i   integer;
  r   jsonb;
  v_p uuid;
  t   text;
begin
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  for i in 1..10 loop
    r := public.add_place(jsonb_build_object('name', 'PRF Pin ' || i, 'kind', 'court_field',
           'lat', -63.5, 'lng', -130.0 + i * 0.01, 'allow_duplicate', true));
  end loop;
  t := pg_temp.try($q$select public.add_place('{"name":"PRF Pin 11","kind":"court_field","lat":-63.6,"lng":-129.5,"allow_duplicate":true}'::jsonb)$q$);
  if t <> 'rate_limited' then raise exception 'FAIL the 11th add gave %', t; end if;
  perform public.delete_my_place((r ->> 'id')::uuid);
  t := pg_temp.try($q$select public.add_place('{"name":"PRF Pin 11","kind":"court_field","lat":-63.6,"lng":-129.5,"allow_duplicate":true}'::jsonb)$q$);
  if t <> 'rate_limited' then raise exception 'FAIL deleting a pin gave an add back: %', t; end if;

  -- Thirty edits of a pin, the pin deleted, then one more edit elsewhere.
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  r := public.add_place(jsonb_build_object('name', 'PRF Edit Pin', 'kind', 'court_field',
         'lat', -63.7, 'lng', -130.0, 'allow_duplicate', true));
  v_p := (r ->> 'id')::uuid;
  for i in 1..30 loop
    r := public.suggest_place_edit(v_p, jsonb_build_object('name', 'PRF Edit Pin ' || i), null);
    if r ->> 'status' <> 'applied' then raise exception 'FAIL setup: an own-pin edit was not applied'; end if;
  end loop;
  perform public.delete_my_place(v_p);
  r := public.add_place(jsonb_build_object('name', 'PRF Edit Pin B', 'kind', 'court_field',
         'lat', -63.8, 'lng', -130.0, 'allow_duplicate', true));
  t := pg_temp.try(format('select public.suggest_place_edit(%L::uuid, %L::jsonb, null)',
                          r ->> 'id', '{"name":"PRF Edit Pin C"}'));
  if t <> 'rate_limited' then raise exception 'FAIL deleting a place gave its edits back: %', t; end if;

  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  perform public.request_account_deletion('test');
end $$;
reset role;

do $$
begin
  if exists (select 1 from public.place_rate_log where user_id = current_setting('t.u1')::uuid) then
    raise exception 'FAIL account deletion left the rate log';
  end if;
  if not exists (select 1 from public.place_rate_log where user_id = current_setting('t.u2')::uuid and kind = 'edit') then
    raise exception 'FAIL edits were not logged';
  end if;
  insert into prf_lines (line) values ('rate limits survive deletes, account deletion clears the log: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Sensitive and events-only plans make no meeting spot
-- ---------------------------------------------------------------------------
do $$
declare
  v_host uuid := current_setting('t.u3')::uuid;
  v_s    uuid := current_setting('t.s')::uuid;
  v_n    uuid := nullif(current_setting('t.n'), '')::uuid;
  vs uuid; vn uuid; vo uuid; e uuid; v_old uuid;
begin
  insert into public.venues (name, location, is_public, created_by)
  values ('PRF Sensitive Hall', pg_temp.pt(-128.5, -63.5), true, v_host) returning id into vs;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_s, v_host, 'PRF sensitive plan', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-128.5, -63.5)) returning id into e;
  insert into public.event_addresses (event_id, venue_id) values (e, vs);
  if pg_temp.spot(vs) is not null or (select place_ref from public.venues where id = vs) is not null then
    raise exception 'FAIL a sensitive-only venue got a meeting spot';
  end if;

  if v_n is not null then
    insert into public.venues (name, location, is_public, created_by)
    values ('PRF Events Hall', pg_temp.pt(-128.4, -63.4), true, v_host) returning id into vn;
    insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
    values (v_n, v_host, 'PRF events-only plan', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
            pg_temp.pt(-128.4, -63.4)) returning id into e;
    insert into public.event_addresses (event_id, venue_id) values (e, vn);
    if pg_temp.spot(vn) is not null then
      raise exception 'FAIL an events-only venue got a meeting spot';
    end if;
  end if;

  -- A spot made before migration 36 from a sensitive plan goes on the refresh.
  insert into public.venues (name, location, is_public, created_by)
  values ('PRF Old Hall', pg_temp.pt(-128.3, -63.3), true, v_host) returning id into vo;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_s, v_host, 'PRF old sensitive plan', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-128.3, -63.3)) returning id into e;
  insert into public.event_addresses (event_id, venue_id) values (e, vo);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('venue', vo::text, 'PRF Old Hall', 'spot', pg_temp.pt(-128.3, -63.3), true, 'active',
          'Meeting spot from public plans') returning id into v_old;
  update public.venues set place_ref = v_old where id = vo;
  if not exists (select 1 from public.places_odbl_export where cursor_id = v_old) then
    raise exception 'FAIL setup: the old spot is not in the export';
  end if;
  perform public.refresh_meeting_spots();
  if exists (select 1 from public.places where id = v_old) or pg_temp.spot(vo) is not null
     or (select place_ref from public.venues where id = vo) is not null then
    raise exception 'FAIL refresh_meeting_spots kept a sensitive-only meeting spot';
  end if;
  if exists (select 1 from public.places_odbl_export x join public.places p on p.id = x.cursor_id
              where p.source = 'venue' and p.source_id in (vs::text, vo::text, coalesce(vn::text, ''))) then
    raise exception 'FAIL a sensitive or events-only meeting spot is in the export';
  end if;
  insert into prf_lines (line) values ('no meeting spot from sensitive or events-only plans'
    || case when v_n is null then ' (no events-only hub here)' else '' end || ': ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. A hidden meeting spot stays hidden
-- ---------------------------------------------------------------------------
do $$
declare
  v_host uuid := current_setting('t.u3')::uuid;
  v_a    uuid := current_setting('t.a')::uuid;
  v uuid; e1 uuid; e2 uuid; s uuid;
begin
  insert into public.venues (name, location, is_public, created_by)
  values ('PRF Corner Lot', pg_temp.pt(-128.0, -64.0), true, v_host) returning id into v;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_host, 'PRF corner plan', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-128.0, -64.0)) returning id into e1;
  insert into public.event_addresses (event_id, venue_id) values (e1, v);
  s := pg_temp.spot(v);
  if s is null or (select place_ref from public.venues where id = v) is distinct from s
     or not exists (select 1 from public.place_hubs where place_id = s and via = 'events') then
    raise exception 'FAIL setup: the corner lot is not a linked meeting spot';
  end if;

  update public.places set status = 'hidden' where id = s;   -- as a report or moderator would
  perform public.meeting_spot_refresh(v);
  if (select status from public.places where id = s) is distinct from 'hidden'::public.place_status
     or (select place_ref from public.venues where id = v) is not null
     or exists (select 1 from public.place_hubs where place_id = s and via = 'events') then
    raise exception 'FAIL a hidden meeting spot kept its links or changed';
  end if;

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_host, 'PRF corner plan 2', now() + interval '2 days', now() + interval '2 days 2 hours', 'Here',
          pg_temp.pt(-128.0, -64.0)) returning id into e2;
  insert into public.event_addresses (event_id, venue_id) values (e2, v);
  if pg_temp.spot(v) is distinct from s or (select status from public.places where id = s) <> 'hidden'
     or (select place_ref from public.venues where id = v) is not null then
    raise exception 'FAIL a new plan brought a hidden meeting spot back';
  end if;

  delete from public.event_addresses where venue_id = v;
  if not exists (select 1 from public.places where id = s and status = 'hidden') then
    raise exception 'FAIL a hidden meeting spot was deleted when its plans went';
  end if;
  update public.places set status = 'removed' where id = s;
  update public.venues set is_public = false where id = v;
  if not exists (select 1 from public.places where id = s and status = 'removed') then
    raise exception 'FAIL a removed meeting spot was deleted when its venue went private';
  end if;

  -- Dismissed (active again): the next refresh links it again.
  update public.venues set is_public = true where id = v;
  insert into public.event_addresses (event_id, venue_id) values (e1, v);
  update public.places set status = 'active' where id = s;
  perform public.meeting_spot_refresh(v);
  if (select place_ref from public.venues where id = v) is distinct from s
     or not exists (select 1 from public.place_hubs where place_id = s and via = 'events') then
    raise exception 'FAIL a restored meeting spot did not link again';
  end if;
  insert into prf_lines (line) values ('hidden and removed meeting spots stay: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. venue_preview_for_place creates nothing
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid;
begin
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-prf-v-' || current_setting('t.tag'), 'PRF Plaza', 'park', pg_temp.pt(-127.5, -64.5),
          true, 'active', '© OpenStreetMap contributors') returning id into v;
  perform set_config('t.pv', v::text, true);
end $$;

set local role authenticated;
do $$
declare
  r jsonb;
  v public.venues%rowtype;
  n integer;
  t text;
begin
  perform pg_temp.as_user(current_setting('t.u3')::uuid);
  select count(*) into n from public.venues where place_ref = current_setting('t.pv')::uuid;
  r := public.venue_preview_for_place(current_setting('t.pv')::uuid);
  if r ->> 'venue_id' is not null or r ->> 'name' <> 'PRF Plaza' or r ->> 'place_id' <> current_setting('t.pv') then
    raise exception 'FAIL preview of a place with no venue';
  end if;
  if n <> 0 then raise exception 'FAIL setup: the plaza already had a venue'; end if;
  t := pg_temp.try(format('select public.venue_preview_for_place(%L::uuid)', gen_random_uuid()));
  if t <> 'place_not_found' then raise exception 'FAIL preview of a missing place gave %', t; end if;
  perform set_config('t.dummy', '1', true);
end $$;
reset role;

do $$
begin
  if exists (select 1 from public.venues where place_ref = current_setting('t.pv')::uuid) then
    raise exception 'FAIL the preview created a venue';
  end if;
end $$;

set local role authenticated;
do $$
declare
  r jsonb;
  v public.venues%rowtype;
begin
  perform pg_temp.as_user(current_setting('t.u3')::uuid);
  v := public.venue_for_place(current_setting('t.pv')::uuid);
  r := public.venue_preview_for_place(current_setting('t.pv')::uuid);
  if (r ->> 'venue_id')::uuid is distinct from v.id then
    raise exception 'FAIL the preview did not return the venue venue_for_place made';
  end if;
  insert into prf_lines (line) values ('venue_preview_for_place: ok');
end $$;
reset role;

select line as places_review_fixes from (
  select 0 as n, 'places_review_fixes: all assertions passed' as line
  union all
  select n, line from prf_lines) x
order by n;

rollback;
