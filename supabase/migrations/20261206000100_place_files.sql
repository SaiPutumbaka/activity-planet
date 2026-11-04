-- ============================================================================
-- Activity Planet schema v2 — migration 42: static place tile files (D-042
--   slices 3 to 5, docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 4.4,
--   4.5 and 10). OpenStreetMap places are built into one gzipped JSON file per
--   0.5-degree tile by .github/workflows/places-files.yml and published to
--   GitHub Pages from main (staging builds stay a workflow artifact). Postgres
--   keeps every place for the transition: a viewer reads OSM rows from the
--   files only when the app asks for it (map_in_view p_files) and the switch
--   meta.places_files is 'on'. Nothing is deleted.
--   Two functions are rebuilt from their latest bodies and change only the
--   lines marked "Migration 42": places_in_view (migration 30,
--   20261124000200_places_read_fixes.sql) and map_in_view (migration 41,
--   20261205000100_places_nightly.sql). Checks: supabase/tests/place_files.sql.
--
--   What this file does
--     1. place_tiles.file_*: the tile's current file (path
--        places/v{rules_version}/{tile}.{hash16}.json.gz, sha256 of the gzip,
--        bytes, row count, rules version, built_from = the database snapshot
--        time the rows were read at, built_at, published_at). No user id.
--     2. meta places_files ('on' or 'off', the server switch) and
--        places_rules_file (JSON: path, sha256, bytes, rules_version,
--        published) for rules/v{n}.{hash16}.json.gz, the hub -> rule ids table
--        the client filters file places with.
--     3. place_files_queue(limit, all, tiles), service_role: the rules table,
--        the tiles to (re)build (no file, an OSM run or rules change since,
--        or a week old) and the tiles whose file to drop (idle or retired
--        for 180 days).
--     4. place_tile_file_page(tile, after, limit), service_role: one page of
--        a tile's active public OSM rows in file order (by osm_ref):
--        [osm_ref, lng, lat, kind, name, rule_ids, address, locality, hours,
--        website, tags]. Public ODbL facts only, no ids.
--     5. place_files_record(jsonb), service_role: records built or published
--        files (tiles and the rules file), or clears a dropped tile's file.
--     6. place_files_in_view(env1, env2), security definer, STABLE: when the
--        switch is on and a rules file is published, the published files of
--        tiles in view ([[tile_id, path, count]]), the rules path, the
--        osm_refs in view hidden or removed since a file was built (the
--        client drops them), and the earliest snapshot time.
--     7. place_id_by_osm_ref(text), invoker: the place id of an active public
--        OSM place, so a place opened from a file still gets its card.
--     8. places_in_view (migration 30 body) gains p_skip_tiles and
--        p_skip_since: OSM rows of those tiles are left out unless corrected
--        (locked_fields) or changed since the snapshot; with p_skip_tiles each
--        place tuple gets osm_ref as element 8 (the merge key). Without them
--        the result is exactly as before. The old signature is dropped.
--     9. map_in_view (migration 41 body) gains p_files (default false: the
--        exact old behaviour) and returns place_files {rules, rules_version,
--        tiles, hidden, sel, all} or null. The old signature is dropped.
--     * meta.schema_version 2.38.
--
--   Account deletion: no user-referencing table or column (place_tiles and
--   meta have no user id), so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_tiles.file_*
-- ---------------------------------------------------------------------------
alter table public.place_tiles
  add column if not exists file_path          text,
  add column if not exists file_sha256        text,
  add column if not exists file_bytes         integer,
  add column if not exists file_count         integer,
  add column if not exists file_rules_version integer,
  add column if not exists file_built_from    timestamptz,
  add column if not exists file_built_at      timestamptz,
  add column if not exists file_published_at  timestamptz;

