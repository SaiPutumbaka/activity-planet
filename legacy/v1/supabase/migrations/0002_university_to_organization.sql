-- ============================================================================
-- Activity Planet — Migration 0002
-- "University" becomes "Organization" and is now optional (empty allowed),
-- so non-students (companies, communities, clubs) can onboard too.
-- Run in the Supabase SQL Editor after 0001.
-- ============================================================================

alter table public.profiles rename column university to organization;

alter table public.profiles alter column organization set default '';

alter table public.profiles drop constraint profiles_university_length;

alter table public.profiles add constraint profiles_organization_length
  check (char_length(organization) <= 120);
