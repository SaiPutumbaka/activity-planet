-- ============================================================================
-- Staging check for migration 20261122000100_places_schema.sql (D-041, hub
-- map slice 3) and the place rules seed. One transaction: sets up throwaway
-- users, venues and places, asserts with DO blocks that raise on failure,
-- then rolls everything back. Prints pass/fail only, never rows.
-- Run as the staging_file of a staging_only migrate.yml run (after the seed).
--   1 Static: schema_version 2.23 or later, RLS on the seven tables, no user id in
--     place_tiles / collector_budget / place_hubs, created_by unreadable by
--     clients, no client writes on places, tile helpers, account deletion
--     covers places.
--   2 Seed: 47 kinds, 575 verified rules, 1332 hub-rule links, place modes
--     436 / 130 / 46 over the catalog (hubs outside it stay 'specific'), the
--     four flagged hubs 'none'.
--   3 ODbL separation: imported and venue rows carry no user id, member rows
--     no import keys, only member rows are private, ODbL-1.0 only, the tag
--     allowlist.
--   4 Privacy rules (design 7): near_your_home, near_private_venue, member
--     public places start pending and only a moderator approves them, a
--     private-to-public flip goes to pending, not_onboarded,
--     place_creator_mismatch, rate_limited after 10 a day, venue rows need a
--     public venue, sensitive hubs take moderator links only, place_ref only
--     on a public venue, source immutable.
--   5 RLS: anon, a creator, another adult, a signed-in non-onboarded user
--     and a moderator each see exactly what design 6 allows.
--   6 Account deletion: private and pending places go, a reviewed one stays
--     without its creator.
-- ============================================================================
begin;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_a   uuid := gen_random_uuid();   -- creator with a saved home and a private venue
  v_b   uuid := gen_random_uuid();   -- another adult, owner of a public venue
  v_n   uuid := gen_random_uuid();   -- signed in, not onboarded
  v_m   uuid := gen_random_uuid();   -- moderator
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_g   uuid;
  v_s   uuid;
  v_id  uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'pls-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_a, v_b, v_n, v_m]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (v_a, v_b, v_n, v_m);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_a, v_b, v_m);
  insert into public.user_roles (user_id, role) values (v_m, 'moderator');
  update public.profile_private set home_point = pg_temp.pt(10.0, 40.0) where user_id = v_a;

  select h.id into v_g
    from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive order by h.slug limit 1;
  select h.id into v_s
    from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive order by h.slug limit 1;
  if v_g is null or v_s is null then raise exception 'setup: no general or sensitive hub'; end if;

  insert into public.venues (name, location, created_by, is_public)
  values ('Places test home', pg_temp.pt(10.1, 40.1), v_a, false) returning id into v_id;
  perform set_config('test.va', v_id::text, true);
  insert into public.venues (name, location, created_by, is_public)
  values ('Places test hall', pg_temp.pt(10.2, 40.2), v_b, true) returning id into v_id;
  perform set_config('test.vb', v_id::text, true);

  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);
  perform set_config('test.n', v_n::text, true);
  perform set_config('test.m', v_m::text, true);
  perform set_config('test.g', v_g::text, true);
  perform set_config('test.s', v_s::text, true);
  perform set_config('test.tag', v_tag, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 23] then
    raise exception 'FAIL schema_version is older than 2.23';
  end if;
  foreach t in array array['place_kinds', 'place_rules', 'hub_place_rules', 'places', 'place_hubs',
                           'place_tiles', 'collector_budget'] loop
    if not coalesce((select c.relrowsecurity from pg_class c
                      where c.oid = ('public.' || t)::regclass), false) then
      raise exception 'FAIL RLS is off on %', t;
    end if;
  end loop;
  -- No user ids in the demand, budget or link tables.
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name in ('place_tiles', 'collector_budget')
                and (data_type = 'uuid' or column_name ~ 'user|created_by|profile')) then
    raise exception 'FAIL place_tiles or collector_budget has a user column';
  end if;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public' and table_name = 'place_hubs'
                and data_type = 'uuid' and column_name not in ('place_id', 'hub_id')) then
    raise exception 'FAIL place_hubs has a user column';
  end if;
  if exists (select 1 from pg_constraint
              where contype = 'f' and confrelid in ('public.profiles'::regclass, 'auth.users'::regclass)
                and conrelid in ('public.place_tiles'::regclass, 'public.collector_budget'::regclass,
                                 'public.place_hubs'::regclass, 'public.place_rules'::regclass,
                                 'public.hub_place_rules'::regclass, 'public.place_kinds'::regclass)) then
    raise exception 'FAIL a places side table references a user';
  end if;
  -- Column grants: nobody reads who added a place.
  if has_column_privilege('anon', 'public.places', 'created_by', 'select')
     or has_column_privilege('authenticated', 'public.places', 'created_by', 'select') then
    raise exception 'FAIL places.created_by is client-readable';
  end if;
  if not has_column_privilege('anon', 'public.places', 'name', 'select')
     or not has_column_privilege('authenticated', 'public.places', 'rule_ids', 'select') then
    raise exception 'FAIL places columns are not readable';
  end if;
  foreach t in array array['places', 'place_hubs', 'place_tiles', 'collector_budget'] loop
    if has_table_privilege('anon', 'public.' || t, 'insert') or has_table_privilege('anon', 'public.' || t, 'update')
       or has_table_privilege('anon', 'public.' || t, 'delete')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete') then
      raise exception 'FAIL clients can write %', t;
    end if;
  end loop;
  if has_table_privilege('anon', 'public.place_tiles', 'select')
     or has_table_privilege('anon', 'public.collector_budget', 'select') then
    raise exception 'FAIL anon can read place_tiles or collector_budget';
  end if;
  if has_function_privilege('authenticated', 'public.places_guard()', 'execute')
     or has_function_privilege('authenticated', 'public.place_hubs_guard()', 'execute') then
    raise exception 'FAIL clients can call the places guards';
  end if;
  -- Tile helpers.
  if public.place_tile_id(33.749, -84.388) <> 247 * 720 + 191
     or public.place_tile_id(90, 180) <> 359 * 720 + 719 or public.place_tile_id(-90, -180) <> 0 then
    raise exception 'FAIL place_tile_id arithmetic';
  end if;
  if not extensions.ST_Contains(public.place_tile_bbox(public.place_tile_id(33.749, -84.388)),
                                extensions.ST_SetSRID(extensions.ST_MakePoint(-84.388, 33.749), 4326)) then
    raise exception 'FAIL place_tile_bbox does not contain its point';
  end if;
  if exists (select 1 from public.areas where slug = 'atlanta')
     and (select count(*) from public.place_tiles t join public.areas a on a.slug = 'atlanta'
           where t.id = public.place_tile_id_of(a.center) and t.status = 'active') <> 1 then
    raise exception 'FAIL Atlanta''s tile is not seeded active';
  end if;
  -- listing_kind and place_ref.
  if (select column_default from information_schema.columns
       where table_schema = 'public' and table_name = 'events' and column_name = 'listing_kind') <> '''plan''::text'
     or not exists (select 1 from pg_constraint where conname = 'events_listing_kind')
     or not exists (select 1 from pg_constraint where conname = 'feed_sources_listing_kind')
     or not exists (select 1 from information_schema.columns
                     where table_schema = 'public' and table_name = 'venues' and column_name = 'place_ref') then
    raise exception 'FAIL listing_kind or venues.place_ref missing';
  end if;
  -- Account deletion covers places.
  if pg_get_functiondef('public.request_account_deletion(text)'::regprocedure) !~ 'delete from public\.places'
     or pg_get_functiondef('public.request_account_deletion(text)'::regprocedure)
          !~ 'update public\.places set created_by = null where created_by = uid' then
    raise exception 'FAIL account deletion does not cover places';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Seed
-- ---------------------------------------------------------------------------
do $$
begin
  if (select count(*) from public.place_kinds) <> 47 then
    raise exception 'FAIL place_kinds count is %', (select count(*) from public.place_kinds);
  end if;
  if (select count(*) from public.place_rules where verified and rules_version = 1) <> 575
     or (select count(*) from public.place_rules) <> 575 then
    raise exception 'FAIL place_rules count is %', (select count(*) from public.place_rules);
  end if;
  if (select count(*) from public.hub_place_rules) <> 1332 then
    raise exception 'FAIL hub_place_rules count is %', (select count(*) from public.hub_place_rules);
  end if;
  -- The catalog's 612 hubs are 436 / 130 / 46; a hub made outside the catalog
  -- (for example from a hub request) keeps the default 'specific'.
  if (select count(*) from public.hubs where place_mode = 'generic') <> 130
     or (select count(*) from public.hubs where place_mode = 'none') <> 46
     or (select count(*) from public.hubs) < 612
     or (select count(*) from public.hubs where place_mode = 'specific') - 436
        <> (select count(*) from public.hubs) - 612 then
    raise exception 'FAIL place modes are not 436 / 130 / 46 over the catalog';
  end if;
  if (select count(*) from public.hubs
       where slug in ('hunting', 'knife-collecting', 'cliff-diving', 'spearfishing') and place_mode = 'none') <> 4 then
    raise exception 'FAIL a flagged hub is not events-only';
  end if;
  if exists (select 1 from public.hub_place_rules r join public.hubs h on h.id = r.hub_id where h.place_mode = 'none') then
    raise exception 'FAIL an events-only hub has place rules';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. ODbL separation (as the owner, no signed-in user: the ingest path)
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims', '', true);
do $$
declare
  v_tag text := current_setting('test.tag');
  v_a   uuid := current_setting('test.a')::uuid;
  v_id  uuid;
begin
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n1' || v_tag, 'Test court', 'court_field', pg_temp.pt(10.3, 40.3), true, 'active',
          '© OpenStreetMap contributors', '{1}')
  returning id into v_id;
  perform set_config('test.o1', v_id::text, true);
  if (select tile_id from public.places where id = v_id) <> public.place_tile_id(40.3, 10.3)
     or (select license from public.places where id = v_id) <> 'ODbL-1.0' then
    raise exception 'FAIL tile_id or default licence on an OSM row';
  end if;

  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, created_by)
    values ('osm', 'n2' || v_tag, 'Bad', 'court_field', pg_temp.pt(10.3, 40.3), true, 'active', 'x', v_a);
    raise exception 'FAIL an OSM row took a user id';
  exception when check_violation then
    if sqlerrm !~ 'places_source_shape' then raise exception 'FAIL OSM with user id gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
    values ('venue', current_setting('test.vb'), 'Bad', 'spot', pg_temp.pt(10.3, 40.3), true, 'active', 'x');
    update public.places set created_by = v_a where source = 'venue' and source_id = current_setting('test.vb');
    raise exception 'FAIL a venue row took a user id';
  exception when check_violation then
    if sqlerrm !~ 'places_source_shape|place_creator' then raise exception 'FAIL venue with user id gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
    values ('geoapify', 'g3' || v_tag, 'Bad', 'court_field', pg_temp.pt(10.3, 40.3), false, 'active', 'x');
    raise exception 'FAIL an imported row was private';
  exception when check_violation then
    if sqlerrm !~ 'places_private_is_user' then raise exception 'FAIL private import gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, license)
    values ('osm', 'n4' || v_tag, 'Bad', 'court_field', pg_temp.pt(10.3, 40.3), true, 'active', 'x', 'CC-BY-4.0');
    raise exception 'FAIL a non-ODbL licence was stored';
  exception when check_violation then
    if sqlerrm !~ 'places_license' then raise exception 'FAIL licence gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, tags)
    values ('osm', 'n5' || v_tag, 'Bad', 'court_field', pg_temp.pt(10.3, 40.3), true, 'active', 'x',
            '{"sport":"basketball","contact:email":"x@example.com"}');
    raise exception 'FAIL a tag outside the allowlist was stored';
  exception when check_violation then
    if sqlerrm !~ 'places_tags_allowlist' then raise exception 'FAIL tags gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'u6' || v_tag, 'Bad', 'spot', pg_temp.pt(10.3, 40.3), false, 'active', 'x', v_a);
    raise exception 'FAIL a member row took an import key';
  exception when check_violation then
    if sqlerrm !~ 'places_source_shape' then raise exception 'FAIL member with source_id gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution)
    values ('user', 'Bad', 'spot', pg_temp.pt(10.3, 40.3), false, 'active', 'x');
    raise exception 'FAIL a private row without its member';
  exception when check_violation then
    if sqlerrm !~ 'places_private_is_user' then raise exception 'FAIL ownerless private gave %', sqlerrm; end if;
  end;
  begin
    update public.places set source = 'user' where id = v_id;
    raise exception 'FAIL source changed';
  exception when check_violation then
    if sqlerrm <> 'place_source_immutable' then raise exception 'FAIL source change gave %', sqlerrm; end if;
  end;

  -- Rule 5: only public venues become meeting spots.
  begin
    insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
    values ('venue', current_setting('test.va'), 'Bad', 'spot', pg_temp.pt(10.1, 40.1), true, 'active', 'x');
    raise exception 'FAIL a private venue became a place';
  exception when check_violation then
    if sqlerrm <> 'venue_not_public' then raise exception 'FAIL private venue gave %', sqlerrm; end if;
  end;
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution)
  values ('venue', current_setting('test.vb'), 'Places test hall', 'spot', pg_temp.pt(10.2, 40.2), true, 'active',
          'Activity Planet plans')
  returning id into v_id;
  perform set_config('test.pven', v_id::text, true);

  -- place_ref only on a public venue. Migration 33 (venues_place_ref_guard): a private venue's
  -- place_ref is cleared on write instead of refused.
  update public.venues set place_ref = current_setting('test.o1')::uuid where id = current_setting('test.va')::uuid;
  if (select place_ref from public.venues where id = current_setting('test.va')::uuid) is not null then
    raise exception 'FAIL a private venue got a place_ref';
  end if;
  update public.venues set place_ref = v_id where id = current_setting('test.vb')::uuid;

  -- A hidden public member place of B (for the RLS checks).
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test hidden', 'spot', pg_temp.pt(10.4, 40.4), true, 'hidden', 'Added by members',
          current_setting('test.b')::uuid)
  returning id into v_id;
  perform set_config('test.phid', v_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Privacy rules, as the creator through a definer path (owner + JWT)
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
do $$
declare
  v_a  uuid := current_setting('test.a')::uuid;
  v_id uuid;
  v_st public.place_status;
  k    integer;
begin
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test private', 'spot', pg_temp.pt(10.05, 40.05), false, 'active', 'Added by members', v_a)
  returning id, status into v_id, v_st;
  if v_st <> 'active' then raise exception 'FAIL a private pin was not active for its creator'; end if;
  perform set_config('test.ppriv', v_id::text, true);

  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test approve', 'spot', pg_temp.pt(10.06, 40.06), true, 'active', 'Added by members', v_a)
  returning id, status into v_id, v_st;
  if v_st <> 'pending' then raise exception 'FAIL a member''s public place skipped review (%)', v_st; end if;
  perform set_config('test.pappr', v_id::text, true);

  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test pending', 'spot', pg_temp.pt(10.07, 40.07), true, 'pending', 'Added by members', v_a)
  returning id into v_id;
  perform set_config('test.ppend', v_id::text, true);

  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test flip', 'spot', pg_temp.pt(10.08, 40.08), false, 'active', 'Added by members', v_a)
  returning id into v_id;
  update public.places set is_public = true where id = v_id returning status into v_st;
  if v_st <> 'pending' then raise exception 'FAIL a private-to-public flip skipped review (%)', v_st; end if;

  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'Bad', 'spot', pg_temp.pt(10.0008, 40.0008), true, 'pending', 'x', v_a);
    raise exception 'FAIL a public place 100 m from home was accepted';
  exception when check_violation then
    if sqlerrm <> 'near_your_home' then raise exception 'FAIL near home gave %', sqlerrm; end if;
  end;
  begin
    update public.places set location = pg_temp.pt(10.0005, 40.0005) where id = current_setting('test.ppend')::uuid;
    raise exception 'FAIL a public place was moved next to home';
  exception when check_violation then
    if sqlerrm <> 'near_your_home' then raise exception 'FAIL move near home gave %', sqlerrm; end if;
  end;
  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'Bad', 'spot', pg_temp.pt(10.1003, 40.1002), true, 'pending', 'x', v_a);
    raise exception 'FAIL a public place 30 m from a private venue was accepted';
  exception when check_violation then
    if sqlerrm <> 'near_private_venue' then raise exception 'FAIL near private venue gave %', sqlerrm; end if;
  end;
  -- A private pin at home is fine (only its creator sees it).
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Places test home pin', 'spot', pg_temp.pt(10.0002, 40.0002), false, 'active', 'x', v_a);
  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'Bad', 'spot', pg_temp.pt(10.5, 40.5), false, 'active', 'x', current_setting('test.b')::uuid);
    raise exception 'FAIL a place was created for someone else';
  exception when check_violation then
    if sqlerrm <> 'place_creator_mismatch' then raise exception 'FAIL creator mismatch gave %', sqlerrm; end if;
  end;
  begin
    update public.places set status = 'active' where id = current_setting('test.pappr')::uuid;
    raise exception 'FAIL the creator approved their own place';
  exception when insufficient_privilege then
    if sqlerrm <> 'moderator_required' then raise exception 'FAIL self-approval gave %', sqlerrm; end if;
  end;

  -- Rate limit: 10 a day (5 made above).
  for k in 1..5 loop
    insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'Places test pin ' || k, 'spot', pg_temp.pt(11 + k * 0.01, 41.0), false, 'active', 'x', v_a);
  end loop;
  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
    values ('user', 'Bad', 'spot', pg_temp.pt(11.5, 41.0), false, 'active', 'x', v_a);
    raise exception 'FAIL an eleventh place in a day was accepted';
  exception when check_violation then
    if sqlerrm <> 'rate_limited' then raise exception 'FAIL rate limit gave %', sqlerrm; end if;
  end;
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.n'), 'role', 'authenticated')::text, true);
do $$
begin
  insert into public.places (source, name, kind, location, is_public, status, attribution, created_by)
  values ('user', 'Bad', 'spot', pg_temp.pt(12.0, 42.0), false, 'active', 'x', current_setting('test.n')::uuid);
  raise exception 'FAIL a member who has not finished onboarding added a place';
exception when check_violation then
  if sqlerrm <> 'not_onboarded' then raise exception 'FAIL not onboarded gave %', sqlerrm; end if;
end $$;

-- A moderator approves; links, sensitive hubs.
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
do $$
declare
  v_st public.place_status;
  v_o1 uuid := current_setting('test.o1')::uuid;
  v_s  uuid := current_setting('test.s')::uuid;
  v_g  uuid := current_setting('test.g')::uuid;
begin
  update public.places set status = 'active' where id = current_setting('test.pappr')::uuid returning status into v_st;
  if v_st <> 'active' then raise exception 'FAIL a moderator could not approve'; end if;

  begin
    insert into public.place_hubs (place_id, hub_id, via) values (v_o1, v_s, 'member');
    raise exception 'FAIL a member link on a sensitive hub';
  exception when check_violation then
    if sqlerrm <> 'sensitive_hub_link' then raise exception 'FAIL sensitive member link gave %', sqlerrm; end if;
  end;
  begin
    insert into public.place_hubs (place_id, hub_id, via, weight) values (v_o1, v_s, 'events', 3);
    raise exception 'FAIL a plan count on a sensitive hub';
  exception when check_violation then
    if sqlerrm <> 'sensitive_hub_link' then raise exception 'FAIL sensitive events link gave %', sqlerrm; end if;
  end;
  insert into public.place_hubs (place_id, hub_id, via) values (v_o1, v_s, 'moderator');
  insert into public.place_hubs (place_id, hub_id, via) values (v_o1, v_g, 'member');
  insert into public.place_hubs (place_id, hub_id, via) values (current_setting('test.ppend')::uuid, v_g, 'member');
  begin
    update public.place_hubs set via = 'member' where place_id = v_o1 and hub_id = v_s;
    raise exception 'FAIL a sensitive link was turned into a member link';
  exception when check_violation then
    if sqlerrm <> 'sensitive_hub_link' then raise exception 'FAIL sensitive update gave %', sqlerrm; end if;
  end;
end $$;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 5. RLS
-- ---------------------------------------------------------------------------
-- A helper (created inside this transaction, rolled back with it): which of
-- the test places the current role sees, as a sorted list of labels.
create function public.pls_test_seen() returns text language sql stable as $$
  select coalesce(string_agg(l.label, ',' order by l.label), '')
    from (values ('o1', current_setting('test.o1')), ('pven', current_setting('test.pven')),
                 ('phid', current_setting('test.phid')), ('ppriv', current_setting('test.ppriv')),
                 ('pappr', current_setting('test.pappr')), ('ppend', current_setting('test.ppend'))) as l(label, id)
    join public.places p on p.id = l.id::uuid;
$$;
grant execute on function public.pls_test_seen() to anon, authenticated;

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  v_seen text := public.pls_test_seen();
  v_n    integer;
begin
  if v_seen <> 'o1,pappr,pven' then raise exception 'FAIL anon sees %', v_seen; end if;
  begin
    perform created_by from public.places limit 1;
    raise exception 'FAIL anon read places.created_by';
  exception when insufficient_privilege then null;
  end;
  begin
    insert into public.places (source, name, kind, location, is_public, status, attribution)
    values ('user', 'Bad', 'spot', 'SRID=4326;POINT(1 1)'::extensions.geography, true, 'active', 'x');
    raise exception 'FAIL anon inserted a place';
  exception when insufficient_privilege then null;
  end;
  select count(*) into v_n from public.place_hubs
   where place_id in (current_setting('test.o1')::uuid, current_setting('test.ppend')::uuid);
  if v_n <> 2 then raise exception 'FAIL anon sees % links (expected the 2 on the public place)', v_n; end if;
  begin
    perform 1 from public.place_tiles limit 1;
    raise exception 'FAIL anon read place_tiles';
  exception when insufficient_privilege then null;
  end;
  begin
    perform 1 from public.collector_budget limit 1;
    raise exception 'FAIL anon read collector_budget';
  exception when insufficient_privilege then null;
  end;
  if (select count(*) from public.place_rules) <> 575 or (select count(*) from public.place_kinds) <> 47 then
    raise exception 'FAIL anon cannot read the rule tables';
  end if;
  begin
    insert into public.place_kinds (slug, label, icon) values ('test_kind', 'Test kind', 'map-pin');
    raise exception 'FAIL anon wrote place_kinds';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- The creator: own private and pending rows too; no writes, no created_by.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
do $$
declare
  v_seen text := public.pls_test_seen();
  v_n    integer;
begin
  if v_seen <> 'o1,pappr,ppend,ppriv,pven' then raise exception 'FAIL the creator sees %', v_seen; end if;
  begin
    perform created_by from public.places where id = current_setting('test.ppriv')::uuid;
    raise exception 'FAIL the creator read created_by';
  exception when insufficient_privilege then null;
  end;
  begin
    update public.places set is_public = true where id = current_setting('test.ppriv')::uuid;
    raise exception 'FAIL the creator flipped is_public directly';
  exception when insufficient_privilege then null;
  end;
  begin
    delete from public.places where id = current_setting('test.ppriv')::uuid;
    raise exception 'FAIL the creator deleted a place directly';
  exception when insufficient_privilege then null;
  end;
  select count(*) into v_n from public.place_hubs where place_id = current_setting('test.ppend')::uuid;
  if v_n <> 1 then raise exception 'FAIL the creator does not see the link on their pending place'; end if;
end $$;
reset role;

-- Another adult: public rows and their own hidden one; no tiles; no rule writes.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
do $$
declare
  v_seen text := public.pls_test_seen();
begin
  if v_seen <> 'o1,pappr,phid,pven' then raise exception 'FAIL another adult sees %', v_seen; end if;
  if exists (select 1 from public.place_hubs where place_id = current_setting('test.ppend')::uuid) then
    raise exception 'FAIL another adult sees a link on a pending place';
  end if;
  if (select count(*) from public.place_tiles) <> 0 or (select count(*) from public.collector_budget) <> 0 then
    raise exception 'FAIL a member read place_tiles or collector_budget';
  end if;
  begin
    insert into public.place_kinds (slug, label, icon) values ('test_kind', 'Test kind', 'map-pin');
    raise exception 'FAIL a member wrote place_kinds';
  exception when insufficient_privilege then null;
  end;
  delete from public.place_rules where id = 1;   -- RLS: no row qualifies
  if not exists (select 1 from public.place_rules where id = 1) then
    raise exception 'FAIL a member deleted a place rule';
  end if;
end $$;
reset role;

-- Signed in but not an adult member yet: imported places only.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.n'), 'role', 'authenticated')::text, true);
do $$
declare
  v_seen text := public.pls_test_seen();
begin
  if v_seen <> 'o1' then raise exception 'FAIL a non-onboarded user sees %', v_seen; end if;
end $$;
reset role;

-- A moderator: everything; tiles yes; rule writes yes; budget writes no.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
do $$
declare
  v_seen text := public.pls_test_seen();
begin
  if v_seen <> 'o1,pappr,phid,ppend,ppriv,pven' then raise exception 'FAIL a moderator sees %', v_seen; end if;
  if exists (select 1 from public.areas where slug = 'atlanta') and (select count(*) from public.place_tiles) < 3 then
    raise exception 'FAIL a moderator cannot read the seeded tiles';
  end if;
  insert into public.place_kinds (slug, label, icon) values ('test_kind', 'Test kind', 'map-pin');
  begin
    insert into public.collector_budget (day, source, used) values (current_date, 'test', 1);
    raise exception 'FAIL a moderator wrote collector_budget';
  exception when insufficient_privilege then null;
  end;
  begin
    perform created_by from public.places limit 1;
    raise exception 'FAIL a moderator read created_by directly';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 6. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
do $$ begin perform public.request_account_deletion(null); end $$;
reset role;
select set_config('request.jwt.claims', '', true);
do $$
declare
  v_a uuid := current_setting('test.a')::uuid;
begin
  if exists (select 1 from public.places where created_by = v_a) then
    raise exception 'FAIL places still name a deleted account';
  end if;
  if exists (select 1 from public.places
              where id in (current_setting('test.ppriv')::uuid, current_setting('test.ppend')::uuid)) then
    raise exception 'FAIL a deleted account''s private or pending place survived';
  end if;
  if not exists (select 1 from public.places where id = current_setting('test.pappr')::uuid and created_by is null
                   and status = 'active' and is_public) then
    raise exception 'FAIL a reviewed public place did not survive unattributed';
  end if;
  if exists (select 1 from public.place_hubs where place_id = current_setting('test.ppend')::uuid) then
    raise exception 'FAIL a deleted place kept its hub link';
  end if;
end $$;

select 'places_schema: all assertions passed' as result;

rollback;