do $$ begin
  alter table public.place_tiles add constraint place_tiles_file_shape check (
    (file_path is null and file_sha256 is null and file_bytes is null and file_count is null
     and file_rules_version is null and file_built_from is null and file_built_at is null
     and file_published_at is null)
    or (file_path ~ '^places/v[0-9]{1,4}/[0-9]{1,6}\.[0-9a-f]{16}\.json\.gz$'
        and file_sha256 ~ '^[0-9a-f]{64}$'
        and file_bytes between 1 and 52428800
        and file_count between 0 and 200000
        and file_rules_version >= 1
        and file_built_from is not null and file_built_at is not null));
exception when duplicate_object then null; end $$;

comment on column public.place_tiles.file_path is
  'D-042 slice 3: the tile''s static places file, places/v{rules_version}/{tile}.{hash16}.json.gz (hash16: the first 16 hex of the sha256 of the uncompressed JSON). Set by place_files_record.';
comment on column public.place_tiles.file_built_from is
  'The database time the file''s rows were read at; OSM rows changed after it come from Postgres (map_in_view p_files).';
comment on column public.place_tiles.file_published_at is
  'When the file was published to GitHub Pages (D-042: from main only). Null for a staging build (artifact only); only published files are offered to the app.';

-- ---------------------------------------------------------------------------
-- 2. meta switch
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('places_files', 'on')
  on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 3. place_files_queue
