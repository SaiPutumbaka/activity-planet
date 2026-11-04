-- ============================================================================
-- Activity Planet schema v2 — migration 38: collector ingest review fixes
--   (D-040; fix forward of migration 37,
--   20261201000100_collector_events_ingest.sql). Every rebuilt function starts
--   from its latest body (migration 37) and changes only the lines marked
--   "Migration 38". Checks: supabase/tests/collector_ingest_fixes.sql.
--
--   What this file does
--     1. feed_sources: collector_last_run_id (the job run that last posted
--        the source) and images_licensed (the seed licenses its images).
--     2. import_title_key(text) and import_is_21_plus(text): helpers.
--        import_title_key is the collector's dedupe key (title letters and
--        digits, lower case, accents dropped; the lower-cased title when
--        that leaves fewer than three characters).
--     3. import_upsert_batch (migration 37 body):
--        - an item {external_id, seen_only: true} only counts as seen
--          (skipped as listed_not_sent): the source still lists it but the
--          collector did not send it (outside the regions, past the window,
--          a duplicate within the source), so it is never missed for that;
--        - an item whose title or categories name alcohol or 21+ is skipped
--          (age_21): imported events are 18+ and cannot carry min_age 21;
--        - the cross-source match uses the collector's key: the same start
--          minute and the same import_title_key or the same URL (was the
--          exact start and lower(title)), so copies whose titles differ
--          only in punctuation or case link instead of making two events.
--        Same signature and grants.
--     4. collector_ingest_events gains p_run_id and p_seen (the 4-argument
--        version is dropped; both new arguments default to null, so the
--        old call shape still works):
--        - a second post for a source with the same run id (an HTTP retry
--          after a commit the job did not hear back from) runs as a partial
--          run, so no missed run is counted twice in one run;
--        - p_seen external ids are sent to import_upsert_batch as seen_only
--          items;
--        - descriptions are clipped to 300 characters and cover_url is
--          dropped unless the source row says images_licensed (the client
--          rules of D-040 are now enforced in the database too);
--        - enabled is written only when it changes, so a post no longer
--          fires the feed_sources_reschedule trigger (which unscheduled and
--          rescheduled every import-feed-* pg_cron job on every post).
--     5. Global keyword rules: the wine-tasting rule (never inserted: the
--        hub is 21+) is dropped if present; drawing matches figure drawing
--        and sketching only (not "prize drawing"); kayaking matches kayak,
--        paddle board and canoe (not pickleball paddles).
--     * meta.schema_version 2.34.
--
--   Account deletion: no new user-referencing table or column (feed_sources
--   holds sources, never people), so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. feed_sources columns
-- ---------------------------------------------------------------------------
alter table public.feed_sources
  add column if not exists collector_last_run_id text,
  add column if not exists images_licensed       boolean not null default false;

