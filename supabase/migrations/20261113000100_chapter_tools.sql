-- ============================================================================
-- Activity Planet schema v2 — migration 16: chapter claims, chapter roles,
--   captain attendee tools, public chapter card
--   (PLAN.md 4.5; D-015, D-022, D-031, D-035).
--
--   What this file does
--     * hub_chapters gains rso_name, pin_url (https only), claimed_by,
--       claimed_at, verified_at. There is no student_orgs table: the RSO
--       identity lives on the claim and on the chapter.
--     * chapter_claim_status enum and chapter_claims: a request to run a
--       chapter, either of an organization (org_id, optional campus_id) or of
--       an area (area_id; D-035). One pending claim per (user, hub, place);
--       readable by the claimant and moderators; written only through RPCs.
--     * submit_chapter_claim(jsonb): an org claim needs a verified, unexpired
--       org_memberships row for that organization (and campus, when both name
--       one); an area claim needs an active, onboarded adult (a moderator
--       reviews it before any role is granted). Refused when the chapter
--       already has an organizer; at most 3 open claims per user.
--     * review_chapter_claim(id, approve, note): moderators only, never on
--       their own claim. Approving creates the hub_chapters row when absent,
--       makes the claimant its organizer, raises org_memberships.role to
--       officer for org claims and stamps claimed_by / claimed_at /
--       verified_at, all in one transaction.
--     * withdraw_chapter_claim(id), my_chapter_claims().
--     * set_chapter_role rebuilt: an organizer may set member or captain on
--       non-organizers (and step down themselves); only a moderator grants
--       organizer or changes another organizer; for an organization's chapter
--       a captain or organizer must hold a verified membership in it; the last
--       organizer can never be demoted. remove_chapter_member(chapter, user):
--       organizer, captain or moderator; a captain cannot remove an organizer;
--       the last organizer cannot be removed. A trigger keeps the last
--       organizer from leaving through the direct delete policy too (account
--       deletion, cascades and moderators excepted).
--     * viewer_can_manage_event(event): host, captain or organizer of the
--       event's chapter, or moderator. my_managed_chapters().
--     * rsvps.checked_in_by; host_check_in(event, user, checked) for anyone
--       viewer_can_manage_event allows, from 1 hour before the start to 24
--       hours after the end; check_in (self) now stamps checked_in_by too.
--     * chapter_public_card(slug or id) for anon and authenticated: name,
--       hub, organization / campus / area label, RSO name and PIN link,
--       verified flag, member count, upcoming public events count. Nothing
--       personal.
--     * request_account_deletion: also deletes the caller's chapter claims
--       and clears claimed_by, chapter_claims.reviewed_by and
--       rsvps.checked_in_by that point at the caller.
--     * meta.schema_version 2.12.
--
--   Already in place and left unchanged (checked against the latest bodies):
--   event_attendees, approve_rsvp and remove_rsvp authorize captains and
--   organizers of the event's chapter (is_chapter_captain); create_event and
--   create_event_series accept kind 'chapter' with chapter_id for captains
--   and organizers, and series take starts_on / ends_on; set_rsvp does not
--   touch check-in columns.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. hub_chapters: RSO identity and claim stamps
-- ---------------------------------------------------------------------------
alter table public.hub_chapters add column if not exists rso_name    text;
alter table public.hub_chapters add column if not exists pin_url     text;
alter table public.hub_chapters add column if not exists claimed_by  uuid references public.profiles (id) on delete set null;
alter table public.hub_chapters add column if not exists claimed_at  timestamptz;
alter table public.hub_chapters add column if not exists verified_at timestamptz;
do $$ begin
  alter table public.hub_chapters
    add constraint hub_chapters_rso_name_length check (rso_name is null or char_length(rso_name) between 2 and 120);
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.hub_chapters
    add constraint hub_chapters_pin_url_format check (pin_url is null or (char_length(pin_url) <= 500 and pin_url ~ '^https://'));
exception when duplicate_object then null; end $$;
create index if not exists hub_chapters_claimed_by_idx on public.hub_chapters (claimed_by);
comment on column public.hub_chapters.rso_name is 'Registered student organization name, from the approved claim (no student_orgs table).';
comment on column public.hub_chapters.pin_url is 'https link to the organization''s PIN (Engage) page or other public listing.';
comment on column public.hub_chapters.verified_at is 'When a moderator approved the claim that gave this chapter its organizer.';

