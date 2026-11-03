-- ============================================================================
-- Activity Planet schema v2 — migration 17: chapter tools review fixes
--   (PLAN.md 4.5; D-035). Fix-forward for 20261113000100_chapter_tools.sql.
--
--   What this file does
--     * chapter_members_clear_claim (AFTER DELETE / UPDATE OF role): when a
--       chapter's last organizer goes (account deletion, removal by a
--       moderator, a moderator demotion or a direct delete), the chapter's
--       verified_at, claimed_at and claimed_by are cleared, so it no longer
--       reads as "Verified organizer" and anyone eligible can claim it again.
--       Existing rows are backfilled the same way.
--     * chapter_public_card: 'verified' also needs an organizer row.
--     * review_chapter_claim: approval re-checks the membership's campus the
--       same way submit_chapter_claim does (a membership that moved to another
--       campus no longer qualifies).
--     * hub_chapters column grants for anon: everything except created_by and
--       claimed_by, so logged-out visitors cannot read people's user ids.
--       authenticated keeps the table-wide select. A new hub_chapters column
--       needs its own anon grant.
--     * meta.schema_version 2.13.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Clear the claim stamps when the last organizer goes
-- ---------------------------------------------------------------------------
create or replace function public.chapter_members_clear_claim()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'organizer'
     and (tg_op = 'DELETE' or new.role <> 'organizer')
     and not exists (select 1 from public.chapter_members
                      where chapter_id = old.chapter_id and role = 'organizer') then
    update public.hub_chapters
       set verified_at = null, claimed_at = null, claimed_by = null
     where id = old.chapter_id
       and (verified_at is not null or claimed_at is not null or claimed_by is not null);
  end if;
  return null;
end $$;

comment on function public.chapter_members_clear_claim() is
  'After the last organizer row of a chapter is deleted or demoted, clears hub_chapters.verified_at, claimed_at and claimed_by.';

drop trigger if exists chapter_members_clear_claim on public.chapter_members;
create trigger chapter_members_clear_claim after update of role or delete on public.chapter_members
  for each row execute function public.chapter_members_clear_claim();

-- Backfill: chapters already left without an organizer.
update public.hub_chapters ch
   set verified_at = null, claimed_at = null, claimed_by = null
 where (ch.verified_at is not null or ch.claimed_at is not null or ch.claimed_by is not null)
   and not exists (select 1 from public.chapter_members cm
                    where cm.chapter_id = ch.id and cm.role = 'organizer');

comment on column public.hub_chapters.verified_at is
  'When a moderator approved the claim that gave this chapter its organizer. Cleared (with claimed_at and claimed_by) when the last organizer goes.';

-- ---------------------------------------------------------------------------
-- 2. review_chapter_claim: approval re-checks the campus too
--    (body of migration 16 plus the campus condition)
-- ---------------------------------------------------------------------------
create or replace function public.review_chapter_claim(p_claim_id uuid, p_approve boolean, p_note text default null)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  c         public.chapter_claims%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_note    text := left(nullif(btrim(coalesce(p_note, '')), ''), 500);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_approve is null then
    raise exception 'invalid_decision' using errcode = 'check_violation';
  end if;
  select * into c from public.chapter_claims where id = p_claim_id for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;
  if c.user_id = uid then
    raise exception 'own_claim' using errcode = '42501', hint = 'Another moderator reviews your claim.';
  end if;
  if c.status <> 'pending' then
    raise exception 'claim_not_pending' using errcode = 'check_violation';
  end if;

  if not p_approve then
    update public.chapter_claims
       set status = 'rejected', reviewed_by = uid, reviewed_at = now(), review_note = v_note
     where id = c.id
     returning * into c;
    return c;
  end if;

  if not exists (select 1 from public.profiles
                  where id = c.user_id and status = 'active' and deleted_at is null) then
    raise exception 'claimant_inactive' using errcode = 'check_violation';
  end if;
  if c.kind = 'org' and not exists (
       select 1 from public.org_memberships m
        where m.user_id = c.user_id and m.org_id = c.org_id
          and (m.expires_at is null or m.expires_at > now())
          and (c.campus_id is null or m.campus_id is null or m.campus_id = c.campus_id)) then
    raise exception 'membership_required' using errcode = 'check_violation',
      hint = 'The claimant''s verified membership has lapsed or moved to another campus.';
  end if;

  -- The chapter: the claim's, else the one at this place, else a new row.
  if c.chapter_id is not null then
    select * into v_chapter from public.hub_chapters where id = c.chapter_id for update;
  end if;
  if v_chapter.id is null then
    select * into v_chapter from public.hub_chapters ch
     where ch.hub_id = c.hub_id
       and ch.org_id is not distinct from c.org_id
       and ch.campus_id is not distinct from c.campus_id
       and ch.area_id is not distinct from c.area_id
     for update;
  end if;
  if v_chapter.id is null then
    insert into public.hub_chapters (hub_id, org_id, campus_id, area_id, slug, name, created_by, rso_name, pin_url)
    values (c.hub_id, c.org_id, c.campus_id, c.area_id, public.chapter_slug_for(c.proposed_name), c.proposed_name,
            c.user_id, c.rso_name, c.pin_url)
    returning * into v_chapter;
  end if;
  if exists (select 1 from public.chapter_members
              where chapter_id = v_chapter.id and role = 'organizer' and user_id <> c.user_id) then
    raise exception 'chapter_has_organizer' using errcode = 'check_violation';
  end if;

  insert into public.chapter_members (user_id, chapter_id, role)
  values (c.user_id, v_chapter.id, 'organizer')
  on conflict (user_id, chapter_id) do update set role = 'organizer';

  if c.kind = 'org' then
    update public.org_memberships
       set role = 'officer'
     where user_id = c.user_id and org_id = c.org_id and role < 'officer';
  end if;

  update public.hub_chapters
     set claimed_by  = c.user_id,
         claimed_at  = now(),
         verified_at = now(),
         is_active   = true,
         rso_name    = coalesce(c.rso_name, rso_name),
         pin_url     = coalesce(c.pin_url, pin_url)
   where id = v_chapter.id;

  update public.chapter_claims
     set status = 'approved', chapter_id = v_chapter.id, reviewed_by = uid, reviewed_at = now(), review_note = v_note
   where id = c.id
   returning * into c;
  return c;
