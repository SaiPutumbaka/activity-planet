-- ============================================================================
-- Staging check for migration 20261126000100_map_ui_fields.sql (D-041, hub
-- map: the fields the Map tab reads) and a shape check of the three map RPCs
-- on the Atlanta data, as the Map tab calls them. One transaction, asserts in
-- DO blocks that raise on failure, rolled back at the end. Prints pass/fail
-- and counts only (row counts, payload bytes), never names, ids or points
-- (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.28; place_tiles_mapping_in_view is definer
--     and STABLE, map_in_view still invoker and STABLE; anon and
--     authenticated execute both; one version of each.
--   2 Fixture (Southern Ocean, no real data there), signed out: a cell
--     carries titles and starts parallel to ids and still no point; plans
--     and shows never hold an approved-only event; mapping true while the
--     tile is wanted, false when it is active, false under zoom_in and when
--     the places layer is off.
--   3 Atlanta, signed out (null hubs = every specific hub; '{}' = no hubs)
--     and signed in (a throwaway user with 5 joined hubs; one generic hub
--     with generic set): every place, plan, show, cell and hub has the
--     encoding the client decodes, every hub index points into hubs, and
--     place_detail returns the keys the place card reads.
--   4 Nothing was written: place_tiles demand unchanged.
-- ============================================================================
begin;

create temp table mui_lines (n serial, line text);
grant insert, select on mui_lines to anon, authenticated;
grant usage on sequence mui_lines_n_seq to anon, authenticated;

create function pg_temp.pt(p_lng double precision, p_lat double precision)
returns extensions.geography language sql immutable as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- Returns null when r has the shape the client decodes, else a message that
-- names only the part and position that failed (no values).
create function pg_temp.mui_shape(r jsonb) returns text language plpgsql stable as $$
declare
  nh  integer;
  x   jsonb;
  i   jsonb;
  k   text;
  n   integer;
begin
  if r ->> 'v' <> '1' then return 'v'; end if;
  foreach k in array array['zoom_in', 'truncated', 'no_hubs', 'generic', 'mapping'] loop
    if jsonb_typeof(r -> k) <> 'boolean' then return 'flag ' || k; end if;
  end loop;
  if jsonb_typeof(r -> 'more') <> 'object' then return 'more'; end if;
  if jsonb_typeof(r -> 'hubs') <> 'array' or jsonb_typeof(r -> 'cells') <> 'array' then return 'hubs/cells'; end if;
  nh := jsonb_array_length(r -> 'hubs');
  for x in select value from jsonb_array_elements(r -> 'hubs') loop
    if jsonb_array_length(x) <> 5 or (x ->> 0)::uuid is null or jsonb_typeof(x -> 1) <> 'string'
       or jsonb_typeof(x -> 2) <> 'string' or x ->> 4 not in ('specific', 'generic', 'none') then
      return 'hub tuple';
    end if;
  end loop;
  if jsonb_typeof(r -> 'places') not in ('array', 'null') then return 'places type'; end if;
  for x in select value from jsonb_array_elements(coalesce(nullif(r -> 'places', 'null'::jsonb), '[]')) loop
    if jsonb_array_length(x) <> 8 or (x ->> 0)::uuid is null
       or jsonb_typeof(x -> 1) <> 'number' or jsonb_typeof(x -> 2) <> 'number'
       or (x ->> 1)::float8 not between -180 and 180 or (x ->> 2)::float8 not between -90 and 90
       or jsonb_typeof(x -> 3) <> 'string' or jsonb_typeof(x -> 6) <> 'string'
       or jsonb_typeof(x -> 5) <> 'number' or (x ->> 5)::integer not between 0 and 127
       or jsonb_typeof(x -> 7) <> 'array' then
      return 'place tuple';
    end if;
    if jsonb_typeof(x -> 4) <> 'null' and (x ->> 4)::integer not between 0 and nh - 1 then
      return 'place hub_idx';
    end if;
    for i in select value from jsonb_array_elements(x -> 7) loop
      if i::text::integer not between 0 and nh - 1 then return 'place hub_idxs'; end if;
    end loop;
    if jsonb_typeof(x -> 4) <> 'null' and x -> 4 <> x -> 7 -> 0 then return 'place hub_idx first'; end if;
  end loop;
  foreach k in array array['plans', 'shows'] loop
    if jsonb_typeof(r -> k) <> 'array' then return k || ' type'; end if;
    for x in select value from jsonb_array_elements(r -> k) loop
      if jsonb_array_length(x) <> 8 or (x ->> 0)::uuid is null
         or jsonb_typeof(x -> 1) <> 'number' or jsonb_typeof(x -> 2) <> 'number'
         or jsonb_typeof(x -> 3) <> 'string' or jsonb_typeof(x -> 4) <> 'number'
         or (x ->> 4)::integer not between 0 and nh - 1
         or (x ->> 5)::integer not between 0 and 15 or jsonb_typeof(x -> 6) <> 'string'
         or jsonb_typeof(x -> 7) <> 'number' then
        return k || ' tuple';
      end if;
    end loop;
  end loop;
  for x in select value from jsonb_array_elements(r -> 'cells') loop
    if jsonb_array_length(x) <> 7 or jsonb_typeof(x -> 0) <> 'number' or jsonb_typeof(x -> 1) <> 'number'
       or (x ->> 0)::numeric <> round((x ->> 0)::numeric, 1) or (x ->> 1)::numeric <> round((x ->> 1)::numeric, 1) then
      return 'cell tuple';
    end if;
    n := (x ->> 2)::integer;
    if n < 1 or jsonb_array_length(x -> 3) <> n or jsonb_array_length(x -> 4) <> n
       or jsonb_array_length(x -> 5) <> n or jsonb_array_length(x -> 6) <> n then
      return 'cell arrays';
    end if;
    for i in select value from jsonb_array_elements(x -> 4) loop
      if i::text::integer not between 0 and nh - 1 then return 'cell hub_idxs'; end if;
    end loop;
    for i in select value from jsonb_array_elements(x -> 5) loop
      if jsonb_typeof(i) <> 'string' then return 'cell titles'; end if;
    end loop;
    for i in select value from jsonb_array_elements(x -> 6) loop
      if jsonb_typeof(i) <> 'number' then return 'cell starts'; end if;
    end loop;
  end loop;
  return null;
end $$;

-- As the owner: no approved-only event is a plan or show, every cell id is
-- approved-only, and no cell is a point other than its 0.1-degree centre.
create function pg_temp.mui_privacy(r jsonb) returns text language plpgsql stable as $$
begin
  if exists (select 1 from jsonb_array_elements(coalesce(r -> 'plans', '[]') || coalesce(r -> 'shows', '[]')) f
               join public.events e on e.id = (f.value ->> 0)::uuid
              where e.address_visibility = 'approved_only') then
    return 'an approved-only event came back as a point';
  end if;
  if exists (select 1 from jsonb_array_elements(r -> 'cells') c
              cross join lateral jsonb_array_elements_text(c.value -> 3) i(id)
               join public.events e on e.id = i.id::uuid
              where e.address_visibility <> 'approved_only'
                 or round(e.approx_lng::numeric, 1) <> (c.value ->> 0)::numeric
                 or round(e.approx_lat::numeric, 1) <> (c.value ->> 1)::numeric) then
    return 'a cell holds a public event or the wrong centre';
  end if;
  if exists (select 1 from jsonb_array_elements(r -> 'cells') c
              cross join lateral jsonb_array_elements_text(c.value -> 3) with ordinality i(id, o)
               join public.events e on e.id = i.id::uuid
              where e.title <> c.value -> 5 ->> (i.o::integer - 1)
                 or extract(epoch from e.starts_at)::bigint <> (c.value -> 6 ->> (i.o::integer - 1))::bigint) then
    return 'cell titles or starts do not line up with ids';
  end if;
  return null;
end $$;

create function pg_temp.mui_counts(p_label text, r jsonb) returns text language sql stable as $$
  select format('%s: places %s plans %s shows %s cells %s (events %s) hubs %s | zoom_in %s truncated %s mapping %s no_hubs %s generic %s | geoapify %s general %s | %s B',
    p_label,
    coalesce(jsonb_array_length(nullif(r -> 'places', 'null'::jsonb)), -1),
    jsonb_array_length(r -> 'plans'), jsonb_array_length(r -> 'shows'), jsonb_array_length(r -> 'cells'),
    (select coalesce(sum((c.value ->> 2)::integer), 0) from jsonb_array_elements(r -> 'cells') c),
    jsonb_array_length(r -> 'hubs'),
    r ->> 'zoom_in', r ->> 'truncated', r ->> 'mapping', r ->> 'no_hubs', r ->> 'generic',
    (select count(*) from jsonb_array_elements(coalesce(nullif(r -> 'places', 'null'::jsonb), '[]')) p
      where ((p.value ->> 5)::integer & 32) <> 0),
    (select count(*) from jsonb_array_elements(coalesce(nullif(r -> 'places', 'null'::jsonb), '[]')) p
      where ((p.value ->> 5)::integer & 1) <> 0),
    octet_length(r::text));
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_h   uuid := gen_random_uuid();   -- host of the fixture plans
  v_u   uuid := gen_random_uuid();   -- Atlanta viewer with 5 joined hubs
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_a   uuid;
  v_e   uuid;
  v_t   integer := public.place_tile_id(-60.2, -150.2);
  v_box extensions.geometry := extensions.ST_MakeEnvelope(-85.0, 33.5, -84.0, 34.5, 4326);
  v_top uuid[];
  v_gen uuid;
begin
  if exists (select 1 from public.events
              where approx_point is not null
                and (approx_point::extensions.geometry) operator(extensions.&&)
                    extensions.ST_MakeEnvelope(-151, -61, -149, -59, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;
  perform set_config('test.demand', (select coalesce(sum(demand), 0)::text from public.place_tiles), true);

  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'mui-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_h, v_u]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (v_h, v_u);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_h, v_u);

  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' and coalesce(h.min_age, 0) < 21
   order by h.slug limit 1;
  if v_a is null then raise exception 'setup: no specific hub'; end if;

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point)
  values (v_a, v_h, 'MUI public plan', now() + interval '1 day', now() + interval '1 day 2 hours', 'Here',
          pg_temp.pt(-150.23, -60.23));
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_a, v_h, 'MUI approved only one', now() + interval '1 day', now() + interval '1 day 2 hours', 'Near here',
          pg_temp.pt(-150.21, -60.19), 'approved_only');
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint, approx_point, address_visibility)
  values (v_a, v_h, 'MUI approved only two', now() + interval '2 days', now() + interval '2 days 2 hours', 'Near here',
          pg_temp.pt(-150.18, -60.22), 'approved_only') returning id into v_e;

  insert into public.place_tiles (id, status) values (v_t, 'wanted')
  on conflict (id) do update set status = 'wanted';
  perform set_config('test.tile', v_t::text, true);

  -- Atlanta viewer: the 5 specific hubs with the most Atlanta places, and
  -- the generic hub with the most.
  with counts as (
    select h.id, h.place_mode, count(*) as n
      from public.places p
      join public.hub_place_rules r on r.rule_id = any (p.rule_ids)
      join public.hubs h on h.id = r.hub_id and h.is_active
      join public.hub_categories c on c.slug = h.category_slug and not c.is_sensitive
     where p.status = 'active' and p.is_public and p.geom operator(extensions.&&) v_box
     group by h.id, h.place_mode
  )
  select array(select c.id from counts c where c.place_mode = 'specific' order by c.n desc, c.id limit 5),
         (select c.id from counts c where c.place_mode = 'generic' order by c.n desc, c.id limit 1)
    into v_top, v_gen;
  if cardinality(v_top) < 5 or v_gen is null then
    raise exception 'setup: fewer than 5 specific hubs or no generic hub with Atlanta places';
  end if;
  insert into public.hub_members (hub_id, user_id, joined_at)
  select u.id, v_u, now() - (u.o || ' minutes')::interval from unnest(v_top) with ordinality u(id, o);

  perform set_config('test.u', v_u::text, true);
  perform set_config('test.gen', v_gen::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.28' then
    raise exception 'FAIL schema_version is not 2.28';
  end if;
  for r in
    select p.oid::regprocedure as sig, p.proname, p.prosecdef, p.provolatile
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname in ('map_in_view', 'place_tiles_mapping_in_view')
  loop
    if r.provolatile <> 's' then raise exception 'FAIL % is not STABLE', r.proname; end if;
    if r.prosecdef <> (r.proname = 'place_tiles_mapping_in_view') then
      raise exception 'FAIL % has the wrong security mode', r.proname;
    end if;
    if not has_function_privilege('anon', r.sig, 'execute')
       or not has_function_privilege('authenticated', r.sig, 'execute') then
      raise exception 'FAIL % is not executable by anon and authenticated', r.proname;
    end if;
  end loop;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname in ('map_in_view', 'place_tiles_mapping_in_view')) <> 2 then
    raise exception 'FAIL expected exactly one version of each function';
  end if;
  if has_table_privilege('anon', 'public.place_tiles', 'select') then
    raise exception 'FAIL anon can read place_tiles';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Fixture, signed out
