-- ============================================================================
-- Activity Planet schema v2 — migration 29: hub map read RPCs (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md sections 5, 6 and 7; build slice
--   6). New functions only; no existing function is rebuilt and no table
--   changes, so request_account_deletion is unchanged (nothing new refers to
--   a user). Checks: supabase/tests/places_read.sql; timings on the Atlanta
--   data: supabase/tests/places_read_perf.sql.
--
--   What this file does
--     1. map_view_box(west, south, east, north): validates a bbox and splits
--        one that crosses the antimeridian (west > east) into two envelopes.
--        Returns the spans and the centre. Pure.
--     2. map_view_hubs(hub_ids): the hubs a view is for. Passed ids (active
--        hubs, first 500 looked at, duplicates dropped, order kept); null =
--        the caller's joined hubs; null for anon = null (every specific
--        hub, D-041 "Signed out"). At most 51 come back so the caller can
--        tell that it cut the list at 50.
--     3. places_own_in_view(env1, env2) and place_is_mine(id), security
--        definer: the caller's own member places (private pins and pending
--        requests) in view, and whether one place is the caller's. They
--        read created_by for the caller only and never return it, so the
--        invoker RPCs can mark "mine" without the column being readable.
--     4. places_in_view(bbox, hub_ids, generic, kinds, query, limit),
--        security invoker (places RLS decides visibility):
--          * zoom_in when the bbox is over 1.0 degree of latitude or 1.5 of
--            longitude (places null);
--          * the rule set is hub_place_rules of the selected hubs whose
--            place_mode is 'specific', plus a 'generic' hub's rules only
--            when it is the one hub selected and generic is set; 'none'
--            hubs never show places. A place matches when rule_ids overlaps
--            the rule set or it has a place_hubs link to a selected hub
--            (not 'none'). Signed out with no hubs: every specific hub.
--            The caller's own private and pending pins always show;
--          * at most 800 places (limit 1 to 1,500), own pins first, then
--            nearest to the bbox centre (planar degrees, read in that order
--            from the GiST index); more than 50 hubs or more places
--            than the limit sets truncated;
--          * compact encoding: each place is
--            [id, lng, lat, kind, hub_idx, flags, name, hub_idxs], with
--            lng/lat rounded to 5 decimals (about 1 m), hub_idx the first matching hub
--            as an index into the response's hubs list, hub_idxs every
--            matching selected hub (so chip filtering stays on the client,
--            design 7 rule 6). flags: 1 general spot, 2 pending, 4 private
--            pin, 8 member-added, 16 meeting spot, 32 Geoapify, 64 mine.
--     5. map_in_view(bbox, hub_ids, layers, from, to, generic, limit),
--        security invoker: places_in_view plus plans and shows (events RLS
--        decides visibility), one jsonb:
--          * events published and overlapping [from, to) (default now to
--            7 days, at most 31 days), approx_point in the bbox, by layer
--            (listing_kind plan or show);
--          * a public address comes back as its point; an approved-only
--            event never does: it is counted in its 0.1-degree cell
--            (cells: [lng, lat, n, ids, hub_idxs]) (D-038);
--          * at most 300 plans, 300 shows and 300 cell events, the selected
--            hubs' first, then by start; plans keep coming back when the
--            bbox is too large for places;
--          * each plan or show is [id, lng, lat, kind, hub_idx, flags, title,
--            starts_at (unix seconds)]; flags: 1 imported, 2 in a selected
--            hub, 4 free, 8 21+. hubs lists the selected hubs first, then
--            the other hubs the events are in: [id, slug, name, emoji,
--            place_mode].
--     6. place_detail(id), security invoker: the card (name, kind, address
--        for public places only, hours as text, website, tags, source line
--        with checked_at and an OpenStreetMap link, up to 12 hubs with the
--        caller's joined hubs first, plans_here: up to 20 upcoming public-
--        address events at a public venue that is this place). Never
--        returns who added a place, member counts or approved-only events.
--     * No viewing logs (design 7 rule 7): every function here is STABLE,
--       so none of them can write; the bbox and the caller are never stored.
--     * Grants: anon and authenticated execute the three RPCs and the
--       helpers they call (invoker functions run the helpers as the
--       caller). meta.schema_version 2.25.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. map_view_box
-- ---------------------------------------------------------------------------
create or replace function public.map_view_box(
  p_west double precision, p_south double precision, p_east double precision, p_north double precision,
  out env1 extensions.geometry, out env2 extensions.geometry,
  out lat_span double precision, out lng_span double precision,
  out c_lng double precision, out c_lat double precision)