-- ---------------------------------------------------------------------------
-- 2. rsvps.checked_in_by (not client-selectable: rsvps has column grants)
-- ---------------------------------------------------------------------------
alter table public.rsvps add column if not exists checked_in_by uuid references public.profiles (id) on delete set null;
create index if not exists rsvps_checked_in_by_idx on public.rsvps (checked_in_by);
comment on column public.rsvps.checked_in_by is
  'Who stamped checked_in_at: the attendee (check_in) or a host, captain, organizer or moderator (host_check_in).';

-- ---------------------------------------------------------------------------
-- 3. Chapter claims
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.chapter_claim_status as enum ('pending', 'approved', 'rejected', 'withdrawn');
exception when duplicate_object then null; end $$;

create table if not exists public.chapter_claims (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  hub_id            uuid not null references public.hubs (id) on delete cascade,
  chapter_id        uuid references public.hub_chapters (id) on delete set null,
  kind              text not null,
  org_id            uuid references public.organizations (id) on delete cascade,
  campus_id         uuid references public.org_campuses (id) on delete cascade,
  area_id           uuid references public.areas (id) on delete cascade,
  proposed_name     text not null,
  rso_name          text,
  pin_url           text,
  officer_role_text text,
  reference_name    text,
  reference_contact text,
  motivation        text not null default '',
  agreement_version text not null,
  status            public.chapter_claim_status not null default 'pending',
  reviewed_by       uuid references public.profiles (id) on delete set null,
  reviewed_at       timestamptz,
  review_note       text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint chapter_claims_kind check (kind in ('org', 'area')),
  constraint chapter_claims_place check (
    (kind = 'org'  and org_id is not null and area_id is null)
    or (kind = 'area' and area_id is not null and org_id is null and campus_id is null)),
  constraint chapter_claims_proposed_name_length     check (char_length(proposed_name) between 2 and 100),
  constraint chapter_claims_rso_name_length          check (rso_name is null or char_length(rso_name) between 2 and 120),
  constraint chapter_claims_pin_url_format           check (pin_url is null or (char_length(pin_url) <= 500 and pin_url ~ '^https://')),
  constraint chapter_claims_officer_role_text_length check (officer_role_text is null or char_length(officer_role_text) <= 80),
  constraint chapter_claims_reference_name_length    check (reference_name is null or char_length(reference_name) <= 80),
  constraint chapter_claims_reference_contact_length check (reference_contact is null or char_length(reference_contact) <= 200),
  constraint chapter_claims_motivation_length        check (char_length(motivation) <= 1000),
  constraint chapter_claims_agreement_version_length check (char_length(agreement_version) between 1 and 20),
  constraint chapter_claims_review_note_length       check (review_note is null or char_length(review_note) <= 500),
  constraint chapter_claims_reviewed_stamp           check ((status in ('approved', 'rejected')) = (reviewed_at is not null))
);
create unique index if not exists chapter_claims_one_pending
  on public.chapter_claims (user_id, hub_id, org_id, campus_id, area_id) nulls not distinct
  where status = 'pending';
create index if not exists chapter_claims_user_idx        on public.chapter_claims (user_id, created_at desc);
create index if not exists chapter_claims_status_idx      on public.chapter_claims (status, created_at);
create index if not exists chapter_claims_hub_idx         on public.chapter_claims (hub_id);
create index if not exists chapter_claims_chapter_idx     on public.chapter_claims (chapter_id);
create index if not exists chapter_claims_org_idx         on public.chapter_claims (org_id);
create index if not exists chapter_claims_campus_idx      on public.chapter_claims (campus_id);
create index if not exists chapter_claims_area_idx        on public.chapter_claims (area_id);
create index if not exists chapter_claims_reviewed_by_idx on public.chapter_claims (reviewed_by);
comment on table public.chapter_claims is
  'Requests to run a chapter: kind org (org_id, optional campus_id; needs a verified org membership) or area (area_id; D-035). Readable by the claimant and moderators. Written only by submit_chapter_claim, review_chapter_claim and withdraw_chapter_claim. Deleted with the account (request_account_deletion).';
