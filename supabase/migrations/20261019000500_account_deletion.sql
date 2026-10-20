-- ============================================================================
-- Activity Planet schema v2 — migration 5: account deletion
--   request_account_deletion(p_reason) is the "delete my account" action behind
--   the in-app screen (/you/delete) and the public page (/account/delete). It
--   runs as one transaction and takes effect immediately:
--     * a ledger row in account_deletions (user id, sha256 of the login email,
--       timestamps, optional reason) kept 30 days as moderation evidence;
--     * the public profile becomes a tombstone: first_name 'Deleted user', empty
--       bio, no avatar, no declared affiliation, status 'deleted', deleted_at
--       stamped; the handle is released to handle_history (held 30 days, like a
--       rename) and replaced with an opaque deleted_xxxxxxxxxx value that can
--       never collide with a real handle;
--     * the private row (email, birth date, location), notification
--       preferences, push devices, hub and chapter memberships, verified
--       emails, open verification codes, organization memberships and app
--       roles are deleted;
--     * the auth user is banned (banned_until) so password, OAuth, magic-link
--       and refresh grants stop at once, and its metadata is wiped.
--   The delete-account Edge Function then finishes with the service role: it
--   soft-deletes the auth user (frees the email and the OAuth identities for a
--   new signup, ends every session), removes avatar files, drops provider
--   tokens and stamps completed_at on the ledger row.
--
--   Why there is no grace period and no cancel_account_deletion():
--     Apple 5.1.1(v) and Google Play accept a deferred deletion only when it is
--     disclosed and short; the product has no messages, bookings or payments
--     yet that would justify a cooling-off window; a restorable state would
--     have to keep every piece of personal data for the whole window; and
--     GoTrue cannot undo a soft delete. Someone who changes their mind signs
--     up again with the same email, which the soft delete makes possible.
--
--   Retention after deletion (mirrored in docs/TRUST-SAFETY-LEGAL.md §11):
--     * account_deletions row: until retain_evidence_until (30 days), then
--       purge_account_deletions() removes it; a moderation hold may extend it;
--     * handle_history row for the released handle: 30 days of hold;
--     * the tombstone profile row and the soft-deleted auth.users row carry no
--       personal data and stay, so content other people received keeps a
--       "Deleted user" author; content tables reference profiles
--       ON DELETE SET NULL, so a later hard purge anonymizes rather than erases;
--     * payment records: none exist yet; when Stripe ships they are kept as
--       tax law requires and are never touched by this function.
--
--   Not wired yet (TODO blocks in the Edge Function): Apple token revocation
--   (waits for Capacitor), processor fan-out, anonymizing messages (there is
--   no messages table yet).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. guard_handle_change: let the deletion transaction swap the handle.
--    The RPC releases the handle itself and sets a transaction-local flag; the
--    guard skips the 30-day cooldown and its own history insert when it is on.
--    Clients cannot set the flag: PostgREST only exposes RPCs, never SET.
-- ---------------------------------------------------------------------------
create or replace function public.guard_handle_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if current_setting('ap.account_deletion', true) = 'on' then
    return new;
  end if;
  if lower(new.handle) is distinct from lower(old.handle) then
    if exists (select 1 from public.reserved_handles where handle = lower(new.handle)) then
      raise exception 'handle_reserved' using errcode = 'check_violation';
    end if;
    -- Only renames after onboarding are rate-limited and recorded; the onboarding write that
    -- replaces the opaque default handle is free.
    if old.onboarding_completed_at is not null and not public.is_privileged() then
      if old.handle_changed_at is not null and old.handle_changed_at > now() - interval '30 days' then
        raise exception 'handle_cooldown' using errcode = 'check_violation',
          hint = 'Handles can change once every 30 days.';
      end if;
      if exists (
        select 1 from public.handle_history
        where lower(handle) = lower(new.handle) and user_id <> new.id
          and released_at > now() - interval '30 days'
      ) then
        raise exception 'handle_taken' using errcode = 'unique_violation';
      end if;
      insert into public.handle_history (user_id, handle) values (old.id, old.handle);
      new.handle_changed_at := now();
    end if;
  end if;
  return new;
end $$;
revoke all on function public.guard_handle_change() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. request_account_deletion: the user-facing action
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    now() + interval '30 days',
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                = v_handle,
         first_name            = 'Deleted user',
         bio                   = '',
         avatar_url            = null,
         home_org_id           = null,
         home_campus_id        = null,
         status                = 'deleted',
         deletion_requested_at = now(),
         deleted_at            = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;

comment on function public.request_account_deletion(text) is
  'Deletes the caller''s account immediately: ledger row, tombstone profile, handle released, private data and memberships removed, auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 3. purge_account_deletions: ledger housekeeping (service role; schedule with
--    pg_cron once it is enabled, or run by hand)
-- ---------------------------------------------------------------------------
create or replace function public.purge_account_deletions()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  delete from public.account_deletions
   where completed_at is not null
     and retain_evidence_until is not null
     and retain_evidence_until < now();
  get diagnostics n = row_count;
  return n;
end $$;

comment on function public.purge_account_deletions() is
  'Removes account_deletions rows whose retain_evidence_until has passed. Returns the count. Service role only.';

-- ---------------------------------------------------------------------------
-- 4. Privileges
-- ---------------------------------------------------------------------------
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;
revoke all on function public.purge_account_deletions() from public, anon, authenticated;
grant execute on function public.purge_account_deletions() to service_role;

insert into public.meta (key, value) values ('schema_version', '2.5')
  on conflict (key) do update set value = excluded.value, updated_at = now();