language plpgsql immutable parallel safe set search_path = '' as $$
begin
  if p_west is null or p_south is null or p_east is null or p_north is null
     or p_south not between -90 and 90 or p_north not between -90 and 90 or p_south >= p_north
     or p_west not between -180 and 180 or p_east not between -180 and 180 or p_west = p_east then
    raise exception 'invalid_bbox' using errcode = 'check_violation',
      hint = 'west, south, east, north in degrees; south < north; west > east crosses the antimeridian.';
  end if;
  lat_span := p_north - p_south;
  c_lat := (p_north + p_south) / 2;
  if p_west < p_east then
    env1 := extensions.ST_MakeEnvelope(p_west, p_south, p_east, p_north, 4326);
    env2 := null;
    lng_span := p_east - p_west;
  else
    env1 := extensions.ST_MakeEnvelope(p_west, p_south, 180, p_north, 4326);
    env2 := extensions.ST_MakeEnvelope(-180, p_south, p_east, p_north, 4326);
    lng_span := (180 - p_west) + (p_east + 180);
  end if;
  c_lng := p_west + lng_span / 2;
  if c_lng > 180 then
    c_lng := c_lng - 360;
  end if;
end $$;

comment on function public.map_view_box(double precision, double precision, double precision, double precision) is
  'Hub map (D-041): validates a bbox (invalid_bbox) and returns one envelope, or two when west > east (the antimeridian), with the spans in degrees and the centre. Pure.';

-- ---------------------------------------------------------------------------
-- 2. map_view_hubs
-- ---------------------------------------------------------------------------
create or replace function public.map_view_hubs(p_hub_ids uuid[])
returns uuid[] language plpgsql stable set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if p_hub_ids is not null then
    return array(
      select u.hid
        from (select t.hid, min(t.o) as o
                from unnest(p_hub_ids[1:500]) with ordinality as t(hid, o)
               where t.hid is not null
               group by t.hid) u
        join public.hubs h on h.id = u.hid and h.is_active
       order by u.o
       limit 51);
  end if;
  if uid is null then
    return null;
  end if;
  return array(
    select hm.hub_id
      from public.hub_members hm
      join public.hubs h on h.id = hm.hub_id and h.is_active
     where hm.user_id = uid
     order by hm.joined_at, hm.hub_id
     limit 51);
end $$;

comment on function public.map_view_hubs(uuid[]) is
  'Hub map (D-041): the hubs a map view is for, in order. The ids passed (active hubs only, duplicates dropped), else the caller''s joined hubs, else null for a signed-out caller (every specific hub). At most 51, so a caller can tell the list was cut at 50. Runs as the caller.';

-- ---------------------------------------------------------------------------
-- 3. Own pins (definer; created_by stays unreadable)
-- ---------------------------------------------------------------------------
create or replace function public.places_own_in_view(p_env1 extensions.geometry, p_env2 extensions.geometry)
returns uuid[] language sql stable security definer set search_path = '' as $$
  select coalesce(array(
    select p.id
      from public.places p
     where p.created_by = (select auth.uid())
       and p.source = 'user'
       and p.status in ('active', 'pending')
       and (p.geom operator(extensions.&&) p_env1 or p.geom operator(extensions.&&) p_env2)
     order by p.created_at desc, p.id
     limit 200), '{}'::uuid[]);
$$;

comment on function public.places_own_in_view(extensions.geometry, extensions.geometry) is
  'Hub map (D-041): ids of the caller''s own member places (active or pending, private or public) inside one or two envelopes, newest first, at most 200. Empty when signed out. Never returns created_by.';

