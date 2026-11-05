-- Staging only (migration 67, RECS_DESIGN.md section 4.4): queue every eligible hub, event and
-- coach listing for embedding (the recs-embed job drains it under its caps), then print counts
-- only: queued, and the queue, embedding and taste counts. No rows, no names. Run as the
-- staging_file of a staging_only migrate.yml run.
select public.recs_backfill() as queued;
select private.recs_counts() as counts;