create or replace trigger chapter_claims_set_updated_at before update on public.chapter_claims
  for each row execute function public.set_updated_at();

alter table public.chapter_claims enable row level security;
drop policy if exists "chapter_claims_select" on public.chapter_claims;
create policy "chapter_claims_select" on public.chapter_claims for select to authenticated
  using (user_id = (select auth.uid()) or (select public.is_moderator()));

revoke all on public.chapter_claims from public, anon, authenticated;
grant select on public.chapter_claims to authenticated;
grant all on public.chapter_claims to service_role;

-- ---------------------------------------------------------------------------
-- 4. Internals: slug for a new chapter, last-organizer guard
-- ---------------------------------------------------------------------------
create or replace function public.chapter_slug_for(p_name text)
returns text language plpgsql volatile security definer set search_path = '' as $$
declare
  v_base text;
  v_slug text;
  i      integer := 1;
begin
  v_base := btrim(regexp_replace(lower(coalesce(p_name, '')), '[^a-z0-9]+', '-', 'g'), '-');
  v_base := btrim(left(v_base, 60), '-');
  if v_base is null or v_base = '' then
    v_base := 'chapter';
  end if;
  v_slug := v_base;
  while exists (select 1 from public.hub_chapters where slug = v_slug) loop
    i := i + 1;
    v_slug := v_base || '-' || i;
  end loop;
  return v_slug;
end $$;

-- A chapter that has an organizer keeps one. Applies to the direct
-- "leave the chapter" delete as well as the RPCs. Not enforced when the
-- chapter itself is going (cascade), when the member's profile is gone or no
-- longer active (account deletion), or for the service role and moderators
-- (their RPC paths check explicitly).
create or replace function public.chapter_members_keep_organizer()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if old.role = 'organizer'
     and (tg_op = 'DELETE' or new.role <> 'organizer')
     and not public.is_privileged()
     and exists (select 1 from public.hub_chapters where id = old.chapter_id)
     and exists (select 1 from public.profiles where id = old.user_id and status = 'active')
     and not exists (select 1 from public.chapter_members
                      where chapter_id = old.chapter_id and role = 'organizer' and user_id <> old.user_id) then
    raise exception 'last_organizer' using errcode = 'check_violation',
      hint = 'A chapter keeps at least one organizer; ask a moderator to hand it over.';
  end if;
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end $$;
drop trigger if exists chapter_members_keep_organizer on public.chapter_members;
create trigger chapter_members_keep_organizer before update of role or delete on public.chapter_members
  for each row execute function public.chapter_members_keep_organizer();