-- ---------------------------------------------------------------------------
set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  r jsonb;
  c jsonb;
  s text;
begin
  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0);
  s := pg_temp.mui_shape(r);
  if s is not null then raise exception 'FAIL fixture shape: %', s; end if;
  if jsonb_array_length(r -> 'cells') <> 1 then raise exception 'FAIL fixture: expected one cell'; end if;
  c := r -> 'cells' -> 0;
  if c -> 0 <> '-150.2'::jsonb or c -> 1 <> '-60.2'::jsonb or (c ->> 2)::integer <> 2 then
    raise exception 'FAIL fixture cell centre or count';
  end if;
  if c -> 5 <> '["MUI approved only one", "MUI approved only two"]'::jsonb then
    raise exception 'FAIL fixture cell titles';
  end if;
  if (c -> 6 ->> 0)::bigint > (c -> 6 ->> 1)::bigint then raise exception 'FAIL fixture cell starts order'; end if;
  if jsonb_array_length(r -> 'plans') <> 1 or r -> 'plans' -> 0 ->> 6 <> 'MUI public plan' then
    raise exception 'FAIL fixture plans';
  end if;
  if (r ->> 'mapping')::boolean is not true then raise exception 'FAIL mapping not set on a wanted tile'; end if;
  perform set_config('test.fixture', r::text, true);

  r := public.map_in_view(-150.5, -60.5, -150.0, -60.0, null, array['plans', 'shows']);
  if (r ->> 'mapping')::boolean then raise exception 'FAIL mapping set without the places layer'; end if;
  r := public.map_in_view(-152.0, -62.0, -148.0, -59.0);
  if (r ->> 'mapping')::boolean or not (r ->> 'zoom_in')::boolean then
    raise exception 'FAIL mapping set under zoom_in';
  end if;
  if pg_temp.mui_shape(r) is not null then raise exception 'FAIL zoom_in shape: %', pg_temp.mui_shape(r); end if;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

