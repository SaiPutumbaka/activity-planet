-- ============================================================================
-- Activity Planet schema v2 — migration 15: importer review fixes, hash reset
--   (follow-up to 20261112000300_importer_review_fixes.sql, which is on
--   staging and is not edited; D-037).
--
--   event_imports.content_hash is NOT NULL, so the hand-off in migration 14
--   failed when it cleared the promoted copy's hash with null (staging run
--   28, supabase/tests/importer_review_fixes.sql). The copy's hash is now set
--   to '' instead: never a real sha256, so its next run still rewrites the
--   event. Otherwise identical to migration 14. Same signature and grants;
--   meta.schema_version stays 2.11.
--
--   Idempotent: safe to re-run.
-- ============================================================================

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
begin
  select * into v_src from public.feed_sources where slug = p_source_slug for update;
  if not found then
    raise exception 'source_not_found' using errcode = 'P0002';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_must_be_array' using errcode = 'check_violation';
  end if;

  -- Fallback point: the source's campus centroid, else Atlanta.
  v_origin := coalesce(
    (select c.location from public.org_campuses c where c.id = v_src.campus_id),
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
               and e.starts_at = v_start and lower(e.title) = lower(v_title)
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
                 'America/New_York', 18, v_free, v_price, 'published', 'public', 'public', v_loc,
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
           and e.starts_at = v_start and lower(e.title) = lower(v_title)
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
             'America/New_York', 18, v_free, v_price, 'published', 'public', 'public', v_loc,
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
  -- nothing at all (an empty feed is more likely an outage than a cancellation).
  if v_total > 0 then
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
           'handed_off', v_handoff),
         last_sample = coalesce((select jsonb_agg(x) from (select value as x from jsonb_array_elements(p_items) limit 2) s),
                                last_sample)
   where id = v_src.id;

  return jsonb_build_object(
    'source', v_src.slug, 'total', v_total, 'inserted', v_inserted, 'updated', v_updated,
    'unchanged', v_unchanged, 'linked_duplicates', v_linked, 'skipped', v_skipped,
    'missed', v_missed, 'cancelled', v_cancel_cnt, 'handed_off', v_handoff, 'first_error', v_first_err);
end $$;

comment on function public.import_upsert_batch(text, jsonb) is
  'Importer write path (D-037), service_role only. p_items is the complete current item set of one source. Upserts kind=imported public events (campus_id as a label: the sibling campus the item names, else the source campus; always 18+), maps hubs by import_hub_rules, skips items that break the events constraints, links exact title+start matches from another source, counts missed runs for upcoming events and cancels after two unless a linked copy from another source is still listed (that copy becomes primary), treats an item whose processing fails as seen, makes the event for a known item that becomes live and upcoming, and records the run on feed_sources. Returns counts.';

revoke all on function public.import_upsert_batch(text, jsonb) from public, anon, authenticated;
grant execute on function public.import_upsert_batch(text, jsonb) to service_role;