create or replace function public.place_is_mine(p_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null
     and exists (select 1 from public.places p where p.id = p_id and p.created_by = (select auth.uid()));
$$;

comment on function public.place_is_mine(uuid) is
  'Hub map (D-041): true when the caller added this place. Never returns who did.';

-- ---------------------------------------------------------------------------
-- 4. places_in_view
-- ---------------------------------------------------------------------------
create or replace function public.places_in_view(
  p_west    double precision,
  p_south   double precision,
  p_east    double precision,
  p_north   double precision,
  p_hub_ids uuid[]  default null,
  p_generic boolean default false,
  p_kinds   text[]  default null,
  p_query   text    default null,
  p_limit   integer default 800
)
returns jsonb language plpgsql stable
set search_path = ''
set plan_cache_mode = 'force_custom_plan'   -- the bbox and rule set differ per call; a cached generic plan scans everything
as $$
declare
  uid          uuid := (select auth.uid());
  b            record;
  v_sel        uuid[];
  v_all        boolean;
  v_hub_cut    boolean := false;
  v_generic_on boolean;
  v_general    boolean := false;
  v_rules      smallint[];
  v_nonrules   smallint[];
  v_compl      boolean := false;
  v_link       uuid[];
  v_own        uuid[] := '{}';
  v_cap        integer := greatest(1, least(coalesce(p_limit, 800), 1500));
  v_q          text;
  v_kinds      text[];
  v_c1         extensions.geometry;
  v_c2         extensions.geometry;
  v_hubs       jsonb;
  v_places     jsonb;
  v_n          integer;
begin
  select * into b from public.map_view_box(p_west, p_south, p_east, p_north);

  if p_query is not null and btrim(p_query) <> '' then
    v_q := lower(btrim(p_query));
    if char_length(v_q) < 2 or char_length(v_q) > 60 then
      raise exception 'query_length' using errcode = 'check_violation', hint = '2 to 60 characters.';
    end if;
    v_q := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;
  if p_kinds is not null then
    v_kinds := p_kinds[1:50];
  end if;

  v_sel := public.map_view_hubs(p_hub_ids);
  v_all := v_sel is null;
  v_sel := coalesce(v_sel, '{}');
  if cardinality(v_sel) > 50 then
    v_sel := v_sel[1:50];
    v_hub_cut := true;
  end if;
  v_generic_on := coalesce(p_generic, false) and cardinality(v_sel) = 1;
  if v_generic_on then
    v_general := exists (select 1 from public.hubs h where h.id = v_sel[1] and h.place_mode = 'generic');
  end if;

  v_hubs := coalesce((
    select jsonb_agg(jsonb_build_array(h.id, h.slug, h.name, h.emoji, h.place_mode) order by u.o)
      from unnest(v_sel) with ordinality as u(id, o)
      join public.hubs h on h.id = u.id), '[]'::jsonb);

  if b.lat_span > 1.0 or b.lng_span > 1.5 then
    return jsonb_build_object('v', 1, 'places', null, 'hubs', v_hubs, 'zoom_in', true,
      'truncated', v_hub_cut, 'more', jsonb_build_object('places', false, 'hubs', v_hub_cut),
      'no_hubs', not v_all and cardinality(v_sel) = 0, 'generic', v_general);
  end if;

  if v_all then
    v_rules := array(select distinct r.rule_id
                       from public.hub_place_rules r join public.hubs h on h.id = r.hub_id
                      where h.is_active and h.place_mode = 'specific');
    v_link  := array(select h.id from public.hubs h where h.is_active and h.place_mode = 'specific');
    -- Most rules belong to some specific hub, and && against a long array
    -- costs a comparison per element for every row, so test against the
    -- shorter complement instead (rule_ids only ever holds known rule ids).
    v_nonrules := array(select r.id from public.place_rules r where not (r.id = any (v_rules)));
    v_compl := cardinality(v_nonrules) < cardinality(v_rules);
  else
    v_rules := array(select distinct r.rule_id
                       from public.hub_place_rules r join public.hubs h on h.id = r.hub_id
                      where h.id = any (v_sel)
                        and (h.place_mode = 'specific' or (h.place_mode = 'generic' and v_generic_on)));
    v_link  := array(select h.id from public.hubs h where h.id = any (v_sel) and h.place_mode <> 'none');
  end if;
  if uid is not null then
    v_own := public.places_own_in_view(b.env1, b.env2);
  end if;
  if b.env2 is null then
    v_c1 := extensions.ST_SetSRID(extensions.ST_MakePoint(b.c_lng, b.c_lat), 4326);
  else
    v_c1 := extensions.ST_SetSRID(extensions.ST_MakePoint(p_west + b.lng_span / 2, b.c_lat), 4326);
    v_c2 := extensions.ST_SetSRID(extensions.ST_MakePoint(p_west + b.lng_span / 2 - 360, b.c_lat), 4326);
  end if;

  -- Nearest first by planar distance to the centre, through the GiST index
  -- (KNN), so a dense view reads about as many rows as it returns. Across the
  -- antimeridian the east part is measured from the centre shifted by 360
  -- degrees, so both parts are measured the same way.
  with near_rules as (
    select x.id, x.d from (
      select p.id, p.geom operator(extensions.<->) v_c1 as d
        from public.places p
       where p.status = 'active' and p.is_public
         and (case when v_compl then cardinality(p.rule_ids) > 0 and not (p.rule_ids <@ v_nonrules)
                   else p.rule_ids && v_rules end)
         and p.geom operator(extensions.&&) b.env1
         and (v_kinds is null or p.kind = any (v_kinds))
         and (v_q is null or p.search_text like v_q)
       order by p.geom operator(extensions.<->) v_c1
       limit v_cap + 1) x
    union all
    select x.id, x.d from (
      select p.id, p.geom operator(extensions.<->) v_c2 as d
        from public.places p
       where p.status = 'active' and p.is_public
         and (case when v_compl then cardinality(p.rule_ids) > 0 and not (p.rule_ids <@ v_nonrules)
                   else p.rule_ids && v_rules end)
         and p.geom operator(extensions.&&) b.env2
         and (v_kinds is null or p.kind = any (v_kinds))
         and (v_q is null or p.search_text like v_q)
       order by p.geom operator(extensions.<->) v_c2
       limit v_cap + 1) x
  ), near_links as (
    select p.id,
           least(p.geom operator(extensions.<->) v_c1, coalesce(p.geom operator(extensions.<->) v_c2, 'infinity')) as d
      from public.place_hubs ph
      join public.places p on p.id = ph.place_id
     where ph.hub_id = any (v_link)
       and p.status = 'active' and p.is_public
       and (p.geom operator(extensions.&&) b.env1 or p.geom operator(extensions.&&) b.env2)
       and (v_kinds is null or p.kind = any (v_kinds))
       and (v_q is null or p.search_text like v_q)
  ), own as (
    select p.id,   -- own pins sort first: a negative distance
           least(p.geom operator(extensions.<->) v_c1, coalesce(p.geom operator(extensions.<->) v_c2, 'infinity')) - 1000 as d
      from public.places p
     where p.id = any (v_own)
       and (v_kinds is null or p.kind = any (v_kinds))
       and (v_q is null or p.search_text like v_q)
  ), cand as (
    select c.id, min(c.d) as d
      from (select * from near_rules union all select * from near_links union all select * from own) c
     group by c.id
  ), pick as (
    select q.* from (
      select p.id, p.lng, p.lat, p.kind, p.name, p.rule_ids, p.source, p.status, p.is_public,
             (c.d < 0) as mine, row_number() over (order by c.d, p.id) as rn
        from cand c
        join public.places p on p.id = c.id) q
     where q.rn <= v_cap + 1
  ), sel as materialized (   -- once, not per place
    select (u.o - 1)::integer as idx, h.id,
           case when h.place_mode = 'specific' or (h.place_mode = 'generic' and v_generic_on)
                then coalesce((select array_agg(r.rule_id) from public.hub_place_rules r where r.hub_id = h.id),
                              '{}'::smallint[])
                else '{}'::smallint[] end as rules,
           h.place_mode <> 'none' as links
      from unnest(v_sel) with ordinality as u(id, o)
      join public.hubs h on h.id = u.id
  ), lk as materialized (
    select ph.place_id, array_agg(ph.hub_id) as hubs
      from public.place_hubs ph
     where ph.place_id in (select k.id from pick k) and ph.hub_id = any (v_link)
     group by ph.place_id
  ), enc as (
    select k.*,
           (l.place_id is not null) as linked,
           array(select s.idx from sel s
                  where s.rules && k.rule_ids or (s.links and s.id = any (coalesce(l.hubs, '{}'::uuid[])))
                  order by s.idx) as hidx
      from pick k
      left join lk l on l.place_id = k.id
  )
  select coalesce(jsonb_agg(jsonb_build_array(
             e.id,
             round(e.lng::numeric, 5)::double precision,
             round(e.lat::numeric, 5)::double precision,
             e.kind,
             e.hidx[1],
             (case when v_general and not e.linked then 1 else 0 end)
             | (case when e.status = 'pending' then 2 else 0 end)
             | (case when not e.is_public then 4 else 0 end)
             | (case e.source when 'user' then 8 when 'venue' then 16 when 'geoapify' then 32 else 0 end)
             | (case when e.mine then 64 else 0 end),
             e.name,
             to_jsonb(e.hidx)) order by e.rn) filter (where e.rn <= v_cap), '[]'::jsonb),
         count(*)
    into v_places, v_n
    from enc e;

  return jsonb_build_object('v', 1, 'places', v_places, 'hubs', v_hubs, 'zoom_in', false,
    'truncated', v_hub_cut or v_n > v_cap,
    'more', jsonb_build_object('places', v_n > v_cap, 'hubs', v_hub_cut),
    'no_hubs', not v_all and cardinality(v_sel) = 0, 'generic', v_general);
end $$;

comment on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer) is
  'Hub map places in a bbox (D-041, design 5), as the caller (places RLS applies). Hubs: p_hub_ids (active, first 50), else the caller''s joined hubs, else (signed out) every specific hub. A place matches when rule_ids overlaps the rules of the specific hubs (plus the one generic hub''s when p_generic and exactly one hub), or it has a place_hubs link to a selected hub that is not events-only; the caller''s own private and pending pins always show. p_kinds and p_query (2 to 60 characters, name and locality) narrow it. zoom_in (places null) above 1.0 x 1.5 degrees; at most p_limit (800, up to 1,500) places, own pins first, then nearest the centre; truncated when more places or more than 50 hubs. Each place is [id, lng, lat, kind, hub_idx, flags, name, hub_idxs] (flags 1 general spot, 2 pending, 4 private, 8 member, 16 meeting spot, 32 Geoapify, 64 mine); hubs is [[id, slug, name, emoji, place_mode]]. Stores nothing. Errors: invalid_bbox, query_length.';

