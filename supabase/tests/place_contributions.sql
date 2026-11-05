-- ============================================================================
-- Staging check for migration 20261128000100_place_contributions.sql (D-041,
-- hub map slices 11 and 12: add_place, corrections, reports and the
-- moderation queue). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail lines only, never names,
-- ids or points (the repo and its Action logs are public). Run as the
-- staging_file of a staging_only migrate.yml run. The fixture sits in the
-- Southern Ocean (lng -130 to -128, lat -62 to -60), where no real data is.
--
-- Design section 7, rule by rule:
--   1 A new member place is private unless asked; "Everyone" needs the
--     confirmation (confirm_public_required) and a hub, and goes pending.
--   2 A public request within 150 m of the saved home point or 50 m of one
--     of the member's private venues is refused (near_your_home,
--     near_private_venue), through add_place, set_my_place_visibility, a
--     move by the creator, and a stranger's move once a moderator approves
--     it (the stranger is never told). A private pin there is fine.
--   3 A pending place is seen by its creator only (pending and mine flags in
--     map_in_view); signed out and other members see nothing through the
--     table, map_in_view, place_detail, the duplicate check, reports or
--     edits, until a moderator approves it.
--   4 private_residence or unsafe hides a member or meeting spot place at
--     once but not an imported one; three open reports from different
--     accounts hide any place, two do not; one open report per person;
--     dismiss brings a hidden place back.
--   5 add_place refuses a public pin beside a private venue (rule 2); the
--     venue and approved-only side is covered by supabase/tests/meeting_spots.sql.
--   6 Sensitive and events-only hubs take no member places or links
--     (hub_not_allowed), in add_place and in hubs_add.
--   7 map_in_view writes nothing: the edit, report and moderation tables and
--     the tile demand are unchanged by a read.
--   8 place_mode none hubs: see 6.
--   9 10 places, 30 edits, 20 reports a day (rate_limited); onboarding is
--     required (onboarding_required); anon cannot call anything.
-- Moderation (slice 12): non-moderators are refused; the queue lists the
-- three kinds with no author fields; approve, reject (back to a private
-- pin) and remove for places; approving an edit to an imported row locks
-- the changed fields; own_item; close locks closed; a removed place
-- supersedes its pending edits; every decision is logged. Account deletion
-- drops pending edits and unattributes reports.
-- ============================================================================
begin;

create temp table pct_lines (n serial, line text);
grant insert, select on pct_lines to anon, authenticated;
grant usage on sequence pct_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- Sign in as a fixture user (null: signed out). The role is set by the caller.
create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

