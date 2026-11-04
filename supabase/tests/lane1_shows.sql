-- ============================================================================
-- Staging check for migration 20261212000100_lane1_shows.sql (migration 48,
-- D-042 slice 10). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never titles, ids,
-- points or real budget rows (the repo and its Action logs are public). Run
-- as the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.44; the three functions are definer and
--     service_role only; the api-shows-sweep pg_cron job exists.
--   2 Budget: take grants within the daily cap and records it; a spent day
--     grants 0; return gives back, never below 0; bad names, counts and days
--     are refused.
--   3 Ticketmaster and SeatGeek sources through collector_ingest_events:
--     rows are listing_kind show, their events are shows, and the shows feed
--     (feed_events_v2 p_listing_kind show) lists them for an adult user while
--     the plans feed does not.
--   4 Sweep: a ticketing copy unseen for 3 days is cancelled as no longer
--     listed, a fresh one stays, an event with a fresh copy from another
--     source stays, and the next listing brings the cancelled one back; raw
--     items of ended ticketing rows are cleared.
--   5 RLS: a member who is not a moderator reads no collector_budget row.
-- The fixture lives in the Southern Ocean (no real data there).
-- ============================================================================
begin;

create temp table l1_lines (n serial, line text);
grant insert, select on l1_lines to authenticated;
grant usage on sequence l1_lines_n_seq to authenticated;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select value from public.meta where key = 'schema_version') <> '2.44' then
    raise exception 'FAIL schema_version is not 2.44';
  end if;
  foreach f in array array['public.collector_api_budget_take(text,integer)',
                           'public.collector_api_budget_return(text,date,integer)',
                           'public.collector_api_shows_sweep()',
                           'public.collector_api_budget_cap(text)'] loop
    if has_function_privilege('anon', f, 'execute')
       or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL grants on %', f;
    end if;
  end loop;
  if not (select p.prosecdef from pg_proc p where p.oid = 'public.collector_api_budget_take(text,integer)'::regprocedure)
     or not (select p.prosecdef from pg_proc p where p.oid = 'public.collector_api_budget_return(text,date,integer)'::regprocedure)
     or not (select p.prosecdef from pg_proc p where p.oid = 'public.collector_api_shows_sweep()'::regprocedure) then
    raise exception 'FAIL a budget or sweep function is not security definer';
  end if;
  if not exists (select 1 from cron.job where jobname = 'api-shows-sweep'
                  and command = 'select public.collector_api_shows_sweep()') then
    raise exception 'FAIL api-shows-sweep is not scheduled';
  end if;
  insert into l1_lines (line) values ('static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Budget
-- ---------------------------------------------------------------------------
do $$
declare
  v_day date := (now() at time zone 'utc')::date;
  r     jsonb;
  v_ok  boolean;
begin
  -- Start today's Ticketmaster row at 990 (rolled back).
  insert into public.collector_budget (day, source, used) values (v_day, 'ticketmaster_calls', 990)
  on conflict (day, source) do update set used = 990;
  delete from public.collector_budget where day = v_day and source = 'seatgeek_calls';

  r := public.collector_api_budget_take('ticketmaster', 25);
  if (r->>'granted')::int <> 10 or (r->>'cap')::int <> 1000 or (r->>'used')::int <> 1000
     or (r->>'day')::date <> v_day then
    raise exception 'FAIL take within the cap: %', r;
  end if;
  r := public.collector_api_budget_take('ticketmaster', 5);
  if (r->>'granted')::int <> 0 then
    raise exception 'FAIL a spent day granted calls';
  end if;
  r := public.collector_api_budget_return('ticketmaster', v_day, 4);
  if (r->>'used')::int <> 996 then
    raise exception 'FAIL return: %', r;
  end if;
  r := public.collector_api_budget_take('seatgeek', 200);
  if (r->>'granted')::int <> 200
     or (select used from public.collector_budget where day = v_day and source = 'seatgeek_calls') <> 200 then
    raise exception 'FAIL seatgeek take on a new day row';
  end if;
  r := public.collector_api_budget_return('seatgeek', v_day, 1000);
  if (r->>'used')::int <> 0 then
    raise exception 'FAIL return went below 0 or did not clamp';
  end if;

  v_ok := false;
  begin perform public.collector_api_budget_take('eventbrite', 1);
  exception when check_violation then v_ok := sqlerrm = 'api_invalid'; end;
  if not v_ok then raise exception 'FAIL an unknown API was not refused'; end if;
  v_ok := false;
  begin perform public.collector_api_budget_take('ticketmaster', 0);
  exception when check_violation then v_ok := sqlerrm = 'calls_invalid'; end;
  if not v_ok then raise exception 'FAIL 0 calls was not refused'; end if;
  v_ok := false;
  begin perform public.collector_api_budget_take('ticketmaster', 1001);
  exception when check_violation then v_ok := sqlerrm = 'calls_invalid'; end;
  if not v_ok then raise exception 'FAIL 1001 calls was not refused'; end if;
  v_ok := false;
  begin perform public.collector_api_budget_return('ticketmaster', v_day - 2, 1);
  exception when check_violation then v_ok := sqlerrm = 'day_invalid'; end;
  if not v_ok then raise exception 'FAIL a return to an old day was not refused'; end if;
  insert into l1_lines (line) values ('budget take and return: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Ticketing sources make shows
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_tag    text := substr(md5(random()::text), 1, 6);
  v_region jsonb := jsonb_build_object('lat', -60.4, 'lng', -150.4, 'radius_km', 50,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_tm     jsonb;
  v_sg     jsonb;
  v_cal    jsonb;
  v_items  jsonb;
  v_res    jsonb;
begin
  if exists (select 1 from public.feed_sources where slug in ('ticketmaster-test-l1', 'seatgeek-test-l1', 'test-l1-cal')) then
    raise exception 'setup: test sources already exist';
  end if;
  perform set_config('test.t', v_t::text, true);
  perform set_config('test.tag', v_tag, true);
  v_tm := jsonb_build_object('slug', 'ticketmaster-test-l1', 'kind', 'ticketmaster',
    'url', 'https://app.ticketmaster.com/discovery/v2/events.json', 'name', 'Ticketmaster',
    'attribution', 'Event data from the Ticketmaster Discovery API (ticketmaster.com).',
    'homepage_url', 'https://www.ticketmaster.com/', 'lane', 'api', 'enabled', true,
    'hubs', '[]'::jsonb, 'region', v_region);
  v_sg := jsonb_build_object('slug', 'seatgeek-test-l1', 'kind', 'seatgeek',
    'url', 'https://api.seatgeek.com/2/events', 'name', 'SeatGeek',
    'attribution', 'Event data from the SeatGeek Platform API (seatgeek.com).',
    'homepage_url', 'https://seatgeek.com/', 'lane', 'api', 'enabled', true,
    'hubs', '[]'::jsonb, 'region', v_region);
  v_cal := jsonb_build_object('slug', 'test-l1-cal', 'kind', 'ics', 'url', 'https://hall.example.org/cal.ics',
    'name', 'Test Hall calendar', 'attribution', 'Listed from the Test Hall public calendar (hall.example.org).',
    'lane', 'feed', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  perform set_config('test.tm', v_tm::text, true);
  perform set_config('test.sg', v_sg::text, true);
  perform set_config('test.cal', v_cal::text, true);

  -- The hall's own calendar lists one show first, so the Ticketmaster copy links to it.
  v_res := public.collector_ingest_events(v_cal, jsonb_build_array(
    jsonb_build_object('external_id', 'hall-gala', 'title', 'Zzl Hall Gala ' || v_tag, 'starts_at', v_t + interval '1 day',
      'url', 'https://hall.example.org/e/gala', 'lat', -60.41, 'lng', -150.41)), true, true);
  if (v_res->>'inserted')::int <> 1 then raise exception 'FAIL calendar setup: %', v_res - 'first_error' - 'source'; end if;

  v_items := jsonb_build_array(
    jsonb_build_object('external_id', 'tm-a', 'title', 'Zzl Harbour Concert ' || v_tag, 'starts_at', v_t,
      'url', 'https://www.ticketmaster.com/event/TESTA', 'lat', -60.41, 'lng', -150.41, 'price_text', 'From €40',
      'raw', jsonb_build_object('k', 'v')),
    jsonb_build_object('external_id', 'tm-b', 'title', 'Zzl Ice Derby ' || v_tag, 'starts_at', v_t + interval '3 hours',
      'url', 'https://www.ticketmaster.com/event/TESTB', 'lat', -60.42, 'lng', -150.42),
    jsonb_build_object('external_id', 'tm-gala', 'title', 'Zzl Hall Gala ' || v_tag, 'starts_at', v_t + interval '1 day',
      'url', 'https://www.ticketmaster.com/event/TESTG', 'lat', -60.41, 'lng', -150.41));
  perform set_config('test.tm_items', v_items::text, true);
  v_res := public.collector_ingest_events(v_tm, v_items, true, true);
  if (v_res->>'inserted')::int <> 2 or (v_res->>'linked_duplicates')::int <> 1 then
    raise exception 'FAIL ticketmaster run: %', v_res - 'first_error' - 'source';
  end if;
  v_res := public.collector_ingest_events(v_sg, jsonb_build_array(
    jsonb_build_object('external_id', '6100001', 'title', 'Zzl Penguins vs. Seals ' || v_tag, 'starts_at', v_t + interval '5 hours',
      'url', 'https://seatgeek.com/test-tickets/6100001', 'lat', -60.43, 'lng', -150.43)), true, true);
  if (v_res->>'inserted')::int <> 1 then
    raise exception 'FAIL seatgeek run: %', v_res - 'first_error' - 'source';
  end if;

  if (select count(*) from public.feed_sources
       where slug in ('ticketmaster-test-l1', 'seatgeek-test-l1') and listing_kind = 'show' and lane = 'api') <> 2 then
    raise exception 'FAIL ticketing sources are not api show sources';
  end if;
  if (select count(*) from public.events e join public.event_imports ei on ei.event_id = e.id and ei.is_primary
       join public.feed_sources fs on fs.id = ei.source_id
      where fs.slug in ('ticketmaster-test-l1', 'seatgeek-test-l1') and e.listing_kind = 'show'
        and e.status = 'published' and e.kind = 'imported') <> 3 then
    raise exception 'FAIL ticketing events are not published shows';
  end if;
  -- The gala is shared with the hall's calendar: a show while a ticketing copy lists it.
  if (select e.listing_kind from public.events e join public.event_imports ei on ei.event_id = e.id
       join public.feed_sources fs on fs.id = ei.source_id
      where fs.slug = 'test-l1-cal' and ei.external_id = 'hall-gala') <> 'show' then
    raise exception 'FAIL the shared event is not a show';
  end if;
  if not public.shows_available() then raise exception 'FAIL shows_available is false'; end if;
  insert into l1_lines (line) values ('ticketing sources make shows: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. The sweep
-- ---------------------------------------------------------------------------
do $$
declare
  v_a    uuid;
  v_b    uuid;
  v_gala uuid;
  v_sg   uuid;
  v_res  jsonb;
begin
  select ei.event_id into v_a from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-l1' and ei.external_id = 'tm-a';
  select ei.event_id into v_b from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'ticketmaster-test-l1' and ei.external_id = 'tm-b';
  select ei.event_id into v_gala from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-l1-cal' and ei.external_id = 'hall-gala';
  select ei.event_id into v_sg from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'seatgeek-test-l1';

  -- Not refreshed for 4 days: tm-a, the gala's Ticketmaster copy and the SeatGeek show.
  update public.event_imports ei set last_seen_at = now() - interval '4 days'
    from public.feed_sources fs
   where fs.id = ei.source_id and fs.slug in ('ticketmaster-test-l1', 'seatgeek-test-l1')
     and ei.external_id in ('tm-a', 'tm-gala', '6100001');

  v_res := public.collector_api_shows_sweep();
  if (v_res->>'cancelled')::int < 2 then raise exception 'FAIL sweep cancelled too few'; end if;
  if (select status from public.events where id = v_a) <> 'cancelled'
     or (select cancel_reason from public.events where id = v_a) <> 'No longer listed by the source.'
     or (select status from public.events where id = v_sg) <> 'cancelled' then
    raise exception 'FAIL stale ticketing shows were not cancelled';
  end if;
  if (select status from public.events where id = v_b) <> 'published' then
    raise exception 'FAIL a fresh ticketing show was cancelled';
  end if;
  if (select status from public.events where id = v_gala) <> 'published' then
    raise exception 'FAIL an event another source still lists was cancelled';
  end if;

  -- Listed again: the importer brings it back.
  v_res := public.collector_ingest_events(current_setting('test.tm')::jsonb,
                                          current_setting('test.tm_items')::jsonb, true, true);
  if (select status from public.events where id = v_a) <> 'published' then
    raise exception 'FAIL a cancelled stale show did not come back when listed again';
  end if;

  -- Ended over 7 days ago: its raw item is cleared.
  update public.events set starts_at = now() - interval '10 days', ends_at = now() - interval '10 days' + interval '2 hours'
   where id = v_b;
  update public.event_imports ei set raw = jsonb_build_object('k', 'v')
    from public.feed_sources fs where fs.id = ei.source_id and fs.slug = 'ticketmaster-test-l1' and ei.external_id = 'tm-b';
  v_res := public.collector_api_shows_sweep();
  if (v_res->>'raw_cleared')::int < 1
     or (select ei.raw from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
          where fs.slug = 'ticketmaster-test-l1' and ei.external_id = 'tm-b') <> '{}'::jsonb then
    raise exception 'FAIL the raw item of an ended show was kept';
  end if;
  if (select ei.raw from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
       where fs.slug = 'ticketmaster-test-l1' and ei.external_id = 'tm-a') = '{}'::jsonb then
    raise exception 'FAIL the raw item of an upcoming show was cleared';
  end if;
  insert into l1_lines (line) values ('sweep: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. As an adult member who is not a moderator
-- ---------------------------------------------------------------------------
do $$
declare
  v_u uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'l1-' || substr(v_u::text, 1, 8) || '@example.com', now(), now());
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
begin
  select count(*) into v_n
    from public.feed_events_v2(now(), now() + interval '7 days', -60.4, -150.4, 100, p_listing_kind => 'show') f
   where f.title like 'Zzl %' || current_setting('test.tag');
  if v_n < 2 then
    raise exception 'FAIL the shows feed lists % of the test shows', v_n;
  end if;
  select count(*) into v_n
    from public.feed_events_v2(now(), now() + interval '7 days', -60.4, -150.4, 100) f
   where f.title like 'Zzl %' || current_setting('test.tag');
  if v_n <> 0 then
    raise exception 'FAIL the plans feed lists % test shows', v_n;
  end if;
  if exists (select 1 from public.collector_budget) then
    raise exception 'FAIL a member who is not a moderator reads collector_budget';
  end if;
  begin
    perform public.collector_api_budget_take('ticketmaster', 1);
    raise exception 'FAIL a member could take API budget';
  exception when insufficient_privilege then null;
  end;
  insert into l1_lines (line) values ('shows feed and RLS as an adult member: ok');
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

select line as lane1_shows from (
  select 0 as n, 'lane1_shows: all assertions passed' as line
  union all
  select n, line from l1_lines) x
order by n;

rollback;
