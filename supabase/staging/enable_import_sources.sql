-- ============================================================================
-- Staging only (D-037): switch on the two seeded feed sources. Production
-- sources stay disabled until the GSU courtesy notice with the Localist
-- permission ask is answered and the legal pages are live. Run as the
-- staging_file of a staging_only migrate.yml run (never on production).
-- The feed_sources_reschedule trigger schedules one hourly pg_cron job per
-- enabled source. Idempotent.
-- ============================================================================
update public.feed_sources
   set enabled = true
 where slug in ('gsu-localist', 'gsu-pin')
   and not enabled;

select slug, enabled, cron_minute,
       (select count(*) from cron.job where jobname = 'import-feed-' || slug) as cron_jobs
  from public.feed_sources
 order by slug;
