-- ============================================================================
-- Activity Planet schema v2 — migration 75: review fixes for migration 74
--   (20270106000100_switch_on_keys.sql). Builds on migrations 1 to 74, which
--   reached staging and are not edited. Checks:
--   supabase/tests/switch_on_review_fixes.sql.
--
--     1. Enable on create respects the source's own off switch. Migration 74's
--        before-insert trigger could not tell a row created off because the
--        call is production's (p_enable false) from one created off because
--        its seed says enabled:false, so a listed source switched off in the
--        collector before its row existed was created on (and its first
--        batch published). collector_ingest_events, rebuilt from its
--        migration 63 body (20261227000100_collector_health_geocode.sql),
--        now decides it at the insert: (p_enable or listed in
--        meta.collector_enable_on_create) and the seed is on and the slug is
--        not disc-. Nothing else in the function changes. The trigger
--        feed_sources_enable_on_create and its function are dropped; the
--        helper private.collector_enable_on_create stays.
--     2. event_share_card, rebuilt from its migration 74 body with one new
--        key, source_kind (the kind of the same source as source_attribution),
--        so the public share page can show "Tickets on <seller>" and the
--        seller's credit for Ticketmaster and SeatGeek shows. Its comment now
--        names source_attribution and source_kind.
--     3. meta.schema_version 2.71.
--
--   Account deletion: no new table and no user-referencing column.
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enable on create, at the insert (migration 63 body; the insert's enabled changed)
-- ---------------------------------------------------------------------------
drop trigger if exists feed_sources_enable_on_create on public.feed_sources;
drop function if exists private.feed_sources_enable_on_create();

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
      -- Migration 75: a source Sai approved (meta.collector_enable_on_create) is created on too,
      -- but only when its own seed is on (v_on).
      (v_slug, v_kind, v_url, v_name, v_attr, v_home,
       (coalesce(p_enable, false) or private.collector_enable_on_create(v_kind, v_slug)) and v_on and v_slug !~ '^disc-',
       v_hub, true, v_lane,
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

revoke all on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) from public, anon, authenticated;
grant execute on function public.collector_ingest_events(jsonb, jsonb, boolean, boolean, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 2. event_share_card (migration 74 body; source_kind added)
-- ---------------------------------------------------------------------------
create or replace function public.event_share_card(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select case
           when e.visibility = 'public' and e.min_age = 18 then
             jsonb_build_object(
               'id', e.id,
               'kind', e.kind,
               'title', e.title,
               'description', e.description,
               'cover_url', e.cover_url,
               'starts_at', e.starts_at,
               'ends_at', e.ends_at,
               'timezone', e.timezone,
               'min_age', e.min_age,
               'capacity', e.capacity,
               'min_headcount', e.min_headcount,
               'is_free', e.is_free,
               'price_text', e.price_text,
               'location_hint', e.location_hint,
               'approx_lat', e.approx_lat,
               'approx_lng', e.approx_lng,
               'going_count', e.going_count,
               'interested_count', e.interested_count,
               'external_url', e.external_url,
               'source_name', e.source_name,
               -- Migration 74: the listing source's attribution (open-data licences).
               'source_attribution', case when e.kind = 'imported' then
                 (select fs.attribution from public.event_imports ei
                    join public.feed_sources fs on fs.id = ei.source_id
                   where ei.event_id = e.id
                   order by ei.is_primary desc, ei.last_seen_at desc
                   limit 1) end,
               -- Migration 75: the same source's kind, so the page can show a ticket seller's
               -- link and credit (ticketSeller in @ap/core/imports).
               'source_kind', case when e.kind = 'imported' then
                 (select fs.kind from public.event_imports ei
                    join public.feed_sources fs on fs.id = ei.source_id
                   where ei.event_id = e.id
                   order by ei.is_primary desc, ei.last_seen_at desc
                   limit 1) end,
               'series_id', e.series_id,
               'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
               'chapter', case when ch.id is not null then jsonb_build_object('id', ch.id, 'slug', ch.slug, 'name', ch.name) end,
               'host', case when p.id is not null
                            then jsonb_build_object('handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url) end
             )
           else
             jsonb_build_object(
               'id', e.id,
               'restricted', case when e.visibility = 'campus' then 'campus' else 'age' end,
               'hub_name', h.name
             )
         end
    from public.events e
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.profiles p on p.id = e.host_id
   where e.id = p_event_id
     and e.status = 'published'
     and e.moderation_state is null   -- Migration 51
     and h.is_active
     and (e.host_id is null or p.status = 'active');
$$;
revoke all on function public.event_share_card(uuid) from public;
grant execute on function public.event_share_card(uuid) to anon, authenticated;
comment on function public.event_share_card(uuid) is
  'Logged-out share page and OG image. Published, public, 18+: the event fields anon may read plus host (handle, first name, avatar), hub and chapter, and for an imported event the attribution and kind of the source that lists it (source_attribution, migration 74; source_kind, migration 75; its primary import, else the latest seen). Published campus or 21+: {id, restricted: campus|age, hub_name}. Null for anything else, when the hub is not active, when the host''s account is not active, or when a moderator hid or removed the plan (migration 51).';

-- ---------------------------------------------------------------------------
-- 3. Version
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.71')
  on conflict (key) do update set value = excluded.value, updated_at = now();