-- ---------------------------------------------------------------------------
-- 5. Claim RPCs
--    submit_chapter_claim keys: kind (org | area; default area when area_id
--    is given, else org), hub_id*, chapter_id, org_id, campus_id, area_id,
--    proposed_name (defaults to the chapter's name), rso_name, pin_url,
--    officer_role_text, reference_name, reference_contact, motivation,
--    agreement_version*.
-- ---------------------------------------------------------------------------
create or replace function public.submit_chapter_claim(p_args jsonb)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  a         jsonb := coalesce(p_args, '{}'::jsonb);
  c         public.chapter_claims%rowtype;
  p         public.profiles%rowtype;
  v_hub     public.hubs%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_age     integer;
  v_c       text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into p from public.profiles where id = uid;
  if p.status is distinct from 'active' or p.onboarding_completed_at is null or p.deleted_at is not null then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_age := public.viewer_age();
  if v_age is null or v_age < 18 then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  c.user_id           := uid;
  c.hub_id            := (a ->> 'hub_id')::uuid;
  c.chapter_id        := (a ->> 'chapter_id')::uuid;
  c.org_id            := (a ->> 'org_id')::uuid;
  c.campus_id         := (a ->> 'campus_id')::uuid;
  c.area_id           := (a ->> 'area_id')::uuid;
  c.kind              := coalesce(nullif(btrim(coalesce(a ->> 'kind', '')), ''),
                                  case when c.area_id is not null then 'area' else 'org' end);
  c.proposed_name     := nullif(btrim(coalesce(a ->> 'proposed_name', '')), '');
  c.rso_name          := nullif(btrim(coalesce(a ->> 'rso_name', '')), '');
  c.pin_url           := nullif(btrim(coalesce(a ->> 'pin_url', '')), '');
  c.officer_role_text := nullif(btrim(coalesce(a ->> 'officer_role_text', '')), '');
  c.reference_name    := nullif(btrim(coalesce(a ->> 'reference_name', '')), '');
  c.reference_contact := nullif(btrim(coalesce(a ->> 'reference_contact', '')), '');
  c.motivation        := btrim(coalesce(a ->> 'motivation', ''));
  c.agreement_version := nullif(btrim(coalesce(a ->> 'agreement_version', '')), '');

  if c.kind not in ('org', 'area') then
    raise exception 'invalid_kind' using errcode = 'check_violation';
  end if;
  if c.agreement_version is null then
    raise exception 'agreement_required' using errcode = 'check_violation',
      hint = 'Accept the Captain Program agreement.';
  end if;
  if c.pin_url is not null and c.pin_url !~ '^https://' then
    raise exception 'pin_url_invalid' using errcode = 'check_violation', hint = 'Use an https:// link.';
  end if;

  select * into v_hub from public.hubs where id = c.hub_id;
  if not found then
    raise exception 'hub_not_found' using errcode = 'P0002';
  end if;
  if not v_hub.is_active then
    raise exception 'hub_inactive' using errcode = 'check_violation';
  end if;
  if v_age < v_hub.min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  -- An existing chapter fixes the place; otherwise look it up by place.
  if c.chapter_id is not null then
    select * into v_chapter from public.hub_chapters where id = c.chapter_id;
    if not found or not v_chapter.is_active then
      raise exception 'chapter_not_found' using errcode = 'P0002';
    end if;
    if v_chapter.hub_id <> c.hub_id then
      raise exception 'chapter_mismatch' using errcode = 'check_violation';
    end if;
    if exists (select 1 from public.chapter_members where chapter_id = c.chapter_id and role = 'organizer') then
      raise exception 'chapter_has_organizer' using errcode = 'check_violation',
        hint = 'This chapter already has an organizer.';
    end if;
    c.kind      := case when v_chapter.org_id is not null then 'org' else 'area' end;
    c.org_id    := v_chapter.org_id;
    c.campus_id := v_chapter.campus_id;
    c.area_id   := v_chapter.area_id;
  end if;

  if c.kind = 'org' then
    c.area_id := null;
    if c.org_id is null then
      raise exception 'org_required' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.organizations where id = c.org_id) then
      raise exception 'org_not_found' using errcode = 'P0002';
    end if;
    if c.campus_id is not null and not exists (
         select 1 from public.org_campuses where id = c.campus_id and org_id = c.org_id) then
      raise exception 'campus_not_found' using errcode = 'P0002';
    end if;
    if not exists (
         select 1 from public.org_memberships m
          where m.user_id = uid and m.org_id = c.org_id
            and (m.expires_at is null or m.expires_at > now())
            and (c.campus_id is null or m.campus_id is null or m.campus_id = c.campus_id)) then
      raise exception 'membership_required' using errcode = '42501',
        hint = 'Verify your email with this organization first.';
    end if;
  else
    c.org_id    := null;
    c.campus_id := null;
    if c.area_id is null then
      raise exception 'area_required' using errcode = 'check_violation';
    end if;
    if not exists (select 1 from public.areas where id = c.area_id) then
      raise exception 'area_not_found' using errcode = 'P0002';
    end if;
  end if;

  if c.chapter_id is null then
    select * into v_chapter from public.hub_chapters ch
     where ch.hub_id = c.hub_id
       and ch.org_id is not distinct from c.org_id
       and ch.campus_id is not distinct from c.campus_id
       and ch.area_id is not distinct from c.area_id;
    if found then
      if not v_chapter.is_active then
        raise exception 'chapter_not_found' using errcode = 'P0002';
      end if;
      c.chapter_id := v_chapter.id;
    end if;
  end if;
  if c.chapter_id is not null and exists (
       select 1 from public.chapter_members where chapter_id = c.chapter_id and role = 'organizer') then
    raise exception 'chapter_has_organizer' using errcode = 'check_violation',
      hint = 'This chapter already has an organizer.';
  end if;
  c.proposed_name := coalesce(c.proposed_name, v_chapter.name);
  if c.proposed_name is null then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;

  -- Serialize per user so two concurrent submits cannot both pass the limit.
  perform pg_advisory_xact_lock(hashtext('chapter_claims:' || uid::text));
  if (select count(*) from public.chapter_claims where user_id = uid and status = 'pending') >= 3 then
    raise exception 'too_many_claims' using errcode = 'check_violation', hint = 'Up to three open claims.';
  end if;
  if exists (select 1 from public.chapter_claims
              where user_id = uid and status = 'pending' and hub_id = c.hub_id
                and org_id is not distinct from c.org_id and campus_id is not distinct from c.campus_id
                and area_id is not distinct from c.area_id) then
    raise exception 'claim_pending' using errcode = 'unique_violation',
      hint = 'You already have an open claim for this chapter.';
  end if;

  insert into public.chapter_claims (user_id, hub_id, chapter_id, kind, org_id, campus_id, area_id, proposed_name,
                                     rso_name, pin_url, officer_role_text, reference_name, reference_contact,
                                     motivation, agreement_version)
  values (c.user_id, c.hub_id, c.chapter_id, c.kind, c.org_id, c.campus_id, c.area_id, c.proposed_name,
          c.rso_name, c.pin_url, c.officer_role_text, c.reference_name, c.reference_contact,
          c.motivation, c.agreement_version)
  returning * into c;
  return c;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.submit_chapter_claim(jsonb) is
  'Asks to run a chapter (PLAN 4.5, D-035). kind org: verified org membership (and campus when both name one). kind area: any onboarded active adult; a moderator reviews it before any role. Errors: not_authenticated, onboarding_required, age_restricted, invalid_kind, agreement_required, pin_url_invalid, hub_not_found, hub_inactive, chapter_not_found, chapter_mismatch, org_required, org_not_found, campus_not_found, membership_required, area_required, area_not_found, chapter_has_organizer, name_required, too_many_claims, claim_pending, or a table constraint name.';

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
          and (m.expires_at is null or m.expires_at > now())) then
    raise exception 'membership_required' using errcode = 'check_violation',
      hint = 'The claimant''s verified membership has lapsed.';
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
  'Moderators approve or reject a pending claim (never their own). Approval, in one transaction: creates the chapter when absent, makes the claimant its organizer, raises org_memberships.role to officer for org claims, stamps claimed_by, claimed_at and verified_at. Errors: not_authenticated, forbidden, invalid_decision, claim_not_found, own_claim, claim_not_pending, claimant_inactive, membership_required, chapter_has_organizer.';

