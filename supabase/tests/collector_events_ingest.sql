-- ============================================================================
-- Staging check for migration 20261201000100_collector_events_ingest.sql
-- (D-040 event collector ingest). One transaction, asserts in DO blocks that
-- raise on failure, rolled back at the end. Prints pass/fail only, never
-- titles, ids or points (the repo and its Action logs are public). Run as the
-- staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.33; collector_ingest_events is definer,
--     service_role only; arcgis is a feed_sources kind.
--   2 Sources from the seed shape: rows created with collector, lane, region,
--     timezone, hub tags and default hub; enabled with p_enable; no pg_cron
--     job and no import-feed dispatch for them.
--   3 Hubs: a keyword rule wins, then the seed's hub tag, then Happening
--     nearby. An item without a point sits on the source's region point.
--   4 Cross-source dedupe: the same title and start from a second collector
--     source links to the first event.
--   5 Partial runs never count misses; complete runs cancel an item missing
--     twice, and a linked copy still listed takes over instead.
--   6 Seed off switches the row off; p_enable false keeps enabled as is; a
--     non-collector slug and a bad kind are refused.
--   7 As an adult user: feed_events_v2 and map_in_view show the events.
-- The fixture lives in the Southern Ocean (no real data there), as in
-- map_ui_fields.sql.
-- ============================================================================
begin;

