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
-- made (the latest-starting one) ends five minutes ago when that time is free;
-- each one takes the latest free slot before that (a run at both widths moves
-- two).
-- ============================================================================
-- Each booking, latest-starting first, gets the latest free slot that ends at or before five
-- minutes ago, stepping back half an hour at a time past any scheduled session of the coach
-- (coach_sessions_no_overlap), including the ones moved just before it.
do $$
declare
  b record;
  len interval;
  t_end timestamptz;
begin
  for b in
    select x.id, x.session_id, x.coach_id, x.ends_at - x.starts_at as len
      from public.bookings x
     where x.status = 'confirmed'
       and x.starts_at > now()
       and x.coach_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com')
       and x.client_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com')
     order by x.starts_at desc
  loop
    len := b.len;
    t_end := now() - interval '5 minutes';
    while exists (select 1 from public.coach_sessions s
                   where s.coach_id = b.coach_id and s.status = 'scheduled'
                     and s.id is distinct from b.session_id
                     and s.starts_at < t_end and s.ends_at > t_end - len) loop
      t_end := t_end - interval '30 minutes';
    end loop;
    update public.coach_sessions s
       set starts_at = t_end - len, ends_at = t_end
     where s.id = b.session_id and s.status = 'scheduled';
    update public.bookings x
       set starts_at = t_end - len,
           ends_at = t_end,
           free_cancel_until = t_end - len - interval '24 hours',
           expires_at = least(x.expires_at, t_end - len)
     where x.id = b.id;
  end loop;
end
$$;

select count(*) as qa_bookings_ended
  from public.bookings b
 where b.status = 'confirmed'
   and b.ends_at <= now()
   and b.coach_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com')
   and b.client_id in (select u.id from auth.users u where u.email like 'qa-e2e-%@example.com');
