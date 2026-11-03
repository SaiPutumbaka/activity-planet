-- ============================================================================
-- Staging counts for the importer (D-037): aggregates only, never row data,
-- because the repo and its Action logs are public. Read-only; rolls back.
-- Run as the staging_file of a staging_only migrate.yml run.
-- ============================================================================
begin;

select fs.slug,
       fs.enabled,
       fs.last_ok_at is not null                                         as has_ok_run,
       fs.last_error is not null                                         as has_error,
       fs.item_count,
       count(ei.*) filter (where ei.is_primary and ei.removed_at is null) as primary_imports,
       count(ei.*) filter (where not ei.is_primary)                      as linked_duplicates,
       count(e.*)  filter (where e.status = 'published' and e.starts_at > now()) as upcoming,
       count(e.*)  filter (where e.status = 'cancelled')                 as cancelled,
       count(distinct e.hub_id)                                          as hubs_used,
       (select count(*) from cron.job j where j.jobname like 'import-feed-%') as cron_jobs
  from public.feed_sources fs
  left join public.event_imports ei on ei.source_id = fs.id
  left join public.events e on e.id = ei.event_id and ei.is_primary
 group by fs.id
 order by fs.slug;

rollback;
