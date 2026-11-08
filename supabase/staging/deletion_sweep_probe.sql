-- Staging only (launch audit M7). Run as the staging_file of a staging-only migrate.yml run, twice:
-- each run prints the delete-account sweep's answers from the last hour ({finished, failed,
-- purged}, counts only; never headers or the secret), then asks for one more sweep through the
-- path pg_cron uses (pg_net with the database's own secret; sent when the query commits).
select r.created, r.status_code, r.timed_out, left(r.content, 120) as content
  from net._http_response r
 where r.created > now() - interval '1 hour' and r.content like '{"finished"%'
 order by r.created desc
 limit 3;
select public.account_deletion_dispatch(true) is not null as sweep_requested;