do $$
declare
  s text := pg_temp.mui_privacy(current_setting('test.fixture')::jsonb);
begin
  if s is not null then raise exception 'FAIL fixture privacy: %', s; end if;
  update public.place_tiles set status = 'active' where id = current_setting('test.tile')::integer;
end $$;

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
begin
  if (public.map_in_view(-150.5, -60.5, -150.0, -60.0) ->> 'mapping')::boolean then
    raise exception 'FAIL mapping set on an active tile';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Atlanta, signed out
-- ---------------------------------------------------------------------------
do $$
declare
  r  jsonb;
  s  text;
  d  jsonb;
  w  timestamptz := now();
begin
  -- As the Map tab sends it: all layers, this week, generic off.
  r := public.map_in_view(-84.45, 33.70, -84.30, 33.85, null, array['places', 'plans', 'shows'], w, w + interval '7 days', false);
  s := pg_temp.mui_shape(r);
  if s is not null then raise exception 'FAIL anon Atlanta shape: %', s; end if;
  if jsonb_array_length(r -> 'places') = 0 then raise exception 'FAIL anon Atlanta: no places'; end if;
  if (r ->> 'mapping')::boolean then raise exception 'FAIL anon Atlanta: an Atlanta tile is still being mapped'; end if;
  insert into mui_lines (line) values (pg_temp.mui_counts('anon_city_all_specific', r));
  perform set_config('test.anon', r::text, true);

  d := public.place_detail((r -> 'places' -> 0 ->> 0)::uuid);
  if d ->> 'v' <> '1' or (d ->> 'id') is null or jsonb_typeof(d -> 'lng') <> 'number'
     or jsonb_typeof(d -> 'lat') <> 'number' or jsonb_typeof(d -> 'hubs') <> 'array'
     or jsonb_typeof(d -> 'plans_here') <> 'array' or jsonb_typeof(d -> 'mine') <> 'boolean'
     or jsonb_typeof(d -> 'is_public') <> 'boolean' or d ->> 'source' not in ('osm', 'user', 'geoapify', 'venue')
     or jsonb_typeof(d -> 'kind_label') <> 'string' or jsonb_typeof(d -> 'kind_icon') <> 'string'
     or jsonb_typeof(d -> 'more_hubs') <> 'boolean'
     or (d ? 'created_by') then
    raise exception 'FAIL anon place_detail shape';
  end if;
  if exists (select 1 from jsonb_array_elements(d -> 'hubs') h
              where jsonb_typeof(h.value -> 'id') <> 'string' or jsonb_typeof(h.value -> 'general') <> 'boolean'
                 or jsonb_typeof(h.value -> 'joined') <> 'boolean' or (h.value ->> 'joined')::boolean) then
    raise exception 'FAIL anon place_detail hubs';
  end if;
  if d ->> 'osm_url' is not null and d ->> 'osm_url' !~ '^https://www\.openstreetmap\.org/(node|way|relation)/[0-9]+$' then
    raise exception 'FAIL anon place_detail osm_url';
  end if;

  -- No hubs at all ('{}'): plans only.
  r := public.map_in_view(-84.45, 33.70, -84.30, 33.85, '{}'::uuid[], array['places', 'plans', 'shows'], w, w + interval '7 days', false);
  if pg_temp.mui_shape(r) is not null or jsonb_array_length(r -> 'places') <> 0 or not (r ->> 'no_hubs')::boolean then
    raise exception 'FAIL anon empty hubs';
  end if;
  insert into mui_lines (line) values (pg_temp.mui_counts('anon_city_no_hubs', r));

  -- Too large for places: zoom_in, plans still.
  r := public.map_in_view(-85.5, 33.0, -83.5, 34.5, null, array['places', 'plans', 'shows'], w, w + interval '30 days', false);
  if pg_temp.mui_shape(r) is not null or not (r ->> 'zoom_in')::boolean then raise exception 'FAIL anon zoomed out'; end if;
  insert into mui_lines (line) values (pg_temp.mui_counts('anon_metro_30d_zoom_in', r));
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 3b. Atlanta, signed in
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
do $$
declare
  r  jsonb;
  s  text;
  d  jsonb;
  w  timestamptz := now();
  v_hubs uuid[] := array(select hm.hub_id from public.hub_members hm
                          where hm.user_id = current_setting('test.u')::uuid order by hm.hub_id);
