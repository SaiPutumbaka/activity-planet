-- ============================================================================
-- Staging check for migration 20261202000100_collector_ingest_fixes.sql
-- (collector ingest review fixes). One transaction, asserts in DO blocks that
-- raise on failure, rolled back at the end. Prints pass/fail only, never
-- titles, ids or points (the repo and its Action logs are public). Run as the
-- staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.34; one collector_ingest_events (6 arguments),
--     definer, service_role only; import_title_key and import_is_21_plus;
--     the wine rule is gone and the drawing and kayaking rules are narrow.
--   2 D-040 item rules: descriptions clipped to 300 characters, cover_url
--     dropped unless the source says images_licensed.
--   3 Repeat posts in one run (same run id) count no missed runs; a new run
--     does; two real misses still cancel.
--   4 Seen ids keep a known item from being missed; 21+ items are skipped.
--   5 Cross-source match by the collector key (punctuation, case, same start
--     minute) and by URL.
--   6 enabled is written only when it changes (the reschedule trigger does
--     not fire on an ordinary post). A test-only trigger and function count
--     the enabled updates; the rollback removes them.
-- The fixture lives in the Southern Ocean (no real data there), as in
-- collector_events_ingest.sql.
-- ============================================================================
begin;

create temp table cif_lines (n serial, line text);
create temp table cif_hits (n integer);

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
declare
  v_sig text := 'public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb)';