-- Runs a statement and returns 'ok' or the error message.
create function pg_temp.try(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;

-- The error's detail (for duplicate_candidates), or null.
create function pg_temp.try_detail(p_sql text) returns text language plpgsql as $$
declare
  v_d text;
begin
  execute p_sql;
  return null;
exception when others then
  get stacked diagnostics v_d = pg_exception_detail;
  return v_d;
end $$;

create function pg_temp.args(p jsonb) returns text language sql immutable as $$
  select quote_literal(p::text) || '::jsonb';
$$;

create function pg_temp.ids(r jsonb) returns text[] language sql immutable as $$
  select coalesce(array(select x.value ->> 0 from jsonb_array_elements(r -> 'places') x), '{}');
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- creator: saved home, a private venue, joined hub a
  u2 uuid := gen_random_uuid();   -- another adult
  u3 uuid := gen_random_uuid();   -- reporter
  u4 uuid := gen_random_uuid();   -- reporter
  u5 uuid := gen_random_uuid();   -- not onboarded
  um uuid := gen_random_uuid();   -- moderator
  v_a uuid; v_b uuid; v_s uuid; v_n uuid;
  v_ven uuid;
  v_id uuid;
  i integer;
begin
  if exists (select 1 from public.places
              where geom operator(extensions.&&) extensions.ST_MakeEnvelope(-130, -62, -128, -60, 4326))
     or exists (select 1 from public.venues
                 where location is not null
                   and (location::extensions.geometry) operator(extensions.&&)
                       extensions.ST_MakeEnvelope(-130, -62, -128, -60, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'pct-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2, u3, u4, u5, um]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2, u3, u4, u5, um);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (u1, u2, u3, u4, um);
  insert into public.user_roles (user_id, role) values (um, 'moderator');
  -- Stored rounded to 0.01 degree by its trigger; this point is already round.
  update public.profile_private set home_point = pg_temp.pt(-129.00, -61.00) where user_id = u1;

  -- a: specific, not sensitive, shows court_field; b: another allowed hub;
  -- s: sensitive; n: events only.
  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and h.min_age < 21
     and exists (select 1 from public.hub_place_rules hr join public.place_rules r on r.id = hr.rule_id
                  where hr.hub_id = h.id and r.kind = 'court_field')
   order by h.slug limit 1;
  select h.id into v_b from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and h.min_age < 21 and h.id <> v_a
   order by h.slug limit 1;
  select h.id into v_s from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive and h.place_mode <> 'none'
   order by h.slug limit 1;
  select h.id into v_n from public.hubs h where h.is_active and h.place_mode = 'none' order by h.slug limit 1;
  if v_a is null or v_b is null or v_s is null or v_n is null then
    raise exception 'setup: hubs missing';
  end if;
  insert into public.hub_members (user_id, hub_id) values (u1, v_a), (u2, v_a);

  -- u1's private venue (their home address for a plan).
  insert into public.venues (name, location, is_public, created_by)
  values ('PCT Flat', pg_temp.pt(-129.20, -61.20), false, u1);

  -- Imported places: A (edits), C (three reports), D (unsafe on an import),
  -- E1..E21 (report rate limit). No rule ids: they show through links only.
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-pct-a-' || v_tag, 'PCT Court One', 'court_field', pg_temp.pt(-129.50, -61.50),
          true, 'active', '© OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.pa', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-pct-c-' || v_tag, 'PCT Shop Gamma', 'shop', pg_temp.pt(-129.70, -61.50),
          true, 'active', '© OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.pc', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('osm', 'test-pct-d-' || v_tag, 'PCT Park Delta', 'park', pg_temp.pt(-129.80, -61.50),
          true, 'active', '© OpenStreetMap contributors') returning id into v_id;
  perform set_config('test.pd', v_id::text, true);
  for i in 1..21 loop
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
    values ('osm', 'test-pct-e' || i || '-' || v_tag, 'PCT Field ' || i, 'park',
            pg_temp.pt(-128.5 + i * 0.01, -60.5), true, 'active', '© OpenStreetMap contributors');
  end loop;
  insert into public.place_hubs (place_id, hub_id, via)
  select p.id, v_a, 'moderator' from public.places p
   where p.source = 'osm' and p.source_id like 'test-pct-%-' || v_tag;

  -- A meeting spot (a public venue's own place).
  insert into public.venues (name, location, is_public, created_by)
  values ('PCT Hall', pg_temp.pt(-129.90, -61.50), true, u2) returning id into v_ven;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('venue', v_ven::text, 'PCT Hall', 'spot', pg_temp.pt(-129.90, -61.50), true, 'active',
          'Meeting spot from public plans') returning id into v_id;
  perform set_config('test.pv', v_id::text, true);

  -- The moderator's own pending place (another moderator decides it).
  insert into public.places (source, name, kind, location, is_public, status, created_by, attribution)
  values ('user', 'PCT Mod Spot', 'court_field', pg_temp.pt(-129.40, -61.80), true, 'pending', um,
          'Added by an Activity Planet member') returning id into v_id;
  perform set_config('test.pm', v_id::text, true);

  perform set_config('test.u1', u1::text, true);
  perform set_config('test.u2', u2::text, true);
  perform set_config('test.u3', u3::text, true);
  perform set_config('test.u4', u4::text, true);
  perform set_config('test.u5', u5::text, true);
  perform set_config('test.um', um::text, true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.s', v_s::text, true);
  perform set_config('test.n', v_n::text, true);
  perform set_config('test.tag', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- Static: version, grants, column privileges
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 30] then
    raise exception 'FAIL schema_version is older than 2.30';
  end if;
  foreach f in array array['public.add_place(jsonb)', 'public.suggest_place_edit(uuid,jsonb,text)',
                           'public.report_place(uuid,text,text)', 'public.set_my_place_visibility(uuid,boolean,boolean)',
                           'public.delete_my_place(uuid)', 'public.mod_place_queue(integer)',
                           'public.mod_resolve_place(text,uuid,text,text)'] loop
    if has_function_privilege('anon', f, 'execute') then raise exception 'FAIL anon can execute %', f; end if;
    if not has_function_privilege('authenticated', f, 'execute') then raise exception 'FAIL authenticated cannot execute %', f; end if;
    if not (select p.prosecdef from pg_proc p where p.oid = f::regprocedure) then raise exception 'FAIL % is not definer', f; end if;
  end loop;
  foreach f in array array['public.place_caller_can_see(uuid)', 'public.place_check_hubs(jsonb,text,boolean)',
                           'public.place_near_private(uuid,extensions.geography)', 'public.place_raise_near(text)',
                           'public.place_duplicates(text,text,extensions.geography,uuid)',
                           'public.place_clean_changes(jsonb)', 'public.place_apply_changes(uuid,jsonb,text,boolean)',
                           'public.mod_place_facts(uuid)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute') then
      raise exception 'FAIL a client can execute %', f;
    end if;
  end loop;
  if has_column_privilege('authenticated', 'public.place_edits', 'proposed_by', 'select')
     or has_column_privilege('authenticated', 'public.place_edits', 'reviewed_by', 'select')
     or has_column_privilege('authenticated', 'public.place_reports', 'reporter_id', 'select')
     or has_column_privilege('authenticated', 'public.place_reports', 'resolved_by', 'select')
     or has_column_privilege('authenticated', 'public.places', 'created_by', 'select') then
    raise exception 'FAIL an author column is client-readable';
  end if;
  if has_table_privilege('authenticated', 'public.place_edits', 'insert')
     or has_table_privilege('authenticated', 'public.place_reports', 'insert')
     or has_table_privilege('authenticated', 'public.place_reports', 'update')
     or has_table_privilege('authenticated', 'public.place_mod_actions', 'insert')
     or has_table_privilege('anon', 'public.place_edits', 'select')
     or has_table_privilege('anon', 'public.place_reports', 'select')
     or has_table_privilege('anon', 'public.place_mod_actions', 'select') then
    raise exception 'FAIL a client can write or anon can read the moderation tables';
  end if;
  insert into pct_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Rule 9 (anon, onboarding) and rules 1, 2, 6, 8: add_place
-- ---------------------------------------------------------------------------
set local role anon;
do $$ begin perform pg_temp.as_user(null); end $$;
do $$
declare
  r text;
begin
  r := pg_temp.try('select public.add_place(''{"name":"PCT Anon","kind":"court_field","lat":-61.3,"lng":-129.3}'')');
  if r not like 'permission denied%' then raise exception 'FAIL anon add_place gave %', r; end if;
  r := pg_temp.try('select public.mod_place_queue()');
  if r not like 'permission denied%' then raise exception 'FAIL anon mod_place_queue gave %', r; end if;
  insert into pct_lines (line) values ('anon refused: ok');
end $$;
reset role;

set local role authenticated;
do $$
declare
  u1 uuid := current_setting('test.u1')::uuid;
  v_a text := current_setting('test.a');
  r  text;
  j  jsonb;
begin
  perform pg_temp.as_user(current_setting('test.u5')::uuid);
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Not Yet', 'kind', 'court_field', 'lat', -61.3, 'lng', -129.3)) || ')');
  if r <> 'onboarding_required' then raise exception 'FAIL not onboarded gave %', r; end if;

  perform pg_temp.as_user(u1);
  -- Rule 1: private by default, here right beside home, hubs pre-filled from the kind.
  j := public.add_place(jsonb_build_object('name', 'PCT Back Court', 'kind', 'court_field',
                                           'lat', -61.0003, 'lng', -129.0005));
  if (j ->> 'is_public')::boolean or j ->> 'status' <> 'active' or not (j -> 'hub_ids') ? v_a then
    raise exception 'FAIL a default add_place is not a private active pin with the kind''s hub';
  end if;
  perform set_config('test.p_priv', j ->> 'id', true);

  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Corner', 'kind', 'court_field', 'lat', -61.0004, 'lng', -129.0008, 'is_public', true,
         'hub_ids', jsonb_build_array(v_a))) || ')');
  if r <> 'confirm_public_required' then raise exception 'FAIL public without confirmation gave %', r; end if;
  -- Rule 2.
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Corner', 'kind', 'court_field', 'lat', -61.0004, 'lng', -129.0008, 'is_public', true,
         'confirm_public', true, 'hub_ids', jsonb_build_array(v_a))) || ')');
  if r <> 'near_your_home' then raise exception 'FAIL public beside home gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Stoop', 'kind', 'court_field', 'lat', -61.2002, 'lng', -129.2003, 'is_public', true,
         'confirm_public', true, 'hub_ids', jsonb_build_array(v_a))) || ')');
  if r <> 'near_private_venue' then raise exception 'FAIL public beside a private venue gave %', r; end if;
  -- Rules 6 and 8.
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Hall Two', 'kind', 'community', 'lat', -61.6, 'lng', -129.1,
         'hub_ids', jsonb_build_array(current_setting('test.s')))) || ')');
  if r <> 'hub_not_allowed' then raise exception 'FAIL a sensitive hub gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Hall Two', 'kind', 'community', 'lat', -61.6, 'lng', -129.1,
         'hub_ids', jsonb_build_array(current_setting('test.n')))) || ')');
  if r <> 'hub_not_allowed' then raise exception 'FAIL an events-only hub gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Hall Two', 'kind', 'community', 'lat', -61.6, 'lng', -129.1, 'is_public', true,
         'confirm_public', true, 'hub_ids', '[]'::jsonb)) || ')');
  if r <> 'hub_required' then raise exception 'FAIL a public place with no hub gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'P', 'kind', 'court_field', 'lat', -61.6, 'lng', -129.1)) || ')');
  if r <> 'name_length' then raise exception 'FAIL a one-letter name gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Nowhere', 'kind', 'no_such_kind', 'lat', -61.6, 'lng', -129.1)) || ')');
  if r <> 'kind_not_found' then raise exception 'FAIL an unknown kind gave %', r; end if;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Site', 'kind', 'court_field', 'lat', -61.6, 'lng', -129.1, 'website', 'javascript:alert(1)')) || ')');
  if r <> 'website_invalid' then raise exception 'FAIL a bad website gave %', r; end if;

  -- Rules 1 and 3: a confirmed public place far from home is pending.
  j := public.add_place(jsonb_build_object('name', 'PCT Court Two', 'kind', 'court_field',
                                           'lat', -61.60, 'lng', -129.60, 'is_public', true, 'confirm_public', true,
                                           'hub_ids', jsonb_build_array(v_a), 'opening_hours', 'Mo-Su 06:00-22:00'));
  if not (j ->> 'is_public')::boolean or j ->> 'status' <> 'pending' then
    raise exception 'FAIL a public member place is not pending';
  end if;
  perform set_config('test.p1', j ->> 'id', true);
  j := public.add_place(jsonb_build_object('name', 'PCT Court Three', 'kind', 'court_field',
                                           'lat', -61.65, 'lng', -129.65, 'is_public', true, 'confirm_public', true,
                                           'hub_ids', jsonb_build_array(v_a)));
  perform set_config('test.p2', j ->> 'id', true);

  -- Duplicate check: the OSM court 20 m away, and the caller's own pending place.
  r := pg_temp.try_detail('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'Court by the bay', 'kind', 'court_field', 'lat', -61.50015, 'lng', -129.50010)) || ')');
  if r is null or not (r::jsonb @> jsonb_build_array(jsonb_build_object('id', current_setting('test.pa')))) then
    raise exception 'FAIL the duplicate check missed the OSM place';
  end if;
  r := pg_temp.try_detail('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'Something else', 'kind', 'court_field', 'lat', -61.6002, 'lng', -129.6002)) || ')');
  if r is null or not (r::jsonb @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p1'), 'mine', true))) then
    raise exception 'FAIL the duplicate check missed the caller''s own pending place';
  end if;
  insert into pct_lines (line) values ('add_place rules 1, 2, 6, 8, onboarding: ok');
end $$;

-- Rule 3 through the duplicate check, and allow_duplicate.
do $$
declare
  r text;
  j jsonb;
begin
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  r := pg_temp.try_detail('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Court Two', 'kind', 'court_field', 'lat', -61.6001, 'lng', -129.6001)) || ')');
  if r is not null and r::jsonb @> jsonb_build_array(jsonb_build_object('id', current_setting('test.p1'))) then
    raise exception 'FAIL the duplicate check showed another member''s pending place';
  end if;
  r := pg_temp.try_detail('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Court One', 'kind', 'court_field', 'lat', -61.5001, 'lng', -129.5001)) || ')');
  if r is null then raise exception 'FAIL no duplicate_candidates for the same name and kind 15 m away'; end if;
  j := public.add_place(jsonb_build_object('name', 'PCT Court One', 'kind', 'court_field',
                                           'lat', -61.5001, 'lng', -129.5001, 'allow_duplicate', true));
  if j ->> 'status' <> 'active' then raise exception 'FAIL allow_duplicate did not add the pin'; end if;
  perform set_config('test.p_u2', j ->> 'id', true);
  insert into pct_lines (line) values ('duplicate check: ok');