begin
  -- "All my hubs": the joined hubs passed explicitly, as the client does.
  r := public.map_in_view(-84.45, 33.70, -84.30, 33.85, v_hubs, array['places', 'plans', 'shows'], w, w + interval '7 days', false);
  s := pg_temp.mui_shape(r);
  if s is not null then raise exception 'FAIL user Atlanta shape: %', s; end if;
  if jsonb_array_length(r -> 'places') = 0 then raise exception 'FAIL user Atlanta: no places'; end if;
  if exists (select 1 from jsonb_array_elements(r -> 'places') p where jsonb_typeof(p.value -> 4) = 'null') then
    raise exception 'FAIL user Atlanta: a place with no hub_idx';
  end if;
  if exists (select 1 from jsonb_array_elements(r -> 'hubs') with ordinality h(v, o)
              where h.o <= 5 and not ((h.v ->> 0)::uuid = any (v_hubs))) then
    raise exception 'FAIL user Atlanta: selected hubs are not first';
  end if;
  insert into mui_lines (line) values (pg_temp.mui_counts('user_city_5_hubs', r));
  perform set_config('test.user', r::text, true);

  d := public.place_detail((r -> 'places' -> 0 ->> 0)::uuid);
  if jsonb_typeof(d -> 'hubs') <> 'array'
     or not exists (select 1 from jsonb_array_elements(d -> 'hubs') h where (h.value ->> 'joined')::boolean) then
    raise exception 'FAIL user place_detail: no joined hub listed';
  end if;

  -- One generic hub with generic set (one chip selected).
  r := public.map_in_view(-84.45, 33.70, -84.30, 33.85, array[current_setting('test.gen')::uuid],
                          array['places', 'plans', 'shows'], w, w + interval '7 days', true);
  if pg_temp.mui_shape(r) is not null or not (r ->> 'generic')::boolean then
    raise exception 'FAIL user generic: % %', pg_temp.mui_shape(r), r ->> 'generic';
  end if;
  if not exists (select 1 from jsonb_array_elements(r -> 'places') p where ((p.value ->> 5)::integer & 1) <> 0) then
    raise exception 'FAIL user generic: no general spots';
  end if;
  insert into mui_lines (line) values (pg_temp.mui_counts('user_city_one_generic_hub', r));
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 4. Privacy of the Atlanta answers, and nothing was written
-- ---------------------------------------------------------------------------
do $$
declare
  s text;
begin
  s := coalesce(pg_temp.mui_privacy(current_setting('test.anon')::jsonb), pg_temp.mui_privacy(current_setting('test.user')::jsonb));
  if s is not null then raise exception 'FAIL Atlanta privacy: %', s; end if;
  if (select coalesce(sum(demand), 0)::text from public.place_tiles) <> current_setting('test.demand') then
    raise exception 'FAIL a read changed place_tiles demand';
  end if;
end $$;

select line as map_ui_fields from (
  select 0 as n, 'map_ui_fields: all assertions passed' as line
  union all
  select n, line from mui_lines) x
order by n;

rollback;
