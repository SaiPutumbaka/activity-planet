-- ============================================================================
-- Staging only (coaching slice 2): moves the browser flows' confirmed bookings
-- between two test accounts (qa-e2e-*@example.com) so that they ended five
-- minutes ago, keeping each booking's length, so 08-coaching.mjs can mark the
-- session done and leave a review without waiting for the real time (slots
-- need at least an hour's notice). Touches only bookings whose coach and
-- client are both test accounts, and their sessions; prints counts, never a
-- row. Run as the staging_file of a staging_only migrate.yml run between the
-- flow's "book" and "finish" phases (never on production). Idempotent: a
-- booking already in the past is left alone. The booking the last "book" run
-- made (the latest-starting one) is the one that ends five minutes ago.
-- ============================================================================
with qa as (
  select u.id from auth.users u where u.email like 'qa-e2e-%@example.com'
), moved as (
  -- Several bookings (a run stopped before its finish phase leaves one) end a day apart, the
  -- latest-starting one five minutes ago, or just before an earlier run's session that is still
  -- scheduled in the last day, so no two scheduled sessions overlap (coach_sessions_no_overlap).
  select b.id, b.session_id, b.ends_at - b.starts_at as len,
         least(now() - interval '5 minutes',
               coalesce((select min(s.starts_at) from public.coach_sessions s
                          where s.coach_id = b.coach_id and s.status = 'scheduled'
                            and s.starts_at <= now() and s.ends_at > now() - interval '1 day'),
                        now() - interval '5 minutes'))
           - (b.ends_at - b.starts_at)
           - (row_number() over (order by b.starts_at desc) - 1) * interval '1 day' as new_start
    from public.bookings b
   where b.status = 'confirmed'
     and b.starts_at > now()
     and b.coach_id in (select id from qa)
     and b.client_id in (select id from qa)
), sessions as (
  update public.coach_sessions s
     set starts_at = m.new_start, ends_at = m.new_start + m.len
    from moved m
   where s.id = m.session_id and s.status = 'scheduled'
  returning s.id
)
update public.bookings b
   set starts_at = m.new_start,
       ends_at = m.new_start + m.len,
       free_cancel_until = m.new_start - interval '24 hours',
       expires_at = least(b.expires_at, m.new_start)
  from moved m
 where b.id = m.id;

select count(*) as qa_bookings_ended
  from public.bookings b
 where b.status = 'confirmed'
   and b.ends_at <= now()
   and b.coach_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com')
   and b.client_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com');