-- ---------------------------------------------------------------------------
create or replace function public.place_files_queue(
  p_limit integer   default 50,
  p_all   boolean   default false,
  p_tiles integer[] default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rv    integer := coalesce((select max(r.rules_version) from public.place_rules r), 1);
  v_limit integer := greatest(1, least(coalesce(p_limit, 50), 500));
begin
  if p_tiles is not null and (cardinality(p_tiles) > 500
     or exists (select 1 from unnest(p_tiles) t where t is null or t < 0 or t > 259199)) then
    raise exception 'tiles_invalid' using errcode = 'check_violation', hint = 'At most 500 tile ids, 0 to 259199.';
  end if;
  return jsonb_build_object(
    'as_of', now(),
    'rules_version', v_rv,
    'rules_file', (select m.value::jsonb from public.meta m where m.key = 'places_rules_file'),
    'hubs', coalesce((
      select jsonb_agg(jsonb_build_array(h.id, h.slug, h.name, h.emoji, h.place_mode, x.rules) order by h.slug)
        from public.hubs h
        cross join lateral (select array_agg(r.rule_id order by r.rule_id) as rules
                              from public.hub_place_rules r where r.hub_id = h.id) x
       where h.is_active and h.place_mode in ('specific', 'generic') and x.rules is not null), '[]'::jsonb),
    'build', coalesce((
      select jsonb_agg(jsonb_build_object('id', q.id, 'status', q.status, 'row_count', q.row_count,
                                          'osm_run_at', q.osm_run_at, 'file_path', q.file_path,
                                          'file_built_at', q.file_built_at)
                       order by q.file_path is not null, q.file_built_at nulls first, q.id)
        from (select t.* from public.place_tiles t
               where t.osm_run_at is not null
                 and (case when p_tiles is not null then t.id = any (p_tiles)
                           else t.status in ('active', 'idle')
                                and (coalesce(p_all, false) or t.file_path is null
                                     or t.file_built_from < t.osm_run_at
                                     or t.file_rules_version is distinct from v_rv
                                     or t.file_built_at < now() - interval '7 days') end)
               order by t.file_path is not null, t.file_built_at nulls first, t.id
               limit v_limit) q), '[]'::jsonb),
    'drop', coalesce((
      select jsonb_agg(t.id order by t.id) from public.place_tiles t
       where t.file_path is not null and t.status in ('idle', 'retired')
         and coalesce(t.idle_since, t.updated_at) < now() - interval '180 days'), '[]'::jsonb));
end $$;

comment on function public.place_files_queue(integer, boolean, integer[]) is
  'Static place files (D-042 slice 3), service_role only: the current rules_version, the recorded rules file, the hub rule table [[id, slug, name, emoji, place_mode, rule_ids]] (active specific and generic hubs with rules), the tiles to build (p_tiles: those, else active or idle tiles with an OSM run and no file, an OSM run or rules change since it, or a file a week old; p_all: every one; up to p_limit, 500), and the tiles whose file is dropped (idle or retired 180 days). No user data.';

revoke all on function public.place_files_queue(integer, boolean, integer[]) from public, anon, authenticated;
grant execute on function public.place_files_queue(integer, boolean, integer[]) to service_role;

-- ---------------------------------------------------------------------------
-- 4. place_tile_file_page
-- ---------------------------------------------------------------------------
create or replace function public.place_tile_file_page(
  p_tile_id integer,
  p_after   text    default null,
  p_limit   integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer := greatest(1, least(coalesce(p_limit, 5000), 5000));
  v_rows  jsonb;
  v_n     integer;
  v_last  text;
begin
  if p_tile_id is null or p_tile_id < 0 or p_tile_id > 259199 then
    raise exception 'tile_unknown' using errcode = 'no_data_found';
  end if;
  if p_after is not null and p_after !~ '^[nwr][0-9]{1,15}$' then
    raise exception 'cursor_invalid' using errcode = 'check_violation';
  end if;
  with page as (
    select p.osm_ref, p.lng, p.lat, p.kind, p.name, p.rule_ids, p.address_text, p.locality,
           p.opening_hours, p.website, p.tags
      from public.places p
     where p.tile_id = p_tile_id and p.source = 'osm' and p.status = 'active' and p.is_public
       and p.osm_ref is not null and (p_after is null or p.osm_ref collate "C" > p_after collate "C")
     order by p.osm_ref collate "C"
     limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_array(
           g.osm_ref, round(g.lng::numeric, 5)::double precision, round(g.lat::numeric, 5)::double precision,
           g.kind, g.name, to_jsonb(g.rule_ids), nullif(g.address_text, ''), nullif(g.locality, ''),
           g.opening_hours, g.website, case when g.tags = '{}'::jsonb then null else g.tags end)
           order by g.osm_ref collate "C"), '[]'::jsonb),
         count(*), max(g.osm_ref collate "C")
    into v_rows, v_n, v_last
    from page g;
  return jsonb_build_object('tile', p_tile_id, 'as_of', now(), 'rows', v_rows,
                            'next', case when v_n = v_limit then v_last end);
end $$;

comment on function public.place_tile_file_page(integer, text, integer) is
  'Static place files (D-042 slice 3), service_role only: up to 5,000 active public OSM rows of one tile after the osm_ref cursor, in C-collation osm_ref order: [osm_ref, lng, lat, kind, name, rule_ids, address, locality, opening_hours, website, tags] (5 decimals; empty fields null). next is the cursor, null on the last page; as_of the database time. Public ODbL facts only: no place id, no member rows.';

revoke all on function public.place_tile_file_page(integer, text, integer) from public, anon, authenticated;
grant execute on function public.place_tile_file_page(integer, text, integer) to service_role;

-- ---------------------------------------------------------------------------
-- 5. place_files_record
-- ---------------------------------------------------------------------------
create or replace function public.place_files_record(p jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_pub     boolean;
  v_rules   jsonb;
  v_t       jsonb;
  v_id      integer;
  v_set     integer := 0;
  v_cleared integer := 0;
  v_unknown integer := 0;
  v_n       integer;
begin
  if p is null or jsonb_typeof(p) <> 'object' or jsonb_typeof(p -> 'published') <> 'boolean' then
    raise exception 'record_invalid' using errcode = 'check_violation', hint = '{published, rules?, tiles?}';
  end if;
  v_pub := (p ->> 'published')::boolean;
  v_rules := p -> 'rules';
  if v_rules is not null and jsonb_typeof(v_rules) <> 'null' then
    if jsonb_typeof(v_rules) <> 'object'
       or coalesce(v_rules ->> 'path', '') !~ '^rules/v[0-9]{1,4}\.[0-9a-f]{16}\.json\.gz$'
       or coalesce(v_rules ->> 'sha256', '') !~ '^[0-9a-f]{64}$'
       or jsonb_typeof(v_rules -> 'bytes') <> 'number' or (v_rules ->> 'bytes')::numeric not between 1 and 10485760
       or jsonb_typeof(v_rules -> 'rules_version') <> 'number' or (v_rules ->> 'rules_version')::numeric < 1 then
      raise exception 'rules_invalid' using errcode = 'check_violation';
    end if;
    -- A staging build never replaces a published rules file.
    if v_pub or coalesce(((select m.value::jsonb from public.meta m where m.key = 'places_rules_file') ->> 'published')::boolean, false) is false then
      insert into public.meta (key, value)
      values ('places_rules_file', jsonb_build_object('path', v_rules ->> 'path', 'sha256', v_rules ->> 'sha256',
                'bytes', (v_rules ->> 'bytes')::integer, 'rules_version', (v_rules ->> 'rules_version')::integer,
                'published', v_pub, 'at', now())::text)
      on conflict (key) do update set value = excluded.value, updated_at = now();
    end if;
  end if;

  if p ? 'tiles' then
    if jsonb_typeof(p -> 'tiles') <> 'array' or jsonb_array_length(p -> 'tiles') > 2000 then
      raise exception 'tiles_invalid' using errcode = 'check_violation', hint = 'At most 2,000 tiles a call.';
    end if;
    for v_t in select * from jsonb_array_elements(p -> 'tiles') loop
      if jsonb_typeof(v_t) <> 'object' or jsonb_typeof(v_t -> 'id') <> 'number'
         or (v_t ->> 'id')::numeric not between 0 and 259199 or (v_t ->> 'id')::numeric <> trunc((v_t ->> 'id')::numeric) then
        raise exception 'tiles_invalid' using errcode = 'check_violation';
      end if;
      v_id := (v_t ->> 'id')::integer;
      if coalesce((v_t ->> 'clear')::boolean, false) then
        update public.place_tiles t
           set file_path = null, file_sha256 = null, file_bytes = null, file_count = null,
               file_rules_version = null, file_built_from = null, file_built_at = null, file_published_at = null
         where t.id = v_id and t.file_path is not null;
        get diagnostics v_n = row_count;
        v_cleared := v_cleared + v_n;
        continue;
      end if;
      if coalesce(v_t ->> 'path', '') !~ ('^places/v[0-9]{1,4}/' || v_id || '\.[0-9a-f]{16}\.json\.gz$')
         or coalesce(v_t ->> 'sha256', '') !~ '^[0-9a-f]{64}$'
         or jsonb_typeof(v_t -> 'bytes') <> 'number' or jsonb_typeof(v_t -> 'count') <> 'number'
         or jsonb_typeof(v_t -> 'rules_version') <> 'number'
         or (v_t ->> 'bytes')::numeric not between 1 and 52428800
         or (v_t ->> 'count')::numeric not between 0 and 200000
         or (v_t ->> 'rules_version')::numeric < 1
         or (v_t ->> 'built_from') is null
         or (v_t ->> 'built_from')::timestamptz > now() + interval '5 minutes' then
        raise exception 'tiles_invalid' using errcode = 'check_violation', hint = 'Each tile: {id, path, sha256, bytes, count, rules_version, built_from} or {id, clear: true}.';
      end if;
      -- A staging build never replaces a published file.
      update public.place_tiles t
         set file_path = v_t ->> 'path', file_sha256 = v_t ->> 'sha256',
             file_bytes = (v_t ->> 'bytes')::integer, file_count = (v_t ->> 'count')::integer,
             file_rules_version = (v_t ->> 'rules_version')::integer,
             file_built_from = (v_t ->> 'built_from')::timestamptz, file_built_at = now(),
             file_published_at = case when v_pub then now() end
       where t.id = v_id and (v_pub or t.file_published_at is null);
      get diagnostics v_n = row_count;
      if v_n = 0 and not exists (select 1 from public.place_tiles t where t.id = v_id) then
        v_unknown := v_unknown + 1;
      end if;
      v_set := v_set + v_n;
    end loop;
  end if;

  return jsonb_build_object('published', v_pub, 'set', v_set, 'cleared', v_cleared, 'unknown', v_unknown,
                            'rules', v_rules is not null and jsonb_typeof(v_rules) <> 'null');
end $$;

comment on function public.place_files_record(jsonb) is
  'Static place files (D-042 slices 3 and 4), service_role only: {published, rules: {path, sha256, bytes, rules_version}?, tiles: [{id, path, sha256, bytes, count, rules_version, built_from} | {id, clear: true}]?}. Records what the files job built (published false: a staging artifact) or published to GitHub Pages (true, main only). An unpublished build never replaces a published file. Returns counts only.';

revoke all on function public.place_files_record(jsonb) from public, anon, authenticated;
grant execute on function public.place_files_record(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 6. place_files_in_view
-- ---------------------------------------------------------------------------
create or replace function public.place_files_in_view(p_env1 extensions.geometry, p_env2 extensions.geometry)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rules jsonb;
  v_tiles jsonb;
  v_ids   integer[];
  v_since timestamptz;
begin
  if coalesce((select m.value from public.meta m where m.key = 'places_files'), 'off') <> 'on' then
    return null;
  end if;
  select m.value::jsonb into v_rules from public.meta m where m.key = 'places_rules_file';
  if v_rules is null or coalesce((v_rules ->> 'published')::boolean, false) is false then
    return null;
  end if;
  select jsonb_agg(jsonb_build_array(t.id, t.file_path, t.file_count) order by t.id),
         array_agg(t.id order by t.id), min(t.file_built_from)
    into v_tiles, v_ids, v_since
    from public.place_tiles t
   where t.file_path is not null and t.file_published_at is not null
     and t.file_rules_version = (v_rules ->> 'rules_version')::integer
     and (t.bbox operator(extensions.&&) p_env1 or t.bbox operator(extensions.&&) p_env2);
  if v_tiles is null then
    return null;
  end if;
  return jsonb_build_object(
    'rules', v_rules ->> 'path',
    'rules_version', (v_rules ->> 'rules_version')::integer,
    'tiles', v_tiles,
    'since', v_since,
    -- OSM rows hidden, closed or removed after their tile's file was built.
    'hidden', coalesce((
      select jsonb_agg(h.osm_ref order by h.osm_ref) from (
        select p.osm_ref
          from public.places p
          join public.place_tiles t on t.id = p.tile_id
         where p.tile_id = any (v_ids) and p.source = 'osm' and p.osm_ref is not null
           and (p.status <> 'active' or not p.is_public)
           and p.updated_at > t.file_built_from
           and (p.geom operator(extensions.&&) p_env1 or p.geom operator(extensions.&&) p_env2)
         limit 5000) h), '[]'::jsonb));
end $$;

comment on function public.place_files_in_view(extensions.geometry, extensions.geometry) is
  'Hub map (D-042 slice 5): null unless meta.places_files is on and a rules file is published; else the rules file path and version, the published files of the place tiles overlapping the envelopes [[tile_id, path, count]], the earliest snapshot time (since) and the osm_refs in view hidden, closed or removed after their file was built (at most 5,000). Public file names and OSM ids only. Stores nothing.';

revoke all on function public.place_files_in_view(extensions.geometry, extensions.geometry) from public;
grant execute on function public.place_files_in_view(extensions.geometry, extensions.geometry) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 7. place_id_by_osm_ref
-- ---------------------------------------------------------------------------
create or replace function public.place_id_by_osm_ref(p_osm_ref text)
returns uuid language sql stable set search_path = '' as $$
  select p.id from public.places p
   where p_osm_ref ~ '^[nwr][0-9]{1,15}$'
     and p.osm_ref = p_osm_ref and p.status = 'active' and p.is_public
   limit 1;
$$;

comment on function public.place_id_by_osm_ref(text) is
  'Hub map (D-042 slice 5), as the caller (places RLS applies): the id of the active public place with this OSM ref, or null, so a place opened from a static file gets its place_detail card. Stores nothing.';

revoke all on function public.place_id_by_osm_ref(text) from public;
grant execute on function public.place_id_by_osm_ref(text) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 8. places_in_view (from the migration 30 body; p_skip_tiles, p_skip_since, osm_ref)
-- ---------------------------------------------------------------------------
drop function if exists public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer);
drop function if exists public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer);

create or replace function public.places_in_view(
  p_west    double precision,
  p_south   double precision,
  p_east    double precision,
  p_north   double precision,
  p_hub_ids uuid[]  default null,
  p_generic boolean default false,
  p_kinds   text[]  default null,
  p_query   text    default null,
  p_limit   integer default 800,
  -- Migration 42: tiles whose OSM rows the client reads from static files.
  p_skip_tiles integer[]   default null,
  p_skip_since timestamptz default null
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
         -- Migration 42: OSM rows of tiles served as files come from the file, except
         -- rows corrected by moderators (locked_fields) or changed since its snapshot.
         and (p_skip_tiles is null or p.source <> 'osm' or not (p.tile_id = any (p_skip_tiles))
              or cardinality(p.locked_fields) > 0 or p.updated_at > coalesce(p_skip_since, 'infinity'))
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
         -- Migration 42: OSM rows of tiles served as files come from the file, except
         -- rows corrected by moderators (locked_fields) or changed since its snapshot.
         and (p_skip_tiles is null or p.source <> 'osm' or not (p.tile_id = any (p_skip_tiles))
              or cardinality(p.locked_fields) > 0 or p.updated_at > coalesce(p_skip_since, 'infinity'))
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
             p.osm_ref,   -- Migration 42
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
             to_jsonb(e.hidx))
             -- Migration 42: with p_skip_tiles, osm_ref as element 8 (the merge key for static files).
             || case when p_skip_tiles is null then '[]'::jsonb else jsonb_build_array(e.osm_ref) end
             order by e.rn) filter (where e.rn <= v_cap), '[]'::jsonb),
         count(*)
    into v_places, v_n
    from enc e;

  return jsonb_build_object('v', 1, 'places', v_places, 'hubs', v_hubs, 'zoom_in', false,
    'truncated', v_hub_cut or v_n > v_cap,
    'more', jsonb_build_object('places', v_n > v_cap, 'hubs', v_hub_cut),
    'no_hubs', not v_all and cardinality(v_sel) = 0, 'generic', v_general);