end $$;

comment on function public.review_chapter_claim(uuid, boolean, text) is
  'Moderators approve or reject a pending claim (never their own). Approval, in one transaction: re-checks the claimant''s verified membership (organization and campus, as at submit), creates the chapter when absent, makes the claimant its organizer, raises org_memberships.role to officer for org claims, stamps claimed_by, claimed_at and verified_at. Errors: not_authenticated, forbidden, invalid_decision, claim_not_found, own_claim, claim_not_pending, claimant_inactive, membership_required, chapter_has_organizer.';

-- ---------------------------------------------------------------------------
-- 3. chapter_public_card: verified only while an organizer exists
--    (body of migration 16 with the verified flag changed)
-- ---------------------------------------------------------------------------
create or replace function public.chapter_public_card(p_chapter text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_key text := lower(btrim(coalesce(p_chapter, '')));
  v_id  uuid;
  v_out jsonb;
begin
  if v_key ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
    v_id := v_key::uuid;
  else
    select id into v_id from public.hub_chapters where slug = v_key;
  end if;
  if v_id is null then
    return null;
  end if;

  select jsonb_build_object(
           'id', c.id,
           'slug', c.slug,
           'name', c.name,
           'description', c.description,
           'cover_url', c.cover_url,
           'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
           'owner_kind', case when c.org_id is not null then 'org' else 'area' end,
           'org', case when o.id is not null then jsonb_build_object('slug', o.slug, 'name', o.name) end,
           'campus', case when oc.id is not null then jsonb_build_object('slug', oc.slug, 'name', oc.name) end,
           'area', case when ar.id is not null then jsonb_build_object('slug', ar.slug, 'name', ar.name) end,
           'place_label', coalesce(oc.name, o.name, ar.name),
           'rso_name', c.rso_name,
           'pin_url', c.pin_url,
           'verified', c.verified_at is not null
                       and exists (select 1 from public.chapter_members om
                                    where om.chapter_id = c.id and om.role = 'organizer'),
           'member_count', (select count(*) from public.chapter_members cm where cm.chapter_id = c.id),
           'upcoming_public_events', (select count(*) from public.events e
                                       where e.chapter_id = c.id and e.status = 'published'
                                         and e.visibility = 'public' and e.starts_at > now())
         )
    into v_out
    from public.hub_chapters c
    join public.hubs h on h.id = c.hub_id
    left join public.organizations o on o.id = c.org_id
    left join public.org_campuses oc on oc.id = c.campus_id
    left join public.areas ar on ar.id = c.area_id
   where c.id = v_id and c.is_active and h.is_active;
  return v_out;
end $$;

comment on function public.chapter_public_card(text) is
  'Logged-out chapter card by slug or id: id, slug, name, description, cover_url, hub {id, slug, name, emoji}, owner_kind org|area, org {slug, name}, campus {slug, name}, area {slug, name}, place_label, rso_name, pin_url, verified (approved claim and an organizer today), member_count, upcoming_public_events. No user ids, handles or names of people. Null when missing or inactive.';

-- ---------------------------------------------------------------------------
-- 4. hub_chapters: anon reads every column except the user references
-- ---------------------------------------------------------------------------
revoke select on public.hub_chapters from anon;
grant select (id, hub_id, org_id, campus_id, area_id, slug, name, description, cover_url, is_active,
              rso_name, pin_url, claimed_at, verified_at, created_at, updated_at)
  on public.hub_chapters to anon;
grant select on public.hub_chapters to authenticated;

-- ---------------------------------------------------------------------------
-- 5. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.chapter_members_clear_claim() from public, anon, authenticated;
revoke all on function public.review_chapter_claim(uuid, boolean, text) from public, anon;
grant execute on function public.review_chapter_claim(uuid, boolean, text) to authenticated;
revoke all on function public.chapter_public_card(text) from public;
grant execute on function public.chapter_public_card(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.13')
  on conflict (key) do update set value = excluded.value, updated_at = now();
