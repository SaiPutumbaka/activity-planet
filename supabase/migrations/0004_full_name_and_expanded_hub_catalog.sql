-- ============================================================================
-- Activity Planet — Migration 0004
-- Adds a display name to profiles, and switches the hub catalog from a
-- small hardcoded list to a large, code-maintained one. Run in the Supabase
-- SQL Editor after 0001, 0002, and 0003.
-- ============================================================================

-- ============================================================================
-- 1. DISPLAY NAME
--    Separate from `username` (the @handle) — shown prominently on the
--    profile, Instagram-style. Optional: falls back to the username in the UI.
-- ============================================================================
alter table public.profiles
  add column full_name text not null default '';

alter table public.profiles
  add constraint profiles_full_name_length check (char_length(full_name) <= 60);

comment on column public.profiles.full_name is
  'Display name shown above @username on the profile. Optional — UI falls back to username.';

-- ============================================================================
-- 2. EXPANDED HUB CATALOG
--    The hub list grew from 8 fixed options to a large, evolving catalog
--    (src/lib/hub-catalog.ts). Hardcoding 150+ literal values into two SQL
--    IN-lists would mean a migration every time the catalog changes, and
--    duplicated, driftable data between SQL and TypeScript. Instead, the
--    TypeScript HUBS array (validated on every write via Zod) is the single
--    source of truth; the database keeps a lighter length/shape check as a
--    defense-in-depth backstop rather than an exact enum match.
-- ============================================================================
alter table public.events
  drop constraint events_category_allowed;

alter table public.events
  add constraint events_category_length check (char_length(category) between 1 and 60);

alter table public.hub_messages
  drop constraint hub_messages_hub_allowed;

alter table public.hub_messages
  add constraint hub_messages_hub_length check (char_length(hub) between 1 and 60);

-- A larger catalog calls for a higher (but still meaningful) "pick your
-- interests" ceiling — was capped at 8 back when there were exactly 8 hubs.
alter table public.profiles
  drop constraint profiles_hobbies_max;

alter table public.profiles
  add constraint profiles_hobbies_max check (coalesce(array_length(selected_hobbies, 1), 0) <= 15);