create or replace function public.withdraw_chapter_claim(p_claim_id uuid)
returns public.chapter_claims language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  c   public.chapter_claims%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into c from public.chapter_claims where id = p_claim_id and user_id = uid for update;
  if not found then
    raise exception 'claim_not_found' using errcode = 'P0002';
  end if;
  if c.status = 'withdrawn' then
    return c;
  end if;
  if c.status <> 'pending' then
    raise exception 'claim_not_pending' using errcode = 'check_violation';
  end if;
  update public.chapter_claims set status = 'withdrawn' where id = c.id returning * into c;
  return c;
end $$;

comment on function public.withdraw_chapter_claim(uuid) is
  'The claimant withdraws a pending claim. Idempotent. Errors: not_authenticated, claim_not_found, claim_not_pending.';

create or replace function public.my_chapter_claims()
returns table (
  id                uuid,
  kind              text,
  status            public.chapter_claim_status,
  hub_id            uuid,
  hub_slug          text,
  hub_name          text,
  chapter_id        uuid,
  chapter_slug      text,
  org_id            uuid,
  campus_id         uuid,
  area_id           uuid,
  place_label       text,
  proposed_name     text,
  rso_name          text,
  pin_url           text,
  officer_role_text text,
  review_note       text,
  created_at        timestamptz,
  reviewed_at       timestamptz
)
language sql stable security definer set search_path = '' as $$
  select c.id, c.kind, c.status, c.hub_id, h.slug, h.name, c.chapter_id, ch.slug,
         c.org_id, c.campus_id, c.area_id,
         coalesce(oc.name, o.name, ar.name),
         c.proposed_name, c.rso_name, c.pin_url, c.officer_role_text, c.review_note, c.created_at, c.reviewed_at
    from public.chapter_claims c
    join public.hubs h on h.id = c.hub_id
    left join public.hub_chapters ch on ch.id = c.chapter_id
    left join public.organizations o on o.id = c.org_id
    left join public.org_campuses oc on oc.id = c.campus_id
    left join public.areas ar on ar.id = c.area_id
   where c.user_id = (select auth.uid())
   order by c.created_at desc;
