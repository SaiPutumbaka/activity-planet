-- ============================================================================
-- Activity Planet schema v2 — migration 8: avatars bucket for profile photos
--   (PLAN.md 4.1 "photo (required to RSVP or message)").
--
--   What this file does
--     * makes sure the public 'avatars' storage bucket exists (JPEG, PNG,
--       WebP; 2 MiB per object). Migration 1 already created it on staging
--       and production with a 5 MiB limit; `on conflict do nothing` keeps
--       whatever limit a project already has, so this is a no-op there and a
--       create on a fresh project. The app uploads a 512 x 512 JPEG at
--       quality 0.85 (well under 200 KB), so either limit is far away;
--     * (re)creates the four storage.objects policies for the bucket, so the
--       profile-photo feature is self-contained in one migration:
--         - everyone can read (the bucket is public; the policy is what lets
--           a signed-in client list its own folder);
--         - a signed-in user can insert, update and delete only objects whose
--           path starts with their own user id folder (<uid>/<file>). The
--           app writes <uid>/<timestamp>.jpg with upsert false and deletes
--           the previous object after profiles.avatar_url points at the new
--           one; the delete-account Edge Function removes the whole folder;
--     * stamps schema_version 2.8 (2.7 belongs to the events build's
--       migration, whichever order the two are applied in).
--
--   profiles.avatar_url: migration 1 already grants
--     update (handle, first_name, bio, avatar_url, home_org_id, home_campus_id)
--   on public.profiles to authenticated, with the profiles_update_own policy
--   (id = auth.uid()), so the app updates avatar_url directly and no new
--   grant is needed. Verified on staging before this migration was written.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Bucket
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/jpeg', 'image/png', 'image/webp'])
on conflict do nothing;

-- ---------------------------------------------------------------------------
-- 2. Policies. Drop every avatars% policy first (migration 1 used the same
--    names) so the set below is the only one that applies.
-- ---------------------------------------------------------------------------
do $$
declare p record;
begin
  for p in
    select policyname from pg_policies
     where schemaname = 'storage' and tablename = 'objects' and policyname like 'avatars%'
  loop
    execute format('drop policy if exists %I on storage.objects', p.policyname);
  end loop;
end $$;

-- Everyone can read: the bucket is public, and listing the own folder needs select.
create policy "avatars_public_read" on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');

-- Own folder only: the object name must start with "<auth.uid()>/". A uuid has no LIKE
-- wildcards, so the pattern is exact.
create policy "avatars_insert_own_folder" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and name like (select auth.uid())::text || '/%');

create policy "avatars_update_own_folder" on storage.objects for update to authenticated
  using (bucket_id = 'avatars' and name like (select auth.uid())::text || '/%')
  with check (bucket_id = 'avatars' and name like (select auth.uid())::text || '/%');

create policy "avatars_delete_own_folder" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and name like (select auth.uid())::text || '/%');

-- ---------------------------------------------------------------------------
-- 3. Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.8')
  on conflict (key) do update set value = excluded.value, updated_at = now();
