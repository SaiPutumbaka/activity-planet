-- ============================================================================
-- Staging only (messaging slice 2): the browser flows' test accounts
-- (qa-e2e-*@example.com, made by apps/app/e2e/01-onboarding.mjs) count as
-- at least two days old, so 07-messaging.mjs can exercise a message request
-- (requests need an account of 24 hours, design section 3). Touches only
-- profiles.created_at of those test accounts; prints a count, never a row.
-- Run as the staging_file of a staging_only migrate.yml run (never on
-- production). Idempotent.
-- ============================================================================
update public.profiles p
   set created_at = now() - interval '2 days'
  from auth.users u
 where u.id = p.id
   and u.email like 'qa-e2e-%@example.com'
   and p.created_at > now() - interval '2 days';

select count(*) as qa_accounts_older_than_a_day
  from public.profiles p
  join auth.users u on u.id = p.id
 where u.email like 'qa-e2e-%@example.com'
   and p.created_at <= now() - interval '1 day';
