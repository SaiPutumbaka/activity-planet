-- ============================================================================
-- Staging check for migration 20270108000100_atlanta_calendars_production.sql
-- (migration 76). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never titles, ids or
-- rows (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.72 or later; meta.collector_enable_on_create
--     keeps migration 74's tokens, lists the eight approved Atlanta seeds once
--     each, and does not list ArtsATL or the BeltLine; the helper says the
--     same.
--   2 Rows: on staging each approved Atlanta row exists and is on.
--   3 Production's call (p_enable false): with the real row moved aside, an
--     approved Atlanta seed is created on; ArtsATL and the BeltLine are
--     created off; an existing approved row that is on stays on.
-- ============================================================================
begin;

create temp table atlcal_lines (n serial, line text);

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  v_tokens text[];
  v_slug   text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 72] then
    raise exception 'FAIL 1 schema_version is older than 2.72';
  end if;
  select array_agg(btrim(t)) into v_tokens
    from public.meta m cross join lateral unnest(string_to_array(m.value, ',')) t
   where m.key = 'collector_enable_on_create';
  if v_tokens is null or not (v_tokens @> array['ticketmaster', 'seatgeek', 'calgary-city-events']) then
    raise exception 'FAIL 1 migration 74''s tokens are gone';
  end if;
  foreach v_slug in array array['atl-kennesaw-state', 'atl-botanical-garden', 'atl-marietta-civicplus', 'atl-piedmont-park',
                                'atl-history-center', 'atl-contra-dance', 'atl-park-pride', 'atl-alliance-offstage'] loop
    if (select count(*) from unnest(v_tokens) t where t = v_slug) <> 1 then
      raise exception 'FAIL 1 an approved Atlanta seed is not listed exactly once';
    end if;
    if not private.collector_enable_on_create('jsonld', v_slug) then
      raise exception 'FAIL 1 collector_enable_on_create misses an approved Atlanta seed';
    end if;
  end loop;
  if v_tokens && array['atl-artsatl-calendar', 'atl-beltline']
     or private.collector_enable_on_create('jsonld', 'atl-artsatl-calendar')
     or private.collector_enable_on_create('jsonld', 'atl-beltline') then
    raise exception 'FAIL 1 ArtsATL or the BeltLine is approved';
  end if;
  if private.collector_enable_on_create('jsonld', 'atl-high-museum') then
    raise exception 'FAIL 1 an Atlanta seed that was not approved is listed';
  end if;
  insert into atlcal_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Staging rows
-- ---------------------------------------------------------------------------
do $$
begin
  if (select count(*) from public.feed_sources
       where slug in ('atl-kennesaw-state', 'atl-botanical-garden', 'atl-marietta-civicplus', 'atl-piedmont-park',
                      'atl-history-center', 'atl-contra-dance', 'atl-park-pride', 'atl-alliance-offstage')
         and collector and enabled) <> 8 then
    raise exception 'FAIL 2 an approved Atlanta row is missing or off on staging';
  end if;
  insert into atlcal_lines (line) values ('rows: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Production's call
-- ---------------------------------------------------------------------------
do $$
declare
  v_region jsonb := jsonb_build_object('lat', 33.749, 'lng', -84.388, 'radius_km', 60,
                                       'label', 'Atlanta metro', 'timezone', 'America/New_York');
  v_src    jsonb;
  v_res    jsonb;
begin
  if exists (select 1 from public.feed_sources
              where slug in ('test-atlcal-contra', 'test-atlcal-artsatl', 'test-atlcal-beltline')) then
    raise exception 'setup: test slugs already exist';
  end if;
  -- The real rows step aside for this transaction, so the seeds are created as on a fresh project.
  update public.feed_sources set slug = 'test-atlcal-contra' where slug = 'atl-contra-dance';
  update public.feed_sources set slug = 'test-atlcal-artsatl' where slug = 'atl-artsatl-calendar';
  update public.feed_sources set slug = 'test-atlcal-beltline' where slug = 'atl-beltline';

  v_src := jsonb_build_object('slug', 'atl-contra-dance', 'kind', 'jsonld',
    'url', 'https://www.contradance.org/events/', 'name', 'Atlanta Contra Dance Society events',
    'attribution', 'Listed from the Atlanta Contra Dance Society public calendar (contradance.org).',
    'lane', 'page', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, false, false);
  if not coalesce((v_res ->> 'created')::boolean, false)
     or not coalesce((select enabled from public.feed_sources where slug = 'atl-contra-dance'), false) then
    raise exception 'FAIL 3 an approved Atlanta seed was not created on by production''s call';
  end if;

  v_src := v_src || jsonb_build_object('slug', 'atl-artsatl-calendar', 'url', 'https://www.artsatl.org/calendar/',
    'name', 'ArtsATL arts calendar', 'attribution', 'Listed from the ArtsATL public arts calendar (artsatl.org).');
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, false, false);
  if coalesce((select enabled from public.feed_sources where slug = 'atl-artsatl-calendar'), true) then
    raise exception 'FAIL 3 ArtsATL was created on by production''s call';
  end if;

  v_src := v_src || jsonb_build_object('slug', 'atl-beltline', 'url', 'https://beltline.org/events/list/',
    'name', 'Atlanta BeltLine events', 'attribution', 'Listed from the Atlanta BeltLine public events calendar (beltline.org).',
    'enabled', false);
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, false, false);
  if coalesce((select enabled from public.feed_sources where slug = 'atl-beltline'), true) then
    raise exception 'FAIL 3 the BeltLine was created on by production''s call';
  end if;

  -- An existing approved row that is on stays on through production's call.
  v_src := jsonb_build_object('slug', 'atl-park-pride', 'kind', 'jsonld',
    'url', 'https://parkpride.org/events/', 'name', 'Park Pride events',
    'attribution', 'Listed from the Park Pride public events calendar (parkpride.org).',
    'lane', 'page', 'enabled', true, 'hubs', jsonb_build_array('volunteering'), 'region', v_region);
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, false, false);
  if coalesce((v_res ->> 'created')::boolean, true)
     or not coalesce((select enabled from public.feed_sources where slug = 'atl-park-pride'), false) then
    raise exception 'FAIL 3 an existing approved row did not stay on';
  end if;
  insert into atlcal_lines (line) values ('production call: ok');
end $$;

select line as atlanta_calendars_production from (
  select 0 as n, 'atlanta_calendars_production: all assertions passed' as line
  union all
  select n, line from atlcal_lines) x
order by n;

rollback;
