-- ============================================================================
-- Staging only (test hygiene): removes what the browser flows (apps/app/e2e)
-- left behind on staging, keeping everything they and Sai's checklist need.
--
-- Removed, only when older than a day and only for the e2e test accounts
-- (qa-e2e-*@example.com):
--   - plans titled 'QA e2e plan ...' that a test account hosts (03-plan.mjs),
--     with their RSVPs, plan chat and notifications (on delete cascade);
--   - coaching bookings between two test accounts titled 'E2E tennis ...'
--     (08-coaching.mjs) with their reviews, unless a payment or Stripe job
--     row refers to one; then 'E2E tennis ...' listings with nothing still to
--     come (their sessions and rules cascade);
--   - messages in conversations whose members are all test accounts
--     (07-messaging.mjs), except photo messages (their files stay with the
--     storage sweep); the DM itself and its accepted request stay, so a later
--     07 run finds an open DM;
--   - reports a test account filed with the note 'QA e2e test report ...'
--     (04, 07) and their evidence copies, except evidence with a photo;
--   - mutes and blocks between two test accounts (a run that stopped early);
--   - organizer claims a test account started that never verified (09);
--   - the test accounts' notifications.
--
-- Kept: the test accounts and their profiles, the demo accounts (handles
-- demo_*), the demo chapter and demo plans, anything a demo account made or
-- is a member of, and anything from the last day (a run in progress).
--
-- Run as the staging_file of a staging_only migrate.yml run, never on
-- production. Prints counts only, never a row. Idempotent: a second run
-- removes nothing new.
-- ============================================================================
begin;

create temp table qa_ids on commit drop as
  select u.id from auth.users u where u.email like 'qa-e2e-%@example.com';

create temp table demo_ids on commit drop as
  select p.id from public.profiles p where p.handle like 'demo\_%';

-- Never treat a demo account as a test account, whatever its email.
delete from qa_ids where id in (select id from demo_ids);

create temp table qa_cleanup_counts (step text primary key, n bigint);

-- Plans the flows posted.
with gone as (
  delete from public.events e
   where e.title like 'QA e2e plan %'
     and e.host_id in (select id from qa_ids)
     and e.created_at < now() - interval '1 day'
     and not exists (select 1 from public.rsvps r
                      where r.event_id = e.id and r.user_id in (select id from demo_ids))
  returning 1
)
insert into qa_cleanup_counts select 'plans_removed', count(*) from gone;

-- Coaching bookings between the two test accounts (reviews and private notes cascade).
with gone as (
  delete from public.bookings b
   where b.title like 'E2E tennis %'
     and b.coach_id in (select id from qa_ids)
     and b.client_id in (select id from qa_ids)
     and b.created_at < now() - interval '1 day'
     and (b.ends_at < now() - interval '1 day'
          or b.status::text not in ('requested', 'confirmed'))
     and not exists (select 1 from public.booking_payments p where p.booking_id = b.id)
     and not exists (select 1 from public.stripe_jobs j where j.booking_id = b.id)
  returning 1
)
insert into qa_cleanup_counts select 'bookings_removed', count(*) from gone;

-- Their listings, when nothing is still to come on them.
with gone as (
  delete from public.coach_listings l
   where l.title like 'E2E tennis %'
     and l.coach_id in (select id from qa_ids)
     and l.created_at < now() - interval '1 day'
     and not exists (select 1 from public.bookings b
                      where b.listing_id = l.id
                        and b.status::text in ('requested', 'confirmed')
                        and b.ends_at > now() - interval '1 day')
  returning 1
)
insert into qa_cleanup_counts select 'listings_removed', count(*) from gone;

-- Messages between test accounts only (conversations with no other member).
with qa_convs as (
  select m.conversation_id
    from public.conversation_members m
   group by m.conversation_id
  having bool_and(m.user_id in (select id from qa_ids))
), gone as (
  delete from public.messages x
   where x.conversation_id in (select conversation_id from qa_convs)
     and x.created_at < now() - interval '1 day'
     and x.image_path is null
  returning 1
)
insert into qa_cleanup_counts select 'messages_removed', count(*) from gone;

-- Test reports (their evidence copies cascade), unless an evidence copy holds a photo.
with gone as (
  delete from public.reports r
   where r.reporter_id in (select id from qa_ids)
     and r.note like 'QA e2e test report%'
     and r.created_at < now() - interval '1 day'
     and not exists (select 1 from public.message_report_evidence e
                      where e.report_id = r.id and e.image_evidence_path is not null)
  returning 1
)
insert into qa_cleanup_counts select 'reports_removed', count(*) from gone;

with gone as (
  delete from public.mutes m
   where m.muter_id in (select id from qa_ids) and m.muted_id in (select id from qa_ids)
     and m.created_at < now() - interval '1 day'
  returning 1
)
insert into qa_cleanup_counts select 'mutes_removed', count(*) from gone;

with gone as (
  delete from public.blocks b
   where b.blocker_id in (select id from qa_ids) and b.blocked_id in (select id from qa_ids)
     and b.created_at < now() - interval '1 day'
  returning 1
)
insert into qa_cleanup_counts select 'blocks_removed', count(*) from gone;

with gone as (
  delete from public.organizer_claims c
   where c.user_id in (select id from qa_ids)
     and c.status <> 'verified'
     and c.created_at < now() - interval '1 day'
  returning 1
)
insert into qa_cleanup_counts select 'claims_removed', count(*) from gone;

with gone as (
  delete from public.notifications n
   where n.user_id in (select id from qa_ids)
     and n.created_at < now() - interval '1 day'
  returning 1
)
insert into qa_cleanup_counts select 'notifications_removed', count(*) from gone;

-- What is left, as counts (the accounts are meant to stay).
insert into qa_cleanup_counts values
  ('qa_accounts_kept', (select count(*) from qa_ids)),
  ('demo_accounts_kept', (select count(*) from demo_ids)),
  ('demo_hosted_plans_kept',
   (select count(*) from public.events e where e.host_id in (select id from demo_ids))),
  ('qa_plans_left',
   (select count(*) from public.events e
     where e.title like 'QA e2e plan %' and e.host_id in (select id from qa_ids))),
  ('qa_listings_left',
   (select count(*) from public.coach_listings l
     where l.title like 'E2E tennis %' and l.coach_id in (select id from qa_ids))),
  ('qa_messages_left',
   (select count(*) from public.messages x where x.author_id in (select id from qa_ids))),
  ('qa_reports_left',
   (select count(*) from public.reports r where r.reporter_id in (select id from qa_ids)));

commit;

select step, n from qa_cleanup_counts order by step;