do $$ begin
  alter table public.feed_sources
    add constraint feed_sources_collector_last_run_id_format
      check (collector_last_run_id is null or collector_last_run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$');
exception when duplicate_object then null; end $$;

comment on column public.feed_sources.collector_last_run_id is
  'The collector job run (run_id) that last posted this source. A second post with the same run id is a retry and runs as a partial run (no missed runs counted twice).';
comment on column public.feed_sources.images_licensed is
  'The collector seed says the source licenses its images for reuse; otherwise collector_ingest_events drops every cover_url (D-040).';

-- ---------------------------------------------------------------------------
-- 2. Helpers
-- ---------------------------------------------------------------------------
-- The collector's dedupe key (packages/collector/src/filter.ts dedupeKey, without the start).
create or replace function public.import_title_key(p_title text)
returns text language sql immutable parallel safe set search_path = '' as $$
  select case when char_length(s.k) >= 3 then s.k else lower(coalesce(p_title, '')) end
    from (select regexp_replace(lower(normalize(coalesce(p_title, ''), NFKD)), '[^[:alnum:]]+', '', 'g') as k) s
$$;

comment on function public.import_title_key(text) is
  'Cross-source dedupe key for imported events: the title''s letters and digits, lower case, accents dropped (NFKD); the lower-cased title when that leaves fewer than three characters.';

-- Alcohol or an explicit 21+ in a title or categories (imported events are 18+ only).
create or replace function public.import_is_21_plus(p_text text)
returns boolean language sql immutable parallel safe set search_path = '' as $$
  select coalesce(p_text, '') ~* '(\m(wines?|winery|wineries|beers?|brewery|breweries|brewpub|brewing company|cocktails?|bourbon|whiske?y|tequila|mezcal|pub crawl|bar crawl)\M|\m21 ?\+|\m21 (and|&) (over|up)\M)'
$$;

comment on function public.import_is_21_plus(text) is
  'True when text names alcohol (wine, beer, brewery, cocktail, spirits, pub or bar crawl) or 21+. import_upsert_batch skips such items (age_21): imported events are 18+.';

-- ---------------------------------------------------------------------------
-- 3. import_upsert_batch (migration 37 body; seen-only items, 21+ skip, collector key match)
-- ---------------------------------------------------------------------------
-- p_items: the complete current set for the source, an array of
--   { external_id, title, description, starts_at, ends_at, all_day, location,
--     lat, lng, url, cover_url, is_free, price_text, categories[], host_org,
--     open_to_public, cancelled, raw }
--   or { external_id, seen_only: true } for an item listed but not sent.
-- Unknown or missing fields are tolerated; an item that cannot satisfy the
-- events constraints is skipped and counted.
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

      if v_point is not null then
        v_point_src := 'source';
      elsif v_src.campus_id is not null and v_campus_pt is not null then
        v_point := v_campus_pt; v_point_src := 'campus_centroid';
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

comment on function public.import_upsert_batch(text, jsonb) is
  'Importer write path (D-037, D-040), service_role only. p_items is the complete current item set of one source. Upserts kind=imported public events (campus_id as a label: the sibling campus the item names, else the source campus; always 18+, so items naming alcohol or 21+ are skipped as age_21; timezone from the source region, else America/New_York), maps hubs by import_hub_rules, skips items that break the events constraints, places items without a usable point on the campus centroid, else the source region point, else Atlanta, links matches from another source (same start minute and the same import_title_key or URL), counts missed runs for upcoming events and cancels after two unless a linked copy from another source is still listed (that copy becomes primary), never counts misses when app.import_partial_run is on (collector_ingest_events, a source read only in part or a repeat post in one run), treats an item whose processing fails, and a seen_only item, as seen, makes the event for a known item that becomes live and upcoming, and records the run on feed_sources. Returns counts.';

-- ---------------------------------------------------------------------------
-- 4. collector_ingest_events (migration 37 body; run id, seen ids, D-040 item rules, enabled)
-- ---------------------------------------------------------------------------
-- p_source: { slug, kind, url, name, attribution, homepage_url?, lane,
--   enabled, hubs: [hub slugs], images_licensed?, region: { lat, lng, radius_km, label, timezone } }
-- p_items: the source's complete item set from this run (import_upsert_batch's shape).
-- p_complete: false when part of the source could not be read this run (a failed fetch that
--   is not an answer); then no missed run is counted and nothing is cancelled.
-- p_enable: switch the row on (staging); false leaves enabled as it is. A seed that is off
--   always switches the row off.
-- p_run_id: the job run. A second post for the source in the same run is partial.
-- p_seen: external ids the source still lists that the job did not send.
drop function if exists public.collector_ingest_events(jsonb, jsonb, boolean, boolean);

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
  if v_kind is null or v_kind not in ('ics', 'rss', 'jsonld', 'localist', 'socrata', 'arcgis', 'ticketmaster', 'seatgeek') then
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
  v_licensed := jsonb_typeof(p_source -> 'images_licensed') = 'boolean' and (p_source ->> 'images_licensed')::boolean;

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

  if not found then
    insert into public.feed_sources
      (slug, kind, url, name, attribution, homepage_url, enabled, default_hub_id, collector, lane,
       region_point, region_radius_km, region_label, region_timezone, hub_tags, collector_seen_at,
       collector_last_run_id, images_licensed)
    values
      (v_slug, v_kind, v_url, v_name, v_attr, v_home, coalesce(p_enable, false) and v_on, v_hub, true, v_lane,
       v_point, v_radius, v_label, v_tz, v_hubs, now(),
       p_run_id, v_licensed);
    v_created := true;
  else
    -- Migration 38: the same run posting the source again is a retry.
    v_repeat := p_run_id is not null and v_row.collector_last_run_id is not distinct from p_run_id;
    -- Migration 38: enabled is not in this update (its trigger reschedules every import-feed job).
    update public.feed_sources
       set kind = v_kind, url = v_url, name = v_name, attribution = v_attr, homepage_url = v_home,
           default_hub_id = v_hub, lane = v_lane, region_point = v_point, region_radius_km = v_radius,
           region_label = v_label, region_timezone = v_tz, hub_tags = v_hubs, collector_seen_at = now(),
           collector_last_run_id = coalesce(p_run_id, collector_last_run_id), images_licensed = v_licensed
     where id = v_row.id;
    -- Migration 38: written only when it changes.
    v_enabled := case when not v_on then false
                      when coalesce(p_enable, false) then not v_row.denylisted
                      else v_row.enabled end;
    if v_enabled is distinct from v_row.enabled then
      update public.feed_sources set enabled = v_enabled where id = v_row.id;
    end if;
  end if;
  select * into v_row from public.feed_sources where slug = v_slug;

  if not v_row.enabled then
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

  return v_res || jsonb_build_object('enabled', true, 'created', v_created, 'complete', coalesce(p_complete, false),
                                     'repeat_run', v_repeat);