$$;

comment on function public.my_chapter_claims() is
  'The caller''s chapter claims, newest first, with hub, chapter and place labels.';

-- ---------------------------------------------------------------------------
-- 6. Chapter roles and members
-- ---------------------------------------------------------------------------
create or replace function public.set_chapter_role(p_chapter uuid, p_user uuid, p_role public.chapter_role)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_mod     boolean := public.is_moderator();
  v_chapter public.hub_chapters%rowtype;
  v_mine    public.chapter_role;
  v_target  public.chapter_members%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_role is null then
    raise exception 'invalid_role' using errcode = 'check_violation';
  end if;
  -- The chapter row lock serializes role changes, so two organizers cannot
  -- demote each other at once.
  select * into v_chapter from public.hub_chapters where id = p_chapter for update;
  if not found then
    raise exception 'chapter_not_found' using errcode = 'P0002';
  end if;
  select role into v_mine from public.chapter_members where chapter_id = p_chapter and user_id = uid;
  if not v_mod then
    if v_mine is distinct from 'organizer' then
      raise exception 'forbidden' using errcode = '42501';
    end if;
    if p_role = 'organizer' then
      raise exception 'organizer_requires_moderator' using errcode = '42501',
        hint = 'Only a moderator can make someone an organizer.';
    end if;
  end if;

  select * into v_target from public.chapter_members where chapter_id = p_chapter and user_id = p_user for update;
  if not found then
    raise exception 'not_a_member' using errcode = 'P0002';
  end if;
  if v_target.role = p_role then
    return;
  end if;
  if v_target.role = 'organizer' then
    if not v_mod and p_user <> uid then
      raise exception 'forbidden' using errcode = '42501',
        hint = 'Only a moderator changes another organizer''s role.';
    end if;
    if not exists (select 1 from public.chapter_members
                    where chapter_id = p_chapter and role = 'organizer' and user_id <> p_user) then
      raise exception 'last_organizer' using errcode = 'check_violation',
        hint = 'A chapter keeps at least one organizer.';
    end if;
  end if;
  if p_role in ('captain', 'organizer') then
    if not exists (select 1 from public.profiles where id = p_user and status = 'active' and onboarding_completed_at is not null) then
      raise exception 'member_inactive' using errcode = 'check_violation';
    end if;
    -- No informal captains on an organization's chapter: verified members only.
    if v_chapter.org_id is not null and not exists (
         select 1 from public.org_memberships m
          where m.user_id = p_user and m.org_id = v_chapter.org_id
            and (m.expires_at is null or m.expires_at > now())) then
      raise exception 'membership_required' using errcode = 'check_violation',
        hint = 'Captains of an organization''s chapter need a verified membership in it.';
    end if;
  end if;

  update public.chapter_members set role = p_role where chapter_id = p_chapter and user_id = p_user;
end $$;

comment on function public.set_chapter_role(uuid, uuid, public.chapter_role) is
  'Changes a chapter member''s role. Organizers set member or captain on non-organizers and may step down themselves; only moderators grant organizer or change another organizer; the last organizer is never demoted; on an organization''s chapter captains and organizers need a verified membership. Errors: not_authenticated, invalid_role, chapter_not_found, forbidden, organizer_requires_moderator, not_a_member, last_organizer, member_inactive, membership_required.';