create temp table cei_lines (n serial, line text);
grant insert, select on cei_lines to authenticated;
grant usage on sequence cei_lines_n_seq to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.33' then
    raise exception 'FAIL schema_version is not 2.33';
  end if;
  if not (select p.prosecdef from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'collector_ingest_events') then
    raise exception 'FAIL collector_ingest_events is not security definer';
  end if;
  if has_function_privilege('authenticated', 'public.collector_ingest_events(jsonb, jsonb, boolean, boolean)', 'execute')
     or has_function_privilege('anon', 'public.collector_ingest_events(jsonb, jsonb, boolean, boolean)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_ingest_events(jsonb, jsonb, boolean, boolean)', 'execute') then
    raise exception 'FAIL collector_ingest_events grants';
  end if;
  if has_function_privilege('authenticated', 'public.import_upsert_batch(text, jsonb)', 'execute') then
    raise exception 'FAIL authenticated can run import_upsert_batch';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'import_upsert_batch') <> 1 then
    raise exception 'FAIL more than one import_upsert_batch';
  end if;
  if pg_get_constraintdef((select oid from pg_constraint where conname = 'feed_sources_kind'
                             and conrelid = 'public.feed_sources'::regclass)) !~ 'arcgis' then
    raise exception 'FAIL arcgis is not a feed_sources kind';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2 to 4. Two sources, first runs
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_tag    text := substr(md5(random()::text), 1, 6);
  v_region jsonb := jsonb_build_object('lat', -60.2, 'lng', -150.2, 'radius_km', 300,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_a      jsonb;
  v_b      jsonb;
  v_items  jsonb;
  v_res    jsonb;
  v_src    public.feed_sources%rowtype;
  v_e      public.events%rowtype;
  v_garden uuid := (select id from public.hubs where slug = 'gardening');
  v_pickle uuid := (select id from public.hubs where slug = 'pickleball');
  v_near   uuid := (select id from public.hubs where slug = 'happening-nearby');
begin
  if v_garden is null or v_pickle is null or v_near is null then
    raise exception 'setup: gardening, pickleball or happening-nearby hub missing';
  end if;
  if exists (select 1 from public.feed_sources where slug in ('test-cei-a', 'test-cei-b')) then
    raise exception 'setup: test sources already exist';
  end if;
  perform set_config('test.t', v_t::text, true);
  perform set_config('test.tag', v_tag, true);

  v_a := jsonb_build_object('slug', 'test-cei-a', 'kind', 'jsonld', 'url', 'https://garden.example.org/calendar/',
    'name', 'Test Garden calendar', 'attribution', 'Listed from the Test Garden public calendar (garden.example.org).',
    'homepage_url', 'https://garden.example.org/', 'lane', 'page', 'enabled', true,
    'hubs', jsonb_build_array('no-such-hub', 'gardening'), 'region', v_region);
  v_b := jsonb_build_object('slug', 'test-cei-b', 'kind', 'ics', 'url', 'https://city.example.org/cal.ics',
    'name', 'Test City calendar', 'attribution', 'Listed from the Test City public calendar (city.example.org).',
    'lane', 'feed', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);

  v_items := jsonb_build_array(
    jsonb_build_object('external_id', 'p:orchid', 'title', 'Zzq Orchid Morning ' || v_tag, 'starts_at', v_t,
      'url', 'https://garden.example.org/e/orchid', 'lat', -60.21, 'lng', -150.21, 'location', 'Glasshouse',
      'categories', jsonb_build_array('Outdoors'), 'attribution', 'x', 'lane', 'page'),
    jsonb_build_object('external_id', 'p:pickle', 'title', 'Zzq Pickleball Social ' || v_tag, 'starts_at', v_t,
      'url', 'https://garden.example.org/e/pickle', 'lat', -60.22, 'lng', -150.22),
    jsonb_build_object('external_id', 'p:nopoint', 'title', 'Zzq Lantern Evening ' || v_tag,
      'starts_at', v_t + interval '1 day', 'url', 'https://garden.example.org/e/lantern'),
    jsonb_build_object('external_id', 'p:shared', 'title', 'Zzq Shared Fair ' || v_tag,
      'starts_at', v_t + interval '2 days', 'url', 'https://garden.example.org/e/shared', 'lat', -60.23, 'lng', -150.23)
  );
  perform set_config('test.items_a', v_items::text, true);

  v_res := public.collector_ingest_events(v_a, v_items, true, true);
  if (v_res->>'created')::boolean is not true or (v_res->>'enabled')::boolean is not true
     or (v_res->>'inserted')::int <> 4 or (v_res->>'partial')::boolean then
    raise exception 'FAIL source A first run: %', v_res - 'first_error' - 'source';
  end if;

  select * into v_src from public.feed_sources where slug = 'test-cei-a';
  if not v_src.collector or not v_src.enabled or v_src.lane <> 'page' or v_src.kind <> 'jsonld'
     or v_src.region_timezone <> 'Pacific/Auckland' or v_src.region_radius_km <> 200
     or v_src.hub_tags <> array['no-such-hub', 'gardening'] or v_src.default_hub_id <> v_garden
     or v_src.attribution not like 'Listed from the Test Garden%' or v_src.collector_seen_at is null
     or v_src.region_point is null then
    raise exception 'FAIL source A row';
  end if;
  if exists (select 1 from cron.job where jobname in ('import-feed-test-cei-a', 'import-feed-test-cei-b')) then
    raise exception 'FAIL a collector source got an import-feed pg_cron job';
  end if;
  if public.import_dispatch('test-cei-a') is not null then
    raise exception 'FAIL a collector source was dispatched to import-feed';
  end if;

  -- Hubs: rule, then the seed's first usable hub tag; timezone from the region.
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src.id and ei.external_id = 'p:pickle';
  if v_e.hub_id <> v_pickle then raise exception 'FAIL a keyword rule did not win'; end if;
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src.id and ei.external_id = 'p:orchid';
  if v_e.hub_id <> v_garden or v_e.timezone <> 'Pacific/Auckland' or v_e.kind <> 'imported'
     or v_e.source_name <> 'Test Garden calendar' or v_e.listing_kind <> 'plan' then
    raise exception 'FAIL the seed hub tag, timezone or source name';
  end if;
  -- No point: the source's region point, labelled area_centroid.
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src.id and ei.external_id = 'p:nopoint';
  if extensions.ST_Distance(v_e.approx_point, v_src.region_point) > 50
     or (select point_source from public.event_imports where source_id = v_src.id and external_id = 'p:nopoint') <> 'area_centroid' then
    raise exception 'FAIL an item without a point is not on the region point';
  end if;

  -- Source B: one item shared with A (same title and start), one of its own.
  v_items := jsonb_build_array(
    jsonb_build_object('external_id', 'uid-shared', 'title', 'Zzq Shared Fair ' || v_tag,
      'starts_at', v_t + interval '2 days', 'url', 'https://city.example.org/e/shared'),
    jsonb_build_object('external_id', 'uid-own', 'title', 'Zzq Harbour Gathering ' || v_tag,
      'starts_at', v_t + interval '3 days', 'url', 'https://city.example.org/e/own'));
  perform set_config('test.items_b', v_items::text, true);
  v_res := public.collector_ingest_events(v_b, v_items, true, true);
  if (v_res->>'inserted')::int <> 1 or (v_res->>'linked_duplicates')::int <> 1 then
    raise exception 'FAIL source B cross-source dedupe: %', v_res - 'first_error' - 'source';
  end if;
  if (select e.hub_id from public.events e join public.event_imports ei on ei.event_id = e.id
       join public.feed_sources fs on fs.id = ei.source_id
      where fs.slug = 'test-cei-b' and ei.external_id = 'uid-own') <> v_near then
    raise exception 'FAIL no rule and no hub tag did not fall back to Happening nearby';
  end if;
  insert into cei_lines (line) values ('sources, hubs, region point and dedupe: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Partial and complete runs
-- ---------------------------------------------------------------------------
do $$
declare
  v_a     jsonb := current_setting('test.a')::jsonb;
  v_b     jsonb := current_setting('test.b')::jsonb;
  v_items jsonb := current_setting('test.items_a')::jsonb;
  v_keep  jsonb;
  v_res   jsonb;
  i       integer;
  v_lantern uuid;
  v_shared  uuid;
begin
  select ei.event_id into v_lantern from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cei-a' and ei.external_id = 'p:nopoint';
  select ei.event_id into v_shared from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cei-a' and ei.external_id = 'p:shared';
  -- A lists only orchid and pickle from now on.
  select jsonb_agg(x) into v_keep from jsonb_array_elements(v_items) x
   where x->>'external_id' in ('p:orchid', 'p:pickle');

  for i in 1..3 loop
    v_res := public.collector_ingest_events(v_a, v_keep, false, true);
    if not (v_res->>'partial')::boolean or (v_res->>'missed')::int <> 0 or (v_res->>'cancelled')::int <> 0 then
      raise exception 'FAIL partial run % counted misses: %', i, v_res - 'first_error' - 'source';
    end if;
  end loop;
  if (select missed_runs from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
       where fs.slug = 'test-cei-a' and ei.external_id = 'p:nopoint') <> 0
     or (select status from public.events where id = v_lantern) <> 'published' then
    raise exception 'FAIL partial runs touched a missing item';
  end if;
  if current_setting('app.import_partial_run', true) = 'on' then
    raise exception 'FAIL app.import_partial_run left on';
  end if;

  v_res := public.collector_ingest_events(v_a, v_keep, true, true);
  if (v_res->>'missed')::int <> 2 or (v_res->>'cancelled')::int <> 0 then
    raise exception 'FAIL complete run 1: %', v_res - 'first_error' - 'source';
  end if;
  -- B still lists the shared item.
  v_res := public.collector_ingest_events(v_b, current_setting('test.items_b')::jsonb, true, true);
  v_res := public.collector_ingest_events(v_a, v_keep, true, true);
  if (v_res->>'cancelled')::int <> 1 or (v_res->>'handed_off')::int <> 1 then
    raise exception 'FAIL complete run 2 (cancel and hand-off): %', v_res - 'first_error' - 'source';
  end if;
  if (select status from public.events where id = v_lantern) <> 'cancelled' then
    raise exception 'FAIL an item missing from two complete runs is not cancelled';
  end if;
  if (select status from public.events where id = v_shared) <> 'published'
     or (select source_name from public.events where id = v_shared) <> 'Test City calendar' then
    raise exception 'FAIL the linked copy did not take over the shared event';
  end if;
  insert into cei_lines (line) values ('partial runs, missing twice and hand-off: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Enabled flags and refusals
-- ---------------------------------------------------------------------------
do $$
declare
  v_a   jsonb := current_setting('test.a')::jsonb;
  v_b   jsonb := current_setting('test.b')::jsonb;
  v_res jsonb;
begin
  v_res := public.collector_ingest_events(v_b, '[]'::jsonb, true, false);
  if not (select enabled from public.feed_sources where slug = 'test-cei-b') then
    raise exception 'FAIL p_enable false switched an enabled row off';
  end if;
  v_res := public.collector_ingest_events(v_a || jsonb_build_object('enabled', false), current_setting('test.items_a')::jsonb, true, true);
  if (v_res->>'enabled')::boolean or v_res ? 'inserted'
     or (select enabled from public.feed_sources where slug = 'test-cei-a') then
    raise exception 'FAIL a seed that is off did not switch its row off: %', v_res;
  end if;
  v_res := public.collector_ingest_events(v_a, '[]'::jsonb, true, false);
  if (select enabled from public.feed_sources where slug = 'test-cei-a') then
    raise exception 'FAIL p_enable false switched a row on';
  end if;
  v_res := public.collector_ingest_events(
    v_a || jsonb_build_object('slug', 'test-cei-new'), '[]'::jsonb, true, false);
  if (select enabled from public.feed_sources where slug = 'test-cei-new') then
    raise exception 'FAIL a new row is on without p_enable';
  end if;

  begin
    perform public.collector_ingest_events(v_a || jsonb_build_object('slug', 'gsu-localist'), '[]'::jsonb, true, true);
    if exists (select 1 from public.feed_sources where slug = 'gsu-localist') then
      raise exception 'FAIL a non-collector slug was accepted';
    end if;
  exception when check_violation then
    if sqlerrm <> 'source_not_collector' then raise; end if;
  end;
  begin
    perform public.collector_ingest_events(v_a || jsonb_build_object('kind', 'page'), '[]'::jsonb, true, true);
    raise exception 'FAIL kind page accepted';
  exception when check_violation then
    if sqlerrm <> 'source_invalid' then raise; end if;
  end;
  begin
    perform public.collector_ingest_events(v_a || jsonb_build_object('region', jsonb_build_object('timezone', 'Mars/Base')), '[]'::jsonb, true, true);
    raise exception 'FAIL a bad timezone accepted';
  exception when check_violation then
    if sqlerrm <> 'source_invalid' then raise; end if;
  end;
  insert into cei_lines (line) values ('enabled flags and refusals: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 7. As an adult user: the feed and the map show the events
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'cei-' || substr(v_u::text, 1, 8) || '@example.com', now(), now());
  update public.profile_private set birth_date = date '1990-05-05' where user_id = v_u;
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id = v_u;
  perform set_config('test.u', v_u::text, true);
end $$;

select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.u'), 'role', 'authenticated')::text, true);
set local role authenticated;

do $$
declare
  v_n integer;
  r   jsonb;
begin
  select count(*) into v_n
    from public.feed_events_v2(now(), now() + interval '7 days', -60.2, -150.2, 100) f
   where f.kind = 'imported' and f.title like 'Zzq %' || current_setting('test.tag');
  if v_n < 3 then
    raise exception 'FAIL feed_events_v2 shows % of the test events', v_n;
  end if;
  r := public.map_in_view(-151.0, -61.0, -149.0, -59.0, null, array['plans']);
  select count(*) into v_n from jsonb_array_elements(r -> 'plans') p
   where ((p.value ->> 5)::integer & 1) <> 0 and p.value ->> 6 like 'Zzq %' || current_setting('test.tag');
  if v_n < 3 then
    raise exception 'FAIL map_in_view shows % of the test events', v_n;
  end if;
  if exists (select 1 from public.feed_sources where collector) then
    raise exception 'FAIL a non-moderator can read feed_sources';
  end if;
  insert into cei_lines (line) values ('feed_events_v2 and map_in_view as an adult user: ok');
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

select line as collector_events_ingest from (
  select 0 as n, 'collector_events_ingest: all assertions passed' as line
  union all
  select n, line from cei_lines) x
order by n;

rollback;
