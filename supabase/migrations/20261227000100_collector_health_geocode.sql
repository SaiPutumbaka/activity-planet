-- ============================================================================
-- Activity Planet schema v2 — migration 63: collector completion, part 2
--   (docs/design/collector/COLLECTOR_COMPLETION.md sections 2.5, 2.6 and 2.9,
--   Slice 1 item 2). Venue geocoding for imported events, the collector
--   health panel with stale and failing source alerts, and discovery-queue
--   tuning. Builds on migration 62 (20261226000100_collector_completion.sql),
--   which reached staging and is not edited. Rebuilt functions start from
--   their latest bodies (named below) and each change is marked
--   "Migration 63". Checks: supabase/tests/venue_geocoding.sql,
--   supabase/tests/collector_health.sql, supabase/tests/discovery_tuning.sql.
--
--   What this file does
--     1. notification_kind gains collector_alert (its own statement, first).
--     2. venue_geocodes: the geocode cache (sha256 key of the normalised
--        location text and the source's region point rounded to 0.1 degree;
--        ok or miss; point; provider place | venue | geoapify | nominatim |
--        photon; expiry 180 days for a hit, 90 for a miss). No user id;
--        service role only. import_location_key(location, region point) is
--        the key, with a TypeScript twin in packages/collector/src/geocode/
--        key.ts tested on the same fixture strings.
--        collector_geocode_queue(p_limit) lists the distinct keys of upcoming
--        imported events still on their area centroid (location text not
--        "Online", at least 4 characters, no unexpired cache row) with the
--        region to search in; collector_geocode_record(p_results) stores the
--        answers (a point outside the region is stored as a miss) and moves
--        the matching events off the centroid (point_source geocoded, a new
--        value of event_imports_point_source). meta.collector_geocode_nominatim
--        (on | off, default on) turns the Nominatim step off without a deploy.
--     3. Rebuilt: collector_api_budget_cap (migration 48,
--        20261212000100_lane1_shows.sql; geoapify_geocode 300 a day),
--        import_upsert_batch (migration 38, 20261202000100_collector_ingest_fixes.sql:
--        the cached geocode before the area centroid).
--     4. collector_job_runs (job ingest | discovery | verify | places_extract |
--        places_files; counts only, at most 8 KB; newest 400 a job) and
--        collector_runs_record (POST /collector/runs/record).
--     5. feed_sources.collector_fail_streak and collector_ingest_events
--        (migration 62 body) counting it: a batch that read nothing or hit an
--        item error adds one, a complete batch resets it.
--     6. mod_collector_health() for moderators: sources by lane and state,
--        stale (enabled, not seen for 26 hours) and failing (streak 3 or an
--        error) sources, each job's last run and whether it is overdue,
--        regions behind (48 hours), the discovery gate's age, candidate
--        outcomes over 7 days, geocoding coverage, today's budgets, open
--        listing removals and organizer claims.
--     7. collector_health_alerts() (pg_cron hourly at minute 23): stale jobs,
--        stale or failing sources, an expired gate, a budget spent before
--        12:00 UTC: one in-app collector_alert per kind, moderator and UTC day.
--        enqueue_notification and claim_pending_notifications (migration 60,
--        20261224000100_coaching.sql) treat collector_alert as in-app only and
--        for moderators only.
--     8. Discovery tuning: source_kind_yield (view: probed and good candidates
--        by place kind and origin, all regions), source_kind_learned_yield(kind)
--        (null under 30 probes) and collector_discovery_yield() (GET
--        /collector/discovery/yield); source_candidates_record (migration 50,
--        20261214000100_discovery_review_fixes.sql) keeps the platform on every
--        outcome and waits 180 days after a second empty probe of a kind whose
--        learned yield is under 5%; source_discovery_probe_queue (same file)
--        orders by score, then Wikidata first, then fewest probes.
--     9. collector_denylist_remote() (GET /collector/denylist): the database-
--        only denylist rows (owner requests) as names and match types, and the
--        slugs of sources switched off and denylisted, for the collector's
--        in-memory denylist.
--     * meta.schema_version 2.59.
--
--   Account deletion: venue_geocodes, collector_job_runs and the yield view
--   hold no user id; collector_alert notifications are in the inbox, which
--   request_account_deletion already deletes. No change there.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enum value (its own statement, before anything uses it)
-- ---------------------------------------------------------------------------
alter type public.notification_kind add value if not exists 'collector_alert';

-- ---------------------------------------------------------------------------
-- 2. Venue geocoding
-- ---------------------------------------------------------------------------
create or replace function public.import_location_key(p_location text, p_region_point extensions.geography)
returns text language sql immutable set search_path = '' as $$
  select case when p_region_point is null or nullif(btrim(coalesce(p_location, '')), '') is null then null
    else encode(extensions.digest(
           btrim(regexp_replace(lower(p_location), '[\x01-\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]+', ' ', 'g'))
           || '|' || round(extensions.ST_Y(p_region_point::extensions.geometry)::numeric, 1)::text
           || ',' || round(extensions.ST_X(p_region_point::extensions.geometry)::numeric, 1)::text,
           'sha256'), 'hex') end;
$$;
comment on function public.import_location_key(text, extensions.geography) is
  'Migration 63: the venue_geocodes key of a location text in a source region: sha256 hex of the text lower-cased with every run of ASCII punctuation, symbols, spaces and controls turned into one space and trimmed, then "|", then the region point''s latitude and longitude rounded to 0.1 degree ("33.7,-84.4"). packages/collector/src/geocode/key.ts computes the same; both are tested on shared fixtures. Null without a text or a point.';

create table if not exists public.venue_geocodes (
  key        text primary key,
  status     text not null,
  point      extensions.geography(Point, 4326),
  provider   text not null,
  place_ref  text,
  confidence real,
  checked_at timestamptz not null default now(),
  expires_at timestamptz not null,
  constraint venue_geocodes_key_format check (key ~ '^[0-9a-f]{64}$'),
  constraint venue_geocodes_status check (status in ('ok', 'miss')),
  constraint venue_geocodes_point check ((status = 'ok') = (point is not null)),
  constraint venue_geocodes_provider check (provider in ('place', 'venue', 'geoapify', 'nominatim', 'photon', 'none')),
  constraint venue_geocodes_place_ref check (place_ref is null or place_ref ~ '^[A-Za-z0-9:._-]{1,80}$'),
  constraint venue_geocodes_confidence check (confidence is null or confidence between 0 and 1)
);
create index if not exists venue_geocodes_expires_idx on public.venue_geocodes (expires_at);
comment on table public.venue_geocodes is
  'Migration 63: geocode cache for imported venue texts (design 2.5). One row per key (import_location_key), hit or miss, so the same text is never asked twice before it expires (180 days for a hit, 90 for a miss). No user id, no text. Service role only; moderators see counts through mod_collector_health.';
alter table public.venue_geocodes enable row level security;
revoke all on public.venue_geocodes from public, anon, authenticated;
grant all on public.venue_geocodes to service_role;

alter table public.event_imports drop constraint if exists event_imports_point_source;
alter table public.event_imports add constraint event_imports_point_source
  check (point_source in ('source', 'campus_centroid', 'area_centroid', 'none', 'geocoded'));

insert into public.meta (key, value) values ('collector_geocode_nominatim', 'on')
  on conflict (key) do nothing;

create or replace function public.collector_geocode_queue(p_limit integer default 300)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'key', q.k, 'location', q.loc,
           'region', jsonb_build_object('lat', q.lat, 'lng', q.lng, 'radius_km', q.radius_km, 'timezone', q.tz))
           order by q.n desc, q.k), '[]'::jsonb)
    from (select x.k, min(x.loc) as loc, min(x.lat) as lat, min(x.lng) as lng, min(x.radius_km) as radius_km,
                 min(x.tz) as tz, count(*) as n
            from (select public.import_location_key(e.location_hint, f.region_point) as k,
                         e.location_hint as loc,
                         round(extensions.ST_Y(f.region_point::extensions.geometry)::numeric, 4)::double precision as lat,
                         round(extensions.ST_X(f.region_point::extensions.geometry)::numeric, 4)::double precision as lng,
                         coalesce(f.region_radius_km, 25) as radius_km, f.region_timezone as tz
                    from public.event_imports ei
                    join public.events e on e.id = ei.event_id
                    join public.feed_sources f on f.id = ei.source_id
                   where ei.is_primary and ei.removed_at is null and ei.point_source = 'area_centroid'
                     and e.kind = 'imported' and e.status = 'published' and e.moderation_state is null
                     and e.starts_at > now() and f.region_point is not null
                     and char_length(btrim(coalesce(e.location_hint, ''))) >= 4
                     and btrim(e.location_hint) !~* '^(online|virtual|zoom|tba|tbd|to be announced|various locations?)$') x
           where x.k is not null
             and not exists (select 1 from public.venue_geocodes g where g.key = x.k and g.expires_at > now())
           group by x.k
           order by count(*) desc, x.k
           limit greatest(1, least(coalesce(p_limit, 300), 500))) q;
$$;
comment on function public.collector_geocode_queue(integer) is
  'Migration 63, service role (GET /collector/geocode/queue): the distinct location keys of upcoming imported events still on their source''s area centroid, with a usable location text (at least 4 characters, not Online, Virtual, TBA and the like) and no unexpired venue_geocodes row: [{key, location (public listing text), region {lat, lng, radius_km, timezone}}], most events first, at most 500 (default 300).';

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
  delete from pg_temp.geo_items;
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
comment on function public.collector_geocode_record(jsonb) is
  'Migration 63, service role (POST /collector/geocode/record): stores geocode answers [{key, status ok | miss, lat?, lng?, provider place | venue | geoapify | nominatim | photon | none, place_ref?, confidence?}] (at most 500). A point outside the region of the sources listing the text is stored as a miss. Hits move the matching upcoming events off the area centroid (approx_point, event_imports.point_source geocoded). Returns counts {stored, ok, miss, outside_region, events}. Error: results_invalid.';

-- ---------------------------------------------------------------------------
-- 3. collector_api_budget_cap (migration 48 body)
-- ---------------------------------------------------------------------------
create or replace function public.collector_api_budget_cap(p_api text)
returns integer
language sql
immutable
set search_path = ''
as $$
  -- Migration 63: geoapify_geocode (venue geocoding, only with GEOAPIFY_SERVER_KEY) 300 a day.
  select case p_api when 'ticketmaster' then 1000 when 'seatgeek' then 1000 when 'geoapify_geocode' then 300 end;
$$;

