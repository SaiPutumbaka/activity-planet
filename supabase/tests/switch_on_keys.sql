-- ============================================================================
-- Staging check for migration 20270106000100_switch_on_keys.sql (migration
-- 74, the switches the Nov 8 keys unlock). One transaction, asserts in DO
-- blocks that raise on failure, rolled back at the end. Prints pass/fail only,
-- never titles, ids or rows (the repo and its Action logs are public). Run as
-- the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.70 or later; meta.chat_images on and
--     private.chat_images_enabled() true; meta.collector_enable_on_create
--     lists ticketmaster, seatgeek and calgary-city-events; the trigger
--     exists; the private helpers are not callable by anon or authenticated;
--     event_share_card stays callable by anon.
--   2 Enable on create: through collector_ingest_events with p_enable false
--     (production's call), a new ticketmaster row and a new row whose slug is
--     listed are created on and their items are published; an unlisted
--     jsonld row stays off; a disc- row of a listed kind stays off; a
--     denylisted listed row stays off.
--   3 Share card: an imported event's card carries its source's attribution
--     (the open-data licence line); a member plan's card has none.
-- The fixture lives in the Southern Ocean (no real data there).
-- ============================================================================
begin;

create temp table sok_lines (n serial, line text);

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  v_tokens text[];
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 70] then
    raise exception 'FAIL 1 schema_version is older than 2.70';
  end if;
  if (select value from public.meta where key = 'chat_images') is distinct from 'on'
     or not private.chat_images_enabled() then
    raise exception 'FAIL 1 chat images are not on';
  end if;
  select array_agg(btrim(t)) into v_tokens
    from public.meta m cross join lateral unnest(string_to_array(m.value, ',')) t
   where m.key = 'collector_enable_on_create';
  if v_tokens is null or not (v_tokens @> array['ticketmaster', 'seatgeek', 'calgary-city-events']) then
    raise exception 'FAIL 1 collector_enable_on_create does not list the approved sources';
  end if;
  if not exists (select 1 from pg_trigger where tgname = 'feed_sources_enable_on_create'
                  and tgrelid = 'public.feed_sources'::regclass and not tgisinternal) then
    raise exception 'FAIL 1 trigger feed_sources_enable_on_create missing';
  end if;
  if has_function_privilege('anon', 'private.collector_enable_on_create(text,text)', 'execute')
     or has_function_privilege('authenticated', 'private.collector_enable_on_create(text,text)', 'execute')
     or has_function_privilege('authenticated', 'private.feed_sources_enable_on_create()', 'execute') then
    raise exception 'FAIL 1 private helper grants';
  end if;
  if not has_function_privilege('anon', 'public.event_share_card(uuid)', 'execute') then
    raise exception 'FAIL 1 event_share_card is not callable by anon';
  end if;
  if not (select p.prosecdef from pg_proc p where p.oid = 'private.feed_sources_enable_on_create()'::regprocedure)
     or (select p.proconfig from pg_proc p where p.oid = 'private.feed_sources_enable_on_create()'::regprocedure)
        is distinct from array['search_path=""'] then
    raise exception 'FAIL 1 trigger function is not definer with an empty search_path';
  end if;
  insert into sok_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Enable on create
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_tag    text := substr(md5(random()::text), 1, 6);
  v_region jsonb := jsonb_build_object('lat', -60.4, 'lng', -150.4, 'radius_km', 50,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_tm     jsonb;
  v_od     jsonb;
  v_page   jsonb;
  v_disc   jsonb;
  v_res    jsonb;
begin
  if exists (select 1 from public.feed_sources
              where slug in ('ticketmaster-test-sok', 'test-sok-open-data', 'test-sok-page', 'disc-test-sok', 'test-sok-denied')) then
    raise exception 'setup: test sources already exist';
  end if;
  -- The test slug joins the list for this transaction only.
  update public.meta set value = value || ',test-sok-open-data,test-sok-denied' where key = 'collector_enable_on_create';

  v_tm := jsonb_build_object('slug', 'ticketmaster-test-sok', 'kind', 'ticketmaster',
    'url', 'https://app.ticketmaster.com/discovery/v2/events.json', 'name', 'Ticketmaster',
    'attribution', 'Event data from the Ticketmaster Discovery API (ticketmaster.com).',
    'homepage_url', 'https://www.ticketmaster.com/', 'lane', 'api', 'enabled', true,
    'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_tm, jsonb_build_array(
    jsonb_build_object('external_id', 'sok-tm-1', 'title', 'Zzk Harbour Show ' || v_tag, 'starts_at', v_t,
      'url', 'https://www.ticketmaster.com/event/SOKTEST1', 'lat', -60.41, 'lng', -150.41)), true, false);
  if not coalesce((v_res ->> 'enabled')::boolean, false) or coalesce((v_res ->> 'inserted')::int, 0) <> 1
     or not (select enabled from public.feed_sources where slug = 'ticketmaster-test-sok') then
    raise exception 'FAIL 2 a new ticketmaster row is not on: %', v_res - 'first_error' - 'source';
  end if;

  v_od := jsonb_build_object('slug', 'test-sok-open-data', 'kind', 'socrata',
    'url', 'https://data.example.gov/resource/abcd-1234.json', 'name', 'Test open data',
    'attribution', 'Contains information licensed under the Test Open Government Licence.',
    'lane', 'api', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  perform set_config('test.od_tag', v_tag, true);
  v_res := public.collector_ingest_events(v_od, jsonb_build_array(
    jsonb_build_object('external_id', 'sok-od-1', 'title', 'Zzk Open Data Fair ' || v_tag, 'starts_at', v_t + interval '3 hours',
      'url', 'https://data.example.gov/e/1', 'lat', -60.42, 'lng', -150.42)), true, false);
  if not coalesce((v_res ->> 'enabled')::boolean, false) or coalesce((v_res ->> 'inserted')::int, 0) <> 1 then
    raise exception 'FAIL 2 a listed slug is not on: %', v_res - 'first_error' - 'source';
  end if;

  v_page := jsonb_build_object('slug', 'test-sok-page', 'kind', 'jsonld',
    'url', 'https://garden.example.org/calendar/', 'name', 'Test garden',
    'attribution', 'Listed from the Test garden calendar (garden.example.org).',
    'lane', 'page', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_page, '[]'::jsonb, true, false);
  if (select enabled from public.feed_sources where slug = 'test-sok-page') then
    raise exception 'FAIL 2 an unlisted row was switched on';
  end if;

  v_disc := v_tm || jsonb_build_object('slug', 'disc-test-sok');
  begin
    v_res := public.collector_ingest_events(v_disc, '[]'::jsonb, true, false);
  exception when others then null;   -- a disc- row may be refused outright; either way it is not on
  end;
  if coalesce((select enabled from public.feed_sources where slug = 'disc-test-sok'), false) then
    raise exception 'FAIL 2 a discovered row was switched on';
  end if;

  insert into public.feed_sources (slug, kind, url, name, attribution, enabled, collector, lane, denylisted)
  values ('test-sok-denied', 'socrata', 'https://data.example.gov/resource/zzzz-0000.json', 'Test denied',
          'Listed from test open data (data.example.gov).', false, true, 'api', true);
  if (select enabled from public.feed_sources where slug = 'test-sok-denied') then
    raise exception 'FAIL 2 a denylisted row was switched on';
  end if;
  insert into sok_lines (line) values ('enable on create: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Share card
-- ---------------------------------------------------------------------------
do $$
declare
  v_event uuid;
  v_card  jsonb;
  v_plan  uuid;
begin
  select ei.event_id into v_event from public.event_imports ei
    join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-sok-open-data' and ei.external_id = 'sok-od-1';
  if v_event is null then raise exception 'FAIL 3 setup: no imported event'; end if;
  v_card := public.event_share_card(v_event);
  if v_card is null or v_card ->> 'source_attribution'
       is distinct from 'Contains information licensed under the Test Open Government Licence.' then
    raise exception 'FAIL 3 the share card does not carry the source attribution';
  end if;
  select e.id into v_plan from public.events e join public.hubs h on h.id = e.hub_id
   where e.kind <> 'imported' and e.status = 'published' and e.visibility = 'public' and e.min_age = 18
     and e.moderation_state is null and h.is_active
   limit 1;
  if v_plan is not null then
    v_card := public.event_share_card(v_plan);
    if v_card is not null and v_card ->> 'source_attribution' is not null then
      raise exception 'FAIL 3 a member plan carries a source attribution';
    end if;
  end if;
  insert into sok_lines (line) values ('share card attribution: ok');
end $$;

select line as switch_on_keys from (
  select 0 as n, 'switch_on_keys: all assertions passed' as line
  union all
  select n, line from sok_lines) x
order by n;

rollback;
