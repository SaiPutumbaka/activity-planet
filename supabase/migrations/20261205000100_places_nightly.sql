-- ============================================================================
-- Activity Planet schema v2 — migration 41: the nightly places run for wanted
--   tiles worldwide (D-042 slice 2, docs/design/auto-coverage/
--   AUTO_COVERAGE_DESIGN.md sections 5.1 and 10). Two functions are rebuilt
--   from their latest bodies and change only the lines marked "Migration 41":
--   place_tiles_queue (migration 28, 20261123000100_places_ingest.sql) and
--   map_in_view (migration 32, 20261126000100_map_ui_fields.sql).
--   Checks: supabase/tests/places_nightly.sql.
--
--   What this file does
--     1. place_tiles.queue_reason: why a wanted or filling tile was not built
--        on the last nightly run: budget (more tiles or downloads than one
--        night allows), size_cap (the places table or the database would pass
--        its cap) or extract_too_big (the smallest Geofabrik extract holding
--        the tile is over 3 GB). Null when the tile is due on the next run.
--        A trigger clears it whenever the tile leaves wanted/filling (an OSM
--        run made it active, or it went idle or retired). No user id.
--     2. place_tiles_set_queue_reasons({tile_id: reason or null}),
--        service_role only: the extract job records the reasons after each
--        run (a tile it built or planned clears; one it deferred gets its
--        reason). Only wanted and filling tiles change. Returns counts.
--     3. place_tiles_mapping_reason_in_view(env1, env2), security definer,
--        STABLE: for tiles in view that are still being mapped, null when one
--        of them is due on the next run, else the mildest reason (budget,
--        then size_cap, then extract_too_big). Returns only that word; never
--        a tile id, count or demand.
--     4. place_tiles_queue (migration 28 body): the wanted kind also takes
--        filling tiles (an idle tile with no OSM run wakes as filling,
--        migration 40, and was never queued); tiles with no OSM run come
--        before refreshes; each entry carries queue_reason. Nothing else.
--     5. map_in_view (migration 32 body): adds mapping_reason (3) next to
--        mapping, only when mapping is true. Same arguments, security
--        invoker, STABLE, grants. Nothing else.
--     * meta.schema_version 2.37.
--
--   Account deletion: no user-referencing table or column (place_tiles has
--   no user id), so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_tiles.queue_reason
-- ---------------------------------------------------------------------------
alter table public.place_tiles add column if not exists queue_reason text;
do $$ begin
  alter table public.place_tiles add constraint place_tiles_queue_reason_values
    check (queue_reason is null or queue_reason in ('budget', 'size_cap', 'extract_too_big'));
exception when duplicate_object then null; end $$;

comment on column public.place_tiles.queue_reason is
  'Why the last nightly places run did not build this wanted or filling tile (D-042 slice 2): budget, size_cap or extract_too_big; null when it is due on the next run. Set by place_tiles_set_queue_reasons; cleared when the tile leaves wanted/filling. The map shows it as mapping_reason.';

create or replace function public.place_tiles_clear_queue_reason()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.status not in ('wanted', 'filling') then
    new.queue_reason := null;
  end if;
  return new;
end $$;
comment on function public.place_tiles_clear_queue_reason() is
  'Trigger: clears place_tiles.queue_reason when a tile is no longer wanted or filling (D-042 slice 2).';

drop trigger if exists place_tiles_clear_queue_reason on public.place_tiles;
create trigger place_tiles_clear_queue_reason
  before insert or update on public.place_tiles
  for each row execute function public.place_tiles_clear_queue_reason();

