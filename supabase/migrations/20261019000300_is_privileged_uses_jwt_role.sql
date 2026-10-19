-- ============================================================================
-- Activity Planet schema v2 — migration 3: is_privileged() must judge the caller
--   Inside a SECURITY DEFINER trigger (guard_handle_change) current_user is the
--   function owner (postgres), so the old definition treated every signed-in
--   user as privileged and the 30-day handle cooldown never fired (found by the
--   staging smoke test). Use the JWT role claim when a request carries one and
--   fall back to current_user only for direct database sessions.
-- ============================================================================
create or replace function public.is_privileged()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(auth.role(), current_user::text) in ('postgres', 'service_role', 'supabase_admin')
      or public.is_moderator();
$$;
revoke all on function public.is_privileged() from public, anon, authenticated;

insert into public.meta (key, value) values ('schema_version', '2.3')
  on conflict (key) do update set value = excluded.value, updated_at = now();
