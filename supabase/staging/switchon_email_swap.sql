-- ============================================================================
-- Staging only (migration 74 switch-on check, Nov 8): one real notification
-- email to Resend's test inbox. Staging's QA accounts use reserved
-- example.com addresses, which must never be sent to, so QA account B's
-- address is swapped for delivered@resend.dev for the length of the check:
-- the original address and email setting are kept in that account's
-- raw_app_meta_data (never printed) and put back by switchon_email_restore.sql.
-- Then one chapter_claim_update notice is queued for B, the send-notifications
-- worker is asked to run (notify_worker_dispatch, the pg_cron path). The
-- weekly scorecard is also asked to run once (scorecard_dispatch, pg_net with
-- the scorecard secret), so it is emailed to SCORECARD_TO. Prints booleans
-- only. Run as the staging_file of a staging_only migrate.yml run (never on
-- production). Run switchon_email_restore.sql a few minutes later: it prints
-- both delivery statuses and puts the address back.
-- ============================================================================
begin;
update auth.users u
   set raw_app_meta_data = coalesce(u.raw_app_meta_data, '{}'::jsonb)
         || jsonb_build_object('qa_saved_email', u.email,
                               'qa_saved_email_enabled',
                               coalesce((select np.email_enabled from public.notification_prefs np where np.user_id = u.id), true)),
       email = 'delivered@resend.dev',
       updated_at = now()
 where u.email like 'qa-e2e-b-%@example.com'
   and not coalesce(u.raw_app_meta_data, '{}'::jsonb) ? 'qa_saved_email'
   and not exists (select 1 from auth.users x where x.email = 'delivered@resend.dev');
update public.notification_prefs np set email_enabled = true
  from auth.users u
 where u.id = np.user_id and u.email = 'delivered@resend.dev';
select public.enqueue_notification(
         u.id, 'chapter_claim_update', 'qa-switchon-email-' || to_char(now(), 'YYYYMMDDHH24MI'),
         null, null, null, null,
         jsonb_build_object('status', 'approved', 'proposed_name', 'Activity Planet staging email check')) is not null
         as queued
  from auth.users u where u.email = 'delivered@resend.dev';
commit;

select public.notify_worker_dispatch() is not null as worker_requested;
select (select status from public.scorecard_runs s where s.week_start = private.scorecard_last_week()) as scorecard_before,
       public.scorecard_dispatch() is not null as scorecard_requested;
