-- ============================================================================
-- Activity Planet schema v2 — migration 32: hub map fields the Map tab needs
--   (D-041, docs/design/hub-map/HUB_MAP_DESIGN.md sections 5 and 9; fix
--   forward of migration 29, 20261124000100_places_read.sql). Checks:
--   supabase/tests/map_ui_fields.sql (schema_version 2.28).
--
--   What this file does
--     1. place_tiles_mapping_in_view(env1, env2), security definer, STABLE:
--        true when a 0.5-degree tile overlapping the view is still 'wanted'
--        or 'filling' (design 3.5: no OSM run yet). place_tiles stays
--        readable by moderators only; this answers one boolean and returns
--        no tile, count or demand. Writes nothing.
--     2. map_in_view is rebuilt from its migration 29 body (no later
--        migration changed it) with two additions and nothing else:
--          * each cell gains titles and starts_at (unix seconds), parallel
--            to ids: [lng, lat, n, ids, hub_idxs, titles, starts]. The list
--            panel names each approved-only event without a second request.
--            Still no point, address or venue for these events (D-038): the
--            cell centre is the only location, exactly as before, and the
--            rows are the ones events RLS already lets the caller read.
--          * mapping: true when places were looked up (places layer on, no
--            zoom_in) and a tile in view is still being mapped, for the
--            "We're mapping this area" state (design 9).
--        Same arguments, same security invoker, still STABLE (no viewing
--        logs), force_custom_plan, same grants.
--     No table changes, so request_account_deletion is unchanged. meta
--     schema_version 2.28.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_tiles_mapping_in_view
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_mapping_in_view(p_env1 extensions.geometry, p_env2 extensions.geometry)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1
      from public.place_tiles t
     where t.status in ('wanted', 'filling')
       and (t.bbox operator(extensions.&&) p_env1 or t.bbox operator(extensions.&&) p_env2));
$$;

comment on function public.place_tiles_mapping_in_view(extensions.geometry, extensions.geometry) is
  'Hub map (D-041, design 3.5 and 9): true when a place tile overlapping one of the envelopes is still wanted or filling (no OSM run yet). Returns only this boolean; place_tiles stays moderator-read. Stores nothing.';

revoke all on function public.place_tiles_mapping_in_view(extensions.geometry, extensions.geometry) from public;
grant execute on function public.place_tiles_mapping_in_view(extensions.geometry, extensions.geometry) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. map_in_view (from the migration 29 body; cells titles/starts, mapping)
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
    'from', v_from,
    'to', v_to);
end $$;

comment on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) is
  'Hub map view (D-041, design 5), as the caller (places and events RLS apply), in one jsonb: places (places_in_view; null when the layer is off or the bbox needs zoom_in), plans and shows (published events overlapping [p_from, p_to), default now to 7 days, at most 31, with approx_point in the bbox; listing_kind plan or show), cells and hubs. A public address is its point; an approved-only event is never a point, only a count in its 0.1-degree cell: cells [[lng, lat, n, ids, hub_idxs, titles, starts]] (D-038; titles and starts parallel to ids, migration 32). At most 300 plans, 300 shows and 300 cell events (selected hubs first, then by start), also when places need zoom_in. A plan or show is [id, lng, lat, kind, hub_idx, flags, title, starts_at unix seconds] (flags 1 imported, 2 selected hub, 4 free, 8 21+); hubs is the selected hubs, then the other hubs the events are in. truncated is any of more.places, hubs, plans, shows, cells. mapping: a place tile in view is still wanted or filling (only when places were looked up). Stores nothing (no viewing logs). Errors: invalid_bbox, layers_invalid, invalid_window, window_too_long.';

revoke all on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) from public;
grant execute on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.28')
  on conflict (key) do update set value = excluded.value, updated_at = now();