-- ---------------------------------------------------------------------------
-- 3. import_upsert_batch (migration 38 body, 20261202000100_collector_ingest_fixes.sql)
-- ---------------------------------------------------------------------------
create or replace function public.import_upsert_batch(p_source_slug text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_src        public.feed_sources%rowtype;
  v_run        timestamptz := clock_timestamp();
  v_origin     extensions.geography;
  v_campus     uuid;
  v_campus_pt  extensions.geography;
  v_item       jsonb;
  v_ext        text;
  v_title      text;
  v_desc       text;
  v_start      timestamptz;
  v_end        timestamptz;
  v_url        text;
  v_cover      text;
  v_loc        text;
  v_lat        double precision;
  v_lng        double precision;
  v_point      extensions.geography;
  v_point_src  text;
  v_cats       text;
  v_host       text;
  v_public     boolean;
  v_free       boolean;
  v_price      text;
  v_cancelled  boolean;
  v_hub        uuid;
  v_hash       text;
  v_imp        public.event_imports%rowtype;
  v_event      uuid;
  v_dup        uuid;
  v_seen       text[] := '{}';
  v_total      integer := 0;
  v_inserted   integer := 0;
  v_updated    integer := 0;
  v_unchanged  integer := 0;
  v_linked     integer := 0;
  v_skipped    jsonb := '{}'::jsonb;
  v_missed     integer := 0;
  v_cancel_cnt integer := 0;
  v_handoff    integer := 0;
  v_ho_primary uuid[];
  v_ho_copy    uuid[];
  v_ho_event   uuid[];
  v_ho_source  uuid[];
  v_first_err  text;
  v_reason     text;
  v_partial    boolean := coalesce(current_setting('app.import_partial_run', true), '') = 'on';
  v_geo        extensions.geography;   -- Migration 63
begin
  select * into v_src from public.feed_sources where slug = p_source_slug for update;
  if not found then
    raise exception 'source_not_found' using errcode = 'P0002';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_must_be_array' using errcode = 'check_violation';
  end if;

  -- Fallback point: the source's campus centroid, else the area the source
  -- covers (region_point, collector sources), else Atlanta.
  v_origin := coalesce(
    (select c.location from public.org_campuses c where c.id = v_src.campus_id),
    v_src.region_point,
    (select a.center from public.areas a where a.slug = 'atlanta'));

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_total := v_total + 1;
    v_reason := null;
    begin
      v_ext := nullif(btrim(coalesce(v_item->>'external_id', '')), '');
      if v_ext is null or char_length(v_ext) > 200 then v_reason := 'bad_external_id'; end if;
      if v_reason is null and v_ext = any (v_seen) then v_reason := 'duplicate_in_batch'; end if;
      -- Seen as soon as the key is known, before any cast that could fail (review fix 1).
      if v_reason is null then v_seen := v_seen || v_ext; end if;
      -- Migration 38: an id the source still lists that the collector did not send
      -- (collector_ingest_events p_seen) only counts as seen.
      if v_reason is null and jsonb_typeof(v_item->'seen_only') = 'boolean' and (v_item->>'seen_only')::boolean then
        v_reason := 'listed_not_sent';
      end if;

      v_title := regexp_replace(btrim(coalesce(v_item->>'title', '')), '\s+', ' ', 'g');
      if v_reason is null and char_length(v_title) < 3 then v_reason := 'title_too_short'; end if;
      v_title := public.import_clip(v_title, 120);

      v_start := nullif(v_item->>'starts_at', '')::timestamptz;
      v_end   := nullif(v_item->>'ends_at', '')::timestamptz;
      if v_reason is null and v_start is null then v_reason := 'no_start'; end if;
      if v_start is not null then
        if v_end is null or v_end <= v_start then
          v_end := case when coalesce((v_item->>'all_day')::boolean, false)
                        then v_start + interval '1 day' - interval '1 minute'
                        else v_start + interval '2 hours' end;
        end if;
        if v_reason is null and v_end > v_start + interval '3 days' then v_reason := 'longer_than_3_days'; end if;
      end if;

      v_url := btrim(coalesce(v_item->>'url', ''));
      if v_reason is null and (v_url !~ '^https://' or char_length(v_url) > 2000) then v_reason := 'no_https_url'; end if;
      -- Migration 38: imported events are 18+; alcohol events (21+) are not imported until
      -- they can carry min_age 21.
      if v_reason is null and public.import_is_21_plus(concat_ws(' ', v_title,
           (select string_agg(x, ' ') from jsonb_array_elements_text(
              case when jsonb_typeof(v_item->'categories') = 'array' then v_item->'categories' else '[]'::jsonb end) x))) then
        v_reason := 'age_21';
      end if;

      if v_reason is not null then
        v_skipped := jsonb_set(v_skipped, array[v_reason], to_jsonb(coalesce((v_skipped->>v_reason)::integer, 0) + 1));
        -- A known item that is still listed but now invalid counts as seen, so it is not cancelled for it.
        if v_ext is not null and v_reason <> 'duplicate_in_batch' then
          update public.event_imports set last_seen_at = v_run, missed_runs = 0
           where source_id = v_src.id and external_id = v_ext;
        end if;
        continue;
      end if;

      v_desc  := public.import_clip(btrim(coalesce(v_item->>'description', '')), 2000);
      v_cover := nullif(btrim(coalesce(v_item->>'cover_url', '')), '');
      if v_cover is not null and (v_cover !~ '^https://' or char_length(v_cover) > 500) then v_cover := null; end if;
      v_loc   := coalesce(public.import_clip(regexp_replace(btrim(coalesce(v_item->>'location', '')), '\s+', ' ', 'g'), 120), '');
      v_cats  := coalesce((select string_agg(x, ' | ') from jsonb_array_elements_text(
                   case when jsonb_typeof(v_item->'categories') = 'array' then v_item->'categories' else '[]'::jsonb end) x), '');
      v_host  := public.import_clip(nullif(btrim(coalesce(v_item->>'host_org', '')), ''), 120);
      v_public := case when jsonb_typeof(v_item->'open_to_public') = 'boolean' then (v_item->>'open_to_public')::boolean end;
      v_free  := case when jsonb_typeof(v_item->'is_free') = 'boolean' then (v_item->>'is_free')::boolean else true end;
      v_price := public.import_clip(nullif(btrim(coalesce(v_item->>'price_text', '')), ''), 40);
      v_cancelled := coalesce(case when jsonb_typeof(v_item->'cancelled') = 'boolean' then (v_item->>'cancelled')::boolean end, false);

      -- Point: the source's coordinates when they are within 200 km of the
      -- fallback, else the campus (or Atlanta) centroid, labelled as such.
      v_lat := case when jsonb_typeof(v_item->'lat') = 'number' then (v_item->>'lat')::double precision end;
      v_lng := case when jsonb_typeof(v_item->'lng') = 'number' then (v_item->>'lng')::double precision end;
      v_point := null;
      if v_lat between -90 and 90 and v_lng between -180 and 180 and not (v_lat = 0 and v_lng = 0) then
        v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
        if v_origin is not null and not extensions.ST_DWithin(v_point, v_origin, 200000) then
          v_point := null;
        end if;
      end if;
      -- Campus label: a sibling campus of the source's campus when the item names it
      -- ("*Alpharetta Campus" in PIN categories, "Dunwoody Campus" in a location),
      -- else the source's campus. Its centroid is the fallback point.
      v_campus := null;
      v_campus_pt := null;
      if v_src.campus_id is not null then
        select c.id, c.location into v_campus, v_campus_pt
          from public.org_campuses c
         where c.org_id = (select c0.org_id from public.org_campuses c0 where c0.id = v_src.campus_id)
           and concat_ws(' ', v_cats, v_loc) ~* ('\m' || c.slug || ' campus\M')
         order by (c.id = v_src.campus_id) desc, c.slug
         limit 1;
      end if;
      if v_campus is null then
        v_campus := v_src.campus_id;
        v_campus_pt := v_origin;
      end if;

      -- Migration 63: the cached geocode of the location text in the source's region.
      v_geo := null;
      if v_point is null and v_src.region_point is not null and char_length(v_loc) >= 4 then
        select g.point into v_geo from public.venue_geocodes g
         where g.key = public.import_location_key(v_loc, v_src.region_point)
           and g.status = 'ok' and g.expires_at > now();
      end if;
      if v_point is not null then
        v_point_src := 'source';
      elsif v_src.campus_id is not null and v_campus_pt is not null then
        v_point := v_campus_pt; v_point_src := 'campus_centroid';
      -- Migration 63: a geocoded venue (venue_geocodes) before the area centroid, so a geocoded
      -- event keeps its point when its content changes.
      elsif v_geo is not null then
        v_point := v_geo; v_point_src := 'geocoded';
      elsif v_origin is not null then
        v_point := v_origin; v_point_src := 'area_centroid';
      else
        v_point_src := 'none';
      end if;

      v_hub := public.import_pick_hub(v_src.id, v_title, v_cats, v_host);
      if v_hub is null then
        raise exception 'catch_all_hub_missing';
      end if;

      v_hash := encode(extensions.digest(concat_ws(chr(31),
                  v_title, v_desc, v_start::text, v_end::text, v_url, v_cover, v_loc,
                  v_point_src, extensions.ST_AsText(v_point::extensions.geometry), v_free::text, v_price,
                  v_host, v_public::text, v_cancelled::text, v_hub::text, v_campus::text), 'sha256'), 'hex');

      select * into v_imp from public.event_imports where source_id = v_src.id and external_id = v_ext for update;

      if found then
        update public.event_imports
           set last_seen_at = v_run, missed_runs = 0,
               raw = coalesce(v_item->'raw', '{}'::jsonb),
               host_org = v_host, open_to_public = v_public
         where id = v_imp.id;

        -- A linked copy whose event was cancelled as no longer listed by the primary source
        -- takes over as primary, so the event comes back while this source lists it (fix 2).
        if v_imp.removed_at is null and not v_imp.is_primary and v_imp.event_id is not null
           and exists (select 1 from public.events e where e.id = v_imp.event_id and e.kind = 'imported'
                        and e.status = 'cancelled' and e.cancel_reason = 'No longer listed by the source.') then
          update public.event_imports set is_primary = false
           where event_id = v_imp.event_id and is_primary;
          update public.event_imports set is_primary = true, content_hash = ''
           where id = v_imp.id;
          v_imp.is_primary := true;
          v_imp.content_hash := '';
        end if;

        if v_imp.removed_at is null and v_imp.is_primary and v_imp.event_id is null then
          -- First seen cancelled or ended, so no event was made; make it once the item is
          -- live and upcoming again (fix 3).
          if v_cancelled or v_end <= now() then
            v_unchanged := v_unchanged + 1;
          else
            v_dup := null;
            select e.id into v_dup
              from public.events e
              join public.event_imports ei on ei.event_id = e.id and ei.is_primary and ei.source_id <> v_src.id
             where e.kind = 'imported' and e.status = 'published'
               -- Migration 38: the collector's key (same start minute; title letters and
               -- digits, or the same URL), not only an exact title and start.
               and e.starts_at >= date_trunc('minute', v_start) and e.starts_at < date_trunc('minute', v_start) + interval '1 minute'
               and (public.import_title_key(e.title) = public.import_title_key(v_title) or e.external_url = v_url)
             order by (lower(e.title) = lower(v_title)) desc, e.created_at
             limit 1;
            if v_dup is not null then
              update public.event_imports
                 set event_id = v_dup, is_primary = false, content_hash = v_hash, point_source = v_point_src
               where id = v_imp.id;
              v_linked := v_linked + 1;
            else
              insert into public.events
                (kind, hub_id, campus_id, host_id, series_id, title, description, cover_url, starts_at, ends_at,
                 timezone, min_age, is_free, price_text, status, visibility, address_visibility, location_hint,
                 approx_point, external_url, source_name)
              values
                ('imported', v_hub, v_campus, null, null, v_title, v_desc, v_cover, v_start, v_end,
                 coalesce(v_src.region_timezone, 'America/New_York'), 18, v_free, v_price, 'published', 'public', 'public', v_loc,
                 v_point, v_url, v_src.name)
              returning id into v_event;
              update public.event_imports
                 set event_id = v_event, content_hash = v_hash, point_source = v_point_src
               where id = v_imp.id;
              v_inserted := v_inserted + 1;
            end if;
          end if;
        elsif v_imp.removed_at is not null or not v_imp.is_primary then
          v_unchanged := v_unchanged + 1;
        elsif v_imp.content_hash = v_hash
              and not exists (select 1 from public.events e where e.id = v_imp.event_id
                               and e.status = 'cancelled' and e.cancel_reason = 'No longer listed by the source.') then
          v_unchanged := v_unchanged + 1;
        else
          update public.events
             set hub_id = v_hub, title = v_title, description = v_desc, cover_url = v_cover,
                 starts_at = v_start, ends_at = v_end, location_hint = v_loc, approx_point = v_point,
                 external_url = v_url, source_name = v_src.name, campus_id = v_campus,
                 min_age = 18, is_free = v_free, price_text = v_price,
                 status = case when v_cancelled then 'cancelled'::public.event_status else 'published'::public.event_status end,
                 cancelled_at = case when v_cancelled then coalesce(cancelled_at, now()) end,
                 cancel_reason = case when v_cancelled then 'Cancelled by the source.' end
           where id = v_imp.event_id and kind = 'imported';
          update public.event_imports
             set content_hash = v_hash, point_source = v_point_src
           where id = v_imp.id;
          v_updated := v_updated + 1;
        end if;
      else
        -- Cheap cross-source dedupe: an identical title and start from another source.
        v_dup := null;
        select e.id into v_dup
          from public.events e
          join public.event_imports ei on ei.event_id = e.id and ei.is_primary and ei.source_id <> v_src.id
         where e.kind = 'imported' and e.status = 'published'
           -- Migration 38: the collector's key (same start minute; title letters and digits,
           -- or the same URL), not only an exact title and start.
           and e.starts_at >= date_trunc('minute', v_start) and e.starts_at < date_trunc('minute', v_start) + interval '1 minute'
           and (public.import_title_key(e.title) = public.import_title_key(v_title) or e.external_url = v_url)
         order by (lower(e.title) = lower(v_title)) desc, e.created_at
         limit 1;

        if v_dup is not null then
          insert into public.event_imports
            (source_id, external_id, event_id, is_primary, content_hash, raw, host_org, open_to_public,
             point_source, first_seen_at, last_seen_at)
          values (v_src.id, v_ext, v_dup, false, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_linked := v_linked + 1;
        elsif v_cancelled or v_end <= now() then
          -- Nothing to show: remember the key, create no event.
          insert into public.event_imports
            (source_id, external_id, event_id, content_hash, raw, host_org, open_to_public, point_source,
             first_seen_at, last_seen_at)
          values (v_src.id, v_ext, null, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_unchanged := v_unchanged + 1;
        else
          insert into public.events
            (kind, hub_id, campus_id, host_id, series_id, title, description, cover_url, starts_at, ends_at,
             timezone, min_age, is_free, price_text, status, visibility, address_visibility, location_hint,
             approx_point, external_url, source_name)
          values
            ('imported', v_hub, v_campus, null, null, v_title, v_desc, v_cover, v_start, v_end,
             coalesce(v_src.region_timezone, 'America/New_York'), 18, v_free, v_price, 'published', 'public', 'public', v_loc,
             v_point, v_url, v_src.name)
          returning id into v_event;
          insert into public.event_imports
            (source_id, external_id, event_id, content_hash, raw, host_org, open_to_public, point_source,
             first_seen_at, last_seen_at)
          values (v_src.id, v_ext, v_event, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_inserted := v_inserted + 1;
        end if;
      end if;
    exception when others then
      v_skipped := jsonb_set(v_skipped, '{error}', to_jsonb(coalesce((v_skipped->>'error')::integer, 0) + 1));
      if v_first_err is null then
        v_first_err := left(coalesce(v_ext, '?') || ': ' || sqlerrm, 500);
      end if;
      -- The item's block was rolled back, its last_seen_at with it. The source still lists
      -- it, so it counts as seen and is never cancelled for an error of ours (fix 1).
      if v_ext is not null then
        begin
          update public.event_imports set last_seen_at = v_run, missed_runs = 0
           where source_id = v_src.id and external_id = v_ext;
        exception when others then
          null;
        end;
      end if;
    end;
  end loop;

  -- Missed runs: only for upcoming events, and never when the source returned
  -- nothing at all (an empty feed is more likely an outage than a cancellation)
  -- or the caller marked the set partial (app.import_partial_run, set by
  -- collector_ingest_events when part of the source could not be read).
  if v_total > 0 and not v_partial then
    with missed as (
      update public.event_imports ei
         set missed_runs = least(ei.missed_runs + 1, 100)
        from public.events e
       where ei.source_id = v_src.id
         and ei.last_seen_at < v_run
         and ei.removed_at is null
         and e.id = ei.event_id
         and e.starts_at > now()
      returning ei.id
    )
    select count(*) into v_missed from missed;

    -- Hand-off (fix 2): a primary missed twice whose event another source still lists
    -- (a linked copy seen on that source's last run) gives primary to that copy instead
    -- of cancelling. The copy's hash is set to '' (never a real sha256) so its next run rewrites the event.
    select coalesce(array_agg(h.primary_id), '{}'), coalesce(array_agg(h.copy_id), '{}'),
           coalesce(array_agg(h.event_id), '{}'), coalesce(array_agg(h.copy_source), '{}')
      into v_ho_primary, v_ho_copy, v_ho_event, v_ho_source
      from (
        select distinct on (p.id) p.id as primary_id, s.id as copy_id, p.event_id, s.source_id as copy_source
          from public.event_imports p
          join public.event_imports s
            on s.event_id = p.event_id and s.id <> p.id and not s.is_primary
           and s.removed_at is null and s.missed_runs = 0 and s.source_id <> v_src.id
         where p.source_id = v_src.id and p.is_primary and p.removed_at is null
           and p.missed_runs >= 2 and p.last_seen_at < v_run
         order by p.id, s.last_seen_at desc
      ) h;
    v_handoff := cardinality(v_ho_copy);
    if v_handoff > 0 then
      update public.event_imports set is_primary = false where id = any (v_ho_primary);
      update public.event_imports set is_primary = true, content_hash = '' where id = any (v_ho_copy);
      update public.events e set source_name = fs.name
        from unnest(v_ho_event, v_ho_source) as h(event_id, source_id)
        join public.feed_sources fs on fs.id = h.source_id
       where e.id = h.event_id and e.kind = 'imported';
    end if;

    with cancelled as (
      update public.events e
         set status = 'cancelled', cancelled_at = now(), cancel_reason = 'No longer listed by the source.'
        from public.event_imports ei
       where ei.source_id = v_src.id and ei.is_primary and ei.removed_at is null
         and ei.last_seen_at < v_run and ei.missed_runs >= 2
         and e.id = ei.event_id and e.starts_at > now()
         and e.status = 'published' and e.kind = 'imported'
         and not exists (select 1 from public.event_imports s
                          where s.event_id = e.id and s.id <> ei.id and not s.is_primary
                            and s.removed_at is null and s.missed_runs = 0)
      returning e.id
    )
    select count(*) into v_cancel_cnt from cancelled;
  end if;

  update public.feed_sources
     set last_run_at = v_run,
         last_ok_at  = v_run,
         last_error  = v_first_err,
         item_count  = v_total,
         last_stats  = jsonb_build_object(
           'total', v_total, 'inserted', v_inserted, 'updated', v_updated, 'unchanged', v_unchanged,
           'linked_duplicates', v_linked, 'skipped', v_skipped, 'missed', v_missed, 'cancelled', v_cancel_cnt,
           'handed_off', v_handoff, 'partial', v_partial),
         last_sample = coalesce((select jsonb_agg(x) from (select value as x from jsonb_array_elements(p_items) limit 2) s),
                                last_sample)
   where id = v_src.id;

  return jsonb_build_object(
    'source', v_src.slug, 'total', v_total, 'inserted', v_inserted, 'updated', v_updated,
    'unchanged', v_unchanged, 'linked_duplicates', v_linked, 'skipped', v_skipped,
    'missed', v_missed, 'cancelled', v_cancel_cnt, 'handed_off', v_handoff, 'partial', v_partial,
    'first_error', v_first_err);
end $$;

-- ---------------------------------------------------------------------------
-- 4. collector_job_runs
-- ---------------------------------------------------------------------------
create table if not exists public.collector_job_runs (
  id          bigint generated always as identity primary key,
  job         text not null,
  run_id      text not null,
  started_at  timestamptz,
  finished_at timestamptz not null default now(),
  outcome     text not null,
  stats       jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint collector_job_runs_key unique (job, run_id),
  constraint collector_job_runs_job check (job in ('ingest', 'discovery', 'verify', 'places_extract', 'places_files')),
  constraint collector_job_runs_run_id check (run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'),
  constraint collector_job_runs_outcome check (outcome in ('ok', 'partial', 'failed')),
  constraint collector_job_runs_stats check (jsonb_typeof(stats) = 'object' and pg_column_size(stats) <= 8192)
);
create index if not exists collector_job_runs_job_idx on public.collector_job_runs (job, finished_at desc);
comment on table public.collector_job_runs is
  'Migration 63: one row per run of a collector job (GitHub Actions: ingest, discovery, verify, places_extract, places_files), posted by the workflow''s last step (POST /collector/runs/record). Counts only, at most 8 KB; the newest 400 a job are kept. No user id. Moderators read; mod_collector_health and collector_health_alerts flag a job whose last run is overdue.';
alter table public.collector_job_runs enable row level security;
revoke all on public.collector_job_runs from public, anon, authenticated;
grant select on public.collector_job_runs to authenticated;   -- rows only through the moderator policy
grant all on public.collector_job_runs to service_role;
drop policy if exists "collector_job_runs_select_mod" on public.collector_job_runs;
create policy "collector_job_runs_select_mod" on public.collector_job_runs for select to authenticated
  using ((select public.is_moderator()));

create or replace function public.collector_runs_record(p_run jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_job   text := p_run ->> 'job';
  v_run   text := p_run ->> 'run_id';
  v_out   text := p_run ->> 'outcome';
  v_stats jsonb := coalesce(p_run -> 'stats', '{}'::jsonb);
  v_start timestamptz;
begin
  if p_run is null or jsonb_typeof(p_run) <> 'object'
     or coalesce(v_job, '') not in ('ingest', 'discovery', 'verify', 'places_extract', 'places_files')
     or coalesce(v_run, '') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'
     or coalesce(v_out, '') not in ('ok', 'partial', 'failed')
     or jsonb_typeof(v_stats) <> 'object' or pg_column_size(v_stats) > 8192
     -- Counts only: every stats value is a number, a boolean or a short word.
     or exists (select 1 from jsonb_each(v_stats) s
                 where s.key !~ '^[a-z0-9_]{1,40}$'
                    or not (jsonb_typeof(s.value) in ('number', 'boolean')
                            or (jsonb_typeof(s.value) = 'string' and s.value #>> '{}' ~ '^[a-z0-9_]{0,40}$'))) then
    raise exception 'run_invalid' using errcode = 'check_violation';
  end if;
  if p_run ? 'started_at' and jsonb_typeof(p_run -> 'started_at') = 'string' then
    begin
      v_start := (p_run ->> 'started_at')::timestamptz;
    exception when others then
      raise exception 'run_invalid' using errcode = 'check_violation';
    end;
    if v_start > now() + interval '5 minutes' or v_start < now() - interval '3 days' then
      v_start := null;
    end if;
  end if;
  insert into public.collector_job_runs (job, run_id, started_at, finished_at, outcome, stats)
  values (v_job, v_run, v_start, now(), v_out, v_stats)
  on conflict (job, run_id) do update
     set finished_at = now(), outcome = excluded.outcome, stats = excluded.stats,
         started_at = coalesce(excluded.started_at, public.collector_job_runs.started_at);
  delete from public.collector_job_runs j
   where j.job = v_job
     and j.id not in (select k.id from public.collector_job_runs k where k.job = v_job
                       order by k.finished_at desc, k.id desc limit 400);
  return jsonb_build_object('job', v_job, 'recorded', true);
end $$;
comment on function public.collector_runs_record(jsonb) is
  'Migration 63, service role (POST /collector/runs/record): records one run {job, run_id, outcome ok | partial | failed, started_at?, stats? (flat counts: numbers, booleans or short words, at most 8 KB)}; a second post of the same run updates it. Keeps the newest 400 runs a job. Error: run_invalid.';

-- ---------------------------------------------------------------------------
-- 5. feed_sources.collector_fail_streak
-- ---------------------------------------------------------------------------
alter table public.feed_sources add column if not exists collector_fail_streak smallint not null default 0;
do $$ begin
  alter table public.feed_sources add constraint feed_sources_fail_streak check (collector_fail_streak between 0 and 1000);
exception when duplicate_object then null; end $$;
comment on column public.feed_sources.collector_fail_streak is
  'Migration 63: collector runs in a row that read nothing (an incomplete batch with no items) or hit an item error; a complete batch resets it. 3 or more is failing on the health panel.';

-- ---------------------------------------------------------------------------
-- 8. Discovery tuning: learned yield by place kind
-- ---------------------------------------------------------------------------
create or replace view public.source_kind_yield with (security_invoker = true) as
  select coalesce(c.place_kind, 'unknown') as place_kind,
         c.origin,
         count(*) filter (where c.last_probe_at is not null)::integer as probed,
         count(*) filter (where c.status in ('probation', 'enabled'))::integer as good,
         count(*) filter (where c.status = 'rejected')::integer as rejected,
         count(*) filter (where c.status = 'discovered')::integer as waiting
    from public.source_candidates c
   group by coalesce(c.place_kind, 'unknown'), c.origin;
comment on view public.source_kind_yield is
  'Migration 63 (design 2.9): discovery candidates by place kind and origin across all regions: probed, good (probation or enabled), rejected, waiting. Security invoker: moderators read it through source_candidates'' policy; the collector reads it through collector_discovery_yield.';
revoke all on public.source_kind_yield from public, anon, authenticated;
grant select on public.source_kind_yield to authenticated, service_role;

create or replace function public.source_kind_learned_yield(p_kind text)
returns numeric language sql stable security definer set search_path = '' as $$
  select case when sum(y.probed) >= 30 then sum(y.good)::numeric / sum(y.probed) end
    from public.source_kind_yield y
   where y.place_kind = coalesce(p_kind, 'unknown');
$$;
comment on function public.source_kind_learned_yield(text) is
  'Migration 63: good over probed candidates of a place kind across every region and origin, or null while fewer than 30 were probed. Internal.';

create or replace function public.collector_discovery_yield()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'kinds', coalesce((select jsonb_object_agg(k.place_kind, jsonb_build_object('probed', k.probed, 'good', k.good))
                         from (select y.place_kind, sum(y.probed)::integer as probed, sum(y.good)::integer as good
                                 from public.source_kind_yield y group by y.place_kind) k), '{}'::jsonb),
    'origins', coalesce((select jsonb_object_agg(o.origin, jsonb_build_object('probed', o.probed, 'good', o.good))
                           from (select y.origin, sum(y.probed)::integer as probed, sum(y.good)::integer as good
                                   from public.source_kind_yield y group by y.origin) o), '{}'::jsonb),
    'platforms', coalesce((select jsonb_object_agg(p.platform, jsonb_build_object('probed', p.probed, 'good', p.good))
                             from (select c.platform, count(*)::integer as probed,
                                          count(*) filter (where c.status in ('probation', 'enabled'))::integer as good
                                     from public.source_candidates c
                                    where c.platform is not null and c.last_probe_at is not null
                                    group by c.platform) p), '{}'::jsonb));
$$;
comment on function public.collector_discovery_yield() is
  'Migration 63, service role (GET /collector/discovery/yield): probed and good candidate counts by place kind, by origin and by platform, across all regions. Counts only. The probe uses a kind''s learned yield once it has 30 probes.';

-- ---------------------------------------------------------------------------
-- 9. collector_denylist_remote
-- ---------------------------------------------------------------------------
create or replace function public.collector_denylist_remote()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'entries', coalesce((select jsonb_agg(jsonb_build_object('name', d.name, 'match', d.match) order by d.name, d.match)
                           from public.collector_denylist d where d.reason like 'owner request%'), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(f.slug order by f.slug) from public.feed_sources f
                          where f.collector and f.denylisted), '[]'::jsonb));
$$;
comment on function public.collector_denylist_remote() is
  'Migration 63, service role (GET /collector/denylist): the denylist rows that live only in the database (reason "owner request <reference>", from mod_listing_removal_resolve) as {name, match}, and the slugs of collector sources switched off and denylisted, which the collector merges into its in-memory denylist before each run. Names and slugs only, never the reason or the reference.';

-- ---------------------------------------------------------------------------
-- 5. collector_ingest_events (migration 62 body, 20261226000100_collector_completion.sql)
-- ---------------------------------------------------------------------------
create or replace function public.collector_ingest_events(
  p_source   jsonb,
  p_items    jsonb,
  p_complete boolean default true,
  p_enable   boolean default false,
  p_run_id   text default null,
  p_seen     jsonb default null
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_slug     text;
  v_kind     text;
  v_url      text;
  v_name     text;
  v_attr     text;
  v_home     text;
  v_lane     text;
  v_on       boolean;
  v_hubs     text[];
  v_hub      uuid;
  v_lat      double precision;
  v_lng      double precision;
  v_point    extensions.geography;
  v_radius   smallint;
  v_label    text;
  v_tz       text;
  v_row      public.feed_sources%rowtype;
  v_created  boolean := false;
  v_res      jsonb;
  -- Migration 38
  v_licensed boolean;
  v_repeat   boolean := false;
  v_enabled  boolean;
  v_items    jsonb;
begin
  if p_source is null or jsonb_typeof(p_source) <> 'object' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'source';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_invalid' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_items) > 2000 then
    raise exception 'batch_too_large' using errcode = 'check_violation';
  end if;
  -- Migration 38: run id and seen ids.
  if p_run_id is not null and p_run_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$' then
    raise exception 'run_id_invalid' using errcode = 'check_violation';
  end if;
  if p_seen is not null and jsonb_typeof(p_seen) <> 'null' then
    if jsonb_typeof(p_seen) <> 'array' or jsonb_array_length(p_seen) > 2000
       or exists (select 1 from jsonb_array_elements(p_seen) s
                   where jsonb_typeof(s.value) <> 'string' or char_length(s.value #>> '{}') not between 1 and 200) then
      raise exception 'items_invalid' using errcode = 'check_violation', hint = 'seen';
    end if;
  end if;

  v_slug := p_source ->> 'slug';
  if v_slug is null or v_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or char_length(v_slug) not between 3 and 60 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'slug';
  end if;
  v_kind := p_source ->> 'kind';
  -- Migration 62: eventbrite (organizer-connected accounts).
  if v_kind is null or v_kind not in ('ics', 'rss', 'jsonld', 'localist', 'socrata', 'arcgis', 'ticketmaster', 'seatgeek',
                                      'eventbrite') then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'kind';
  end if;
  v_url := p_source ->> 'url';
  if v_url is null or v_url !~ '^https://' or char_length(v_url) > 500 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'url';
  end if;
  v_name := btrim(coalesce(p_source ->> 'name', ''));
  if char_length(v_name) not between 2 and 80 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'name';
  end if;
  v_attr := btrim(coalesce(p_source ->> 'attribution', ''));
  if char_length(v_attr) not between 10 and 300 then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'attribution';
  end if;
  v_home := nullif(btrim(coalesce(p_source ->> 'homepage_url', '')), '');
  if v_home is not null and (v_home !~ '^https://' or char_length(v_home) > 500) then
    v_home := null;
  end if;
  v_lane := p_source ->> 'lane';
  if v_lane is null or v_lane not in ('api', 'feed', 'page') then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'lane';
  end if;
  if jsonb_typeof(p_source -> 'enabled') <> 'boolean' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'enabled';
  end if;
  v_on := (p_source ->> 'enabled')::boolean;
  -- Migration 38: images are kept only when the seed says they are licensed.
  -- Migration 39: false, not null, when the source does not say (feed_sources.images_licensed is not null).
  v_licensed := coalesce(jsonb_typeof(p_source -> 'images_licensed') = 'boolean' and (p_source ->> 'images_licensed')::boolean, false);

  if p_source ? 'hubs' and jsonb_typeof(p_source -> 'hubs') <> 'null' then
    if jsonb_typeof(p_source -> 'hubs') <> 'array' or jsonb_array_length(p_source -> 'hubs') > 5
       or exists (select 1 from jsonb_array_elements(p_source -> 'hubs') h
                   where jsonb_typeof(h.value) <> 'string' or h.value #>> '{}' !~ '^[a-z0-9]+(-[a-z0-9]+)*$'
                      or char_length(h.value #>> '{}') > 80) then
      raise exception 'source_invalid' using errcode = 'check_violation', hint = 'hubs';
    end if;
    v_hubs := array(select h.value #>> '{}' from jsonb_array_elements(p_source -> 'hubs') with ordinality h(value, o) order by h.o);
  else
    v_hubs := '{}';
  end if;
  -- The first hub tag that is an active 18+ hub; rules still win over it (import_pick_hub).
  select h.id into v_hub
    from unnest(v_hubs) with ordinality t(slug, o)
    join public.hubs h on h.slug = t.slug and h.is_active and h.min_age = 18
   order by t.o
   limit 1;

  if jsonb_typeof(p_source -> 'region') = 'object' then
    v_lat := case when jsonb_typeof(p_source #> '{region,lat}') = 'number' then (p_source #>> '{region,lat}')::double precision end;
    v_lng := case when jsonb_typeof(p_source #> '{region,lng}') = 'number' then (p_source #>> '{region,lng}')::double precision end;
    if v_lat between -90 and 90 and v_lng between -180 and 180 and not (v_lat = 0 and v_lng = 0) then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
    end if;
    if jsonb_typeof(p_source #> '{region,radius_km}') = 'number' then
      v_radius := least(200, greatest(1, round((p_source #>> '{region,radius_km}')::numeric)))::smallint;
    end if;
    v_label := public.import_clip(nullif(btrim(coalesce(p_source #>> '{region,label}', '')), ''), 120);
    v_tz := nullif(btrim(coalesce(p_source #>> '{region,timezone}', '')), '');
    if v_tz is not null and not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz) then
      raise exception 'source_invalid' using errcode = 'check_violation', hint = 'timezone';
    end if;
  end if;

  select * into v_row from public.feed_sources where slug = v_slug for update;
  if found and not v_row.collector then
    raise exception 'source_not_collector' using errcode = 'check_violation';
  end if;
  -- Migration 62: organizer rows are made only by connect_organizer_feed and the Eventbrite connection.
  if not found and v_slug ~ '^org-' then
    raise exception 'source_invalid' using errcode = 'check_violation', hint = 'slug';
  end if;

  if not found then
    insert into public.feed_sources
      (slug, kind, url, name, attribution, homepage_url, enabled, default_hub_id, collector, lane,
       region_point, region_radius_km, region_label, region_timezone, hub_tags, collector_seen_at,
       collector_last_run_id, images_licensed)
    values
      -- Migration 46: p_enable never turns on a discovered source (disc- slug); the lifecycle does.
      (v_slug, v_kind, v_url, v_name, v_attr, v_home, coalesce(p_enable, false) and v_on and v_slug !~ '^disc-', v_hub, true, v_lane,
       v_point, v_radius, v_label, v_tz, v_hubs, now(),
       p_run_id, v_licensed);
    v_created := true;
  else
    -- Migration 38: the same run posting the source again is a retry.
    v_repeat := p_run_id is not null and v_row.collector_last_run_id is not distinct from p_run_id;
    -- Migration 62: an organizer row keeps its URL, name, attribution, homepage and the owner's image
    -- licence; any claimed row keeps the owner's default hub.
    if v_row.origin = 'organizer' then
      v_url := v_row.url;
      v_name := v_row.name;
      v_attr := v_row.attribution;
      v_home := v_row.homepage_url;
      v_licensed := v_row.images_licensed;
    end if;
    -- Migration 38: enabled is not in this update (its trigger reschedules every import-feed job).
    update public.feed_sources
       set kind = v_kind, url = v_url, name = v_name, attribution = v_attr, homepage_url = v_home,
           default_hub_id = coalesce(v_row.organizer_hub_id, v_hub), lane = v_lane, region_point = v_point, region_radius_km = v_radius,
           region_label = v_label, region_timezone = v_tz, hub_tags = v_hubs, collector_seen_at = now(),
           collector_last_run_id = coalesce(p_run_id, collector_last_run_id), images_licensed = v_licensed,
           organizer_refresh_requested_at = null   -- Migration 62
     where id = v_row.id;
    -- Migration 38: written only when it changes.
    v_enabled := case when not v_on then false
                      -- Migration 62: stopped by the owner, or an organizer row without a verified owner.
                      when v_row.organizer_stopped_at is not null then false
                      when v_row.origin = 'organizer' and (v_row.organizer_id is null or v_row.denylisted) then false
                      -- Migration 62: a connected feed is switched on by its first good run (a complete read with items).
                      when v_row.origin = 'organizer' and not v_row.enabled then
                        coalesce(p_complete, false) and not v_repeat and jsonb_array_length(p_items) > 0
                      when v_row.origin = 'organizer' then v_row.enabled
                      -- Migration 46: a discovered source stays as the lifecycle set it.
                      when v_slug ~ '^disc-' or v_row.discovery_status is not null then v_row.enabled
                      when coalesce(p_enable, false) then not v_row.denylisted
                      else v_row.enabled end;
    if v_enabled is distinct from v_row.enabled then
      update public.feed_sources set enabled = v_enabled where id = v_row.id;
    end if;
  end if;
  select * into v_row from public.feed_sources where slug = v_slug;

  if not v_row.enabled then
    -- Migration 63: a source that is off has no streak.
    if v_row.collector_fail_streak <> 0 then
      update public.feed_sources set collector_fail_streak = 0 where id = v_row.id;
    end if;
    return jsonb_build_object('source', v_slug, 'enabled', false, 'created', v_created,
                              'complete', coalesce(p_complete, false), 'total', jsonb_array_length(p_items),
                              'repeat_run', v_repeat);
  end if;

  -- Migration 38: D-040 item rules (excerpt of at most 300 characters; images only when
  -- licensed), then the seen ids as seen_only items.
  select coalesce(jsonb_agg(
           case when jsonb_typeof(x.value) = 'object' then
             (case when v_licensed then x.value else x.value - 'cover_url' end) - 'seen_only'
             || case when jsonb_typeof(x.value -> 'description') = 'string'
                     then jsonb_build_object('description', left(x.value ->> 'description', 300))
                     else '{}'::jsonb end
           else x.value end
           order by x.o), '[]'::jsonb)
    into v_items
    from jsonb_array_elements(p_items) with ordinality x(value, o);
  if p_seen is not null and jsonb_typeof(p_seen) = 'array' then
    v_items := v_items || coalesce((select jsonb_agg(jsonb_build_object('external_id', s.value #>> '{}', 'seen_only', true) order by s.o)
                                      from jsonb_array_elements(p_seen) with ordinality s(value, o)), '[]'::jsonb);
  end if;

  perform set_config('app.import_partial_run',
    case when coalesce(p_complete, false) and not v_repeat then 'off' else 'on' end, true);
  begin
    v_res := public.import_upsert_batch(v_slug, v_items);
  exception when others then
    perform set_config('app.import_partial_run', 'off', true);
    raise;
  end;
  perform set_config('app.import_partial_run', 'off', true);

  -- Migration 63: failing streak. A batch that read nothing (incomplete with no items) or hit an
  -- item error adds one; a complete batch without errors resets it.
  if (not coalesce(p_complete, false) and jsonb_array_length(p_items) = 0) or (v_res ->> 'first_error') is not null then
    update public.feed_sources set collector_fail_streak = least(collector_fail_streak + 1, 1000) where id = v_row.id;
  elsif coalesce(p_complete, false) and not v_repeat then
    update public.feed_sources set collector_fail_streak = 0 where id = v_row.id and collector_fail_streak <> 0;
  end if;

  return v_res || jsonb_build_object('enabled', true, 'created', v_created, 'complete', coalesce(p_complete, false),
                                     'repeat_run', v_repeat);
end $$;

-- ---------------------------------------------------------------------------
-- 8. source_candidates_record (migration 50 body, 20261214000100_discovery_review_fixes.sql)
-- ---------------------------------------------------------------------------
create or replace function public.source_candidates_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r          jsonb;
  v_c        public.source_candidates%rowtype;
  v_today    date := (now() at time zone 'UTC')::date;
  v_id       uuid;
  v_run      text;
  v_out      text;
  v_kind     text;
  v_url      text;
  v_plat     text;
  v_items    integer;
  v_inreg    integer;
  v_req      integer;
  v_err      integer;
  v_complete boolean;
  v_good     boolean;
  v_status   text;
  v_reason   text;
  v_retry    timestamptz;
  v_lock     boolean;
  v_slug     text;
  v_name     text;
  v_attr     text;
  v_rpoint   extensions.geography;
  v_rradius  smallint;
  v_rlabel   text;
  v_rtz      text;
  v_chk      jsonb;
  v_counts   jsonb := jsonb_build_object('recorded', 0, 'repeat', 0, 'skipped', 0, 'unknown', 0,
                                         'probation', 0, 'enabled', 0, 'paused', 0, 'rejected', 0);
  v_int      text := '^[0-9]{1,7}$';
  v_yield    numeric;   -- Migration 63
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 500 then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  -- Every entry is checked before anything is written.
  if exists (select 1 from jsonb_array_elements(p_results) e
              where jsonb_typeof(e.value) <> 'object'
                 or coalesce(e.value ->> 'candidate_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                 or coalesce(e.value ->> 'run_id', '') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'
                 or coalesce(e.value ->> 'outcome', '') not in ('ok', 'empty', 'no_feed', 'error', 'blocked', 'robots', 'noindex', 'needs_permission', 'denylisted')
                 or (e.value ? 'kind' and jsonb_typeof(e.value -> 'kind') <> 'null' and coalesce(e.value ->> 'kind', '') not in ('ics', 'rss', 'page'))
                 or (e.value ? 'platform' and jsonb_typeof(e.value -> 'platform') <> 'null' and coalesce(e.value ->> 'platform', '') !~ '^[a-z0-9_]{1,40}$')
                 or (e.value ? 'complete' and jsonb_typeof(e.value -> 'complete') not in ('boolean', 'null'))
                 or exists (select 1 from unnest(array['items', 'in_region', 'requests', 'errors']) k
                             where e.value ? k and jsonb_typeof(e.value -> k) <> 'null'
                               and (jsonb_typeof(e.value -> k) <> 'number' or (e.value ->> k) !~ v_int))) then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;

  delete from public.source_probe_results where created_at < now() - interval '90 days';

  for r in select value from jsonb_array_elements(p_results) loop
    v_id := (r ->> 'candidate_id')::uuid;
    v_run := r ->> 'run_id';
    select * into v_c from public.source_candidates where id = v_id for update;
    if not found then
      v_counts := jsonb_set(v_counts, '{unknown}', to_jsonb((v_counts ->> 'unknown')::int + 1));
      continue;
    end if;
    if exists (select 1 from public.source_probe_results p where p.candidate_id = v_id and p.run_id = v_run) then
      v_counts := jsonb_set(v_counts, '{repeat}', to_jsonb((v_counts ->> 'repeat')::int + 1));
      continue;
    end if;
    -- Locked, moderator-rejected, unapproved and needs_permission rows take no results.
    if v_c.locked or v_c.status = 'needs_permission' or v_c.review_status in ('pending', 'rejected') then
      v_counts := jsonb_set(v_counts, '{skipped}', to_jsonb((v_counts ->> 'skipped')::int + 1));
      continue;
    end if;

    v_out := r ->> 'outcome';
    v_kind := nullif(r ->> 'kind', '');
    v_plat := nullif(r ->> 'platform', '');
    v_items := (r ->> 'items')::integer;
    v_inreg := (r ->> 'in_region')::integer;
    v_req := (r ->> 'requests')::integer;
    v_err := (r ->> 'errors')::integer;
    v_complete := coalesce((r ->> 'complete')::boolean, true);
    v_url := null;
    if r ? 'url' and jsonb_typeof(r -> 'url') = 'string' then
      v_chk := public.source_url_check(r ->> 'url');
      -- A feed on another host (a calendar vendor) is fine; source_url_check applied the denylist.
      if (v_chk ->> 'ok')::boolean then
        v_url := v_chk ->> 'url';
      elsif v_chk ->> 'error' = 'url_denylisted' then
        v_out := 'denylisted';
      end if;
    end if;
    if public.collector_host_denied(v_c.host) is not null then
      v_out := 'denylisted';
    end if;

    -- A good run (design 6.3): valid in-window items inside the region, a complete read, under
    -- 20% errors, and a feed to read next time.
    v_good := v_out = 'ok' and coalesce(v_items, 0) >= 1 and coalesce(v_inreg, 0) >= 1 and v_complete
              and (coalesce(v_req, 0) = 0 or coalesce(v_err, 0)::numeric / v_req < 0.2)
              and coalesce(v_kind, v_c.feed_kind) is not null and coalesce(v_url, v_c.feed_url) is not null;
    if v_out = 'ok' and not v_good then
      v_out := case when coalesce(v_inreg, 0) = 0 or coalesce(v_items, 0) = 0 then 'empty' else 'error' end;
    end if;

    insert into public.source_probe_results
      (candidate_id, run_id, run_on, outcome, good, feed_kind, platform, items, in_region, requests, errors, complete)
    values (v_id, v_run, v_today, v_out, v_good, v_kind, v_plat, v_items, v_inreg, v_req, v_err, v_complete);

    -- Migration 63: the platform is kept whatever the outcome, so the yield view shows which fail.
    v_c.platform := coalesce(v_plat, v_c.platform);
    v_status := v_c.status;
    v_reason := v_c.reason;
    v_retry := v_c.retry_after;
    v_lock := false;

    if v_good then
      v_c.ok_runs := v_c.ok_runs + 1;
      v_c.empty_runs := 0;
      v_c.empty_since := null;
      -- Migration 50: a good run ends a run of errors.
      v_c.error_runs := 0;
      v_c.error_since := null;
      v_c.feed_kind := coalesce(v_kind, v_c.feed_kind);
      v_c.feed_url := coalesce(v_url, v_c.feed_url);
      -- Two separate UTC days: a second good run on the same day does not count.
      if v_c.last_ok_on is distinct from v_today then
        v_c.ok_days := least(32000, v_c.ok_days + 1);
        v_c.last_ok_on := v_today;
      end if;
      v_reason := null;
      v_retry := null;
      if v_c.ok_days >= 2 then
        -- At most 40 enabled discovered sources a region (design 7).
        if v_c.status <> 'enabled' and v_c.region_id is not null
           and (select count(*) from public.source_candidates x
                 where x.region_id = v_c.region_id and x.status = 'enabled' and x.id <> v_id) >= 40 then
          v_status := 'probation';
          v_reason := 'region_cap';
        else
          v_status := 'enabled';
        end if;
      else
        v_status := 'probation';
      end if;
    elsif v_out in ('empty', 'no_feed') then
      v_c.empty_runs := v_c.empty_runs + 1;
      v_c.empty_since := coalesce(v_c.empty_since, v_today);
      if v_c.status in ('discovered', 'rejected') then
        v_status := 'rejected';
        v_reason := case when v_out = 'no_feed' then 'no_feed' else 'no_events_in_region' end;
        v_retry := now() + interval '30 days';
        -- Migration 63: a second empty probe of a kind whose learned yield is under 5% waits 180 days.
        if v_out = 'empty' and v_c.status = 'rejected' and v_c.reason = 'no_events_in_region' then
          v_yield := public.source_kind_learned_yield(v_c.place_kind);
          if v_yield is not null and v_yield < 0.05 then
            v_retry := now() + interval '180 days';
          end if;
        end if;
      elsif v_today - v_c.empty_since >= 30 then
        v_status := 'rejected';
        v_reason := 'empty_30_days';
        v_retry := now() + interval '30 days';
      elsif v_c.empty_runs >= 3 then
        v_status := 'paused';
        v_reason := 'empty_runs';
        v_retry := now() + interval '7 days';
      end if;
    elsif v_out = 'error' then
      v_c.error_runs := v_c.error_runs + 1;
      -- Migration 50: a live source that keeps failing is paused after 3 error runs with no good
      -- run between (retried weekly) and rejected after 30 days of errors (retry in 30 days).
      v_c.error_since := coalesce(v_c.error_since, v_today);
      if v_c.status in ('discovered', 'rejected') and v_c.error_runs >= 3 then
        v_status := 'rejected';
        v_reason := 'errors';
        v_retry := now() + interval '30 days';
      elsif v_c.status in ('probation', 'enabled', 'paused') and v_today - v_c.error_since >= 30 then
        v_status := 'rejected';
        v_reason := 'errors_30_days';
        v_retry := now() + interval '30 days';
      elsif v_c.status in ('probation', 'enabled', 'paused') and v_c.error_runs >= 3 then
        v_status := 'paused';
        v_reason := 'error_runs';
        v_retry := now() + interval '7 days';
      end if;
    elsif v_out = 'blocked' then
      -- 401, 403 or a bot challenge: rejected at once, never retried automatically.
      v_status := 'rejected';
      v_reason := 'blocked';
      v_retry := null;
    elsif v_out in ('robots', 'noindex') then
      v_status := 'rejected';
      v_reason := v_out;
      v_retry := now() + interval '30 days';
    elsif v_out = 'needs_permission' then
      v_status := 'needs_permission';
      v_reason := coalesce(v_plat, 'needs_permission');
      v_retry := null;
    elsif v_out = 'denylisted' then
      v_status := 'rejected';
      v_reason := 'denylisted';
      v_retry := null;
      v_lock := true;
    end if;
    if v_status = 'rejected' and v_c.status <> 'rejected' then
      v_c.ok_days := 0;
      v_c.last_ok_on := null;
    end if;

    update public.source_candidates
       set status = v_status, reason = v_reason, retry_after = v_retry, locked = locked or v_lock,
           status_at = case when v_status is distinct from status then now() else status_at end,
           ok_runs = v_c.ok_runs, empty_runs = v_c.empty_runs, error_runs = v_c.error_runs, error_since = v_c.error_since,
           ok_days = v_c.ok_days, last_ok_on = v_c.last_ok_on, empty_since = v_c.empty_since,
           feed_kind = v_c.feed_kind, feed_url = v_c.feed_url, platform = v_c.platform,
           last_probe_at = now()
     where id = v_id;

    -- The feed_sources row: created at probation (off), on only while enabled.
    v_slug := public.source_candidate_slug(v_id);
    if v_status in ('probation', 'enabled') and not exists (select 1 from public.feed_sources f where f.candidate_id = v_id) then
      v_name := coalesce(v_c.name, left(v_c.host, 80));
      v_attr := left(case when v_name = v_c.host then 'Events from ' || v_c.host
                          else 'Events from ' || v_name || ' (' || v_c.host || ')' end, 300);
      v_rpoint := null; v_rradius := null; v_rlabel := null; v_rtz := null;
      if v_c.region_id is not null then
        select g.point, g.radius_km, g.label, g.timezone into v_rpoint, v_rradius, v_rlabel, v_rtz
          from public.collector_regions g where g.id = v_c.region_id;
      end if;
      if not exists (select 1 from public.feed_sources f where f.slug = v_slug) then
        insert into public.feed_sources
          (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane,
           region_point, region_radius_km, region_label, region_timezone, discovered_from,
           discovery_status, candidate_id)
        values
          (v_slug, case v_c.feed_kind when 'page' then 'jsonld' else v_c.feed_kind end, v_c.feed_url,
           case when char_length(v_name) < 2 then v_c.host else v_name end,
           case when char_length(v_attr) < 10 then 'Events from ' || v_c.host || ' (public calendar)' else v_attr end,
           'https://' || v_c.host || '/', false, true, case v_c.feed_kind when 'page' then 'page' else 'feed' end,
           v_rpoint, v_rradius, v_rlabel, v_rtz, v_c.url,
           v_status, v_id);
      end if;
    end if;
    update public.feed_sources
       set discovery_status = v_status,
           enabled = v_status = 'enabled' and not denylisted
     where candidate_id = v_id
       and (discovery_status is distinct from v_status or enabled is distinct from (v_status = 'enabled' and not denylisted));
    if v_lock then
      update public.feed_sources set enabled = false, denylisted = true where candidate_id = v_id;
    end if;

    v_counts := jsonb_set(v_counts, '{recorded}', to_jsonb((v_counts ->> 'recorded')::int + 1));
    if v_status in ('probation', 'enabled', 'paused', 'rejected') and v_status is distinct from v_c.status then
      v_counts := jsonb_set(v_counts, array[v_status], to_jsonb((v_counts ->> v_status)::int + 1));
    end if;
  end loop;
  return v_counts;
end $$;

-- ---------------------------------------------------------------------------
-- 8. source_discovery_probe_queue (migration 50 body, same file)
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_probe_queue(
  p_probe_hash text,
  p_regions    uuid[]  default null,
  p_per_region integer default 150,
  p_limit      integer default 500)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_cap   integer := least(500, greatest(1, coalesce(p_per_region, 150)));
  v_out   jsonb;
begin
  if not public.source_discovery_gate_open(p_probe_hash) then
    raise exception 'discovery_gate_closed' using errcode = 'check_violation';
  end if;
  with probed as (
    select c.region_id, count(distinct p.candidate_id)::integer as n
      from public.source_probe_results p
      join public.source_candidates c on c.id = p.candidate_id
     where p.run_on = v_today and p.run_id like 'probe-%' and c.region_id is not null
     group by c.region_id
  ), due as (
    -- Migration 63: the stored score, then Wikidata first, then fewest previous probes.
    select c.*, row_number() over (partition by c.region_id
                                   order by c.score desc, (c.origin = 'wikidata') desc,
                                            (c.ok_runs + c.empty_runs + c.error_runs), c.created_at, c.id) as rn
      from public.source_candidates c
     where not c.locked
       and c.region_id is not null
       and c.review_status in ('none', 'approved')
       and (c.status = 'discovered' or (c.status = 'rejected' and c.retry_after is not null))
       and (c.retry_after is null or c.retry_after <= now())
       and (p_regions is null or c.region_id = any (p_regions))
       and public.source_discovery_allowed(c.origin, c.country, c.region_id)  -- Migration 50: the region's zone too
       and public.collector_host_denied(c.host) is null
  ), q as (
    select d.*, row_number() over (order by d.rn, d.score desc, (d.origin = 'wikidata') desc,
                                            (d.ok_runs + d.empty_runs + d.error_runs), d.created_at, d.id) as ord
      from due d
      left join probed p on p.region_id = d.region_id
     where d.rn <= v_cap - coalesce(p.n, 0)
     order by d.rn, d.score desc, (d.origin = 'wikidata') desc, (d.ok_runs + d.empty_runs + d.error_runs), d.created_at, d.id
     limit least(2000, greatest(1, coalesce(p_limit, 500)))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'url', q.url, 'host', q.host, 'origin', q.origin, 'region_id', q.region_id,
           'name', q.name, 'place_kind', q.place_kind, 'wikidata_id', q.wikidata_id, 'country', q.country,
           'score', q.score, 'status', q.status) order by q.ord), '[]'::jsonb)
    into v_out
    from q;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- 6. mod_collector_health
-- ---------------------------------------------------------------------------
-- How long after its last run a job counts as overdue (all are daily except verify, every 30 minutes).
create or replace function public.collector_job_stale_after(p_job text)
returns interval language sql immutable set search_path = '' as $$
  select case p_job when 'verify' then interval '2 hours' else interval '26 hours' end;
$$;
comment on function public.collector_job_stale_after(text) is 'Migration 63: the age after which a job''s last run is overdue (verify 2 hours, the daily jobs 26 hours). Internal.';

create or replace function public.collector_health_snapshot()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_day date := (now() at time zone 'UTC')::date;
begin
  return jsonb_build_object(
    'generated_at', now(),
    'sources', coalesce((select jsonb_agg(jsonb_build_object('lane', s.lane, 'state', s.state, 'count', s.n)
                                          order by s.lane, s.state)
                           from (select coalesce(f.lane, 'none') as lane,
                                        case when f.origin = 'organizer' then 'organizer'
                                             when f.discovery_status = 'probation' then 'probation'
                                             when f.enabled then 'enabled' else 'off' end as state,
                                        count(*)::integer as n
                                   from public.feed_sources f where f.collector
                                  group by 1, 2) s), '[]'::jsonb),
    'stale', coalesce((select jsonb_agg(jsonb_build_object('slug', f.slug, 'name', f.name, 'lane', f.lane,
                                                           'hours', floor(extract(epoch from (now() - coalesce(f.collector_seen_at, f.created_at))) / 3600)::integer)
                                        order by f.collector_seen_at nulls first, f.slug)
                         from (select * from public.feed_sources f
                                where f.collector and f.enabled
                                  and coalesce(f.collector_seen_at, f.created_at) < now() - interval '26 hours'
                                order by f.collector_seen_at nulls first, f.slug limit 100) f), '[]'::jsonb),
    'failing', coalesce((select jsonb_agg(jsonb_build_object('slug', f.slug, 'name', f.name, 'lane', f.lane,
                                                             'streak', f.collector_fail_streak,
                                                             'error', case when f.last_error is not null then 'item_error'
                                                                           else 'read_failed' end)
                                          order by f.collector_fail_streak desc, f.slug)
                           from (select * from public.feed_sources f
                                  where f.collector and f.enabled
                                    and (f.collector_fail_streak >= 3 or f.last_error is not null)
                                  order by f.collector_fail_streak desc, f.slug limit 100) f), '[]'::jsonb),
    'jobs', (select jsonb_object_agg(j.job,
                       case when r.finished_at is null then jsonb_build_object('last_run', null, 'overdue', false)
                            else jsonb_build_object('last_run', r.finished_at, 'outcome', r.outcome,
                                                    'overdue', r.finished_at < now() - public.collector_job_stale_after(j.job)) end)
               from unnest(array['ingest', 'discovery', 'verify', 'places_extract', 'places_files']) j(job)
               left join lateral (select x.finished_at, x.outcome from public.collector_job_runs x
                                   where x.job = j.job order by x.finished_at desc limit 1) r on true),
    'regions', jsonb_build_object(
       'total', (select count(*) from public.collector_regions),
       'behind', (select count(*) from public.collector_regions r
                   where r.last_collected_at is null or r.last_collected_at < now() - interval '48 hours')),
    'gate', (select jsonb_build_object('passed', g.passed, 'at', g.created_at,
                                       'age_days', floor(extract(epoch from (now() - g.created_at)) / 86400)::integer,
                                       'expired', g.created_at < now() - interval '30 days')
               from public.source_discovery_gates g order by g.created_at desc limit 1),
    'discovery_7d', coalesce((select jsonb_object_agg(p.outcome, p.n)
                                from (select pr.outcome, count(*)::integer as n from public.source_probe_results pr
                                       where pr.created_at > now() - interval '7 days' group by pr.outcome) p), '{}'::jsonb),
    'geocoding', jsonb_build_object(
       'upcoming', (select count(*) from public.event_imports ei join public.events e on e.id = ei.event_id
                     where ei.is_primary and e.kind = 'imported' and e.status = 'published' and e.starts_at > now()),
       'on_centroid', (select count(*) from public.event_imports ei join public.events e on e.id = ei.event_id
                        where ei.is_primary and ei.point_source = 'area_centroid' and e.kind = 'imported'
                          and e.status = 'published' and e.starts_at > now()),
       'geocoded', (select count(*) from public.event_imports ei join public.events e on e.id = ei.event_id
                     where ei.is_primary and ei.point_source = 'geocoded' and e.kind = 'imported'
                       and e.status = 'published' and e.starts_at > now()),
       'cache_ok', (select count(*) from public.venue_geocodes g where g.status = 'ok' and g.expires_at > now()),
       'cache_miss', (select count(*) from public.venue_geocodes g where g.status = 'miss' and g.expires_at > now()),
       'checked_7d', (select count(*) from public.venue_geocodes g where g.checked_at > now() - interval '7 days'),
       'nominatim', coalesce((select m.value from public.meta m where m.key = 'collector_geocode_nominatim'), 'on')),
    'budgets', coalesce((select jsonb_object_agg(b.source, jsonb_build_object('used', b.used,
                                   'cap', public.collector_api_budget_cap(regexp_replace(b.source, '_calls$', ''))))
                           from public.collector_budget b where b.day = v_day), '{}'::jsonb),
    'removals_open', (select count(*) from public.listing_removal_requests lr where lr.status = 'open'),
    'claims', jsonb_build_object(
       'pending', (select count(*) from public.organizer_claims c where c.status = 'pending'),
       'verified_unreviewed', (select count(*) from public.organizer_claims c where c.status = 'verified' and c.reviewed_at is null)));
end $$;
comment on function public.collector_health_snapshot() is 'Migration 63: the body of mod_collector_health, for it and collector_health_alerts. Internal.';

create or replace function public.mod_collector_health()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
begin
  if (select auth.uid()) is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not coalesce(public.is_moderator(), false) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return public.collector_health_snapshot();
end $$;
comment on function public.mod_collector_health() is
  'Migration 63, moderators (/admin/health, Events): {generated_at, sources [{lane, state enabled | off | probation | organizer, count}], stale [{slug, name, lane, hours}] (enabled, not seen for 26 hours), failing [{slug, name, lane, streak, error item_error | read_failed}] (streak 3 or more, or an item error; never the error text), jobs {job: {last_run, outcome, overdue}} (26 hours, verify 2), regions {total, behind} (not collected for 48 hours), gate {passed, at, age_days, expired (30 days)}, discovery_7d {outcome: count}, geocoding {upcoming, on_centroid, geocoded, cache_ok, cache_miss, checked_7d, nominatim}, budgets {source: {used, cap}} (today, UTC), removals_open, claims {pending, verified_unreviewed}}. Errors: not_authenticated, forbidden.';

-- ---------------------------------------------------------------------------
-- 7. collector_health_alerts
-- ---------------------------------------------------------------------------
create or replace function public.collector_health_alerts()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  h      jsonb := public.collector_health_snapshot();
  v_day  text := to_char((now() at time zone 'UTC')::date, 'YYYY-MM-DD');
  v_kind text;
  v_cnt  integer;
  v_mod  uuid;
  v_n    integer := 0;
  v_id   uuid;
  v_alerts jsonb := '{}'::jsonb;
begin
  -- Someone who is no longer a moderator loses unread alerts.
  delete from public.notifications n
   where n.kind = 'collector_alert' and n.read_at is null
     and not exists (select 1 from public.user_roles r where r.user_id = n.user_id and r.role in ('moderator', 'admin'));

  v_cnt := (select count(*) from jsonb_each(h -> 'jobs') j where (j.value ->> 'overdue')::boolean);
  if v_cnt > 0 then v_alerts := v_alerts || jsonb_build_object('jobs_overdue', v_cnt); end if;
  v_cnt := jsonb_array_length(h -> 'stale');
  if v_cnt > 0 then v_alerts := v_alerts || jsonb_build_object('sources_stale', v_cnt); end if;
  v_cnt := jsonb_array_length(h -> 'failing');
  if v_cnt > 0 then v_alerts := v_alerts || jsonb_build_object('sources_failing', v_cnt); end if;
  if coalesce((h #>> '{gate,expired}')::boolean, false) then
    v_alerts := v_alerts || jsonb_build_object('gate_expired', 1);
  end if;
  if extract(hour from (now() at time zone 'UTC')) < 12 then
    v_cnt := (select count(*) from jsonb_each(h -> 'budgets') b
               where (b.value ->> 'cap') is not null and (b.value ->> 'used')::int >= (b.value ->> 'cap')::int);
    if v_cnt > 0 then v_alerts := v_alerts || jsonb_build_object('budget_spent', v_cnt); end if;
  end if;

  for v_kind, v_cnt in select a.key, (a.value #>> '{}')::integer from jsonb_each(v_alerts) a loop
    for v_mod in select distinct r.user_id from public.user_roles r
                   join public.profiles p on p.id = r.user_id and p.status = 'active' and p.deleted_at is null
                  where r.role in ('moderator', 'admin') loop
      v_id := public.enqueue_notification(v_mod, 'collector_alert', 'collector_alert:' || v_kind || ':' || v_day || ':' || v_mod::text,
                                          null, null, null, null, jsonb_build_object('alert', v_kind, 'count', v_cnt));
      if v_id is not null then
        v_n := v_n + 1;
      end if;
    end loop;
  end loop;
  return v_n;
end $$;
comment on function public.collector_health_alerts() is
  'Migration 63, pg_cron collector-health-alerts hourly at minute 23: from the health snapshot, the alerts jobs_overdue, sources_stale, sources_failing, gate_expired and budget_spent (a daily budget used up before 12:00 UTC), each sent to every active moderator at most once a UTC day as an in-app collector_alert (dedupe key collector_alert:<alert>:<day>:<moderator>; payload {alert, count}, counts only). Unread alerts of people who are no longer moderators are deleted. Returns the notices added.';

-- ---------------------------------------------------------------------------
-- 7. enqueue_notification (migration 60 body, 20261224000100_coaching.sql)
-- ---------------------------------------------------------------------------
create or replace function public.enqueue_notification(
  p_user_id    uuid,
  p_kind       public.notification_kind,
  p_dedupe_key text,
  p_event_id   uuid default null,
  p_hub_id     uuid default null,
  p_chapter_id uuid default null,
  p_actor_id   uuid default null,
  p_payload    jsonb default '{}'::jsonb,
  p_batch      boolean default false)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  np           public.notification_prefs%rowtype;
  v_topic      boolean;
  v_email      public.notification_channel_status;
  v_push       public.notification_channel_status;
  v_push_after timestamptz;
  v_tz         text;
  v_now_local  timestamp;
  v_local      time;
  v_quiet      boolean;
  v_id         uuid;
  v_joiner     text;
begin
  if p_user_id is null or p_kind is null or nullif(btrim(coalesce(p_dedupe_key, '')), '') is null then
    return null;
  end if;
  if not exists (select 1 from public.profiles
                  where id = p_user_id and status = 'active' and deleted_at is null) then
    return null;
  end if;
  -- Migration 63: collector alerts go to moderators only.
  if p_kind = 'collector_alert' and not exists (
       select 1 from public.user_roles r where r.user_id = p_user_id and r.role in ('moderator', 'admin')) then
    return null;
  end if;
  -- Migration 51: across a block, social notices are dropped and every other
  -- notice loses its actor; a mute drops the social notices.
  if p_actor_id is not null and p_actor_id <> p_user_id then
    if public.users_blocked(p_user_id, p_actor_id) then
      -- Migration 58: message and message_request are social too.
      if p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request') then
        return null;
      end if;
      p_actor_id := null;
    elsif p_kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request')
          and exists (select 1 from public.mutes m where m.muter_id = p_user_id and m.muted_id = p_actor_id) then
      return null;
    end if;
  end if;

  select * into np from public.notification_prefs where user_id = p_user_id;
  -- Topic switches; confirmations of the person's own actions and claim
  -- reviews are transactional and follow only the channel switches.
  v_topic := case
    when p_kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
    when p_kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
    when p_kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
    when p_kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
    when p_kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
    -- Migration 60: booking reminders, review prompts and review notices follow bookings;
    -- confirmations, declines, cancellations and payment due are transactional.
    when p_kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)
    else true
  end;
  v_email := case when np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic
                       -- Migration 58: chat notices never go by email (the daily cap is for plans).
                       or p_kind in ('message', 'message_request')
                       -- Migration 60: of the booking kinds only requested, confirmed, cancelled and
                       -- payment due are emailed (logistics).
                       or p_kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action')
                       -- Migration 63: collector alerts are in-app only (moderators).
                       or p_kind = 'collector_alert'
                  then 'skipped' else 'pending' end;
  v_push  := case when np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic
                       or p_kind = 'collector_alert'   -- Migration 63
                  then 'skipped' else 'pending' end;

  if v_push = 'pending' and np.quiet_start is not null and np.quiet_end is not null
     and np.quiet_start <> np.quiet_end then
    v_tz := case when public.is_valid_timezone(np.timezone) then np.timezone else 'America/New_York' end;
    v_now_local := now() at time zone v_tz;
    v_local := v_now_local::time;
    v_quiet := case when np.quiet_start < np.quiet_end
                    then v_local >= np.quiet_start and v_local < np.quiet_end
                    else v_local >= np.quiet_start or v_local < np.quiet_end end;
    if v_quiet then
      v_push_after := ((v_now_local::date + np.quiet_end)
                       + case when np.quiet_end <= v_local then interval '1 day' else interval '0' end)
                      at time zone v_tz;
    end if;
  end if;

  if p_batch and p_kind = 'message' then
    -- Migration 58: a burst of messages is one row; count is the number of
    -- messages, seq the newest, actor the latest sender. Seen again on news.
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb) || jsonb_build_object('count', 1),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'count', coalesce((n.payload ->> 'count')::integer, 1) + 1,
                        'seq', coalesce(p_payload -> 'seq', n.payload -> 'seq')),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
    returning n.id into v_id;
  elsif p_batch then
    -- joiners: md5(dedupe_key || ':' || actor) per distinct actor, so the set
    -- never stores a user id (account deletion needs no payload scrub).
    v_joiner := md5(p_dedupe_key || ':' || coalesce(p_actor_id::text, ''));
    insert into public.notifications as n
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id,
            coalesce(p_payload, '{}'::jsonb)
              || jsonb_build_object('count', 1, 'joiners', jsonb_build_array(v_joiner)),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do update
       set payload  = n.payload || jsonb_build_object(
                        'joiners', coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))
                                   || to_jsonb(v_joiner),
                        'count', jsonb_array_length(coalesce(n.payload -> 'joiners',
                                            jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, ''))))) + 1),
           actor_id = excluded.actor_id,
           read_at  = null,
           seen_at  = null
     where p_actor_id is not null
       and not (coalesce(n.payload -> 'joiners',
                         jsonb_build_array(md5(n.dedupe_key || ':' || coalesce(n.actor_id::text, '')))) ? v_joiner)
    returning n.id into v_id;
  else
    insert into public.notifications
      (user_id, kind, event_id, hub_id, chapter_id, actor_id, payload, dedupe_key, email_status, push_status, push_after)
    values (p_user_id, p_kind, p_event_id, p_hub_id, p_chapter_id, p_actor_id, coalesce(p_payload, '{}'::jsonb),
            p_dedupe_key, v_email, v_push, v_push_after)
    on conflict (dedupe_key) do nothing
    returning id into v_id;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 7. claim_pending_notifications (migration 60 body, same file)
-- ---------------------------------------------------------------------------
create or replace function public.claim_pending_notifications(p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_limit     integer := greatest(1, least(coalesce(p_limit, 50), 100));
  v_cap       integer;
  v_day       date := (now() at time zone 'UTC')::date;
  v_reserved  integer;
  n           public.notifications%rowtype;
  np          public.notification_prefs%rowtype;
  e           public.events%rowtype;
  v_email     boolean;
  v_push      boolean;
  v_email_st  public.notification_channel_status;
  v_push_st   public.notification_channel_status;
  v_push_aft  timestamptz;
  v_err       text;
  v_topic     boolean;
  v_social    boolean;
  v_blocked   boolean;
  v_actor     text;
  v_quiet     timestamptz;
  v_to        text;
  v_devices   jsonb;
  v_out       jsonb := '[]'::jsonb;
  v_conv      uuid;   -- Migration 58
  v_bk        uuid;   -- Migration 60
begin
  -- Expire what is too old to be useful (in-app keeps it).
  update public.notifications
     set email_status = case when email_status = 'pending' then 'skipped'::public.notification_channel_status else email_status end,
         push_status  = case when push_status  = 'pending' then 'skipped'::public.notification_channel_status else push_status end,
         last_error   = 'expired',
         claimed_at   = null
   where (email_status = 'pending' or push_status = 'pending')
     and created_at < now() - interval '2 days';

  v_cap := coalesce((select case when value ~ '^\d{1,5}$' then value::integer end
                       from public.meta where key = 'notify_email_daily_cap'), 90);
  insert into public.notification_email_days (day) values (v_day) on conflict (day) do nothing;
  select reserved into v_reserved from public.notification_email_days where day = v_day for update;

  for n in
    select * from public.notifications x
     where (x.email_status = 'pending'
            or (x.push_status = 'pending' and (x.push_after is null or x.push_after <= now())))
       and (x.claimed_at is null or x.claimed_at < now() - interval '10 minutes')
     order by x.created_at
     limit v_limit
     for update skip locked
  loop
    v_email_st := n.email_status;
    v_push_st  := n.push_status;
    v_push_aft := n.push_after;
    v_err := null;
    v_email := n.email_status = 'pending';
    v_push := n.push_status = 'pending' and (n.push_after is null or n.push_after <= now());

    -- Five tries per channel, then failed.
    if n.attempts >= 5 then
      if v_email then v_email_st := 'failed'; end if;
      if v_push then v_push_st := 'failed'; end if;
      v_email := false; v_push := false; v_err := 'too_many_attempts';
    end if;

    -- Migration 63: collector alerts are in-app only; never email or push, whatever the row says.
    if (v_email or v_push) and n.kind = 'collector_alert' then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'in_app_only';
    end if;

    -- Seen in the app already: nothing to send.
    if (v_email or v_push) and n.read_at is not null then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'read_in_app';
    end if;

    -- The recipient, and their prefs as they are now.
    if (v_email or v_push) and not exists (
         select 1 from public.profiles p
          where p.id = n.user_id and p.status = 'active' and p.deleted_at is null) then
      if v_email then v_email_st := 'skipped'; end if;
      if v_push then v_push_st := 'skipped'; end if;
      v_email := false; v_push := false; v_err := 'inactive_recipient';
    end if;

    if v_email or v_push then
      select * into np from public.notification_prefs where user_id = n.user_id;
      v_topic := case
        when n.kind in ('event_reminder_day', 'event_reminder_2h') then coalesce(np.event_reminders, true)
        when n.kind in ('event_cancelled', 'event_updated', 'broadcast') then coalesce(np.event_updates, true)
        when n.kind in ('attendee_joined', 'hub_new_event') then coalesce(np.hub_activity, true)
        when n.kind = 'checkin_prompt' then coalesce(np.checkin_prompts, true)
        when n.kind in ('message', 'message_request') then coalesce(np.messages, true)   -- Migration 58
        when n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt', 'review_received', 'review_reply') then coalesce(np.bookings, true)   -- Migration 60
        else true
      end;
      if v_email and (np.unsubscribed_all_at is not null or not coalesce(np.email_enabled, true) or not v_topic) then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      if v_push and (np.unsubscribed_all_at is not null or not coalesce(np.push_enabled, true) or not v_topic) then
        v_push_st := 'skipped'; v_push := false; v_err := 'prefs';
      end if;
    end if;

    -- Never across a block (or to a muter, for the social notices).
    -- Migration 56: the same rule as enqueue_notification (migration 51). Only
    -- attendee_joined and hub_new_event are social; every other notice,
    -- broadcast included (it may carry plan logistics), still goes across a
    -- block or a mute but never names the actor.
    v_actor := null;
    if (v_email or v_push) and n.actor_id is not null and n.actor_id <> n.user_id then
      v_social := n.kind in ('attendee_joined', 'hub_new_event', 'message', 'message_request');   -- Migration 58
      v_blocked := public.users_blocked(n.user_id, n.actor_id);
      if v_social and (v_blocked or exists (select 1 from public.mutes m
                                             where m.muter_id = n.user_id and m.muted_id = n.actor_id)) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'blocked';
      elsif not v_blocked then
        select p.first_name into v_actor from public.profiles p
         where p.id = n.actor_id and p.status = 'active' and p.deleted_at is null and p.moderation_state is null;
      end if;
    end if;

    -- Stale plan notices. Migration 56: every notice about a plan (all but
    -- event_cancelled, which is the news itself) is skipped once the plan is
    -- gone, moderated or cancelled, so a removed title never goes out; the
    -- already-started check stays for reminders only.
    if (v_email or v_push) and n.event_id is not null and n.kind <> 'event_cancelled' then
      select * into e from public.events where id = n.event_id;
      if not found or e.moderation_state is not null
         or e.status = 'cancelled'
         or (n.kind in ('event_reminder_day', 'event_reminder_2h') and e.starts_at <= now()) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Migration 58: chat notices. Never email; nothing once the conversation
    -- is gone, closed or muted now, or the member has read up to its seq.
    if (v_email or v_push) and n.kind in ('message', 'message_request') then
      if v_email then
        v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
      end if;
      v_conv := case when n.payload ->> 'conversation_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                     then (n.payload ->> 'conversation_id')::uuid end;
      if v_push and (
           not exists (select 1 from public.conversations c where c.id = v_conv and c.closed_at is null)
           or exists (select 1 from public.conversation_members cm
                       where cm.conversation_id = v_conv and cm.user_id = n.user_id
                         and (cm.muted_until > now() or cm.removed_at is not null or cm.left_at is not null
                              or (n.kind = 'message' and n.payload ->> 'seq' ~ '^\d{1,18}$'
                                  and cm.last_read_seq >= (n.payload ->> 'seq')::bigint)))) then
        v_push_st := 'skipped'; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Migration 60: booking notices. Email only for requested, confirmed, cancelled and payment
    -- due; reminders, payment due and review prompts are skipped once the booking moved on.
    if v_email and n.kind in ('booking_declined', 'booking_reminder_day', 'booking_reminder_2h', 'booking_review_prompt',
                                      'booking_no_show', 'review_received', 'review_reply', 'coach_payout_action') then
      v_email_st := 'skipped'; v_email := false; v_err := 'prefs';
    end if;
    if (v_email or v_push) and n.kind in ('booking_reminder_day', 'booking_reminder_2h', 'booking_payment_due',
                                          'booking_review_prompt') then
      v_bk := case when n.payload ->> 'booking_id' ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
                   then (n.payload ->> 'booking_id')::uuid end;
      if not exists (
           select 1 from public.bookings b
            where b.id = v_bk
              and ((n.kind in ('booking_reminder_day', 'booking_reminder_2h') and b.status = 'confirmed' and b.starts_at > now())
                   or (n.kind = 'booking_payment_due'
                       and (n.payload ? 'fallback' or (b.status = 'confirmed' and b.payment_state in ('due', 'processing'))))
                   or (n.kind = 'booking_review_prompt' and b.status = 'completed'
                       and not exists (select 1 from public.coach_reviews r where r.booking_id = b.id)))) then
        if v_email then v_email_st := 'skipped'; end if;
        if v_push then v_push_st := 'skipped'; end if;
        v_email := false; v_push := false; v_err := 'stale';
      end if;
    end if;

    -- Quiet hours, as set now (push waits, never dropped).
    if v_push then
      v_quiet := public.notification_quiet_until(n.user_id);
      if v_quiet is not null then
        v_push_aft := v_quiet; v_push := false;
      end if;
    end if;

    -- Email: a confirmed address and room under the daily cap.
    v_to := null;
    if v_email then
      select u.email into v_to from auth.users u
       where u.id = n.user_id and u.email_confirmed_at is not null and u.email is not null and u.email <> '';
      if v_to is null then
        v_email_st := 'skipped'; v_email := false; v_err := 'no_confirmed_email';
      elsif v_reserved >= v_cap then
        v_email_st := 'skipped'; v_email := false; v_err := 'daily_cap';
      else
        v_reserved := v_reserved + 1;
      end if;
    end if;

    -- Push: live web devices on an allowed service.
    v_devices := null;
    if v_push then
      select coalesce(jsonb_agg(jsonb_build_object(
               'device_id', d.id,
               'endpoint', d.subscription ->> 'endpoint',
               'p256dh', d.subscription #>> '{keys,p256dh}',
               'auth', d.subscription #>> '{keys,auth}') order by d.last_seen_at desc), '[]'::jsonb)
        into v_devices
        from (select * from public.push_devices pd
               where pd.user_id = n.user_id and pd.revoked_at is null and pd.platform = 'web'
                 and public.push_endpoint_allowed(pd.subscription ->> 'endpoint')
                 and pd.subscription #>> '{keys,p256dh}' is not null
                 and pd.subscription #>> '{keys,auth}' is not null
               order by pd.last_seen_at desc limit 10) d;
      if jsonb_array_length(v_devices) = 0 then
        v_push_st := 'skipped'; v_push := false; v_devices := null;
        v_err := coalesce(v_err, 'no_device');
      end if;
    end if;

    update public.notifications
       set email_status = v_email_st,
           push_status  = v_push_st,
           push_after   = v_push_aft,
           claimed_at   = case when v_email or v_push then now() else null end,
           attempts     = attempts + case when v_email or v_push then 1 else 0 end,
           last_error   = coalesce(v_err, last_error)
     where id = n.id;

    if v_email or v_push then
      v_out := v_out || jsonb_build_array(jsonb_build_object(
        'id', n.id,
        'kind', n.kind,
        'created_at', n.created_at,
        'event_id', n.event_id,
        'payload', n.payload - 'joiners',
        'actor_name', v_actor,
        'hub', (select jsonb_build_object('slug', h.slug, 'name', h.name) from public.hubs h where h.id = n.hub_id),
        'chapter', (select jsonb_build_object('slug', c.slug, 'name', c.name) from public.hub_chapters c where c.id = n.chapter_id),
        'email', case when v_email then jsonb_build_object(
                   'to', v_to, 'unsubscribe_token', public.notification_unsubscribe_token(n.user_id)) end,
        'push', case when v_push then v_devices end));
    end if;
  end loop;

  update public.notification_email_days set reserved = v_reserved where day = v_day;
  return v_out;
end $$;

-- ---------------------------------------------------------------------------
-- pg_cron
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; collector-health-alerts not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'collector-health-alerts') then
    perform cron.unschedule('collector-health-alerts');
  end if;
  perform cron.schedule('collector-health-alerts', '23 * * * *', 'select public.collector_health_alerts()');
end $$;

-- ---------------------------------------------------------------------------
-- Privileges (explicit) and version stamp (last)
-- ---------------------------------------------------------------------------
revoke all on function public.import_location_key(text, extensions.geography) from public, anon, authenticated;
grant execute on function public.import_location_key(text, extensions.geography) to service_role;
revoke all on function public.collector_geocode_queue(integer) from public, anon, authenticated;
grant execute on function public.collector_geocode_queue(integer) to service_role;
revoke all on function public.collector_geocode_record(jsonb) from public, anon, authenticated;
grant execute on function public.collector_geocode_record(jsonb) to service_role;
revoke all on function public.collector_runs_record(jsonb) from public, anon, authenticated;
grant execute on function public.collector_runs_record(jsonb) to service_role;
revoke all on function public.source_kind_learned_yield(text) from public, anon, authenticated;
grant execute on function public.source_kind_learned_yield(text) to service_role;
revoke all on function public.collector_discovery_yield() from public, anon, authenticated;
grant execute on function public.collector_discovery_yield() to service_role;
revoke all on function public.collector_denylist_remote() from public, anon, authenticated;
grant execute on function public.collector_denylist_remote() to service_role;
revoke all on function public.collector_job_stale_after(text) from public, anon, authenticated;
revoke all on function public.collector_health_snapshot() from public, anon, authenticated;
revoke all on function public.collector_health_alerts() from public, anon, authenticated;
grant execute on function public.collector_health_alerts() to service_role;
revoke all on function public.mod_collector_health() from public, anon;
grant execute on function public.mod_collector_health() to authenticated;
-- Rebuilt.
revoke all on function public.collector_api_budget_cap(text) from public, anon, authenticated;
grant execute on function public.collector_api_budget_cap(text) to service_role;
revoke all on function public.import_upsert_batch(text, jsonb) from public, anon, authenticated;
grant execute on function public.import_upsert_batch(text, jsonb) to service_role;
revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;
revoke all on function public.source_candidates_record(jsonb) from public, anon, authenticated;
grant execute on function public.source_candidates_record(jsonb) to service_role;
revoke all on function public.source_discovery_probe_queue(text, uuid[], integer, integer) from public, anon, authenticated;
grant execute on function public.source_discovery_probe_queue(text, uuid[], integer, integer) to service_role;
revoke all on function public.enqueue_notification(uuid, public.notification_kind, text, uuid, uuid, uuid, uuid, jsonb, boolean)
  from public, anon, authenticated;
revoke all on function public.claim_pending_notifications(integer) from public, anon, authenticated;
grant execute on function public.claim_pending_notifications(integer) to service_role;

insert into public.meta (key, value) values ('schema_version', '2.59')
  on conflict (key) do update set value = excluded.value, updated_at = now();
