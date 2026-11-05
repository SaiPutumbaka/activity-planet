-- ============================================================================
-- Staging only (release B known gap): archives the "E2E tennis ..." listings
-- the browser flow 08-coaching.mjs left active on the QA test accounts
-- (qa-e2e-*@example.com) in earlier book-only runs. The same change the
-- Archive button makes (set_listing_status: status only). Leaves a listing
-- alone while it has a requested or confirmed booking still to come, so a
-- run in progress is not disturbed. Touches only test accounts; prints
-- counts, never a row. Run as the staging_file of a staging_only migrate.yml
-- run (never on production). Idempotent: an archived listing stays archived.
-- ============================================================================
with qa as (
  select u.id from auth.users u where u.email like 'qa-e2e-%@example.com'
), archived as (
  update public.coach_listings l
     set status = 'archived'
   where l.coach_id in (select id from qa)
     and l.title like 'E2E tennis %'
     and l.status <> 'archived'
     and not exists (select 1 from public.bookings b
                      where b.listing_id = l.id
                        and b.status in ('requested', 'confirmed')
                        and b.ends_at > now())
  returning l.id
)
select (select count(*) from archived) as qa_listings_archived,
       (select count(*) from public.coach_listings l
         where l.coach_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com')
           and l.title like 'E2E tennis %' and l.status = 'active'
           -- the statement's snapshot predates the update, so leave out the rows it archived
           and l.id not in (select id from archived)) as qa_listings_still_active;
