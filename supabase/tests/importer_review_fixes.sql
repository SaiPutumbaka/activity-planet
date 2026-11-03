-- ============================================================================
-- Staging check for migration 20261112000300_importer_review_fixes.sql.
-- 1. An item whose processing raises still counts as seen (never cancelled).
-- 2. A primary missed twice hands its event to a linked copy that the other
--    source still lists; a copy seen again revives an event cancelled as no
--    longer listed.
-- 3. An item first seen cancelled gets its event once it is live again.
-- Prints only pass/fail and counts. ROLLBACK at the end.
-- ============================================================================
begin;

do $$
declare
  v_t     timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_a     uuid;
  v_b     uuid;
  v_res   jsonb;
  v_event uuid;
  v_e     public.events%rowtype;
  v_ei    public.event_imports%rowtype;
  v_keep  jsonb;
begin
  insert into public.feed_sources (slug, kind, url, name)
  values ('test-fix-a', 'engage_rss', 'https://example.com/a.rss', 'Test Feed A')
  returning id into v_a;
  insert into public.feed_sources (slug, kind, url, name)
  values ('test-fix-b', 'localist', 'https://example.com/b', 'Test Feed B')
  returning id into v_b;

  v_keep := jsonb_build_object('external_id', 'keep', 'title', 'Always listed', 'starts_at', v_t,
                               'url', 'https://example.com/e/keep');

  -- 1. Error on a known item ---------------------------------------------------
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
    jsonb_build_object('external_id', 'err', 'title', 'Error prone night', 'starts_at', v_t,
                       'url', 'https://example.com/e/err')));
  if (v_res->>'inserted')::int <> 2 then raise exception 'FAIL 1 setup: %', v_res; end if;
  for i in 1..3 loop
    v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
      jsonb_build_object('external_id', 'err', 'title', 'Error prone night', 'starts_at', 'not a date',
                         'url', 'https://example.com/e/err')));
    if coalesce((v_res->'skipped'->>'error')::int, 0) <> 1 then raise exception 'FAIL 1 error count: %', v_res; end if;
  end loop;
  select * into v_ei from public.event_imports where source_id = v_a and external_id = 'err';
  select * into v_e from public.events where id = v_ei.event_id;
  if v_ei.missed_runs <> 0 or v_e.status <> 'published' then
    raise exception 'FAIL 1 erroring item was treated as missed: missed % status %', v_ei.missed_runs, v_e.status;
  end if;
  raise notice 'fix 1 ok: erroring item missed_runs % status %', v_ei.missed_runs, v_e.status;

  -- 2a. Hand-off to a listed copy ----------------------------------------------
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
    jsonb_build_object('external_id', 'x', 'title', 'Shared Event', 'starts_at', v_t,
                       'url', 'https://example.com/a/x')));
  v_res := public.import_upsert_batch('test-fix-b', jsonb_build_array(
    jsonb_build_object('external_id', 'bx', 'title', 'shared event', 'starts_at', v_t,
                       'url', 'https://example.com/b/x', 'description', 'From B')));
  if (v_res->>'linked_duplicates')::int <> 1 then raise exception 'FAIL 2a link: %', v_res; end if;
  select event_id into v_event from public.event_imports where source_id = v_a and external_id = 'x';
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep));
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep));
  if (v_res->>'handed_off')::int <> 1 or (v_res->>'cancelled')::int <> 0 then
    raise exception 'FAIL 2a hand-off: %', v_res;
  end if;
  select * into v_e from public.events where id = v_event;
  if v_e.status <> 'published' or v_e.source_name <> 'Test Feed B' then
    raise exception 'FAIL 2a event after hand-off: status % source %', v_e.status, v_e.source_name;
  end if;
  if not (select is_primary from public.event_imports where source_id = v_b and external_id = 'bx')
     or (select is_primary from public.event_imports where source_id = v_a and external_id = 'x') then
    raise exception 'FAIL 2a primary flags';
  end if;
  v_res := public.import_upsert_batch('test-fix-b', jsonb_build_array(
    jsonb_build_object('external_id', 'bx', 'title', 'shared event', 'starts_at', v_t,
                       'url', 'https://example.com/b/x', 'description', 'From B')));
  select * into v_e from public.events where id = v_event;
  if (v_res->>'updated')::int <> 1 or v_e.external_url <> 'https://example.com/b/x' or v_e.status <> 'published' then
    raise exception 'FAIL 2a copy rewrite: % url %', v_res, v_e.external_url;
  end if;
  raise notice 'fix 2a ok: handed_off 1, event stays published under the copy source';

  -- 2b. A copy seen again revives a cancelled event ----------------------------
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
    jsonb_build_object('external_id', 'y', 'title', 'Second Shared', 'starts_at', v_t,
                       'url', 'https://example.com/a/y')));
  v_res := public.import_upsert_batch('test-fix-b', jsonb_build_array(
    jsonb_build_object('external_id', 'by', 'title', 'Second Shared', 'starts_at', v_t,
                       'url', 'https://example.com/b/y')));
  select event_id into v_event from public.event_imports where source_id = v_a and external_id = 'y';
  update public.event_imports set missed_runs = 1 where source_id = v_b and external_id = 'by';
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep));
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep));
  select * into v_e from public.events where id = v_event;
  if v_e.status <> 'cancelled' then raise exception 'FAIL 2b setup: status %, %', v_e.status, v_res; end if;
  v_res := public.import_upsert_batch('test-fix-b', jsonb_build_array(
    jsonb_build_object('external_id', 'by', 'title', 'Second Shared', 'starts_at', v_t,
                       'url', 'https://example.com/b/y')));
  select * into v_e from public.events where id = v_event;
  if v_e.status <> 'published' or v_e.source_name <> 'Test Feed B'
     or not (select is_primary from public.event_imports where source_id = v_b and external_id = 'by') then
    raise exception 'FAIL 2b revive: status % source % %', v_e.status, v_e.source_name, v_res;
  end if;
  raise notice 'fix 2b ok: copy revived the event';

  -- 3. First seen cancelled, later live ----------------------------------------
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
    jsonb_build_object('external_id', 'z', 'title', 'Back on night', 'starts_at', v_t,
                       'url', 'https://example.com/a/z', 'cancelled', true)));
  if (select event_id from public.event_imports where source_id = v_a and external_id = 'z') is not null then
    raise exception 'FAIL 3 setup: cancelled item made an event';
  end if;
  v_res := public.import_upsert_batch('test-fix-a', jsonb_build_array(v_keep,
    jsonb_build_object('external_id', 'z', 'title', 'Back on night', 'starts_at', v_t,
                       'url', 'https://example.com/a/z', 'cancelled', false)));
  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_a and ei.external_id = 'z';
  if (v_res->>'inserted')::int <> 1 or v_e.id is null or v_e.status <> 'published' or v_e.min_age <> 18 then
    raise exception 'FAIL 3 reinstated item: %', v_res;
  end if;
  raise notice 'fix 3 ok: reinstated item inserted';

  if has_function_privilege('authenticated', 'public.import_upsert_batch(text, jsonb)', 'execute')
     or has_function_privilege('anon', 'public.import_upsert_batch(text, jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.import_upsert_batch(text, jsonb)', 'execute') then
    raise exception 'FAIL import_upsert_batch grants';
  end if;
end $$;

select 'importer_review_fixes: all assertions passed' as result;

rollback;
