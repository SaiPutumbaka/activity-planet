-- ============================================================================
-- Staging smoke for send-notifications (migration 55): asks the deployed
-- function for one run through the same path pg_cron uses (pg_net with the
-- notify_worker_secret header), forced even when nothing is due. Not rolled
-- back (pg_net sends only after commit); writes nothing but the pg_net
-- request. Read the answer afterwards from net._http_response (counts only:
-- {claimed, email, push, devices, email_configured, push_configured}).
-- ============================================================================
do $$
begin
  if public.notify_worker_dispatch(true) is null then
    raise exception 'FAIL notify_worker_dispatch sent nothing (project_url, secret or pg_net missing)';
  end if;
end $$;

select 'notify_worker_smoke: request sent' as result;