revoke all on function public.place_tiles_clear_queue_reason() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. place_tiles_set_queue_reasons
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_set_queue_reasons(p_reasons jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_set     integer := 0;
  v_cleared integer := 0;
  v_total   integer;
begin
  if p_reasons is null or jsonb_typeof(p_reasons) <> 'object' then
    raise exception 'invalid_reasons' using errcode = 'check_violation', hint = 'An object of tile id to reason or null.';
  end if;
  select count(*) into v_total from jsonb_each(p_reasons);
  if v_total > 2000 then
    raise exception 'too_many_tiles' using errcode = 'check_violation', hint = 'At most 2,000 tiles a call.';
  end if;
  if exists (select 1 from jsonb_each(p_reasons) e
              where e.key !~ '^[0-9]{1,6}$' or e.key::integer > 259199
                 or not (jsonb_typeof(e.value) = 'null'
                         or (jsonb_typeof(e.value) = 'string'
                             and e.value #>> '{}' in ('budget', 'size_cap', 'extract_too_big')))) then
    raise exception 'invalid_reasons' using errcode = 'check_violation',
      hint = 'Tile ids 0 to 259199; reasons budget, size_cap, extract_too_big or null.';
  end if;

  with r as (
    select e.key::integer as id, e.value #>> '{}' as reason from jsonb_each(p_reasons) e
  ), u as (
    update public.place_tiles t
       set queue_reason = r.reason
      from r
     where t.id = r.id
       and t.status in ('wanted', 'filling')
       and t.queue_reason is distinct from r.reason
    returning r.reason
  )
  select count(*) filter (where u.reason is not null), count(*) filter (where u.reason is null)
    into v_set, v_cleared from u;

  return jsonb_build_object('tiles', v_total, 'set', v_set, 'cleared', v_cleared,
                            'unchanged', v_total - v_set - v_cleared);
end $$;

comment on function public.place_tiles_set_queue_reasons(jsonb) is
  'Nightly places run (D-042 slice 2), service_role only: {tile_id: budget | size_cap | extract_too_big | null}. Sets or clears queue_reason on wanted and filling tiles; other tiles and unknown ids are left alone. Returns counts only.';

revoke all on function public.place_tiles_set_queue_reasons(jsonb) from public, anon, authenticated;
grant execute on function public.place_tiles_set_queue_reasons(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 3. place_tiles_mapping_reason_in_view
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_mapping_reason_in_view(p_env1 extensions.geometry, p_env2 extensions.geometry)
returns text language sql stable security definer set search_path = '' as $$
  select case min(case t.queue_reason when 'budget' then 1 when 'size_cap' then 2
                                      when 'extract_too_big' then 3 else 0 end)
           when 1 then 'budget' when 2 then 'size_cap' when 3 then 'extract_too_big' end
    from public.place_tiles t
   where t.status in ('wanted', 'filling')
     and (t.bbox operator(extensions.&&) p_env1 or t.bbox operator(extensions.&&) p_env2);
$$;

comment on function public.place_tiles_mapping_reason_in_view(extensions.geometry, extensions.geometry) is
  'Hub map (D-042 slice 2): for place tiles overlapping the envelopes that are still wanted or filling, null when any is due on the next nightly run (or none is being mapped), else the mildest queue_reason: budget, size_cap, extract_too_big. Returns only that word; place_tiles stays moderator-read. Stores nothing.';

revoke all on function public.place_tiles_mapping_reason_in_view(extensions.geometry, extensions.geometry) from public;
grant execute on function public.place_tiles_mapping_reason_in_view(extensions.geometry, extensions.geometry) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. place_tiles_queue (from the migration 28 body)
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_queue(
  p_kinds text[] default array['wanted', 'refresh'],
  p_limit integer default 20)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'status', q.status, 'demand', q.demand, 'row_count', q.row_count,
           'osm_run_at', q.osm_run_at,
           -- Migration 41: the last run's reason for not building it.
           'queue_reason', q.queue_reason,
           'west', extensions.ST_XMin(q.bbox), 'south', extensions.ST_YMin(q.bbox),
           'east', extensions.ST_XMax(q.bbox), 'north', extensions.ST_YMax(q.bbox))
           -- Migration 41: tiles with no OSM run first, then by demand.
           order by q.osm_run_at is not null, q.demand desc, q.osm_run_at nulls first, q.id), '[]'::jsonb)
    from (select t.* from public.place_tiles t
           -- Migration 41: wanted also takes filling (no OSM run yet).
           where ('wanted' = any (p_kinds) and t.status in ('wanted', 'filling'))
              or ('refresh' = any (p_kinds) and t.status = 'active'
                  and (t.osm_run_at is null or t.osm_run_at < now() - interval '6 days'))
           order by t.osm_run_at is not null, t.demand desc, t.osm_run_at nulls first, t.id
           limit greatest(1, least(coalesce(p_limit, 20), 100))) as q;
$$;

comment on function public.place_tiles_queue(text[], integer) is
  'Collector tiles queue (design 3.1 step 1; D-042 slice 2), service_role only: wanted and filling tiles (no OSM run yet) first, by demand, then active tiles due a weekly refresh (no OSM run for 6 days), with bounding boxes and the last run''s queue_reason. No user data.';

revoke all on function public.place_tiles_queue(text[], integer) from public, anon, authenticated;
grant execute on function public.place_tiles_queue(text[], integer) to service_role;

-- ---------------------------------------------------------------------------
-- 5. map_in_view (from the migration 32 body; mapping_reason)
-- ---------------------------------------------------------------------------
create or replace function public.map_in_view(
  p_west    double precision,
  p_south   double precision,
  p_east    double precision,
  p_north   double precision,
  p_hub_ids uuid[]      default null,
  p_layers  text[]      default array['places', 'plans', 'shows'],
  p_from    timestamptz default null,
  p_to      timestamptz default null,
  p_generic boolean     default false,
  p_limit   integer     default 800
)
returns jsonb language plpgsql stable
set search_path = ''
set plan_cache_mode = 'force_custom_plan'
as $$
declare
  b         record;
  v_layers  text[] := coalesce(p_layers, array['places', 'plans', 'shows']);
  v_from    timestamptz := coalesce(p_from, now());
  v_to      timestamptz;
  v_pl      jsonb;
  v_hubs    jsonb;
  v_sel     uuid[];
  v_hub_cut boolean := false;
  v_ev      jsonb;
  v_mapping boolean := false;
  v_reason  text;     -- Migration 41
begin
  select * into b from public.map_view_box(p_west, p_south, p_east, p_north);
  if cardinality(v_layers) = 0
     or exists (select 1 from unnest(v_layers) l where l is null or l not in ('places', 'plans', 'shows')) then
    raise exception 'layers_invalid' using errcode = 'check_violation', hint = 'places, plans, shows.';
  end if;
  v_to := coalesce(p_to, v_from + interval '7 days');
  if v_to <= v_from then
    raise exception 'invalid_window' using errcode = 'check_violation';
  end if;
  if v_to - v_from > interval '31 days' then
    raise exception 'window_too_long' using errcode = 'check_violation', hint = 'Up to 31 days.';
  end if;

  if 'places' = any (v_layers) then
    v_pl := public.places_in_view(p_west, p_south, p_east, p_north, p_hub_ids, p_generic, null, null, p_limit);
    v_hubs := v_pl -> 'hubs';
    v_hub_cut := coalesce((v_pl -> 'more' ->> 'hubs')::boolean, false);
    -- Migration 32: is a tile in view still being mapped (design 9)?
    if not coalesce((v_pl ->> 'zoom_in')::boolean, false) then
      v_mapping := public.place_tiles_mapping_in_view(b.env1, b.env2);
      -- Migration 41: why it is not built yet, when it is queued (D-042 slice 2).
      if v_mapping then
        v_reason := public.place_tiles_mapping_reason_in_view(b.env1, b.env2);
      end if;
    end if;
  else
    v_sel := coalesce(public.map_view_hubs(p_hub_ids), '{}');
    if cardinality(v_sel) > 50 then
      v_sel := v_sel[1:50];
      v_hub_cut := true;
    end if;
    v_hubs := coalesce((
      select jsonb_agg(jsonb_build_array(h.id, h.slug, h.name, h.emoji, h.place_mode) order by u.o)
        from unnest(v_sel) with ordinality as u(id, o)
        join public.hubs h on h.id = u.id), '[]'::jsonb);
  end if;
  v_sel := array(select (x.e ->> 0)::uuid from jsonb_array_elements(v_hubs) with ordinality as x(e, o) order by x.o);

  if 'plans' = any (v_layers) or 'shows' = any (v_layers) then
    with ev as (
      select e.id, e.hub_id, e.kind, e.title, e.starts_at, e.is_free, e.min_age, e.approx_lng, e.approx_lat,
             case when e.address_visibility = 'approved_only' then 'cell' else e.listing_kind end as grp,
             (e.hub_id = any (v_sel)) as in_sel
        from public.events e
        join public.hubs h on h.id = e.hub_id
       where e.status = 'published'
         and e.starts_at < v_to and e.ends_at > v_from
         and e.approx_point is not null
         and ((e.approx_point::extensions.geometry) operator(extensions.&&) b.env1
              or (e.approx_point::extensions.geometry) operator(extensions.&&) b.env2)
         and ((e.listing_kind = 'plan' and 'plans' = any (v_layers))
              or (e.listing_kind = 'show' and 'shows' = any (v_layers)))
    ), rk as (
      select ev.*, row_number() over (partition by ev.grp order by ev.in_sel desc, ev.starts_at, ev.id) as rn
        from ev
    ), kept as (
      select * from rk where rk.rn <= 300
    ), xh as (
      select d.hub_id, (cardinality(v_sel) + row_number() over (order by d.hub_id) - 1)::integer as idx
        from (select distinct k.hub_id from kept k where not (k.hub_id = any (v_sel))) d
    ), hx as (
      select u.id as hub_id, (u.o - 1)::integer as idx from unnest(v_sel) with ordinality as u(id, o)
      union all
      select xh.hub_id, xh.idx from xh
    ), enc as (
      select k.*, hx.idx,
             (case when k.kind = 'imported' then 1 else 0 end)
             | (case when k.in_sel then 2 else 0 end)
             | (case when k.is_free then 4 else 0 end)
             | (case when k.min_age >= 21 then 8 else 0 end) as flags
        from kept k
        join hx on hx.hub_id = k.hub_id
    ), cells as (
      select round(e.approx_lng::numeric, 1)::double precision as lng,
             round(e.approx_lat::numeric, 1)::double precision as lat, count(*) as n,
             jsonb_agg(e.id order by e.starts_at, e.id) as ids,
             jsonb_agg(e.idx order by e.starts_at, e.id) as hidx,
             -- Migration 32: titles and start times, parallel to ids. No point.
             jsonb_agg(e.title order by e.starts_at, e.id) as titles,
             jsonb_agg(extract(epoch from e.starts_at)::bigint order by e.starts_at, e.id) as starts,
             min(e.starts_at) as first_at
        from enc e
       where e.grp = 'cell'
       group by 1, 2
    )
    select jsonb_build_object(
      'plans', coalesce((select jsonb_agg(jsonb_build_array(e.id, round(e.approx_lng::numeric, 5)::double precision,
                 round(e.approx_lat::numeric, 5)::double precision, e.kind, e.idx, e.flags, e.title,
                 extract(epoch from e.starts_at)::bigint) order by e.rn)
                 from enc e where e.grp = 'plan'), '[]'::jsonb),
      'shows', coalesce((select jsonb_agg(jsonb_build_array(e.id, round(e.approx_lng::numeric, 5)::double precision,
                 round(e.approx_lat::numeric, 5)::double precision, e.kind, e.idx, e.flags, e.title,
                 extract(epoch from e.starts_at)::bigint) order by e.rn)
                 from enc e where e.grp = 'show'), '[]'::jsonb),
      'cells', coalesce((select jsonb_agg(jsonb_build_array(c.lng, c.lat, c.n, c.ids, c.hidx, c.titles, c.starts)
                 order by c.first_at, c.lng, c.lat) from cells c), '[]'::jsonb),
      'more', jsonb_build_object(
                 'plans', exists (select 1 from rk where rk.grp = 'plan' and rk.rn > 300),
                 'shows', exists (select 1 from rk where rk.grp = 'show' and rk.rn > 300),
                 'cells', exists (select 1 from rk where rk.grp = 'cell' and rk.rn > 300)),
      'extra_hubs', coalesce((select jsonb_agg(jsonb_build_array(h.id, h.slug, h.name, h.emoji, h.place_mode)
                 order by x.idx) from xh x join public.hubs h on h.id = x.hub_id), '[]'::jsonb))
      into v_ev;
  end if;

  return jsonb_build_object(
    'v', 1,
    'places', case when v_pl is null then null else v_pl -> 'places' end,
    'plans', case when 'plans' = any (v_layers) then v_ev -> 'plans' else null end,
    'shows', case when 'shows' = any (v_layers) then v_ev -> 'shows' else null end,
    'cells', coalesce(v_ev -> 'cells', '[]'::jsonb),
    'hubs', v_hubs || coalesce(v_ev -> 'extra_hubs', '[]'::jsonb),
    'zoom_in', coalesce((v_pl ->> 'zoom_in')::boolean, false),
    'truncated', coalesce((v_pl ->> 'truncated')::boolean, false) or v_hub_cut
                 or coalesce((v_ev -> 'more' ->> 'plans')::boolean, false)
                 or coalesce((v_ev -> 'more' ->> 'shows')::boolean, false)
                 or coalesce((v_ev -> 'more' ->> 'cells')::boolean, false),
    'more', jsonb_build_object(
              'places', coalesce((v_pl -> 'more' ->> 'places')::boolean, false),
              'hubs', v_hub_cut,
              'plans', coalesce((v_ev -> 'more' ->> 'plans')::boolean, false),
              'shows', coalesce((v_ev -> 'more' ->> 'shows')::boolean, false),
              'cells', coalesce((v_ev -> 'more' ->> 'cells')::boolean, false)),
    'no_hubs', coalesce((v_pl ->> 'no_hubs')::boolean,
                        p_hub_ids is null and (select auth.uid()) is not null and cardinality(v_sel) = 0),
    'generic', coalesce((v_pl ->> 'generic')::boolean, false),
    'mapping', v_mapping,
    'mapping_reason', v_reason,  -- Migration 41
    'from', v_from,
    'to', v_to);
end $$;

comment on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) is
  'Hub map view (D-041, design 5), as the caller (places and events RLS apply), in one jsonb: places (places_in_view; null when the layer is off or the bbox needs zoom_in), plans and shows (published events overlapping [p_from, p_to), default now to 7 days, at most 31, with approx_point in the bbox; listing_kind plan or show), cells and hubs. A public address is its point; an approved-only event is never a point, only a count in its 0.1-degree cell: cells [[lng, lat, n, ids, hub_idxs, titles, starts]] (D-038; titles and starts parallel to ids, migration 32). At most 300 plans, 300 shows and 300 cell events (selected hubs first, then by start), also when places need zoom_in. A plan or show is [id, lng, lat, kind, hub_idx, flags, title, starts_at unix seconds] (flags 1 imported, 2 selected hub, 4 free, 8 21+); hubs is the selected hubs, then the other hubs the events are in. truncated is any of more.places, hubs, plans, shows, cells. mapping: a place tile in view is still wanted or filling (only when places were looked up); mapping_reason (migration 41): null while one of them is due on the next nightly run, else budget, size_cap or extract_too_big. Stores nothing (no viewing logs). Errors: invalid_bbox, layers_invalid, invalid_window, window_too_long.';

revoke all on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) from public;
grant execute on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.37')
  on conflict (key) do update set value = excluded.value, updated_at = now();
