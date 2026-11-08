-- ============================================================================
-- Staging check for migration 20270107000100_switch_on_review_fixes.sql
-- (migration 75). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never titles, ids or
-- rows (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.71 or later; migration 74's trigger and its
--     function are gone; collector_ingest_events is callable by the service
--     role only; event_share_card's comment names source_kind.
--   2 Enable on create: through collector_ingest_events with p_enable false
--     (production's call), a listed source whose seed is off is created off
--     and publishes nothing; a listed source whose seed is on is created on
--     and publishes its item; an unlisted source is created off; with
--     p_enable true (staging's call) an unlisted source whose seed is on is
--     created on.
--   3 Share card: a ticketing import's card carries source_kind ticketmaster
--     and its attribution; a member plan's card has no source_kind.
-- The fixture lives in the Southern Ocean (no real data there).
-- ============================================================================
begin;

create temp table sorf_lines (n serial, line text);

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 71] then
    raise exception 'FAIL 1 schema_version is older than 2.71';
  end if;
  if exists (select 1 from pg_trigger where tgname = 'feed_sources_enable_on_create'
              and tgrelid = 'public.feed_sources'::regclass and not tgisinternal) then
    raise exception 'FAIL 1 the migration 74 trigger is still there';
  end if;
  if to_regprocedure('private.feed_sources_enable_on_create()') is not null then
    raise exception 'FAIL 1 the migration 74 trigger function is still there';
  end if;
  if has_function_privilege('anon', 'public.collector_ingest_events(jsonb,jsonb,boolean,boolean,text,jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_ingest_events(jsonb,jsonb,boolean,boolean,text,jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_ingest_events(jsonb,jsonb,boolean,boolean,text,jsonb)', 'execute') then
    raise exception 'FAIL 1 collector_ingest_events grants';
  end if;
  if (select p.proconfig from pg_proc p
       where p.oid = 'public.collector_ingest_events(jsonb,jsonb,boolean,boolean,text,jsonb)'::regprocedure)
     is distinct from array['search_path=""'] then
    raise exception 'FAIL 1 collector_ingest_events search_path';
  end if;
  if coalesce(obj_description('public.event_share_card(uuid)'::regprocedure, 'pg_proc'), '') !~ 'source_kind' then
    raise exception 'FAIL 1 the event_share_card comment does not name source_kind';
  end if;
  if not has_function_privilege('anon', 'public.event_share_card(uuid)', 'execute') then
    raise exception 'FAIL 1 event_share_card is not callable by anon';
  end if;
  insert into sorf_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Enable on create
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_tag    text := substr(md5(random()::text), 1, 6);
  v_region jsonb := jsonb_build_object('lat', -60.5, 'lng', -150.5, 'radius_km', 50,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_src    jsonb;
  v_res    jsonb;
begin
  if exists (select 1 from public.feed_sources
              where slug in ('test-sorf-off', 'ticketmaster-test-sorf', 'test-sorf-unlisted', 'test-sorf-staging')) then
    raise exception 'setup: test sources already exist';
  end if;
  -- The test slug joins the list for this transaction only.
  update public.meta set value = value || ',test-sorf-off' where key = 'collector_enable_on_create';

  -- A listed source whose seed is off: created off, its batch not published.
  v_src := jsonb_build_object('slug', 'test-sorf-off', 'kind', 'socrata',
    'url', 'https://data.example.gov/resource/sorf-0001.json', 'name', 'Test open data off',
    'attribution', 'Contains information licensed under the Test Open Government Licence.',
    'lane', 'api', 'enabled', false, 'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_src, jsonb_build_array(
    jsonb_build_object('external_id', 'sorf-off-1', 'title', 'Zzq Off Fair ' || v_tag, 'starts_at', v_t,
      'url', 'https://data.example.gov/e/sorf1', 'lat', -60.51, 'lng', -150.51)), true, false);
  if coalesce((v_res ->> 'enabled')::boolean, true)
     or coalesce((select enabled from public.feed_sources where slug = 'test-sorf-off'), true) then
    raise exception 'FAIL 2 a listed source whose seed is off was created on';
  end if;
  if exists (select 1 from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
              where fs.slug = 'test-sorf-off') then
    raise exception 'FAIL 2 a listed source whose seed is off published its batch';
  end if;

  -- A listed kind whose seed is on: created on, its item published.
  v_src := jsonb_build_object('slug', 'ticketmaster-test-sorf', 'kind', 'ticketmaster',
    'url', 'https://app.ticketmaster.com/discovery/v2/events.json', 'name', 'Ticketmaster',
    'attribution', 'Event data from the Ticketmaster Discovery API (ticketmaster.com).',
    'homepage_url', 'https://www.ticketmaster.com/', 'lane', 'api', 'enabled', true,
    'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_src, jsonb_build_array(
    jsonb_build_object('external_id', 'sorf-tm-1', 'title', 'Zzq Harbour Show ' || v_tag, 'starts_at', v_t + interval '2 hours',
      'url', 'https://www.ticketmaster.com/event/SORFTEST1', 'lat', -60.52, 'lng', -150.52)), true, false);
  if not coalesce((v_res ->> 'enabled')::boolean, false) or coalesce((v_res ->> 'inserted')::int, 0) <> 1
     or not (select enabled from public.feed_sources where slug = 'ticketmaster-test-sorf') then
    raise exception 'FAIL 2 a listed source whose seed is on was not created on';
  end if;

  -- An unlisted source, production's call: created off.
  v_src := jsonb_build_object('slug', 'test-sorf-unlisted', 'kind', 'jsonld',
    'url', 'https://garden.example.org/sorf/', 'name', 'Test garden',
    'attribution', 'Listed from the Test garden calendar (garden.example.org).',
    'lane', 'page', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, true, false);
  if (select enabled from public.feed_sources where slug = 'test-sorf-unlisted') then
    raise exception 'FAIL 2 an unlisted source was created on by production''s call';
  end if;

  -- Staging's call (p_enable true) still creates an unlisted source on.
  v_src := v_src || jsonb_build_object('slug', 'test-sorf-staging', 'url', 'https://garden.example.org/sorf2/');
  v_res := public.collector_ingest_events(v_src, '[]'::jsonb, true, true);
  if not coalesce((select enabled from public.feed_sources where slug = 'test-sorf-staging'), false) then
    raise exception 'FAIL 2 p_enable no longer creates a source on';
  end if;
  insert into sorf_lines (line) values ('enable on create: ok');
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
   where fs.slug = 'ticketmaster-test-sorf' and ei.external_id = 'sorf-tm-1';
  if v_event is null then raise exception 'FAIL 3 setup: no imported event'; end if;
  v_card := public.event_share_card(v_event);
  if v_card is null or v_card ->> 'source_kind' is distinct from 'ticketmaster'
     or v_card ->> 'source_attribution'
        is distinct from 'Event data from the Ticketmaster Discovery API (ticketmaster.com).'
     or v_card ->> 'external_url' is null then
    raise exception 'FAIL 3 the share card does not carry the source kind, attribution and link';
  end if;
  select e.id into v_plan from public.events e join public.hubs h on h.id = e.hub_id
   where e.kind <> 'imported' and e.status = 'published' and e.visibility = 'public' and e.min_age = 18
     and e.moderation_state is null and h.is_active
   limit 1;
  if v_plan is not null then
    v_card := public.event_share_card(v_plan);
    if v_card is not null and v_card ->> 'source_kind' is not null then
      raise exception 'FAIL 3 a member plan carries a source kind';
    end if;
  end if;
  insert into sorf_lines (line) values ('share card source kind: ok');
end $$;

select line as switch_on_review_fixes from (
  select 0 as n, 'switch_on_review_fixes: all assertions passed' as line
  union all
  select n, line from sorf_lines) x
order by n;

rollback;
