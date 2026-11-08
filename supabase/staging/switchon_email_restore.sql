-- ============================================================================
-- Staging only (migration 74 switch-on check, Nov 8): puts QA account B's own
-- address and email setting back after switchon_email_swap.sql, and prints
-- whether a password-reset email went out while it pointed at Resend's test
-- inbox (recovery_sent_at in the last hour; a boolean, never a time or an
-- address) and whether the signed unsubscribe link turned email off
-- (notification_prefs.email_enabled false before the restore). Also prints
-- the check notice's delivery status and the weekly scorecard's status, and
-- asks for the scorecard again to show a sent week is never sent twice
-- (scorecard_dispatch answers null). Run as the
-- staging_file of a staging_only migrate.yml run (never on production).
-- Idempotent.
-- ============================================================================
-- Only the last statement's result is printed (supabase db query), so the
-- checks are kept in a temporary table and printed together at the end.
create temp table switchon_mail_check as
select (select (u.recovery_sent_at is not null and u.recovery_sent_at > now() - interval '1 hour')
          from auth.users u where u.email = 'delivered@resend.dev' and u.raw_app_meta_data ? 'qa_saved_email')
         as reset_email_sent,
       (select not np.email_enabled from public.notification_prefs np join auth.users u on u.id = np.user_id
         where u.email = 'delivered@resend.dev' and u.raw_app_meta_data ? 'qa_saved_email')
         as unsubscribed_by_link,
       (select n.email_status::text from public.notifications n join auth.users u on u.id = n.user_id
         where u.email = 'delivered@resend.dev' and n.kind = 'chapter_claim_update'
           and n.created_at > now() - interval '2 hours'
         order by n.created_at desc limit 1) as notice_email,
       (select s.status from public.scorecard_runs s where s.week_start = private.scorecard_last_week())
         as scorecard,
       public.scorecard_dispatch() is null as scorecard_second_request_refused;

begin;
update public.notification_prefs np
   set email_enabled = coalesce((u.raw_app_meta_data ->> 'qa_saved_email_enabled')::boolean, true)
  from auth.users u
 where u.id = np.user_id and u.email = 'delivered@resend.dev' and u.raw_app_meta_data ? 'qa_saved_email';
update auth.users u
   set email = u.raw_app_meta_data ->> 'qa_saved_email',
       raw_app_meta_data = u.raw_app_meta_data - 'qa_saved_email' - 'qa_saved_email_enabled',
       updated_at = now()
 where u.email = 'delivered@resend.dev' and u.raw_app_meta_data ? 'qa_saved_email'
   and u.raw_app_meta_data ->> 'qa_saved_email' like 'qa-e2e-b-%@example.com';
commit;

select c.*,
       (select count(*) from auth.users where email = 'delivered@resend.dev') as accounts_still_on_test_inbox,
       (select count(*) from auth.users where email like 'qa-e2e-b-%@example.com') as qa_b_restored
  from switchon_mail_check c;
