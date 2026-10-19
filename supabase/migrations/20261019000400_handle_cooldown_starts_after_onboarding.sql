-- ============================================================================
-- Activity Planet schema v2 — migration 4: the handle chosen during onboarding
--   does not count as the one change per 30 days. guard_handle_change stamped
--   handle_changed_at on the onboarding write too, so the first real rename was
--   refused (found by the staging smoke test after migration 3).
-- ============================================================================
create or replace function public.guard_handle_change()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
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

insert into public.meta (key, value) values ('schema_version', '2.4')
  on conflict (key) do update set value = excluded.value, updated_at = now();