-- ---------------------------------------------------------------------------
-- 5. map_in_view
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
      'cells', coalesce((select jsonb_agg(jsonb_build_array(c.lng, c.lat, c.n, c.ids, c.hidx)
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
    'from', v_from,
    'to', v_to);
end $$;

comment on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) is
  'Hub map view (D-041, design 5), as the caller (places and events RLS apply), in one jsonb: places (places_in_view; null when the layer is off or the bbox needs zoom_in), plans and shows (published events overlapping [p_from, p_to), default now to 7 days, at most 31, with approx_point in the bbox; listing_kind plan or show), cells and hubs. A public address is its point; an approved-only event is never a point, only a count in its 0.1-degree cell: cells [[lng, lat, n, ids, hub_idxs]] (D-038). At most 300 plans, 300 shows and 300 cell events (selected hubs first, then by start), also when places need zoom_in. A plan or show is [id, lng, lat, kind, hub_idx, flags, title, starts_at unix seconds] (flags 1 imported, 2 selected hub, 4 free, 8 21+); hubs is the selected hubs, then the other hubs the events are in. truncated is any of more.places, hubs, plans, shows, cells. Stores nothing (no viewing logs). Errors: invalid_bbox, layers_invalid, invalid_window, window_too_long.';

-- ---------------------------------------------------------------------------
-- 6. place_detail
-- ---------------------------------------------------------------------------
create or replace function public.place_detail(p_id uuid)
returns jsonb language plpgsql stable set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  p        record;
  v_joined uuid[] := '{}';
  v_hubs   jsonb;
  v_more   boolean;
  v_plans  jsonb;
begin
  if p_id is null then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  select x.id, x.source, x.source_id, x.osm_ref, x.name, x.kind, k.label as kind_label, k.icon as kind_icon,
         x.lat, x.lng, x.address_text, x.locality, x.country, x.opening_hours, x.website, x.tags,
         x.is_public, x.status, x.attribution, x.license, x.last_seen_at, x.rule_ids
    into p
    from public.places x
    join public.place_kinds k on k.slug = x.kind
   where x.id = p_id;
  if not found then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;

  if uid is not null then
    v_joined := array(select hm.hub_id from public.hub_members hm where hm.user_id = uid);
  end if;

  with hs as (
    select h.id, h.slug, h.name, h.emoji, h.place_mode, (h.id = any (v_joined)) as joined
      from public.hubs h
     where h.is_active and h.place_mode <> 'none'
       and (h.id in (select r.hub_id from public.hub_place_rules r where r.rule_id = any (p.rule_ids))
            or h.id in (select ph.hub_id from public.place_hubs ph where ph.place_id = p.id))
     order by (h.id = any (v_joined)) desc, (h.place_mode = 'specific') desc, h.name, h.id
     limit 13
  ), numbered as (
    select hs.*, row_number() over (order by hs.joined desc, (hs.place_mode = 'specific') desc, hs.name, hs.id) as rn
      from hs
  )
  select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'slug', n.slug, 'name', n.name, 'emoji', n.emoji,
                                               'general', n.place_mode = 'generic', 'joined', n.joined)
                            order by n.rn) filter (where n.rn <= 12), '[]'::jsonb),
         count(*) > 12
    into v_hubs, v_more
    from numbered n;

  -- Plans here: upcoming events with a public address at a public venue that
  -- is this place (venues.place_ref, or the venue a meeting spot came from).
  -- Approved-only events never appear (D-038).
  select coalesce(jsonb_agg(jsonb_build_object('id', q.id, 'title', q.title, 'starts_at', q.starts_at,
                                               'ends_at', q.ends_at, 'timezone', q.timezone,
                                               'hub_id', q.hub_id, 'hub_slug', q.hub_slug, 'kind', q.kind,
                                               'listing_kind', q.listing_kind)
                            order by q.starts_at, q.id), '[]'::jsonb)
    into v_plans
    from (select e.id, e.title, e.starts_at, e.ends_at, e.timezone, e.hub_id, h.slug as hub_slug, e.kind,
                 e.listing_kind
            from public.venues v
            join public.event_addresses ea on ea.venue_id = v.id
            join public.events e on e.id = ea.event_id
            join public.hubs h on h.id = e.hub_id
           where (v.place_ref = p.id or (p.source = 'venue' and v.id::text = p.source_id))
             and v.is_public
             and e.status = 'published'
             and e.address_visibility = 'public'
             and e.ends_at > now()
           order by e.starts_at, e.id
           limit 20) q;

  return jsonb_build_object(
    'v', 1,
    'id', p.id,
    'name', p.name,
    'kind', p.kind,
    'kind_label', p.kind_label,
    'kind_icon', p.kind_icon,
    'lat', round(p.lat::numeric, 6)::double precision,
    'lng', round(p.lng::numeric, 6)::double precision,
    'address_text', case when p.is_public and p.address_text <> '' then p.address_text end,
    'locality', nullif(p.locality, ''),
    'country', p.country,
    'opening_hours', p.opening_hours,
    'website', p.website,
    'tags', p.tags,
    'source', p.source,
    'status', p.status,
    'is_public', p.is_public,
    'mine', public.place_is_mine(p.id),
    'attribution', p.attribution,
    'license', p.license,
    'checked_at', case when p.source in ('osm', 'geoapify') then p.last_seen_at end,
    'osm_url', case when p.osm_ref is not null then
                 'https://www.openstreetmap.org/'
                 || case left(p.osm_ref, 1) when 'n' then 'node' when 'w' then 'way' else 'relation' end
                 || '/' || substr(p.osm_ref, 2) end,
    'hubs', v_hubs,
    'more_hubs', v_more,
    'plans_here', v_plans);
