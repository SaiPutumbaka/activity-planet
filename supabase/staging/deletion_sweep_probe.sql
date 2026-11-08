-- Staging only (launch audit M7). Run as the staging_file of a staging-only migrate.yml run, twice:
-- each run prints the delete-account sweep's answers from the last hour ({finished, failed,
-- purged}, counts only; never headers or the secret), then asks for one more sweep through the
-- path pg_cron uses (pg_net with the database's own secret; sent when the query commits).
-- One statement: the CLI prints only the last result.
select (select coalesce(json_agg(json_build_object('status', r.status_code, 'timed_out', r.timed_out,
                                                   'answer', left(r.content, 120)) order by r.created desc), '[]')
          from net._http_response r
         where r.created > now() - interval '1 hour'
           and (r.content like '{"finished"%' or r.content like '{"error"%')) as previous_answers,
       public.account_deletion_dispatch(true) is not null as sweep_requested;
