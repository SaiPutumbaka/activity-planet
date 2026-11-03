-- ============================================================================
-- Staging check for migration 20261112000100_importer.sql (D-037).
-- One transaction: two throwaway feed sources, synthetic batches through
-- import_upsert_batch, a fresh Atlanta user, assertions in DO blocks that
-- raise on failure, then ROLLBACK. Run as the staging_file of a staging_only
-- migrate.yml run.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup and batch 1
-- ---------------------------------------------------------------------------
do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_campus uuid := (select c.id from public.org_campuses c join public.organizations o on o.id = c.org_id
                     where o.slug = 'georgia-state' and c.slug = 'atlanta');
  v_res    jsonb;
  v_items  jsonb;
  v_viewer uuid := gen_random_uuid();
begin
  if v_campus is null then raise exception 'setup: GSU Atlanta campus missing'; end if;
  perform set_config('test.t', v_t::text, true);

  insert into public.feed_sources (slug, kind, url, name, attribution, item_label, campus_id)
  values ('test-importer-a', 'localist', 'https://example.com/api/2/events', 'Test Calendar A',
          'Listed from Test Calendar A.', null, v_campus),
         ('test-importer-b', 'engage_rss', 'https://example.com/events.rss', 'Test Feed B',
          'Listed from Test Feed B.', 'Test student org event', null);

  v_items := jsonb_build_array(
    jsonb_build_object('external_id', 'bball', 'title', 'Pickup Basketball Night', 'description', 'Bring shoes.',
      'starts_at', v_t, 'ends_at', v_t + interval '1 hour', 'location', 'Rec Center',
      'lat', 33.7537, 'lng', -84.3826, 'url', 'https://example.com/e/bball', 'open_to_public', true,
      'categories', jsonb_build_array('Recreation'), 'host_org', 'Recreational Services', 'raw', '{"id": 1}'::jsonb),
    jsonb_build_object('external_id', 'noend', 'title', 'Quiet Study Session', 'starts_at', v_t,
      'url', 'https://example.com/e/noend'),
    jsonb_build_object('external_id', 'long', 'title', 'Semester Exhibit', 'starts_at', v_t,
      'ends_at', v_t + interval '4 days', 'url', 'https://example.com/e/long'),
    jsonb_build_object('external_id', 'http', 'title', 'Plain http listing', 'starts_at', v_t,
      'url', 'http://example.com/e/http'),
    jsonb_build_object('external_id', 'short', 'title', 'ab', 'starts_at', v_t, 'url', 'https://example.com/e/short'),
    jsonb_build_object('external_id', 'bigtitle', 'title', repeat('Long title ', 20), 'starts_at', v_t,
      'location', repeat('Somewhere ', 15), 'url', 'https://example.com/e/big', 'cover_url', 'http://example.com/x.png'),
    jsonb_build_object('external_id', 'nomatch', 'title', 'Zzyzx gathering', 'starts_at', v_t,
      'url', 'https://example.com/e/nomatch'),
    jsonb_build_object('external_id', 'gone', 'title', 'Zzyzx later gathering', 'starts_at', v_t + interval '2 days',
      'url', 'https://example.com/e/gone'),
    jsonb_build_object('external_id', 'gone', 'title', 'Duplicate key in batch', 'starts_at', v_t,
      'url', 'https://example.com/e/dup'),
    jsonb_build_object('external_id', 'badtime', 'title', 'Bad time', 'starts_at', 'not a time',
      'url', 'https://example.com/e/badtime')
  );
  perform set_config('test.items', v_items::text, true);

  v_res := public.import_upsert_batch('test-importer-a', v_items);
  if (v_res->>'total')::int <> 10 or (v_res->>'inserted')::int <> 5 then
    raise exception 'FAIL batch 1 counts: %', v_res;
  end if;
  if (v_res->'skipped'->>'longer_than_3_days')::int <> 1 or (v_res->'skipped'->>'no_https_url')::int <> 1
     or (v_res->'skipped'->>'title_too_short')::int <> 1 or (v_res->'skipped'->>'duplicate_in_batch')::int <> 1
     or (v_res->'skipped'->>'error')::int <> 1 then
    raise exception 'FAIL batch 1 skip reasons: %', v_res;
  end if;

  -- Fresh Atlanta user (no hubs, no campus).
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_viewer, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'importer-viewer-' || substr(v_viewer::text, 1, 8) || '@example.com', now(), now());
  perform set_config('test.viewer', v_viewer::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- Shape of what batch 1 wrote
-- ---------------------------------------------------------------------------
do $$
declare
  v_src  uuid := (select id from public.feed_sources where slug = 'test-importer-a');
  v_e    public.events%rowtype;
  v_imp  public.event_imports%rowtype;
begin
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'bball';
  if v_e.kind <> 'imported' or v_e.host_id is not null or v_e.series_id is not null
     or v_e.visibility <> 'public' or v_e.min_age <> 18 or v_e.status <> 'published'
     or v_e.external_url <> 'https://example.com/e/bball' or v_e.source_name <> 'Test Calendar A'
     or v_e.campus_id is null or v_e.location_hint <> 'Rec Center' then
    raise exception 'FAIL bball event shape: %', row_to_json(v_e);
  end if;
  if (select slug from public.hubs where id = v_e.hub_id) <> 'basketball' then
    raise exception 'FAIL bball hub: %', (select slug from public.hubs where id = v_e.hub_id);
  end if;
  if abs(v_e.approx_lat - 33.7537) > 0.0001 then
    raise exception 'FAIL bball point should come from the source';
  end if;
  select * into v_imp from public.event_imports where source_id = v_src and external_id = 'bball';
  if v_imp.point_source <> 'source' or v_imp.open_to_public is not true or v_imp.host_org <> 'Recreational Services'
     or v_imp.raw <> '{"id": 1}'::jsonb then
    raise exception 'FAIL bball import row: %', row_to_json(v_imp);
  end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'noend';
  if v_e.ends_at <> v_e.starts_at + interval '2 hours' then
    raise exception 'FAIL default end is start + 2 hours: % %', v_e.starts_at, v_e.ends_at;
  end if;
  if (select slug from public.hubs where id = v_e.hub_id) <> 'study-sessions' then
    raise exception 'FAIL noend hub';
  end if;
  if (select point_source from public.event_imports where source_id = v_src and external_id = 'noend') <> 'campus_centroid'
     or abs(v_e.approx_lat - 33.753) > 0.001 then
    raise exception 'FAIL noend should sit on the campus centroid';
  end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'bigtitle';
  if char_length(v_e.title) <> 120 or right(v_e.title, 1) <> '…' or char_length(v_e.location_hint) > 120
     or v_e.cover_url is not null then
    raise exception 'FAIL clipping: % / % / %', v_e.title, v_e.location_hint, v_e.cover_url;
  end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'nomatch';
  if (select slug from public.hubs where id = v_e.hub_id) <> 'happening-nearby' then
    raise exception 'FAIL unmatched item should land in happening-nearby';
  end if;

  if exists (select 1 from public.event_imports where source_id = v_src and external_id in ('long', 'http', 'short')) then
    raise exception 'FAIL skipped items must not create import rows';
  end if;
  if (select last_ok_at from public.feed_sources where id = v_src) is null
     or (select item_count from public.feed_sources where id = v_src) <> 10 then
    raise exception 'FAIL run status not recorded';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Cross-source dedupe, missed runs, cancel, re-publish, empty feed
-- ---------------------------------------------------------------------------
do $$
declare
  v_t     timestamptz := current_setting('test.t')::timestamptz;
  v_items jsonb := current_setting('test.items')::jsonb;
  v_keep  jsonb;
  v_res   jsonb;
  v_src   uuid := (select id from public.feed_sources where slug = 'test-importer-a');
  v_gone  uuid;
  v_n     integer;
begin
  -- Same title (other case) and start from another source: linked, not duplicated.
  select count(*) into v_n from public.events where kind = 'imported';
  v_res := public.import_upsert_batch('test-importer-b', jsonb_build_array(
    jsonb_build_object('external_id', 'b-1', 'title', 'PICKUP BASKETBALL NIGHT', 'starts_at', v_t,
      'url', 'https://example.com/b/1', 'host_org', 'Basketball Club')));
  if (v_res->>'linked_duplicates')::int <> 1 or (select count(*) from public.events where kind = 'imported') <> v_n then
    raise exception 'FAIL cross-source dedupe: %', v_res;
  end if;

  select event_id into v_gone from public.event_imports where source_id = v_src and external_id = 'gone';
  select coalesce(jsonb_agg(x), '[]'::jsonb) into v_keep
    from jsonb_array_elements(v_items) x where x->>'external_id' <> 'gone';

  v_res := public.import_upsert_batch('test-importer-a', v_keep);
  if (v_res->>'inserted')::int <> 0 or (v_res->>'updated')::int <> 0 or (v_res->>'missed')::int <> 1 then
    raise exception 'FAIL second run should change nothing and miss one: %', v_res;
  end if;
  if (select status from public.events where id = v_gone) <> 'published' then
    raise exception 'FAIL one missed run must not cancel';
  end if;

  v_res := public.import_upsert_batch('test-importer-a', v_keep);
  if (select status from public.events where id = v_gone) <> 'cancelled' or (v_res->>'cancelled')::int <> 1 then
    raise exception 'FAIL two missed runs must cancel: %', v_res;
  end if;

  v_res := public.import_upsert_batch('test-importer-a', v_items);
  if (select status from public.events where id = v_gone) <> 'published' then
    raise exception 'FAIL an item that comes back is published again: %', v_res;
  end if;

  -- An empty feed is not a cancellation.
  v_res := public.import_upsert_batch('test-importer-a', '[]'::jsonb);
  if (select max(missed_runs) from public.event_imports where source_id = v_src) <> 0 then
    raise exception 'FAIL an empty run must not count as missed';
  end if;

  -- A changed item updates its event in place.
  v_res := public.import_upsert_batch('test-importer-a', jsonb_set(v_items, '{0,title}', '"Pickup Basketball Night (moved)"'));
  if (v_res->>'updated')::int <> 1
     or not exists (select 1 from public.events e join public.event_imports ei on ei.event_id = e.id
                     where ei.source_id = v_src and ei.external_id = 'bball' and e.title = 'Pickup Basketball Night (moved)') then
    raise exception 'FAIL changed item not updated: %', v_res;
  end if;

  -- Unknown source.
  begin
    perform public.import_upsert_batch('no-such-source', '[]'::jsonb);
    raise exception 'FAIL unknown source accepted';
  exception when no_data_found then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges, catch-all hub, secret, schedule, version
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('authenticated', 'public.import_upsert_batch(text, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.import_upsert_batch(text, jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.import_upsert_batch(text, jsonb)', 'execute') then
    raise exception 'FAIL import_upsert_batch must be service_role only';
  end if;
  if has_function_privilege('authenticated', 'public.import_verify_secret(text)', 'execute')
     or has_function_privilege('authenticated', 'public.import_record_error(text, text, jsonb)', 'execute')
     or has_function_privilege('service_role', 'public.import_set_function_url(text)', 'execute')
     or has_function_privilege('authenticated', 'public.import_dispatch(text)', 'execute')
     or has_function_privilege('service_role', 'public.import_dispatch_all()', 'execute') then
    raise exception 'FAIL importer helpers are callable by clients';
  end if;
  if has_table_privilege('anon', 'public.feed_sources', 'select')
     or has_table_privilege('authenticated', 'public.feed_sources', 'insert')
     or has_table_privilege('authenticated', 'public.event_imports', 'update')
     or has_table_privilege('authenticated', 'public.import_hub_rules', 'delete') then
    raise exception 'FAIL clients hold write or anon grants on importer tables';
  end if;
  if not exists (select 1 from public.hubs where slug = 'happening-nearby' and scope = 'general'
                  and min_age = 18 and is_active) then
    raise exception 'FAIL catch-all hub missing or campus-scoped';
  end if;
  if (select count(*) from public.import_hub_rules) < 50 then
    raise exception 'FAIL starter hub rules missing: %', (select count(*) from public.import_hub_rules);
  end if;
  if not exists (select 1 from vault.secrets where name = 'import_feed_secret') then
    raise exception 'FAIL shared secret not generated';
  end if;
  if public.import_verify_secret('short') or public.import_verify_secret(repeat('0', 64)) then
    raise exception 'FAIL import_verify_secret accepts a wrong secret';
  end if;
  if not public.import_verify_secret((select decrypted_secret from vault.decrypted_secrets where name = 'import_feed_secret')) then
    raise exception 'FAIL import_verify_secret rejects the real secret';
  end if;
  if (select count(*) from cron.job where jobname like 'import-feed-%')
     <> (select count(*) from public.feed_sources where enabled) then
    raise exception 'FAIL one cron job per enabled source';
  end if;
  if exists (select 1 from public.feed_sources where slug in ('gsu-localist', 'gsu-pin') and url !~ '^https://') then
    raise exception 'FAIL seeded sources';
  end if;
  if (select value from public.meta where key = 'schema_version') <> '2.11' then
    raise exception 'FAIL schema_version is not 2.11';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- As a fresh Atlanta user: Feed v2 shows the imported rows, labels resolve,
-- the importer tables read as empty
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.viewer'), 'role', 'authenticated')::text, true);

do $$
declare
  v_t   timestamptz := current_setting('test.t')::timestamptz;
  v_n   integer;
  v_lab record;
begin
  select count(*) into v_n
    from public.feed_events_v2(now(), now() + interval '30 days')
   where is_imported and source_name in ('Test Calendar A') and matched_by = 'nearby';
  if v_n < 4 then
    raise exception 'FAIL feed_events_v2 shows % test imported rows to a fresh Atlanta user', v_n;
  end if;

  select * into v_lab from public.imported_event_labels(array(
    select e.id from public.events e where e.title = 'Pickup Basketball Night (moved)' and e.kind = 'imported'));
  if v_lab.source_slug <> 'test-importer-a' or v_lab.open_to_public is not true
     or v_lab.affiliated_org_name <> 'Georgia State University' or v_lab.approximate_location then
    raise exception 'FAIL labels: %', row_to_json(v_lab);
  end if;

  if (select count(*) from public.feed_sources) <> 0 or (select count(*) from public.event_imports) <> 0 then
    raise exception 'FAIL a non-moderator can read importer tables';
  end if;

  begin
    perform public.import_upsert_batch('test-importer-a', '[]'::jsonb);
    raise exception 'FAIL authenticated can call import_upsert_batch';
  exception when insufficient_privilege then null;
  end;
end $$;

reset role;

select 'importer: all assertions passed' as result;

rollback;
