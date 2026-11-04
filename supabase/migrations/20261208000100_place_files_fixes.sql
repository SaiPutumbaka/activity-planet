-- ============================================================================
-- Activity Planet schema v2 — migration 44: review fixes for place files and
--   the Geoapify quick fill (D-042 slices 5 and 9). Two rebuilt functions,
--   each from its latest body, changing only the lines marked "Migration 44":
--   place_files_in_view (migration 42, 20261206000100_place_files.sql) and
--   places_fill_supersede (migration 43, 20261207000100_places_fill.sql).
--   Checks: supabase/tests/place_files_fixes.sql.
--
--   What this file does
--     1. place_files_in_view:
--        - hidden lists every OSM row of the offered tiles changed after the
--          tile's file was built, not only rows no longer active and public.
--          The app drops the file copy of a hidden ref and shows the database
--          row instead, so a changed row is never shown from a stale file
--          (before, a changed active row cut by places_in_view's cap showed
--          its file copy).
--        - a row whose location a moderator locked counts even when its new
--          spot is outside the view, so the file copy at its old spot is not
--          shown; the rows that must go come first under the 5,000 limit
--          (no longer active and public, then locked, then the rest).
--        - only active and idle tiles offer a file. A retired tile's OSM rows
--          are deleted and its file is never rebuilt, so the map answers from
--          the database there (empty until the tile comes back).
--     2. places_fill_supersede: keeps retirement's guard (migration 36):
--        a Geoapify row a moderator hid or removed, and that no OSM row
--        merged (merged_into null), is never deleted, so its moderation
--        history (place_mod_actions, resolved reports, edits) stays.
--     * meta.schema_version 2.40.
--
--   Account deletion: no new table or column; request_account_deletion is
--   unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_files_in_view (migration 42 body)
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
     and t.status in ('active', 'idle')   -- Migration 44: a retired tile's file is never rebuilt
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
    -- Migration 44: OSM rows changed after their tile's file was built (the database owns them).
    'hidden', coalesce((
      select jsonb_agg(h.osm_ref order by h.osm_ref) from (
        select p.osm_ref
          from public.places p
          join public.place_tiles t on t.id = p.tile_id
         where p.tile_id = any (v_ids) and p.source = 'osm' and p.osm_ref is not null
           and p.updated_at > t.file_built_from
           -- Migration 44: a moved row counts wherever its new spot is.
           and (p.geom operator(extensions.&&) p_env1 or p.geom operator(extensions.&&) p_env2
                or 'location' = any (p.locked_fields))
         -- Migration 44: rows that must not show first.
         order by (p.status = 'active' and p.is_public), cardinality(p.locked_fields) = 0, p.osm_ref
         limit 5000) h), '[]'::jsonb));
end $$;

comment on function public.place_files_in_view(extensions.geometry, extensions.geometry) is
  'Hub map (D-042 slice 5): null unless meta.places_files is on and a rules file is published; else the rules file path and version, the published files of the active or idle place tiles overlapping the envelopes [[tile_id, path, count]], the earliest snapshot time (since) and the osm_refs changed after their file was built (hidden: in view, or with a moderator-locked location anywhere in those tiles; at most 5,000, rows no longer active and public first, then locked rows). The client drops the file copy of a hidden ref. Public file names and OSM ids only. Stores nothing.';

revoke all on function public.place_files_in_view(extensions.geometry, extensions.geometry) from public;
grant execute on function public.place_files_in_view(extensions.geometry, extensions.geometry) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. places_fill_supersede (migration 43 body)
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_supersede()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tiles   integer[];
  v_deleted integer := 0;
begin
  with gone as (
    delete from public.places p
     using public.place_tiles t
     where t.id = p.tile_id
       and t.osm_run_at is not null
       and p.source = 'geoapify'
       and p.locked_fields = '{}'
       -- Migration 44: a row a moderator hid or removed stays (retirement's guard, migration 36).
       and (p.status in ('active', 'closed') or p.merged_into is not null)
       and not exists (select 1 from public.venues v where v.place_ref = p.id)
       and not exists (select 1 from public.place_hubs ph where ph.place_id = p.id and ph.via in ('member', 'moderator'))
       and not exists (select 1 from public.place_edits pe where pe.place_id = p.id and pe.status = 'pending')
       and not exists (select 1 from public.place_reports pr where pr.place_id = p.id and pr.status = 'open')
       and not exists (select 1 from public.places m where m.merged_into = p.id)
    returning p.tile_id
  )
  select coalesce(array_agg(distinct g.tile_id), '{}'), count(*) into v_tiles, v_deleted from gone g;

  if cardinality(v_tiles) > 0 then
    update public.place_tiles t
       set row_count = (select count(*) from public.places p
                         where p.tile_id = t.id and p.status = 'active' and p.is_public)
     where t.id = any (v_tiles);
  end if;
  return v_deleted;
end $$;

comment on function public.places_fill_supersede() is
  'D-042 slice 9 (pg_cron places-fill): deletes the Geoapify rows of tiles that have an OSM run (the OSM build merged the ones it matched by osm_ref), except rows with locked fields, rows a moderator hid or removed that no OSM row merged, rows with a venue, member or moderator hub links, a pending edit, an open report or a row merged into them (the retirement exceptions). Recomputes row_count. Returns the rows deleted.';

revoke all on function public.places_fill_supersede() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.40')
  on conflict (key) do update set value = excluded.value, updated_at = now();