begin
  if (select value from public.meta where key = 'schema_version') <> '2.34' then
    raise exception 'FAIL schema_version is not 2.34';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'collector_ingest_events') <> 1 then
    raise exception 'FAIL not exactly one collector_ingest_events';
  end if;
  if not (select p.prosecdef from pg_proc p where p.oid = v_sig::regprocedure) then
    raise exception 'FAIL collector_ingest_events is not security definer';
  end if;
  if has_function_privilege('authenticated', v_sig, 'execute')
     or has_function_privilege('anon', v_sig, 'execute')
     or not has_function_privilege('service_role', v_sig, 'execute') then
    raise exception 'FAIL collector_ingest_events grants';
  end if;
  if has_function_privilege('authenticated', 'public.import_upsert_batch(text, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.import_title_key(text)', 'execute')
     or has_function_privilege('authenticated', 'public.import_is_21_plus(text)', 'execute') then
    raise exception 'FAIL helper grants';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'import_upsert_batch') <> 1 then
    raise exception 'FAIL more than one import_upsert_batch';
  end if;

  if public.import_title_key('Zzq Fall Fair: Kids'' Day!') <> public.import_title_key('ZZQ fall fair - kids day')
     or public.import_title_key('Café Night') <> public.import_title_key('cafe night')
     or public.import_title_key('Zzq Fall Fair') = public.import_title_key('Zzq Fall Fair 2')
     or public.import_title_key('!!') <> '!!' then
    raise exception 'FAIL import_title_key';
  end if;
  if not public.import_is_21_plus('Wine Tasting in the Garden')
     or not public.import_is_21_plus('Craft Beer Festival')
     or not public.import_is_21_plus('Cocktail class')
     or not public.import_is_21_plus('Brewery tour')
     or not public.import_is_21_plus('Trivia night (21+)')
     or not public.import_is_21_plus('Comedy | 21 and over')
     or public.import_is_21_plus('Pickleball social')
     or public.import_is_21_plus('Spring plant sale')
     or public.import_is_21_plus('Swine and cattle show')
     or public.import_is_21_plus('Run 21K') then
    raise exception 'FAIL import_is_21_plus';
  end if;

  if exists (select 1 from public.import_hub_rules where source_id is null and pattern ~ 'wine tasting') then
    raise exception 'FAIL the wine-tasting rule is still there';
  end if;
  if exists (select 1 from public.import_hub_rules r join public.hubs h on h.id = r.hub_id
              where r.source_id is null and h.slug = 'drawing' and 'Raffle and prize drawing' ~* r.pattern) then
    raise exception 'FAIL a drawing rule matches a prize drawing';
  end if;
  if not exists (select 1 from public.import_hub_rules r join public.hubs h on h.id = r.hub_id
                  where r.source_id is null and h.slug = 'drawing' and 'Figure drawing night' ~* r.pattern) then
    raise exception 'FAIL no drawing rule matches figure drawing';
  end if;
  if exists (select 1 from public.import_hub_rules r join public.hubs h on h.id = r.hub_id
              where r.source_id is null and h.slug = 'kayaking' and 'Pickleball paddle demo' ~* r.pattern) then
    raise exception 'FAIL a kayaking rule matches a pickleball paddle';
  end if;
  if not exists (select 1 from public.import_hub_rules r join public.hubs h on h.id = r.hub_id
                  where r.source_id is null and h.slug = 'kayaking' and 'Sunset paddleboard tour' ~* r.pattern)
     or not exists (select 1 from public.import_hub_rules r join public.hubs h on h.id = r.hub_id
                     where r.source_id is null and h.slug = 'kayaking' and 'Canoe trip' ~* r.pattern) then
    raise exception 'FAIL no kayaking rule matches paddleboard or canoe';
  end if;
  insert into cif_lines (line) values ('static checks, helpers and rules: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. D-040 item rules
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_tag    text := substr(md5(random()::text), 1, 6);
  v_region jsonb := jsonb_build_object('lat', -60.2, 'lng', -150.2, 'radius_km', 300,
                                       'label', 'Test ocean', 'timezone', 'Pacific/Auckland');
  v_a      jsonb;
  v_b      jsonb;
  v_c      jsonb;
  v_items  jsonb;
  v_res    jsonb;
  v_e      public.events%rowtype;
begin
  if exists (select 1 from public.feed_sources where slug in ('test-cif-a', 'test-cif-b', 'test-cif-c')) then
    raise exception 'setup: test sources already exist';
  end if;
  perform set_config('test.t', v_t::text, true);
  perform set_config('test.tag', v_tag, true);
  v_a := jsonb_build_object('slug', 'test-cif-a', 'kind', 'jsonld', 'url', 'https://garden.example.org/calendar/',
    'name', 'Test Garden calendar', 'attribution', 'Listed from the Test Garden public calendar (garden.example.org).',
    'lane', 'page', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_b := jsonb_build_object('slug', 'test-cif-b', 'kind', 'ics', 'url', 'https://city.example.org/cal.ics',
    'name', 'Test City calendar', 'attribution', 'Listed from the Test City public calendar (city.example.org).',
    'lane', 'feed', 'enabled', true, 'hubs', '[]'::jsonb, 'region', v_region);
  v_c := v_a || jsonb_build_object('slug', 'test-cif-c', 'images_licensed', true);
  perform set_config('test.a', v_a::text, true);
  perform set_config('test.b', v_b::text, true);

  v_items := jsonb_build_array(
    jsonb_build_object('external_id', 'p:orchid', 'title', 'Zzq Orchid Morning ' || v_tag, 'starts_at', v_t,
      'url', 'https://garden.example.org/e/orchid', 'lat', -60.21, 'lng', -150.21,
      'description', repeat('Long text. ', 200), 'cover_url', 'https://garden.example.org/i/orchid.jpg'),
    jsonb_build_object('external_id', 'p:lantern', 'title', 'Zzq Lantern Evening ' || v_tag,
      'starts_at', v_t + interval '1 day', 'url', 'https://garden.example.org/e/lantern'),
    jsonb_build_object('external_id', 'p:far', 'title', 'Zzq Autumn Walk ' || v_tag,
      'starts_at', v_t + interval '2 days', 'url', 'https://garden.example.org/e/far'),
    jsonb_build_object('external_id', 'p:pickle', 'title', 'Zzq Pickleball Social ' || v_tag,
      'starts_at', v_t + interval '3 days', 'url', 'https://garden.example.org/e/pickle'));
  perform set_config('test.items_a', v_items::text, true);

  v_res := public.collector_ingest_events(v_a, v_items, true, true, 'run-1', null);
  if (v_res->>'inserted')::int <> 4 or (v_res->>'repeat_run')::boolean or (v_res->>'partial')::boolean then
    raise exception 'FAIL source A first run: %', v_res - 'first_error' - 'source';
  end if;
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
    join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-a' and ei.external_id = 'p:orchid';
  if char_length(v_e.description) > 300 or v_e.cover_url is not null then
    raise exception 'FAIL description not clipped or unlicensed cover kept';
  end if;
  if (select collector_last_run_id from public.feed_sources where slug = 'test-cif-a') <> 'run-1'
     or (select images_licensed from public.feed_sources where slug = 'test-cif-a') then
    raise exception 'FAIL run id or images_licensed on the row';
  end if;

  -- Another event (own title and URL), so it is not linked to source A's.
  v_res := public.collector_ingest_events(v_c, jsonb_build_array(
    jsonb_build_object('external_id', 'p:orchid', 'title', 'Zzq Cover Check ' || v_tag, 'starts_at', v_t,
      'url', 'https://garden.example.org/e/cover', 'cover_url', 'https://garden.example.org/i/orchid.jpg')),
    true, true, 'run-1', null);
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
    join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-c' and ei.external_id = 'p:orchid';
  if v_e.id is null or v_e.cover_url is distinct from 'https://garden.example.org/i/orchid.jpg'
     or not (select images_licensed from public.feed_sources where slug = 'test-cif-c') then
    raise exception 'FAIL a licensed source lost its cover';
  end if;
  insert into cif_lines (line) values ('excerpt and image rules: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Repeat posts in one run
-- ---------------------------------------------------------------------------
do $$
declare
  v_a     jsonb := current_setting('test.a')::jsonb;
  v_items jsonb := current_setting('test.items_a')::jsonb;
  v_keep  jsonb;
  v_res   jsonb;
  v_lantern uuid;
  v_missed  integer;
begin
  select ei.event_id into v_lantern from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-a' and ei.external_id = 'p:lantern';
  select jsonb_agg(x) into v_keep from jsonb_array_elements(v_items) x where x->>'external_id' <> 'p:lantern';

  -- The same run again (a retry after a commit): partial, no miss.
  v_res := public.collector_ingest_events(v_a, v_keep, true, true, 'run-1', null);
  if not (v_res->>'repeat_run')::boolean or not (v_res->>'partial')::boolean or (v_res->>'missed')::int <> 0 then
    raise exception 'FAIL a repeat post counted misses: %', v_res - 'first_error' - 'source';
  end if;
  -- A new run: one miss; its retry: still one.
  v_res := public.collector_ingest_events(v_a, v_keep, true, true, 'run-2', null);
  v_res := public.collector_ingest_events(v_a, v_keep, true, true, 'run-2', null);
  select missed_runs into v_missed from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-a' and ei.external_id = 'p:lantern';
  if v_missed <> 1 or (select status from public.events where id = v_lantern) <> 'published' then
    raise exception 'FAIL a retry in one run counted a second miss (missed_runs %)', v_missed;
  end if;
  -- A second real miss cancels.
  v_res := public.collector_ingest_events(v_a, v_keep, true, true, 'run-3', null);
  if (v_res->>'repeat_run')::boolean or (v_res->>'cancelled')::int <> 1
     or (select status from public.events where id = v_lantern) <> 'cancelled' then
    raise exception 'FAIL two real misses did not cancel: %', v_res - 'first_error' - 'source';
  end if;
  -- The old call shape (no run id) still works and is never a repeat.
  v_res := public.collector_ingest_events(v_a, v_keep, true, true);
  v_res := public.collector_ingest_events(v_a, v_keep, true, true);
  if (v_res->>'repeat_run')::boolean or (v_res->>'partial')::boolean then
    raise exception 'FAIL a post without a run id was read as a repeat';
  end if;
  insert into cif_lines (line) values ('repeat posts in one run: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Seen ids and 21+ items
-- ---------------------------------------------------------------------------
do $$
declare
  v_a     jsonb := current_setting('test.a')::jsonb;
  v_items jsonb := current_setting('test.items_a')::jsonb;
  v_t     timestamptz := current_setting('test.t')::timestamptz;
  v_tag   text := current_setting('test.tag');
  v_keep  jsonb;
  v_res   jsonb;
  i       integer;
begin
  select jsonb_agg(x) into v_keep from jsonb_array_elements(v_items) x
   where x->>'external_id' in ('p:orchid', 'p:pickle');
  v_keep := v_keep || jsonb_build_array(
    jsonb_build_object('external_id', 'p:wine', 'title', 'Zzq Wine Tasting Evening ' || v_tag,
      'starts_at', v_t + interval '4 days', 'url', 'https://garden.example.org/e/wine'),
    jsonb_build_object('external_id', 'p:ale', 'title', 'Zzq Harvest Social ' || v_tag,
      'categories', jsonb_build_array('Beer & Spirits'),
      'starts_at', v_t + interval '4 days', 'url', 'https://garden.example.org/e/ale'));
  for i in 1..3 loop
    v_res := public.collector_ingest_events(v_a, v_keep, true, true, 'run-seen-' || i, '["p:far"]'::jsonb);
  end loop;
  if (v_res #>> '{skipped,listed_not_sent}')::int <> 1 or (v_res #>> '{skipped,age_21}')::int <> 2 then
    raise exception 'FAIL seen or age_21 counts: %', v_res -> 'skipped';
  end if;
  if (select ei.missed_runs from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
       where fs.slug = 'test-cif-a' and ei.external_id = 'p:far') <> 0
     or (select e.status from public.events e join public.event_imports ei on ei.event_id = e.id
           join public.feed_sources fs on fs.id = ei.source_id
          where fs.slug = 'test-cif-a' and ei.external_id = 'p:far') <> 'published' then
    raise exception 'FAIL a seen id was missed or cancelled';
  end if;
  if exists (select 1 from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
              where fs.slug = 'test-cif-a' and ei.external_id in ('p:wine', 'p:ale')) then
    raise exception 'FAIL a 21+ item was imported';
  end if;
  begin
    perform public.collector_ingest_events(v_a, '[]'::jsonb, true, true, 'run-x', '[1]'::jsonb);
    raise exception 'FAIL a bad seen list was accepted';
  exception when check_violation then
    if sqlerrm <> 'items_invalid' then raise; end if;
  end;
  begin
    perform public.collector_ingest_events(v_a, '[]'::jsonb, true, true, 'bad run id', null);
    raise exception 'FAIL a bad run id was accepted';
  exception when check_violation then
    if sqlerrm <> 'run_id_invalid' then raise; end if;
  end;
  insert into cif_lines (line) values ('seen ids and 21+ items: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Cross-source match by the collector key
-- ---------------------------------------------------------------------------
do $$
declare
  v_b     jsonb := current_setting('test.b')::jsonb;
  v_t     timestamptz := current_setting('test.t')::timestamptz;
  v_tag   text := current_setting('test.tag');
  v_res   jsonb;
  v_orchid uuid;
  v_pickle uuid;
begin
  select ei.event_id into v_orchid from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-a' and ei.external_id = 'p:orchid';
  select ei.event_id into v_pickle from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
   where fs.slug = 'test-cif-a' and ei.external_id = 'p:pickle';
  v_res := public.collector_ingest_events(v_b, jsonb_build_array(
    -- Same event: other case and punctuation, 30 seconds later in the same minute.
    jsonb_build_object('external_id', 'uid-orchid', 'title', upper('Zzq orchid morning! ' || v_tag) || '!!',
      'starts_at', v_t + interval '30 seconds', 'url', 'https://city.example.org/e/orchid'),
    -- Same event: another title, the same URL and start.
    jsonb_build_object('external_id', 'uid-pickle', 'title', 'Zzq Paddle Sports Meetup ' || v_tag,
      'starts_at', v_t + interval '3 days', 'url', 'https://garden.example.org/e/pickle'),
    -- Another event: same title, another minute.
    jsonb_build_object('external_id', 'uid-other', 'title', 'Zzq Orchid Morning ' || v_tag,
      'starts_at', v_t + interval '5 minutes', 'url', 'https://city.example.org/e/other')),
    true, true, 'run-b-1', null);
  if (v_res->>'linked_duplicates')::int <> 2 or (v_res->>'inserted')::int <> 1 then
    raise exception 'FAIL collector-key match: %', v_res - 'first_error' - 'source';
  end if;
  if (select ei.event_id from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
       where fs.slug = 'test-cif-b' and ei.external_id = 'uid-orchid') <> v_orchid
     or (select ei.event_id from public.event_imports ei join public.feed_sources fs on fs.id = ei.source_id
          where fs.slug = 'test-cif-b' and ei.external_id = 'uid-pickle') <> v_pickle then
    raise exception 'FAIL linked to the wrong events';
  end if;
  insert into cif_lines (line) values ('cross-source match by title key and URL: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. enabled is written only when it changes
-- ---------------------------------------------------------------------------
create function public.zz_cif_count_enabled_updates() returns trigger language plpgsql as $$
begin
  insert into pg_temp.cif_hits (n) values (1);
  return null;
end $$;
create trigger cif_enabled_updates after update of enabled on public.feed_sources
  for each statement execute function public.zz_cif_count_enabled_updates();

do $$
declare
  v_a   jsonb := current_setting('test.a')::jsonb;
  v_res jsonb;
begin
  delete from cif_hits;
  v_res := public.collector_ingest_events(v_a, '[]'::jsonb, true, true, 'run-e-1', null);
  v_res := public.collector_ingest_events(v_a, '[]'::jsonb, true, false, 'run-e-2', null);
  if (select count(*) from cif_hits) <> 0 then
    raise exception 'FAIL an ordinary post wrote enabled';
  end if;
  v_res := public.collector_ingest_events(v_a || jsonb_build_object('enabled', false), '[]'::jsonb, true, true, 'run-e-3', null);
  if (select count(*) from cif_hits) <> 1 or (select enabled from public.feed_sources where slug = 'test-cif-a') then
    raise exception 'FAIL a seed that is off did not switch its row off once';
  end if;
  insert into cif_lines (line) values ('enabled written only on change: ok');
end $$;

select line as collector_ingest_fixes from (
  select 0 as n, 'collector_ingest_fixes: all assertions passed' as line
  union all
  select n, line from cif_lines) x
order by n;

rollback;