end $$;

comment on function public.place_detail(uuid) is
  'Hub map place card (D-041, design 5 and 9), as the caller (places RLS: a place the caller cannot see is place_not_found). Name, kind with label and icon, point, address (public places only), locality, country, hours as text, website, allowlisted tags, source, status, mine, attribution and licence, checked_at (OSM and Geoapify rows), osm_url, up to 12 hubs (joined first, then specific, more_hubs when there are more; general = a generic hub) and plans_here (up to 20 upcoming events with a public address at a public venue that is this place). Never who added it, member counts or approved-only events. Stores nothing. Errors: place_not_found.';

-- ---------------------------------------------------------------------------
-- 7. Grants (explicit). The invoker RPCs run the helpers as the caller, so
--    both roles execute them; the definer helpers only ever answer about the
--    caller's own rows.
-- ---------------------------------------------------------------------------
revoke all on function public.map_view_box(double precision, double precision, double precision, double precision) from public;
revoke all on function public.map_view_hubs(uuid[]) from public;
revoke all on function public.places_own_in_view(extensions.geometry, extensions.geometry) from public;
revoke all on function public.place_is_mine(uuid) from public;
revoke all on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer) from public;
revoke all on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) from public;
revoke all on function public.place_detail(uuid) from public;

grant execute on function public.map_view_box(double precision, double precision, double precision, double precision) to anon, authenticated, service_role;
grant execute on function public.map_view_hubs(uuid[]) to anon, authenticated, service_role;
grant execute on function public.places_own_in_view(extensions.geometry, extensions.geometry) to anon, authenticated, service_role;
grant execute on function public.place_is_mine(uuid) to anon, authenticated, service_role;
grant execute on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer) to anon, authenticated, service_role;
grant execute on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer) to anon, authenticated, service_role;
grant execute on function public.place_detail(uuid) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.25')
  on conflict (key) do update set value = excluded.value, updated_at = now();
