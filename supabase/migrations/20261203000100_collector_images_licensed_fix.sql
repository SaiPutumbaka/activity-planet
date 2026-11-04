-- ============================================================================
-- Activity Planet schema v2 — migration 39: collector_ingest_events
--   images_licensed fix (fix forward of migration 38,
--   20261202000100_collector_ingest_fixes.sql). The rebuilt function starts
--   from its latest body (migration 38) and changes only the line marked
--   "Migration 39". Checks: supabase/tests/collector_ingest_fixes.sql.
--
--   What this file does
--     1. collector_ingest_events (migration 38 body): a source without
--        images_licensed (every call before the Edge Function sends it, and
--        API sources) reads as false instead of null, which broke the
--        insert and update of feed_sources (images_licensed is not null).
--        Same signature and grants.
--     * meta.schema_version 2.35.
--
--   Account deletion: no new user-referencing table or column, so
--   request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

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

revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.35')
  on conflict (key) do update set value = excluded.value, updated_at = now();
