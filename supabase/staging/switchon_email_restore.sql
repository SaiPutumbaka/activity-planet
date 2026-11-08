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
select (u.recovery_sent_at is not null and u.recovery_sent_at > now() - interval '1 hour') as reset_email_sent,
       coalesce((select not np.email_enabled from public.notification_prefs np where np.user_id = u.id), false)
         as unsubscribed_by_link
  from auth.users u where u.email = 'delivered@resend.dev' and u.raw_app_meta_data ? 'qa_saved_email';

select n.email_status::text as email, n.push_status::text as push, coalesce(n.last_error, '-') as last_error
  from public.notifications n join auth.users u on u.id = n.user_id
 where u.email = 'delivered@resend.dev' and n.kind = 'chapter_claim_update'
   and n.created_at > now() - interval '2 hours'
 order by n.created_at desc limit 1;

select s.status as scorecard, s.sent_at is not null as has_sent_at, coalesce(s.error, '-') as error,
       public.scorecard_dispatch() is null as second_request_refused
  from public.scorecard_runs s where s.week_start = private.scorecard_last_week();

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

select (select count(*) from auth.users where email = 'delivered@resend.dev') as accounts_still_on_test_inbox,
       (select count(*) from auth.users where email like 'qa-e2e-b-%@example.com') as qa_b_restored;