create or replace function public.remove_chapter_member(p_chapter uuid, p_user uuid)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  v_mod    boolean := public.is_moderator();
  v_mine   public.chapter_role;
  v_target public.chapter_members%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  perform 1 from public.hub_chapters where id = p_chapter for update;
  if not found then
    raise exception 'chapter_not_found' using errcode = 'P0002';
  end if;
  select role into v_mine from public.chapter_members where chapter_id = p_chapter and user_id = uid;
  if not v_mod and (v_mine is null or v_mine = 'member') then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into v_target from public.chapter_members where chapter_id = p_chapter and user_id = p_user for update;
  if not found then
    raise exception 'not_a_member' using errcode = 'P0002';
  end if;
  if v_target.role = 'organizer' then
    if not v_mod and v_mine <> 'organizer' then
      raise exception 'forbidden' using errcode = '42501', hint = 'Captains cannot remove an organizer.';
    end if;
    if not v_mod and p_user <> uid then
      raise exception 'forbidden' using errcode = '42501',
        hint = 'Only a moderator removes another organizer.';
    end if;
    if not exists (select 1 from public.chapter_members
                    where chapter_id = p_chapter and role = 'organizer' and user_id <> p_user) then
      raise exception 'last_organizer' using errcode = 'check_violation',
        hint = 'A chapter keeps at least one organizer.';
    end if;
  end if;
  delete from public.chapter_members where chapter_id = p_chapter and user_id = p_user;
end $$;

comment on function public.remove_chapter_member(uuid, uuid) is
  'Removes someone from a chapter: organizers, captains and moderators may; a captain cannot remove an organizer; only a moderator removes another organizer; the last organizer is never removed. Errors: not_authenticated, chapter_not_found, forbidden, not_a_member, last_organizer.';

create or replace function public.my_managed_chapters()
returns table (
  chapter_id  uuid,
  slug        text,
  name        text,
  role        public.chapter_role,
  hub_id      uuid,
  hub_slug    text,
  hub_name    text,
  org_id      uuid,
  campus_id   uuid,
  area_id     uuid,
  place_label text,
  is_active   boolean
)
language sql stable security definer set search_path = '' as $$
  select ch.id, ch.slug, ch.name, cm.role, h.id, h.slug, h.name, ch.org_id, ch.campus_id, ch.area_id,
         coalesce(oc.name, o.name, ar.name), ch.is_active
    from public.chapter_members cm
    join public.hub_chapters ch on ch.id = cm.chapter_id
    join public.hubs h on h.id = ch.hub_id
    left join public.organizations o on o.id = ch.org_id
    left join public.org_campuses oc on oc.id = ch.campus_id
    left join public.areas ar on ar.id = ch.area_id
   where cm.user_id = (select auth.uid()) and cm.role in ('captain', 'organizer')
   order by ch.name;
$$;

comment on function public.my_managed_chapters() is
  'Chapters where the caller is a captain or organizer (the "post as" picker and the captain tools).';

