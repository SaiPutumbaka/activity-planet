-- ============================================================================
-- Staging check for migration 20261112000200_importer_campus_from_item.sql.
-- An item naming a sibling campus ("*Alpharetta Campus") gets that campus as
-- its label and its centroid as the point; an item naming none keeps the
-- source campus; source coordinates still win. ROLLBACK at the end.
-- ============================================================================
begin;

do $$
declare
  v_t      timestamptz := date_trunc('hour', now()) + interval '1 day';
  v_atl    uuid := (select c.id from public.org_campuses c join public.organizations o on o.id = c.org_id
                     where o.slug = 'georgia-state' and c.slug = 'atlanta');
  v_alph   uuid := (select c.id from public.org_campuses c join public.organizations o on o.id = c.org_id
                     where o.slug = 'georgia-state' and c.slug = 'alpharetta');
  v_res    jsonb;
  v_e      public.events%rowtype;
  v_src    uuid;
begin
  insert into public.feed_sources (slug, kind, url, name, campus_id)
  values ('test-campus-item', 'engage_rss', 'https://example.com/events.rss', 'Test Campus Feed', v_atl)
  returning id into v_src;

  v_res := public.import_upsert_batch('test-campus-item', jsonb_build_array(
    jsonb_build_object('external_id', 'alph', 'title', 'Alpharetta study night', 'starts_at', v_t,
      'url', 'https://example.com/e/alph', 'categories', jsonb_build_array('Educational', '*Alpharetta Campus')),
    jsonb_build_object('external_id', 'none', 'title', 'Downtown thing', 'starts_at', v_t,
      'url', 'https://example.com/e/none', 'categories', jsonb_build_array('Social')),
    jsonb_build_object('external_id', 'pt', 'title', 'Pinned thing', 'starts_at', v_t, 'lat', 33.76, 'lng', -84.39,
      'url', 'https://example.com/e/pt', 'categories', jsonb_build_array('*Alpharetta Campus'))));
  if (v_res->>'inserted')::int <> 3 then raise exception 'FAIL inserts: %', v_res; end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'alph';
  if v_e.campus_id <> v_alph or abs(v_e.approx_lat - 34.052) > 0.001 or v_e.min_age <> 18 then
    raise exception 'FAIL named campus: campus % lat %', v_e.campus_id, v_e.approx_lat;
  end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'none';
  if v_e.campus_id <> v_atl or abs(v_e.approx_lat - 33.753) > 0.001 then
    raise exception 'FAIL default campus: campus % lat %', v_e.campus_id, v_e.approx_lat;
  end if;

  select e.* into v_e from public.events e join public.event_imports ei on ei.event_id = e.id
   where ei.source_id = v_src and ei.external_id = 'pt';
  if v_e.campus_id <> v_alph or abs(v_e.approx_lat - 33.76) > 0.0001 then
    raise exception 'FAIL source point must win: lat %', v_e.approx_lat;
  end if;

  -- Re-running the same set changes nothing.
  v_res := public.import_upsert_batch('test-campus-item', (select jsonb_agg(x) from jsonb_array_elements(jsonb_build_array(
    jsonb_build_object('external_id', 'alph', 'title', 'Alpharetta study night', 'starts_at', v_t,
      'url', 'https://example.com/e/alph', 'categories', jsonb_build_array('Educational', '*Alpharetta Campus')))) x));
  if (v_res->>'unchanged')::int <> 1 then raise exception 'FAIL re-run not idempotent: %', v_res; end if;

  if has_function_privilege('authenticated', 'public.import_upsert_batch(text, jsonb)', 'execute') then
    raise exception 'FAIL import_upsert_batch grant';
  end if;
end $$;

select 'importer_campus_from_item: all assertions passed' as result;

rollback;