end $$;

comment on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) is
  'Collector ingest (D-040), service_role only (the collector Edge Function, POST /collector/ingest/events). Creates or updates the source''s feed_sources row from the seed (collector = true, kind, url, name, attribution, lane, region, hub tags, images_licensed; the first active 18+ hub tag is default_hub_id), switches it on when p_enable and off when the seed is off (enabled is written only when it changes), then, when the row is enabled, runs import_upsert_batch on p_items (descriptions clipped to 300 characters, cover_url dropped unless images_licensed) plus p_seen ids as seen_only items; p_complete false marks a partial read, and a second post with the same p_run_id is partial too, so no missed runs are counted for it. A slug owned by a non-collector source is refused. Errors: source_invalid (hint names the field), items_invalid, batch_too_large, run_id_invalid, source_not_collector. Returns import_upsert_batch''s counts plus enabled, created, complete and repeat_run.';

-- ---------------------------------------------------------------------------
-- 5. Global keyword rules
-- ---------------------------------------------------------------------------
delete from public.import_hub_rules
 where source_id is null and pattern = '\m(wine tasting)\M';

update public.import_hub_rules
   set pattern = '\m(figure drawing|sketching|life drawing|drawing class)\M'
 where source_id is null and pattern = '\m(drawing|sketching|figure drawing)\M'
   and not exists (select 1 from public.import_hub_rules x
                    where x.source_id is null and x.pattern = '\m(figure drawing|sketching|life drawing|drawing class)\M');

update public.import_hub_rules
   set pattern = '\m(kayak\w*|paddle ?board\w*|canoe\w*)\M'
 where source_id is null and pattern = '\m(kayak\w*|paddle)\M'
   and not exists (select 1 from public.import_hub_rules x
                    where x.source_id is null and x.pattern = '\m(kayak\w*|paddle ?board\w*|canoe\w*)\M');

-- ---------------------------------------------------------------------------
-- Grants (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.import_title_key(text) from public, anon, authenticated;
grant execute on function public.import_title_key(text) to service_role;
revoke all on function public.import_is_21_plus(text) from public, anon, authenticated;
grant execute on function public.import_is_21_plus(text) to service_role;
revoke all on function public.import_upsert_batch(text, jsonb) from public, anon, authenticated;
grant execute on function public.import_upsert_batch(text, jsonb) to service_role;
revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;

-- No client writes on feed_sources (moderators keep their read).
revoke insert, update, delete, truncate, references, trigger on public.feed_sources from public, anon, authenticated;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.34')
  on conflict (key) do update set value = excluded.value, updated_at = now();
