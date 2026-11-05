-- ============================================================================
-- Staging check for migration 20261227000100_collector_health_geocode.sql
-- (migration 63), venue geocoding (docs/design/collector/COLLECTOR_COMPLETION.md
-- 2.5). One transaction: a test source on an invented host (aptest-<tag>-*.org;
-- nothing is fetched) in the Southern Ocean; asserts in DO blocks that raise
-- on failure, then rolls everything back. Prints pass/fail lines only.
--
--   1 Static: RLS, grants, no DELETE without WHERE (migration 64), the key equals the collector's TypeScript key on
--     the shared fixtures (packages/collector/test/geocode.test.ts).
--   2 Queue: online, short, cached and already-placed items are left out.
--   3 Record: a point outside the region is stored as a miss; a hit moves the
--     event off the centroid; bad input is refused.
--   4 A later content change through collector_ingest_events keeps the point.
--   5 A miss expires (and is queued again).
-- ============================================================================
begin;

create temp table vg_lines (n serial, line text);
grant insert, select on vg_lines to anon, authenticated, service_role;
grant usage on sequence vg_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.src(p_tag text) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-geo', 'kind', 'ics', 'url', 'https://aptest-' || p_tag || '-geo.org/cal.ics',
    'name', 'Geocode test source', 'attribution', 'Listed from a test calendar.', 'lane', 'feed', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.item(p_tag text, p_id text, p_loc text, p_title text default null,
                             p_lat double precision default null, p_lng double precision default null) returns jsonb language sql as $$
  select jsonb_strip_nulls(jsonb_build_object(
    'external_id', p_id, 'title', coalesce(p_title, 'Geocode test ' || p_tag || ' ' || p_id),
    'starts_at', to_char(date_trunc('hour', now()) + interval '4 days', 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://aptest-' || p_tag || '-geo.org/e/' || p_id, 'location', p_loc, 'lat', p_lat, 'lng', p_lng));
$$;

create function pg_temp.pt(p_lat double precision, p_lng double precision) returns extensions.geography language sql as $$
  select extensions.ST_SetSRID(extensions.ST_MakePoint(p_lng, p_lat), 4326)::extensions.geography;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static and the shared key fixtures
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 59] then
    raise exception 'FAIL 1 schema_version is older than 2.59';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.venue_geocodes'::regclass)
     or has_table_privilege('authenticated', 'public.venue_geocodes', 'select')
     or has_table_privilege('anon', 'public.venue_geocodes', 'select')
     or has_function_privilege('authenticated', 'public.collector_geocode_queue(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_geocode_record(jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_geocode_record(jsonb)', 'execute')
     or exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'venue_geocodes'
                   and column_name ~ 'user') then
    raise exception 'FAIL 1 RLS or grants';
  end if;
  -- The same fixtures as packages/collector/test/geocode.test.ts.
  if public.import_location_key('The Earl, 488 Flat Shoals Ave SE', pg_temp.pt(33.749, -84.388))
       <> '689ef8895f9f632da96d72c0942c391ee45e8320b252cd8ab72ec5068bfa4b59'
     or public.import_location_key('  Café Müller -- Room #2 ', pg_temp.pt(51.05, 13.74))
       <> 'b5be71a6868b2a6ee4db177197c3c2226f898792565331826380097a14dcf760'
     or public.import_location_key('CITY HALL (Room 101)', pg_temp.pt(-33.86, 151.21))
       <> '570a8993b144b57a10c1c107906d41501e2061cd159d483f59a6dcc47fbaeb9b'
     or public.import_location_key('Plaza Mayor', pg_temp.pt(-0.04, -78.45))
       <> '267ccd55fc532a2038fcba917ebae77d5fc95fae52ac31144f1b50d5c6227114'
     or public.import_location_key('', pg_temp.pt(1, 1)) is not null then
    raise exception 'FAIL 1 import_location_key differs from the collector''s';
  end if;
  -- Migration 64: Supabase's safeupdate (loaded for the API roles) refuses a DELETE without WHERE.
  if pg_get_functiondef('public.collector_geocode_record(jsonb)'::regprocedure) ~* 'delete\s+from\s+[a-z_.]+\s*;' then
    raise exception 'FAIL 1 collector_geocode_record has a DELETE without WHERE (safeupdate refuses it)';
  end if;
  if (select value from public.meta where key = 'collector_geocode_nominatim') not in ('on', 'off') then
    raise exception 'FAIL 1 meta.collector_geocode_nominatim';
  end if;
  insert into vg_lines (line) values ('1 static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup: one source with a geocodable, an online, a short, a placed and a cached item
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_region extensions.geography := pg_temp.pt(-63.0, -125.0);
begin
  perform set_config('t.tag', v_tag, true);
  insert into public.venue_geocodes (key, status, point, provider, expires_at)
  values (public.import_location_key('Cached Hall ' || v_tag, v_region), 'miss', null, 'nominatim', now() + interval '10 days');
  perform public.collector_ingest_events(pg_temp.src(v_tag), jsonb_build_array(
    pg_temp.item(v_tag, 'a', 'Test Venue ' || v_tag || ', 1 Main Street'),
    pg_temp.item(v_tag, 'b', 'Online'),
    pg_temp.item(v_tag, 'c', 'abc'),
    pg_temp.item(v_tag, 'd', 'Placed Venue ' || v_tag, null, -63.01, -125.01),
    pg_temp.item(v_tag, 'e', 'Cached Hall ' || v_tag),
    pg_temp.item(v_tag, 'f', 'Far Venue ' || v_tag)), true, true, 'vg-' || v_tag || '-1');
  if (select count(*) from public.event_imports ei join public.feed_sources f on f.id = ei.source_id
       where f.slug = 'aptest-' || v_tag || '-geo' and ei.point_source = 'area_centroid') <> 5 then
    raise exception 'FAIL setup: expected 5 items on the centroid';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Queue
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
  v_region extensions.geography := pg_temp.pt(-63.0, -125.0);
  q jsonb := public.collector_geocode_queue(500);
  ka text := public.import_location_key('Test Venue ' || v_tag || ', 1 Main Street', v_region);
begin
  if not exists (select 1 from jsonb_array_elements(q) x
                  where x.value ->> 'key' = ka and x.value ->> 'location' = 'Test Venue ' || v_tag || ', 1 Main Street'
                    and (x.value #>> '{region,radius_km}')::int = 25) then
    raise exception 'FAIL 2 the geocodable item is not queued';
  end if;
  if exists (select 1 from jsonb_array_elements(q) x
              where x.value ->> 'key' in (public.import_location_key('Online', v_region),
                                          public.import_location_key('abc', v_region),
                                          public.import_location_key('Placed Venue ' || v_tag, v_region),
                                          public.import_location_key('Cached Hall ' || v_tag, v_region))) then
    raise exception 'FAIL 2 an online, short, placed or cached item is queued';
  end if;
  insert into vg_lines (line) values ('2 queue: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Record
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_region extensions.geography := pg_temp.pt(-63.0, -125.0);
  ka text := public.import_location_key('Test Venue ' || v_tag || ', 1 Main Street', v_region);
  kf text := public.import_location_key('Far Venue ' || v_tag, v_region);
  v jsonb;
  v_ev uuid;
begin
  begin
    perform public.collector_geocode_record(jsonb_build_array(jsonb_build_object('key', ka, 'status', 'ok', 'provider', 'nominatim')));
    raise exception 'FAIL 3 a hit without a point accepted';
  exception when others then
    if sqlerrm <> 'results_invalid' then raise exception 'FAIL 3 results_invalid: %', sqlerrm; end if;
  end;
  v := public.collector_geocode_record(jsonb_build_array(
    jsonb_build_object('key', ka, 'status', 'ok', 'lat', -63.02, 'lng', -125.03, 'provider', 'nominatim',
                       'place_ref', 'osm:n123', 'confidence', 0.8),
    jsonb_build_object('key', kf, 'status', 'ok', 'lat', -60.0, 'lng', -125.0, 'provider', 'photon')));
  if (v ->> 'outside_region')::int <> 1 or (v ->> 'ok')::int <> 1 or (v ->> 'events')::int <> 1 then
    raise exception 'FAIL 3 counts %', v;
  end if;
  if (select status from public.venue_geocodes where key = kf) <> 'miss' then
    raise exception 'FAIL 3 a point outside the region was stored as a hit';
  end if;
  select ei.event_id into v_ev from public.event_imports ei join public.feed_sources f on f.id = ei.source_id
   where f.slug = 'aptest-' || v_tag || '-geo' and ei.external_id = 'a';
  if (select point_source from public.event_imports ei join public.feed_sources f on f.id = ei.source_id
       where f.slug = 'aptest-' || v_tag || '-geo' and ei.external_id = 'a') <> 'geocoded'
     or extensions.ST_Distance((select approx_point from public.events where id = v_ev), pg_temp.pt(-63.02, -125.03)) > 1 then
    raise exception 'FAIL 3 the event did not move off the centroid';
  end if;
  if (select expires_at from public.venue_geocodes where key = ka) < now() + interval '170 days'
     or (select expires_at from public.venue_geocodes where key = kf) > now() + interval '100 days' then
    raise exception 'FAIL 3 expiry';
  end if;
  perform set_config('t.ev', v_ev::text, true);
  insert into vg_lines (line) values ('3 record: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. A content change keeps the geocoded point
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_ev uuid := current_setting('t.ev')::uuid;
begin
  perform public.collector_ingest_events(pg_temp.src(v_tag), jsonb_build_array(
    pg_temp.item(v_tag, 'a', 'Test Venue ' || v_tag || ', 1 Main Street', 'Geocode test renamed ' || v_tag)),
    true, true, 'vg-' || v_tag || '-2');
  if (select title from public.events where id = v_ev) <> 'Geocode test renamed ' || v_tag then
    raise exception 'FAIL 4 the content change was not applied';
  end if;
  if extensions.ST_Distance((select approx_point from public.events where id = v_ev), pg_temp.pt(-63.02, -125.03)) > 1
     or (select ei.point_source from public.event_imports ei where ei.event_id = v_ev and ei.is_primary) <> 'geocoded' then
    raise exception 'FAIL 4 the content change put the event back on the centroid';
  end if;
  insert into vg_lines (line) values ('4 content change keeps the point: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. A miss expires
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_region extensions.geography := pg_temp.pt(-63.0, -125.0);
  kc text := public.import_location_key('Cached Hall ' || v_tag, v_region);
begin
  update public.venue_geocodes set expires_at = now() - interval '1 minute' where key = kc;
  if not exists (select 1 from jsonb_array_elements(public.collector_geocode_queue(500)) x where x.value ->> 'key' = kc) then
    raise exception 'FAIL 5 an expired miss is not queued again';
  end if;
  insert into vg_lines (line) values ('5 miss expiry: ok');
end $$;

select line as venue_geocoding from (
  select 0 as n, 'venue_geocoding: all assertions passed' as line
  union all
  select n, line from vg_lines) x
order by n;

rollback;
