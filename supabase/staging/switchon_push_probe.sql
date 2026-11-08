-- ============================================================================
-- Staging only (migration 74 switch-on check, Nov 8): web push with the VAPID
-- keys. Headless Chromium holds no real push subscription, so QA account B gets
-- a probe device: an FCM endpoint path that no browser registered, with a
-- freshly generated P-256 key pair whose private half was discarded (nothing
-- here is a secret). One chapter_claim_update notice is queued for B and the
-- send-notifications worker is asked to run. The worker must build a
-- VAPID-signed, aes128gcm-encrypted push and send it to FCM; FCM answers that
-- the registration is unknown (404 or 410: the device is revoked as gone) or
-- refuses it with another status (counted as failed). Either way the outcome
-- names the push service's answer, not "no_vapid_keys". B's own email is on a
-- reserved domain, so the email side ends skipped reserved_domain.
-- switchon_push_check.sql prints the outcome and removes the probe device.
-- Run as the staging_file of a staging_only migrate.yml run (never on
-- production).
-- ============================================================================
begin;
select set_config('request.jwt.claims',
                  json_build_object('sub', u.id, 'role', 'authenticated')::text, true)
  from auth.users u where u.email like 'qa-e2e-b-%@example.com';
select public.register_push_device(
         jsonb_build_object(
           'endpoint', 'https://fcm.googleapis.com/fcm/send/qa-switchon-probe-00f3ab496e5f6da59b961457',
           'keys', jsonb_build_object(
             'p256dh', 'BNSSTFpmfMhXxYv9MbLKOfpH3RNP6kYAU0Q6lQvCA9yXCNRmibrRPHTIK7sqsdT33iM-0qkpEquN_kYjxcNPzR0',
             'auth', 'jD-MyICTmRqoN6gfvOfubQ')),
         'qa-switchon-probe', 'switchon');
select set_config('request.jwt.claims', '', true);
select public.enqueue_notification(
         u.id, 'chapter_claim_update', 'qa-switchon-push-' || to_char(now(), 'YYYYMMDDHH24MI'),
         null, null, null, null,
         jsonb_build_object('status', 'approved', 'proposed_name', 'Activity Planet staging push check'))
  from auth.users u where u.email like 'qa-e2e-b-%@example.com';
commit;

-- Only the last statement's result is printed (supabase db query).
select (select count(*) from public.push_devices d
         where d.revoked_at is null and d.subscription ->> 'endpoint' like '%qa-switchon-probe-%') as probe_devices,
       public.notify_worker_dispatch() is not null as worker_requested;