end $$;


comment on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer, integer[], timestamptz) is
  'Hub map places in a bbox (D-041, design 5), as the caller (places RLS applies). Hubs: p_hub_ids (active, first 50), else the caller''s joined hubs, else (signed out) every specific hub. A place matches when rule_ids overlaps the rules of the specific hubs (plus the one generic hub''s when p_generic and exactly one hub), or it has a place_hubs link to a selected hub that is not events-only; the caller''s own private and pending pins always show. p_kinds and p_query (2 to 60 characters, name and locality) narrow it. zoom_in (places null) above 1.0 x 1.5 degrees; at most p_limit (800, up to 1,500) places, own pins first, then nearest the centre; truncated when more places or more than 50 hubs. Migration 42: OSM rows of p_skip_tiles (tiles the client reads from static files) are left out unless corrected (locked_fields) or changed after p_skip_since. Each place is [id, lng, lat, kind, hub_idx, flags, name, hub_idxs] (flags 1 general spot, 2 pending, 4 private, 8 member, 16 meeting spot, 32 Geoapify, 64 mine), plus osm_ref (or null) as element 8 when p_skip_tiles is given; hubs is [[id, slug, name, emoji, place_mode]]. Stores nothing. Errors: invalid_bbox, query_length.';

revoke all on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer, integer[], timestamptz) from public;
grant execute on function public.places_in_view(double precision, double precision, double precision, double precision, uuid[], boolean, text[], text, integer, integer[], timestamptz) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 9. map_in_view (from the migration 41 body; p_files, place_files)
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
  p_limit   integer     default 800,
  p_files   boolean     default false   -- Migration 42
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
  v_files   jsonb;    -- Migration 42
  v_skip    integer[];
  v_since   timestamptz;
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
    -- Migration 42: tiles in view served as static files (D-042 slices 3 to 5).
    if coalesce(p_files, false) and not (b.lat_span > 1.0 or b.lng_span > 1.5) then
      v_files := public.place_files_in_view(b.env1, b.env2);
      if v_files is not null then
        v_skip := array(select (x.e ->> 0)::integer from jsonb_array_elements(v_files -> 'tiles') as x(e));
        v_since := (v_files ->> 'since')::timestamptz;
      end if;
    end if;
    v_pl := public.places_in_view(p_west, p_south, p_east, p_north, p_hub_ids, p_generic, null, null, p_limit,
                                  v_skip, v_since);
    -- Migration 42: which hubs the client matches file places against.
    if v_files is not null then
      v_files := (v_files - 'since') || jsonb_build_object(
        'sel', jsonb_array_length(coalesce(v_pl -> 'hubs', '[]'::jsonb)),
        'all', public.map_view_hubs(p_hub_ids) is null);
    end if;
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
    'place_files', v_files,      -- Migration 42
    'from', v_from,
    'to', v_to);
