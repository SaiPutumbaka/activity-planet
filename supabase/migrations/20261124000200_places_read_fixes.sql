-- ============================================================================
-- Activity Planet schema v2 — migration 30: hub map read fixes (D-041, hub
--   map slice 6, fix forward of migration 29, 20261124000100_places_read.sql).
--   The one rebuilt function (places_in_view) starts from its migration 29
--   body; only the "lk" step (explicit hub links of the picked places)
--   changed. Checks: supabase/tests/places_read.sql (schema_version 2.26);
--   timings: supabase/tests/places_read_perf.sql.
--
--   Why: on staging a signed-out view (no hubs = every specific hub, 437 of
--   them) cost about 150 microseconds per returned place: the planner probed
--   place_hubs once per (picked place, hub) pair. The links are now looked up
--   by place id only, and skipped when no hubs are selected (hub_idxs are
--   empty then). Nothing else changes: same arguments, same result, still
--   STABLE, security invoker, force_custom_plan.
--
--   Idempotent: safe to re-run.
-- ============================================================================

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
    -- Migration 30: looked up by place id only (one index probe per picked
    -- place) and filtered with a non-indexable test, so the planner cannot
    -- turn "place_id = k.id and hub_id = any (v_link)" into one probe per
    -- (place, hub) pair (437 hubs x 800 places for a signed-out view). With
    -- no selected hubs (signed out, every specific hub) hub_idxs are empty
    -- and nothing here is needed.
    select ph.place_id, array_agg(ph.hub_id) as hubs
      from pick k
      join public.place_hubs ph on ph.place_id = k.id
     where cardinality(v_sel) > 0 and array_position(v_link, ph.hub_id) is not null
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

revoke all on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer) from public;
grant execute on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer) to anon, authenticated, service_role;

-- Version stamp (last)
insert into public.meta (key, value) values ('schema_version', '2.26')
  on conflict (key) do update set value = excluded.value, updated_at = now();
