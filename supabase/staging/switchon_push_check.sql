-- ============================================================================
-- Staging only (migration 74 switch-on check, Nov 8): the outcome of
-- switchon_push_probe.sql (statuses and counts only), then the probe device is
-- removed. Run as the staging_file of a staging_only migrate.yml run (never on
-- production). Idempotent.
-- ============================================================================
create temp table switchon_push_out as
select (select n.push_status::text from public.notifications n join auth.users u on u.id = n.user_id
         where u.email like 'qa-e2e-b-%@example.com' and n.kind = 'chapter_claim_update'
           and n.dedupe_key like 'qa-switchon-push-%'
         order by n.created_at desc limit 1) as push,
       (select coalesce(n.last_error, '-') from public.notifications n join auth.users u on u.id = n.user_id
         where u.email like 'qa-e2e-b-%@example.com' and n.kind = 'chapter_claim_update'
           and n.dedupe_key like 'qa-switchon-push-%'
         order by n.created_at desc limit 1) as last_error,
       (select n.email_status::text from public.notifications n join auth.users u on u.id = n.user_id
         where u.email like 'qa-e2e-b-%@example.com' and n.kind = 'chapter_claim_update'
           and n.dedupe_key like 'qa-switchon-push-%'
         order by n.created_at desc limit 1) as email,
       (select count(*) from public.push_devices d
         where d.subscription ->> 'endpoint' like '%qa-switchon-probe-%' and d.revoked_at is not null) as probe_revoked_as_gone,
       (select max(d.failure_count) from public.push_devices d
         where d.subscription ->> 'endpoint' like '%qa-switchon-probe-%') as probe_fail_count;

delete from public.push_devices d where d.subscription ->> 'endpoint' like '%qa-switchon-probe-%';

select o.*, (select count(*) from public.push_devices d
              where d.subscription ->> 'endpoint' like '%qa-switchon-probe-%') as probe_devices_left
  from switchon_push_out o;
