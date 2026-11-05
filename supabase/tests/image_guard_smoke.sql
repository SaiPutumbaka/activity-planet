-- Staging smoke for the image-guard Edge Function (migration 52). Not a rolled-back test: it
-- asks image-guard for one sweep through the same path pg_cron uses (pg_net with the
-- image_guard_secret header), which deletes nothing when nothing is queued, and prints the
-- answers image-guard gave in the last 30 minutes (outcome and counts only; never headers,
-- never user rows). Run it twice: the second run shows the first run's answer.
select (public.image_guard_dispatch(jsonb_build_object('op', 'sweep')) is not null) as sweep_sent;
select r.status_code, r.timed_out, left(r.error_msg, 200) as error, left(r.content, 300) as content
  from net._http_response r
 where r.created > now() - interval '30 minutes'
   and (r.content like '{"deleted"%' or r.content like '{"outcome"%' or r.content like '{"error"%')
 order by r.created desc
 limit 3;