end $$;


comment on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer, boolean) is
  'Hub map view (D-041, design 5), as the caller (places and events RLS apply), in one jsonb: places (places_in_view; null when the layer is off or the bbox needs zoom_in), plans and shows (published events overlapping [p_from, p_to), default now to 7 days, at most 31, with approx_point in the bbox; listing_kind plan or show), cells and hubs. A public address is its point; an approved-only event is never a point, only a count in its 0.1-degree cell: cells [[lng, lat, n, ids, hub_idxs, titles, starts]] (D-038; titles and starts parallel to ids, migration 32). At most 300 plans, 300 shows and 300 cell events (selected hubs first, then by start), also when places need zoom_in. A plan or show is [id, lng, lat, kind, hub_idx, flags, title, starts_at unix seconds] (flags 1 imported, 2 selected hub, 4 free, 8 21+); hubs is the selected hubs, then the other hubs the events are in. truncated is any of more.places, hubs, plans, shows, cells. mapping: a place tile in view is still wanted or filling (only when places were looked up); mapping_reason (migration 41): null while one of them is due on the next nightly run, else budget, size_cap or extract_too_big. place_files (migration 42, D-042 slice 5): with p_files and meta.places_files on, the published static files of tiles in view {rules, rules_version, tiles [[tile_id, path, count]], hidden [osm_ref], sel (how many of hubs are the selected hubs), all (every specific hub)}; their OSM rows are then left out of places except corrected or changed ones, and the client merges the files (a database row with the same osm_ref wins, hidden refs are dropped); null otherwise, and places are exactly as before. Stores nothing (no viewing logs). Errors: invalid_bbox, layers_invalid, invalid_window, window_too_long.';

revoke all on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer, boolean) from public;
grant execute on function public.map_in_view(double precision, double precision, double precision, double precision, uuid[], text[], timestamptz, timestamptz, boolean, integer, boolean) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.38')
  on conflict (key) do update set value = excluded.value, updated_at = now();