end $$;

-- Rule 9: ten new places a day.
do $$
declare
  i integer;
  r text;
begin
  perform pg_temp.as_user(current_setting('test.u3')::uuid);
  for i in 1..10 loop
    perform public.add_place(jsonb_build_object('name', 'PCT Pin ' || i, 'kind', 'court_field',
                                                'lat', -60.8, 'lng', -129.9 + i * 0.01, 'allow_duplicate', true));
  end loop;
  r := pg_temp.try('select public.add_place(' || pg_temp.args(jsonb_build_object(
         'name', 'PCT Pin 11', 'kind', 'court_field', 'lat', -60.8, 'lng', -129.7, 'allow_duplicate', true)) || ')');
  if r <> 'rate_limited' then raise exception 'FAIL the eleventh place gave %', r; end if;
  insert into pct_lines (line) values ('ten places a day: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Rule 3: who sees a pending place
-- ---------------------------------------------------------------------------
do $$
declare
  p1 text := current_setting('test.p1');
  pp text := current_setting('test.p_priv');
  r  jsonb;
  v_fl integer;
  t  text;
begin
  perform pg_temp.as_user(current_setting('test.u1')::uuid);
  r := public.map_in_view(-129.99, -61.95, -128.99, -60.99, array[current_setting('test.a')::uuid]);
  select (x.value ->> 5)::integer into v_fl from jsonb_array_elements(r -> 'places') x where x.value ->> 0 = p1;
  if v_fl is null or v_fl & 2 = 0 or v_fl & 64 = 0 then raise exception 'FAIL the creator does not see the pending pin'; end if;
  select (x.value ->> 5)::integer into v_fl from jsonb_array_elements(r -> 'places') x where x.value ->> 0 = pp;
  if v_fl is null or v_fl & 4 = 0 then raise exception 'FAIL the creator does not see the private pin'; end if;
  if (public.place_detail(p1::uuid)) ->> 'status' <> 'pending' then raise exception 'FAIL the creator cannot open the pending card'; end if;

  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  if exists (select 1 from public.places where id in (p1::uuid, pp::uuid)) then
    raise exception 'FAIL another member reads a pending or private place';
  end if;
  r := public.map_in_view(-129.99, -61.95, -128.99, -60.99, array[current_setting('test.a')::uuid]);
  if p1 = any (pg_temp.ids(r)) or pp = any (pg_temp.ids(r)) then
    raise exception 'FAIL map_in_view shows another member''s pending or private place';
  end if;
  t := pg_temp.try('select public.place_detail(' || quote_literal(p1) || '::uuid)');
  if t <> 'place_not_found' then raise exception 'FAIL place_detail on a pending place gave %', t; end if;
  t := pg_temp.try('select public.report_place(' || quote_literal(p1) || '::uuid, ''spam'')');
  if t <> 'place_not_found' then raise exception 'FAIL reporting a pending place gave %', t; end if;
  t := pg_temp.try('select public.suggest_place_edit(' || quote_literal(p1) || '::uuid, ''{"name":"PCT X"}'')');
  if t <> 'place_not_found' then raise exception 'FAIL editing a pending place gave %', t; end if;
  insert into pct_lines (line) values ('rule 3 signed in: ok');
end $$;
reset role;

set local role anon;
do $$ begin perform pg_temp.as_user(null); end $$;
do $$
declare
  r jsonb;
begin
  if exists (select 1 from public.places where id in (current_setting('test.p1')::uuid, current_setting('test.p_priv')::uuid)) then
    raise exception 'FAIL anon reads a pending or private place';
  end if;
  r := public.map_in_view(-129.99, -61.95, -128.99, -60.99, array[current_setting('test.a')::uuid]);
  if current_setting('test.p1') = any (pg_temp.ids(r)) then raise exception 'FAIL anon map shows a pending place'; end if;
  if not (current_setting('test.pa') = any (pg_temp.ids(r))) then raise exception 'FAIL anon map lost the OSM place'; end if;
  insert into pct_lines (line) values ('rule 3 signed out: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- The creator's own pin: visibility and delete (rules 1 and 2)
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  pp text := current_setting('test.p_priv');
  r  text;
  j  jsonb;
begin
  perform pg_temp.as_user(current_setting('test.u1')::uuid);
  r := pg_temp.try('select public.set_my_place_visibility(' || quote_literal(pp) || '::uuid, true)');
  if r <> 'confirm_public_required' then raise exception 'FAIL going public unconfirmed gave %', r; end if;
  r := pg_temp.try('select public.set_my_place_visibility(' || quote_literal(pp) || '::uuid, true, true)');
  if r <> 'near_your_home' then raise exception 'FAIL a home pin going public gave %', r; end if;
  -- Withdraw a pending request and send it again.
  j := public.set_my_place_visibility(current_setting('test.p2')::uuid, false);
  if (j ->> 'is_public')::boolean or j ->> 'status' <> 'active' then raise exception 'FAIL withdrawing a request'; end if;
  j := public.set_my_place_visibility(current_setting('test.p2')::uuid, true, true);
  if j ->> 'status' <> 'pending' then raise exception 'FAIL re-requesting did not go pending'; end if;
  -- The creator's own unreviewed pin changes at once.
  j := public.suggest_place_edit(pp::uuid, '{"name":"PCT Back Court Renamed","opening_hours":"24/7"}');
  if j ->> 'status' <> 'applied' or not (j ->> 'applied')::boolean then raise exception 'FAIL an own pin edit was queued'; end if;
  if (select name from public.places where id = pp::uuid) <> 'PCT Back Court Renamed' then
    raise exception 'FAIL an own pin edit did not apply';
  end if;
  r := pg_temp.try('select public.report_place(' || quote_literal(pp) || '::uuid, ''spam'')');
  if r <> 'own_place' then raise exception 'FAIL reporting one''s own place gave %', r; end if;
  perform public.delete_my_place(pp::uuid);
  if exists (select 1 from public.places where id = pp::uuid) then raise exception 'FAIL delete_my_place'; end if;
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  r := pg_temp.try('select public.delete_my_place(' || quote_literal(current_setting('test.p1')) || '::uuid)');
  if r <> 'place_not_found' then raise exception 'FAIL deleting someone else''s place gave %', r; end if;
  insert into pct_lines (line) values ('own pin: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Moderation of places
-- ---------------------------------------------------------------------------
do $$
declare
  p1 text := current_setting('test.p1');
  q  jsonb;
  it jsonb;
  r  text;
  j  jsonb;
begin
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  r := pg_temp.try('select public.mod_place_queue()');
  if r <> 'forbidden' then raise exception 'FAIL a member read the queue: %', r; end if;
  r := pg_temp.try('select public.mod_resolve_place(''place'', ' || quote_literal(p1) || '::uuid, ''approve'')');
  if r <> 'forbidden' then raise exception 'FAIL a member resolved a place: %', r; end if;

  perform pg_temp.as_user(current_setting('test.um')::uuid);
  q := public.mod_place_queue(200);
  select x.value into it from jsonb_array_elements(q -> 'items') x
   where x.value ->> 'kind' = 'place' and x.value ->> 'id' = p1;
  if it is null then raise exception 'FAIL the pending place is not in the queue'; end if;
  if (it -> 'place' ->> 'name') <> 'PCT Court Two' or not (it -> 'place' ->> 'member_added')::boolean
     or jsonb_array_length(it -> 'place' -> 'hubs') <> 1 then
    raise exception 'FAIL the queue item lacks the place facts';
  end if;
  if q::text ~ '(created_by|proposed_by|reporter_id|handle|email)' then
    raise exception 'FAIL the queue names who added something';
  end if;
  if (q -> 'counts' ->> 'places')::integer < 2 then raise exception 'FAIL queue counts'; end if;
  r := pg_temp.try('select public.mod_resolve_place(''place'', ' || quote_literal(current_setting('test.pm')) || '::uuid, ''approve'')');
  if r <> 'own_item' then raise exception 'FAIL a moderator approved their own place: %', r; end if;
  r := pg_temp.try('select public.mod_resolve_place(''place'', ' || quote_literal(p1) || '::uuid, ''hide'')');
  if r <> 'invalid_action' then raise exception 'FAIL an invalid action gave %', r; end if;

  j := public.mod_resolve_place('place', p1::uuid, 'approve', 'Looks right');
  if j ->> 'place_status' <> 'active' then raise exception 'FAIL approve'; end if;
  r := pg_temp.try('select public.mod_resolve_place(''place'', ' || quote_literal(p1) || '::uuid, ''approve'')');
  if r <> 'item_not_pending' then raise exception 'FAIL approving twice gave %', r; end if;
  j := public.mod_resolve_place('place', current_setting('test.p2')::uuid, 'reject', 'Not a public place');
  if (j ->> 'is_public')::boolean or j ->> 'place_status' <> 'active' then
    raise exception 'FAIL reject did not make it a private pin';
  end if;
  if (select count(*) from public.place_mod_actions where place_id in (p1::uuid, current_setting('test.p2')::uuid)) <> 2 then
    raise exception 'FAIL decisions are not logged';
  end if;
  -- A moderator's own public place is active at once (outreach seeding, founder answer 6).
  j := public.add_place(jsonb_build_object('name', 'PCT Seeded Spot', 'kind', 'court_field', 'lat', -61.9, 'lng', -129.9,
                                           'is_public', true, 'confirm_public', true,
                                           'hub_ids', jsonb_build_array(current_setting('test.a'))));
  if j ->> 'status' <> 'active' then raise exception 'FAIL a moderator''s place is not active'; end if;
  insert into pct_lines (line) values ('moderate places: ok');
end $$;

-- After approval: everyone sees the reviewed place; the rejected one stays private.
do $$
declare
  r jsonb;
begin
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  r := public.map_in_view(-129.99, -61.95, -128.99, -60.99, array[current_setting('test.a')::uuid]);
  if not (current_setting('test.p1') = any (pg_temp.ids(r))) then raise exception 'FAIL the approved place is not on the map'; end if;
  if current_setting('test.p2') = any (pg_temp.ids(r)) then raise exception 'FAIL the rejected place is on the map'; end if;
  if (public.place_detail(current_setting('test.p1')::uuid)) ->> 'status' <> 'active' then
    raise exception 'FAIL the approved card';
  end if;
  insert into pct_lines (line) values ('approved place visible: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Corrections (and rule 2 for moves, rule 6 for hubs_add)
-- ---------------------------------------------------------------------------
do $$
declare
  pa uuid := current_setting('test.pa')::uuid;
  j  jsonb;
  r  text;
  e1 uuid;
begin
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  j := public.suggest_place_edit(pa, '{"name":"PCT Court One Old"}', 'First try');
  e1 := (j ->> 'id')::uuid;
  j := public.suggest_place_edit(pa, '{"name":"PCT Court One North","opening_hours":"Mo-Fr 07:00-21:00"}', 'Sign at the gate');
  if j ->> 'status' <> 'pending' or (j ->> 'applied')::boolean then raise exception 'FAIL a member edit was not queued'; end if;
  perform set_config('test.e_a', j ->> 'id', true);
  if (select status from public.place_edits where id = e1) <> 'superseded' then
    raise exception 'FAIL a second edit did not supersede the first';
  end if;
  if (select name from public.places where id = pa) <> 'PCT Court One' then raise exception 'FAIL a queued edit applied'; end if;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(pa::text) || '::uuid, '
       || pg_temp.args(jsonb_build_object('hubs_add', jsonb_build_array(current_setting('test.s')))) || ')');
  if r <> 'hub_not_allowed' then raise exception 'FAIL hubs_add with a sensitive hub gave %', r; end if;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(pa::text) || '::uuid, ''{"created_by":null}'')');
  if r <> 'invalid_changes' then raise exception 'FAIL an unknown field gave %', r; end if;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(pa::text) || '::uuid, ''{}'')');
  if r <> 'no_changes' then raise exception 'FAIL an empty edit gave %', r; end if;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(pa::text) || '::uuid, ''{"website":"ftp://x"}'')');
  if r <> 'website_invalid' then raise exception 'FAIL a bad website edit gave %', r; end if;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(current_setting('test.pv')) || '::uuid, ''{"name":"PCT Hall X"}'')');
  if r <> 'meeting_spot' then raise exception 'FAIL editing a meeting spot gave %', r; end if;
  -- A stranger's move next to the creator's home is queued, never refused with a reason.
  j := public.suggest_place_edit(current_setting('test.p1')::uuid,
                                 '{"location":{"lat":-61.0002,"lng":-129.0002}}');
  if j ->> 'status' <> 'pending' then raise exception 'FAIL a stranger''s move was not queued'; end if;
  perform set_config('test.e_move', j ->> 'id', true);
  perform pg_temp.as_user(current_setting('test.u3')::uuid);
  j := public.suggest_place_edit(pa, jsonb_build_object('hubs_add', jsonb_build_array(current_setting('test.b'))));
  perform set_config('test.e_hub', j ->> 'id', true);

  -- The creator's own move of a reviewed public place next to home is refused.
  perform pg_temp.as_user(current_setting('test.u1')::uuid);
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(current_setting('test.p1')) || '::uuid, '
       || '''{"location":{"lat":-61.0001,"lng":-129.0001}}'')');
  if r <> 'near_your_home' then raise exception 'FAIL the creator''s move home gave %', r; end if;
  r := pg_temp.try('select public.set_my_place_visibility(' || quote_literal(current_setting('test.p1')) || '::uuid, false)');
  if r <> 'reviewed_place' then raise exception 'FAIL hiding a reviewed place gave %', r; end if;
  r := pg_temp.try('select public.delete_my_place(' || quote_literal(current_setting('test.p1')) || '::uuid)');
  if r <> 'reviewed_place' then raise exception 'FAIL deleting a reviewed place gave %', r; end if;
  insert into pct_lines (line) values ('suggest_place_edit: ok');
end $$;

-- Thirty edits a day.
do $$
declare
  i integer;
  r text;
begin
  perform pg_temp.as_user(current_setting('test.u4')::uuid);
  for i in 1..30 loop
    perform public.suggest_place_edit(current_setting('test.pd')::uuid, jsonb_build_object('opening_hours', 'Try ' || i));
  end loop;
  r := pg_temp.try('select public.suggest_place_edit(' || quote_literal(current_setting('test.pd')) || '::uuid, ''{"name":"PCT Park 31"}'')');
  if r <> 'rate_limited' then raise exception 'FAIL the 31st edit gave %', r; end if;
  insert into pct_lines (line) values ('thirty edits a day: ok');
end $$;

-- A moderator reviews the edits.
do $$
declare
  pa uuid := current_setting('test.pa')::uuid;
  q  jsonb;
  it jsonb;
  j  jsonb;
  r  text;
begin
  perform pg_temp.as_user(current_setting('test.um')::uuid);
  q := public.mod_place_queue(200);
  select x.value into it from jsonb_array_elements(q -> 'items') x
   where x.value ->> 'kind' = 'edit' and x.value ->> 'id' = current_setting('test.e_a');
  if it is null or it -> 'current' ->> 'name' <> 'PCT Court One' or it -> 'changes' ->> 'name' <> 'PCT Court One North'
     or it ->> 'note' <> 'Sign at the gate' then
    raise exception 'FAIL the edit item lacks changes, current values or the note';
  end if;
  select x.value into it from jsonb_array_elements(q -> 'items') x
   where x.value ->> 'kind' = 'edit' and x.value ->> 'id' = current_setting('test.e_move');
  if it is null or (it ->> 'move_m')::integer < 50000 then raise exception 'FAIL the move item lacks move_m'; end if;

  j := public.mod_resolve_place('edit', current_setting('test.e_a')::uuid, 'approve');
  if not ((j -> 'locked_fields') ? 'name' and (j -> 'locked_fields') ? 'opening_hours') then
    raise exception 'FAIL approving an import edit did not lock its fields';
  end if;
  if (select name || '|' || opening_hours from public.places where id = pa) <> 'PCT Court One North|Mo-Fr 07:00-21:00' then
    raise exception 'FAIL the approved edit did not apply';
  end if;
  if (select status from public.place_edits where id = current_setting('test.e_a')::uuid) <> 'approved'
     or (select reviewed_at from public.place_edits where id = current_setting('test.e_a')::uuid) is null then
    raise exception 'FAIL the edit is not marked approved';
  end if;
  perform public.mod_resolve_place('edit', current_setting('test.e_hub')::uuid, 'approve');
  if not exists (select 1 from public.place_hubs where place_id = pa and hub_id = current_setting('test.b')::uuid and via = 'member') then
    raise exception 'FAIL hubs_add did not link the hub';
  end if;
  -- The stranger's move home: the guard refuses it on approval.
  r := pg_temp.try('select public.mod_resolve_place(''edit'', ' || quote_literal(current_setting('test.e_move')) || '::uuid, ''approve'')');
  if r <> 'near_your_home' then raise exception 'FAIL approving a move to the creator''s home gave %', r; end if;
  j := public.mod_resolve_place('edit', current_setting('test.e_move')::uuid, 'reject', 'Wrong spot');
  if (select status from public.place_edits where id = current_setting('test.e_move')::uuid) <> 'rejected' then
    raise exception 'FAIL reject an edit';
  end if;
  -- A moderator's own correction applies at once and locks.
  j := public.suggest_place_edit(current_setting('test.pd')::uuid, '{"website":"https://example.org/park"}');
  if j ->> 'status' <> 'approved' then raise exception 'FAIL a moderator edit was queued'; end if;
  if not exists (select 1 from public.places where id = current_setting('test.pd')::uuid and 'website' = any (locked_fields)) then
    raise exception 'FAIL a moderator edit to an import did not lock';
  end if;
  insert into pct_lines (line) values ('moderate edits, locked fields: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Rule 4: reports
-- ---------------------------------------------------------------------------
do $$
declare
  pc text := current_setting('test.pc');
  pd text := current_setting('test.pd');
  j  jsonb;
  r  text;
begin
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  r := pg_temp.try('select public.report_place(' || quote_literal(pc) || '::uuid, ''because'')');
  if r <> 'invalid_reason' then raise exception 'FAIL a bad reason gave %', r; end if;
  -- private_residence on a reviewed member place: hidden at once.
  j := public.report_place(current_setting('test.p1')::uuid, 'private_residence', 'This is my neighbour''s house');
  if not (j ->> 'hidden')::boolean then raise exception 'FAIL private_residence did not hide a member place'; end if;
  if exists (select 1 from public.places where id = current_setting('test.p1')::uuid) then
    raise exception 'FAIL a hidden place is still readable';
  end if;
  -- unsafe on a meeting spot: hidden; on an import: not.
  j := public.report_place(current_setting('test.pv')::uuid, 'unsafe');
  if not (j ->> 'hidden')::boolean then raise exception 'FAIL unsafe did not hide a meeting spot'; end if;
  j := public.report_place(pd::uuid, 'unsafe');
  if (j ->> 'hidden')::boolean then raise exception 'FAIL one unsafe report hid an imported place'; end if;
  -- Three reporters hide any place; two do not; one open report each.
  j := public.report_place(pc::uuid, 'closed', 'Shut last month');
  j := public.report_place(pc::uuid, 'spam');
  if not (j ->> 'already')::boolean then raise exception 'FAIL a second open report was created'; end if;
  perform pg_temp.as_user(current_setting('test.u3')::uuid);
  j := public.report_place(pc::uuid, 'wrong_info');
  if (j ->> 'hidden')::boolean then raise exception 'FAIL two reports hid a place'; end if;
  perform pg_temp.as_user(current_setting('test.u4')::uuid);
  j := public.report_place(pc::uuid, 'other');
  if not (j ->> 'hidden')::boolean then raise exception 'FAIL three reporters did not hide a place'; end if;
  insert into pct_lines (line) values ('rule 4 reports: ok');
end $$;

-- Twenty reports a day.
do $$
declare
  ids uuid[];
  i integer;
  r text;
begin
  select array_agg(id order by source_id) into ids from public.places
   where source = 'osm' and source_id like 'test-pct-e%-' || current_setting('test.tag');
  perform pg_temp.as_user(current_setting('test.u3')::uuid);
  for i in 1..19 loop    -- u3 already reported C today
    perform public.report_place(ids[i], 'wrong_info');
  end loop;
  r := pg_temp.try('select public.report_place(' || quote_literal(ids[20]::text) || '::uuid, ''wrong_info'')');
  if r <> 'rate_limited' then raise exception 'FAIL the 21st report gave %', r; end if;
  insert into pct_lines (line) values ('twenty reports a day: ok');
end $$;

-- A moderator decides the reports.
do $$
declare
  q  jsonb;
  it jsonb;
  j  jsonb;
begin
  perform pg_temp.as_user(current_setting('test.um')::uuid);
  q := public.mod_place_queue(200);
  select x.value into it from jsonb_array_elements(q -> 'items') x
   where x.value ->> 'kind' = 'reports' and x.value ->> 'id' = current_setting('test.pc');
  if it is null or (it ->> 'open')::integer <> 3 or (it ->> 'reporters')::integer <> 3
     or (it -> 'reasons' ->> 'closed')::integer <> 1 or jsonb_array_length(it -> 'reports') <> 3
     or it -> 'place' ->> 'status' <> 'hidden' then
    raise exception 'FAIL the reports item';
  end if;
  j := public.mod_resolve_place('reports', current_setting('test.pc')::uuid, 'dismiss');
  if j ->> 'place_status' <> 'active' then raise exception 'FAIL dismiss did not bring the place back'; end if;
  if exists (select 1 from public.place_reports where place_id = current_setting('test.pc')::uuid and status = 'open') then
    raise exception 'FAIL dismiss left open reports';
  end if;
  j := public.mod_resolve_place('reports', current_setting('test.pd')::uuid, 'close');
  if j ->> 'place_status' <> 'closed' or not ((j -> 'locked_fields') ? 'closed') then
    raise exception 'FAIL close did not close and lock an import';
  end if;
  j := public.mod_resolve_place('reports', current_setting('test.pv')::uuid, 'hide');
  if j ->> 'place_status' <> 'hidden' then raise exception 'FAIL hide'; end if;
  -- Remove: the place's pending edits are superseded.
  perform pg_temp.as_user(current_setting('test.u3')::uuid);
  perform public.suggest_place_edit(current_setting('test.pa')::uuid, '{"locality":"PCT Town"}');
  perform pg_temp.as_user(current_setting('test.u4')::uuid);
  perform public.report_place(current_setting('test.pa')::uuid, 'not_public');
  perform pg_temp.as_user(current_setting('test.um')::uuid);
  j := public.mod_resolve_place('reports', current_setting('test.pa')::uuid, 'remove');
  if j ->> 'place_status' <> 'removed'
     or exists (select 1 from public.place_edits where place_id = current_setting('test.pa')::uuid and status = 'pending') then
    raise exception 'FAIL remove left pending edits';
  end if;
  insert into pct_lines (line) values ('moderate reports: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Rule 7: a map read writes nothing; RLS on the new tables
-- ---------------------------------------------------------------------------
do $$
declare
  v_before bigint;
  v_after  bigint;
  v_n      integer;
begin
  perform pg_temp.as_user(current_setting('test.um')::uuid);   -- sees every row of the three tables
  select (select count(*) from public.place_edits) + (select count(*) from public.place_reports)
       + (select count(*) from public.place_mod_actions) into v_before;
  perform pg_temp.as_user(current_setting('test.u2')::uuid);
  perform public.map_in_view(-129.99, -61.95, -128.99, -60.99, array[current_setting('test.a')::uuid]);
  perform public.map_in_view(-129.99, -61.95, -128.99, -60.99);
  -- Only one's own rows.
  select count(*) into v_n from public.place_reports;
  if v_n <> 4 then
    raise exception 'FAIL a member sees other people''s reports (%)', v_n;
  end if;
  if exists (select 1 from public.place_mod_actions) then raise exception 'FAIL a member reads the moderation log'; end if;
  perform pg_temp.as_user(current_setting('test.u4')::uuid);
  if exists (select 1 from public.place_edits where place_id = current_setting('test.pa')::uuid) then
    raise exception 'FAIL a member sees another member''s edits';
  end if;
  perform pg_temp.as_user(current_setting('test.um')::uuid);
  select (select count(*) from public.place_edits) + (select count(*) from public.place_reports)
       + (select count(*) from public.place_mod_actions) into v_after;
  if v_after <> v_before then raise exception 'FAIL a map read wrote rows'; end if;
  insert into pct_lines (line) values ('rule 7 and RLS: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- Account deletion
-- ---------------------------------------------------------------------------
do $$
declare
  u2 uuid := current_setting('test.u2')::uuid;
begin
  -- u2 gets a pending edit on the reopened shop, then deletes their account.
  perform pg_temp.as_user(u2);
  execute 'set local role authenticated';
  perform public.suggest_place_edit(current_setting('test.pc')::uuid, '{"opening_hours":"Sa 10:00-14:00"}', 'Weekends');
  perform public.request_account_deletion('test');
  execute 'reset role';
  if exists (select 1 from public.place_edits where proposed_by = u2 or (status = 'pending' and note = 'Weekends')) then
    raise exception 'FAIL deletion kept the caller''s edits attributed or pending';
  end if;
  if exists (select 1 from public.place_reports where reporter_id = u2)
     or exists (select 1 from public.place_reports where note = 'Shut last month') then
    raise exception 'FAIL deletion kept the caller''s reports attributed';
  end if;
  if not exists (select 1 from public.place_reports where place_id = current_setting('test.p1')::uuid
                    and reason = 'private_residence' and reporter_id is null) then
    raise exception 'FAIL deletion dropped the reason of a report that hid a place';
  end if;
  if exists (select 1 from public.places where id = current_setting('test.p_u2')::uuid) then
    raise exception 'FAIL deletion kept the caller''s private pin';
  end if;
  insert into pct_lines (line) values ('account deletion: ok');
end $$;

select line as place_contributions from (
  select 0 as n, 'place_contributions: all assertions passed' as line
  union all
  select n, line from pct_lines) x
order by n;

rollback;