-- ---------------------------------------------------------------------------
-- 7. Event management: viewer_can_manage_event, host_check_in, check_in
-- ---------------------------------------------------------------------------
create or replace function public.viewer_can_manage_event(p_event_id uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select (select auth.uid()) is not null and exists (
    select 1 from public.events e
     where e.id = p_event_id
       and (e.host_id = (select auth.uid())
            or public.is_chapter_captain(e.chapter_id)
            or public.is_moderator())
  );
$$;

comment on function public.viewer_can_manage_event(uuid) is
  'True when the caller is the host, a captain or organizer of the event''s chapter, or a moderator.';

create or replace function public.host_check_in(p_event_id uuid, p_user_id uuid, p_checked boolean default true)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not public.viewer_can_manage_event(p_event_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.starts_at - interval '1 hour' or now() > e.ends_at + interval '24 hours' then
    raise exception 'check_in_window' using errcode = 'check_violation',
      hint = 'Check people in from an hour before the start until a day after the end.';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'P0002';
  end if;
  if coalesce(p_checked, true) then
    if r.status <> 'going' then
      raise exception 'not_going' using errcode = 'check_violation';
    end if;
    if r.checked_in_at is null then
      update public.rsvps set checked_in_at = now(), checked_in_by = uid
       where event_id = p_event_id and user_id = p_user_id
       returning * into r;
    end if;
  elsif r.checked_in_at is not null then
    update public.rsvps set checked_in_at = null, checked_in_by = null
     where event_id = p_event_id and user_id = p_user_id
     returning * into r;
  end if;
  return r;
end $$;

comment on function public.host_check_in(uuid, uuid, boolean) is
  'Host, chapter captain or organizer, or moderator checks a going attendee in (p_checked true) or undoes it (false), from 1 hour before the start to 24 hours after the end. Idempotent. Errors: not_authenticated, event_not_found, forbidden, event_cancelled, check_in_window, rsvp_not_found, not_going.';

-- Same as migration 6 plus checked_in_by. Window: one hour before start to
-- six hours after end. Going RSVPs only.
create or replace function public.check_in(p_event_id uuid)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.starts_at - interval '1 hour' or now() > e.ends_at + interval '6 hours' then
    raise exception 'check_in_window' using errcode = 'check_violation',
      hint = 'Check in from an hour before the start until six hours after the end.';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  if not found or r.status <> 'going' then
    raise exception 'not_going' using errcode = 'check_violation', hint = 'Tap Going first.';
  end if;
  if r.checked_in_at is null then
    update public.rsvps set checked_in_at = now(), checked_in_by = uid
     where event_id = p_event_id and user_id = uid
     returning * into r;
  end if;
  return r;
end $$;

comment on function public.check_in(uuid) is
  'Stamps checked_in_at (and checked_in_by = the caller) on the caller''s going RSVP, from 1 hour before start to 6 hours after end. Idempotent. Errors: not_authenticated, event_not_found, event_cancelled, check_in_window, not_going.';

-- ---------------------------------------------------------------------------
-- 8. Public chapter card (logged-out chapter page; nothing personal)
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
           'verified', c.verified_at is not null,
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
  'Logged-out chapter card by slug or id: id, slug, name, description, cover_url, hub {id, slug, name, emoji}, owner_kind org|area, org {slug, name}, campus {slug, name}, area {slug, name}, place_label, rso_name, pin_url, verified, member_count, upcoming_public_events. No user ids, handles or names of people. Null when missing or inactive.';

-- ---------------------------------------------------------------------------
-- 9. request_account_deletion: chapter claims and the new user references
--    (body of migration 11 plus the chapter lines)
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
  v_event   uuid;
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
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
   where host_id = uid and status = 'published' and starts_at > now();
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;
  update public.rsvps set checked_in_by = null where checked_in_by = uid;

  -- Chapters: the caller's claims (reference contacts included) go; stamps
  -- that point at the caller are cleared. The chapter_members row goes below
  -- (the last-organizer guard lets a deleted profile leave).
  delete from public.chapter_claims where user_id = uid;
  update public.chapter_claims set reviewed_by = null where reviewed_by = uid;
  update public.hub_chapters set claimed_by = null where claimed_by = uid;

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
  delete from public.area_waitlist            where user_id = uid;
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
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships, chapter claims and the city waitlist row removed, claimed_by / reviewed_by / checked_in_by references cleared, hosted series and future events cancelled with their addresses, private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 10. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.chapter_slug_for(text) from public, anon, authenticated;
revoke all on function public.chapter_members_keep_organizer() from public, anon, authenticated;

revoke all on function public.submit_chapter_claim(jsonb) from public, anon;
grant execute on function public.submit_chapter_claim(jsonb) to authenticated;
revoke all on function public.review_chapter_claim(uuid, boolean, text) from public, anon;
grant execute on function public.review_chapter_claim(uuid, boolean, text) to authenticated;
revoke all on function public.withdraw_chapter_claim(uuid) from public, anon;
grant execute on function public.withdraw_chapter_claim(uuid) to authenticated;
revoke all on function public.my_chapter_claims() from public, anon;
grant execute on function public.my_chapter_claims() to authenticated;
revoke all on function public.set_chapter_role(uuid, uuid, public.chapter_role) from public, anon;
grant execute on function public.set_chapter_role(uuid, uuid, public.chapter_role) to authenticated;
revoke all on function public.remove_chapter_member(uuid, uuid) from public, anon;
grant execute on function public.remove_chapter_member(uuid, uuid) to authenticated;
revoke all on function public.my_managed_chapters() from public, anon;
grant execute on function public.my_managed_chapters() to authenticated;
revoke all on function public.viewer_can_manage_event(uuid) from public, anon;
grant execute on function public.viewer_can_manage_event(uuid) to authenticated;
revoke all on function public.host_check_in(uuid, uuid, boolean) from public, anon;
grant execute on function public.host_check_in(uuid, uuid, boolean) to authenticated;
revoke all on function public.check_in(uuid) from public, anon;
grant execute on function public.check_in(uuid) to authenticated;
revoke all on function public.chapter_public_card(text) from public;
grant execute on function public.chapter_public_card(text) to anon, authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.12')
  on conflict (key) do update set value = excluded.value, updated_at = now();
