-- ============================================================================
-- Activity Planet schema v2 — migration 2: fixes from the staging advisors
--   * moderator/admin write policies split into insert/update/delete so they no
--     longer overlap the read policies (multiple_permissive_policies);
--   * covering indexes for every foreign key the linter listed;
--   * surrogate primary key on hub_stats;
--   * trigger functions no longer executable through the REST RPC surface
--     (auth triggers keep execute for supabase_auth_admin).
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Split "for all" write policies
-- ---------------------------------------------------------------------------
drop policy if exists "organizations_write_admin" on public.organizations;
create policy "organizations_insert_admin" on public.organizations for insert to authenticated
  with check ((select public.has_role('admin'::public.app_role)));
create policy "organizations_update_admin" on public.organizations for update to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));
create policy "organizations_delete_admin" on public.organizations for delete to authenticated
  using ((select public.has_role('admin'::public.app_role)));

drop policy if exists "org_email_domains_write_admin" on public.org_email_domains;
create policy "org_email_domains_insert_admin" on public.org_email_domains for insert to authenticated
  with check ((select public.has_role('admin'::public.app_role)));
create policy "org_email_domains_update_admin" on public.org_email_domains for update to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));
create policy "org_email_domains_delete_admin" on public.org_email_domains for delete to authenticated
  using ((select public.has_role('admin'::public.app_role)));

drop policy if exists "org_campuses_write_admin" on public.org_campuses;
create policy "org_campuses_insert_admin" on public.org_campuses for insert to authenticated
  with check ((select public.has_role('admin'::public.app_role)));
create policy "org_campuses_update_admin" on public.org_campuses for update to authenticated
  using ((select public.has_role('admin'::public.app_role))) with check ((select public.has_role('admin'::public.app_role)));
create policy "org_campuses_delete_admin" on public.org_campuses for delete to authenticated
  using ((select public.has_role('admin'::public.app_role)));

drop policy if exists "hub_categories_write_mod" on public.hub_categories;
create policy "hub_categories_insert_mod" on public.hub_categories for insert to authenticated
  with check ((select public.is_moderator()));
create policy "hub_categories_update_mod" on public.hub_categories for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
create policy "hub_categories_delete_mod" on public.hub_categories for delete to authenticated
  using ((select public.is_moderator()));

drop policy if exists "hubs_write_mod" on public.hubs;
create policy "hubs_insert_mod" on public.hubs for insert to authenticated
  with check ((select public.is_moderator()));
create policy "hubs_update_mod" on public.hubs for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
create policy "hubs_delete_mod" on public.hubs for delete to authenticated
  using ((select public.is_moderator()));

drop policy if exists "hub_chapters_write_mod" on public.hub_chapters;
create policy "hub_chapters_insert_mod" on public.hub_chapters for insert to authenticated
  with check ((select public.is_moderator()));
create policy "hub_chapters_update_mod" on public.hub_chapters for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
create policy "hub_chapters_delete_mod" on public.hub_chapters for delete to authenticated
  using ((select public.is_moderator()));

-- chapter_members: moderators act through set_chapter_role() and the owner policies; the
-- blanket "for all" policy overlapped every action, so it goes. Moderator inserts/deletes of
-- other people's memberships are a week-4 captain-tools concern and will get explicit policies.
drop policy if exists "chapter_members_write_mod" on public.chapter_members;
create policy "chapter_members_read" on public.chapter_members for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or not exists (
      select 1 from public.hub_chapters ch
      join public.hubs h on h.id = ch.hub_id
      join public.hub_categories c on c.slug = h.category_slug
      where ch.id = chapter_members.chapter_id and c.is_sensitive
    )
  );
-- (re-created above with the same body so the single read policy is the only SELECT policy)
drop policy if exists "chapter_members_delete_own" on public.chapter_members;
create policy "chapter_members_delete_own_or_mod" on public.chapter_members for delete to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 2. Covering indexes for foreign keys
-- ---------------------------------------------------------------------------
create index if not exists email_verification_codes_org_idx on public.email_verification_codes (org_id);
create index if not exists handle_history_user_idx on public.handle_history (user_id);
create index if not exists hub_chapters_campus_idx on public.hub_chapters (campus_id);
create index if not exists hub_chapters_created_by_idx on public.hub_chapters (created_by);
create index if not exists hub_requests_hub_idx on public.hub_requests (hub_id);
create index if not exists hub_requests_reviewed_by_idx on public.hub_requests (reviewed_by);
create index if not exists hub_requests_user_idx on public.hub_requests (user_id);
create index if not exists hubs_created_by_idx on public.hubs (created_by);
create index if not exists org_memberships_campus_idx on public.org_memberships (campus_id);
create index if not exists org_memberships_granted_by_idx on public.org_memberships (granted_by);
create index if not exists org_memberships_verified_email_idx on public.org_memberships (verified_email_id);
create index if not exists user_roles_granted_by_idx on public.user_roles (granted_by);
create index if not exists verified_emails_org_idx on public.verified_emails (org_id);

-- ---------------------------------------------------------------------------
-- 3. hub_stats primary key
-- ---------------------------------------------------------------------------
alter table public.hub_stats add column if not exists id uuid not null default gen_random_uuid();
do $$
begin
  if not exists (
    select 1 from pg_constraint where conrelid = 'public.hub_stats'::regclass and contype = 'p'
  ) then
    alter table public.hub_stats add primary key (id);
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Trigger functions are not RPCs
-- ---------------------------------------------------------------------------
revoke all on function public.guard_handle_change() from public, anon, authenticated;
revoke all on function public.require_birth_date_for_onboarding() from public, anon, authenticated;
revoke all on function public.enforce_minimum_age() from public, anon, authenticated;
revoke all on function public.protect_birth_date() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.handle_user_email_change() from public, anon, authenticated;
grant execute on function public.handle_new_user() to supabase_auth_admin;
grant execute on function public.handle_user_email_change() to supabase_auth_admin;
-- is_privileged is only called from triggers; it never needs to be an RPC.
revoke all on function public.is_privileged() from public, anon, authenticated;

insert into public.meta (key, value) values ('schema_version', '2.2')
  on conflict (key) do update set value = excluded.value, updated_at = now();
