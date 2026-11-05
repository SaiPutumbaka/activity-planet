-- ============================================================================
-- Activity Planet schema v2 — migration 64: collector completion review fix.
--   Builds on migration 63 (20261227000100_collector_health_geocode.sql), which
--   reached staging and is not edited. collector_geocode_record starts from its
--   migration 63 body and changes only the line marked "Migration 64": on
--   Supabase the pg_safeupdate guard refuses a DELETE without a WHERE clause
--   ("DELETE requires a WHERE clause"), so the first nightly geocode run on
--   staging (collector-ingest run 42018066237) got a 502 when it posted its
--   answers. Checks: supabase/tests/venue_geocoding.sql (now run through the
--   Edge Function path too, by the nightly job). meta.schema_version 2.60.
--
--   Account deletion: no new table or column.
--
--   Idempotent: safe to re-run.
-- ============================================================================

create or replace function public.collector_geocode_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r        jsonb;
  v_key    text;
  v_status text;
  v_point  extensions.geography;
  v_ok     boolean;
  v_n      integer;
  v_counts jsonb := jsonb_build_object('stored', 0, 'ok', 0, 'miss', 0, 'outside_region', 0, 'events', 0);
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 500
     or exists (select 1 from jsonb_array_elements(p_results) x
                 where jsonb_typeof(x.value) <> 'object'
                    or coalesce(x.value ->> 'key', '') !~ '^[0-9a-f]{64}$'
                    or coalesce(x.value ->> 'status', '') not in ('ok', 'miss')
                    or coalesce(x.value ->> 'provider', '') not in ('place', 'venue', 'geoapify', 'nominatim', 'photon', 'none')
                    or (x.value ->> 'status' = 'ok' and (coalesce(jsonb_typeof(x.value -> 'lat'), '') <> 'number'
                                                       or coalesce(jsonb_typeof(x.value -> 'lng'), '') <> 'number'))
                    or (x.value ->> 'status' = 'ok'
                        and (case when jsonb_typeof(x.value -> 'lat') = 'number' then (x.value ->> 'lat')::double precision end not between -90 and 90
                             or case when jsonb_typeof(x.value -> 'lng') = 'number' then (x.value ->> 'lng')::double precision end not between -180 and 180))
                    or (x.value ? 'place_ref' and jsonb_typeof(x.value -> 'place_ref') <> 'null'
                        and coalesce(x.value ->> 'place_ref', '') !~ '^[A-Za-z0-9:._-]{1,80}$')
                    or (x.value ? 'confidence' and jsonb_typeof(x.value -> 'confidence') <> 'null'
                        and (jsonb_typeof(x.value -> 'confidence') <> 'number'
                             or case when jsonb_typeof(x.value -> 'confidence') = 'number'
                                     then (x.value ->> 'confidence')::double precision end not between 0 and 1))) then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  delete from public.venue_geocodes where expires_at < now() - interval '30 days';

  -- The upcoming centroid items, keyed once for this call.
  create temp table if not exists pg_temp.geo_items (import_id uuid, event_id uuid, k text,
                                                     region_point extensions.geography, radius_km integer) on commit drop;
  -- Migration 64: Supabase's safeupdate refuses a DELETE without a WHERE clause.
  delete from pg_temp.geo_items where true;
  insert into pg_temp.geo_items
  select ei.id, e.id, public.import_location_key(e.location_hint, f.region_point), f.region_point,
         coalesce(f.region_radius_km, 25)
    from public.event_imports ei
    join public.events e on e.id = ei.event_id
    join public.feed_sources f on f.id = ei.source_id
   where ei.is_primary and ei.removed_at is null and ei.point_source = 'area_centroid'
     and e.kind = 'imported' and e.starts_at > now() and f.region_point is not null
     and char_length(btrim(coalesce(e.location_hint, ''))) >= 4;

  for r in select value from jsonb_array_elements(p_results) loop
    v_key := r ->> 'key';
    v_status := r ->> 'status';
    v_point := null;
    if v_status = 'ok' then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint((r ->> 'lng')::double precision,
                                                               (r ->> 'lat')::double precision), 4326)::extensions.geography;
      -- Inside the region of the sources that list the text, else a miss.
      v_ok := exists (select 1 from pg_temp.geo_items g
                       where g.k = v_key and extensions.ST_DWithin(g.region_point, v_point, g.radius_km * 1000.0));
      if not v_ok and exists (select 1 from pg_temp.geo_items g where g.k = v_key) then
        v_status := 'miss';
        v_point := null;
        v_counts := jsonb_set(v_counts, '{outside_region}', to_jsonb((v_counts ->> 'outside_region')::int + 1));
      elsif not v_ok then
        -- No item lists the text any more: nothing to check against, keep it as a miss.
        v_status := 'miss';
        v_point := null;
      end if;
    end if;
    insert into public.venue_geocodes (key, status, point, provider, place_ref, confidence, checked_at, expires_at)
    values (v_key, v_status, v_point, r ->> 'provider', nullif(r ->> 'place_ref', ''),
            case when jsonb_typeof(r -> 'confidence') = 'number' then (r ->> 'confidence')::real end, now(),
            now() + case when v_status = 'ok' then interval '180 days' else interval '90 days' end)
    on conflict (key) do update
       set status = excluded.status, point = excluded.point, provider = excluded.provider,
           place_ref = excluded.place_ref, confidence = excluded.confidence,
           checked_at = excluded.checked_at, expires_at = excluded.expires_at;
    v_counts := jsonb_set(v_counts, '{stored}', to_jsonb((v_counts ->> 'stored')::int + 1));
    v_counts := jsonb_set(v_counts, array[v_status], to_jsonb((v_counts ->> v_status)::int + 1));
    if v_status = 'ok' then
      update public.events e set approx_point = v_point
        from pg_temp.geo_items g
       where g.k = v_key and e.id = g.event_id and e.kind = 'imported'
         and extensions.ST_DWithin(g.region_point, v_point, g.radius_km * 1000.0);
      update public.event_imports ei set point_source = 'geocoded'
        from pg_temp.geo_items g
       where g.k = v_key and ei.id = g.import_id
         and extensions.ST_DWithin(g.region_point, v_point, g.radius_km * 1000.0);
      get diagnostics v_n = row_count;
      v_counts := jsonb_set(v_counts, '{events}', to_jsonb((v_counts ->> 'events')::int + v_n));
    end if;
  end loop;
  return v_counts;
end $$;

revoke all on function public.collector_geocode_record(jsonb) from public, anon, authenticated;
grant execute on function public.collector_geocode_record(jsonb) to service_role;

insert into public.meta (key, value) values ('schema_version', '2.60')
  on conflict (key) do update set value = excluded.value, updated_at = now();
