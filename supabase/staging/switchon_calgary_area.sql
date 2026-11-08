-- ============================================================================
-- Staging only (migration 74 switch-on check, Nov 8): a fresh area in Calgary,
-- as if a new member saved a home there (collector_note_home_point, called as
-- the migration owner, so no person is recorded). It adds the collector region
-- that brings the City of Calgary open-data dataset into the next staging
-- collector run, and a wanted place tile with demand 1 that the places-fill
-- function fills with Geoapify. No member row is touched. Prints counts only.
-- Run as the staging_file of a staging_only migrate.yml run (never on
-- production). Idempotent: a second run adds nothing.
-- ============================================================================
select public.collector_note_home_point(
         extensions.ST_SetSRID(extensions.ST_MakePoint(-114.07, 51.05), 4326)::extensions.geography,
         null, null) as calgary_region_added;

select (select count(*) from public.collector_regions r
         where extensions.ST_DWithin(r.point,
                 extensions.ST_SetSRID(extensions.ST_MakePoint(-114.07, 51.05), 4326)::extensions.geography, 30000))
         as calgary_regions,
       (select count(*) from public.place_tiles t
         where t.id = public.place_tile_id_of(
                 extensions.ST_SetSRID(extensions.ST_MakePoint(-114.07, 51.05), 4326)::extensions.geography)
           and t.demand >= 1 and t.osm_run_at is null) as calgary_fillable_tiles;
