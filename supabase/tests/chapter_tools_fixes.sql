-- ============================================================================
-- Staging check for migration 20261113000200_chapter_tools_fixes.sql.
-- One transaction: throwaway users, an organization with two campuses, an
-- org claim and an area claim; DO blocks raise on failure; ROLLBACK at the
-- end. Prints only pass/fail.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_users  uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  v_names  text[] := array['a', 'b', 'c', 'm'];
  v_hubs   uuid[];
  v_org    uuid;
  v_campus uuid;
  v_other  uuid;
  v_tag    text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..4 loop
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_users[i], '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ctf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_users[i];
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_users[i];
    perform set_config('test.' || v_names[i], v_users[i]::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (v_users[4], 'moderator');

  select array_agg(id order by slug) into v_hubs
    from (select h.id, h.slug from public.hubs h
           where h.is_active and h.min_age = 18 and h.scope = 'general'
             and not exists (select 1 from public.hub_chapters ch where ch.hub_id = h.id)
           order by h.slug limit 2) t;
  if coalesce(array_length(v_hubs, 1), 0) < 2 then
    raise exception 'setup: need two general hubs without chapters on staging';
  end if;
  perform set_config('test.hub1', v_hubs[1]::text, true);
  perform set_config('test.hub2', v_hubs[2]::text, true);

  insert into public.organizations (slug, name, kind)
  values ('ctf-org-' || v_tag, 'Chapter Fixes Test University', 'university')
  returning id into v_org;
  insert into public.org_campuses (org_id, slug, name) values (v_org, 'main', 'Main Campus')
  returning id into v_campus;
  insert into public.org_campuses (org_id, slug, name) values (v_org, 'other', 'Other Campus')
  returning id into v_other;
  insert into public.org_memberships (user_id, org_id, campus_id, source)
  values (v_users[1], v_org, v_campus, 'manual'),
         (v_users[3], v_org, v_campus, 'manual');
  perform set_config('test.org', v_org::text, true);
  perform set_config('test.campus', v_campus::text, true);
  perform set_config('test.other', v_other::text, true);
  perform set_config('test.atl', (select id::text from public.areas where slug = 'atlanta'), true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Org claim at Main Campus by A
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  c public.chapter_claims;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  c := public.submit_chapter_claim(jsonb_build_object(
    'kind', 'org', 'hub_id', current_setting('test.hub1'), 'org_id', current_setting('test.org'),
    'campus_id', current_setting('test.campus'), 'proposed_name', 'Fixes Org Chapter', 'agreement_version', 'v1'));
  if c.status <> 'pending' then raise exception 'FAIL 1 claim not pending'; end if;
  perform set_config('test.claim_a', c.id::text, true);
end $$;

-- A's membership moves to the other campus before review.
reset role;
update public.org_memberships set campus_id = current_setting('test.other')::uuid
 where user_id = current_setting('test.a')::uuid and org_id = current_setting('test.org')::uuid;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 2. Approval re-checks the campus
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.review_chapter_claim(current_setting('test.claim_a')::uuid, true, null);
    raise exception 'FAIL 2 approved a claim whose membership moved campus';
  exception when others then
    if sqlerrm <> 'membership_required' then raise exception 'FAIL 2 campus: %', sqlerrm; end if;
  end;
end $$;

reset role;
update public.org_memberships set campus_id = current_setting('test.campus')::uuid
 where user_id = current_setting('test.a')::uuid and org_id = current_setting('test.org')::uuid;
set local role authenticated;

do $$
declare
  c    public.chapter_claims;
  v_ch public.hub_chapters;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  c := public.review_chapter_claim(current_setting('test.claim_a')::uuid, true, null);
  if c.status <> 'approved' or c.chapter_id is null then raise exception 'FAIL 2 approve'; end if;
  select * into v_ch from public.hub_chapters where id = c.chapter_id;
  if v_ch.verified_at is null or v_ch.claimed_by is distinct from current_setting('test.a')::uuid then
    raise exception 'FAIL 2 stamps';
  end if;
  if (public.chapter_public_card(c.chapter_id::text) ->> 'verified')::boolean is not true then
    raise exception 'FAIL 2 card not verified';
  end if;
  perform set_config('test.ch_org', c.chapter_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. The organizer deletes their account: the chapter is unverified and
--    can be claimed again
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;

do $$
declare
  v_ch public.hub_chapters;
  c    public.chapter_claims;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  select * into v_ch from public.hub_chapters where id = current_setting('test.ch_org')::uuid;
  if not found then raise exception 'FAIL 3 chapter not readable'; end if;
  if v_ch.verified_at is not null or v_ch.claimed_at is not null or v_ch.claimed_by is not null then
    raise exception 'FAIL 3 claim stamps survive the last organizer''s deletion';
  end if;
  if (public.chapter_public_card(v_ch.id::text) ->> 'verified')::boolean is not false then
    raise exception 'FAIL 3 card still verified';
  end if;
  c := public.submit_chapter_claim(jsonb_build_object(
    'chapter_id', v_ch.id, 'hub_id', current_setting('test.hub1'), 'agreement_version', 'v1'));
  if c.status <> 'pending' or c.chapter_id <> v_ch.id then raise exception 'FAIL 3 reclaim'; end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Area chapter: a moderator deletes the organizer row directly
-- ---------------------------------------------------------------------------
do $$
declare
  c public.chapter_claims;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  c := public.submit_chapter_claim(jsonb_build_object(
    'kind', 'area', 'hub_id', current_setting('test.hub2'), 'area_id', current_setting('test.atl'),
    'proposed_name', 'Fixes Area Chapter', 'agreement_version', 'v1'));
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  c := public.review_chapter_claim(c.id, true, null);
  if (select verified_at from public.hub_chapters where id = c.chapter_id) is null then
    raise exception 'FAIL 4 area chapter not verified';
  end if;

  delete from public.chapter_members where chapter_id = c.chapter_id and user_id = current_setting('test.b')::uuid;
  if exists (select 1 from public.hub_chapters
              where id = c.chapter_id
                and (verified_at is not null or claimed_at is not null or claimed_by is not null)) then
    raise exception 'FAIL 4 claim stamps survive a moderator delete';
  end if;
  if (public.chapter_public_card(c.chapter_id::text) ->> 'verified')::boolean is not false then
    raise exception 'FAIL 4 card still verified';
  end if;
  perform set_config('test.ch_area', c.chapter_id::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 5. anon cannot read user references on hub_chapters
-- ---------------------------------------------------------------------------
reset role;
set local role anon;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  perform id, hub_id, org_id, campus_id, area_id, slug, name, description, cover_url, is_active,
          rso_name, pin_url, claimed_at, verified_at, created_at, updated_at
     from public.hub_chapters limit 1;
  begin
    perform claimed_by from public.hub_chapters limit 1;
    raise exception 'FAIL 5 anon read claimed_by';
  exception when insufficient_privilege then null;
  end;
  begin
    perform created_by from public.hub_chapters limit 1;
    raise exception 'FAIL 5 anon read created_by';
  exception when insufficient_privilege then null;
  end;
  if public.chapter_public_card(current_setting('test.ch_area')) is null then
    raise exception 'FAIL 5 anon card missing';
  end if;
end $$;

reset role;
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 13] then
    raise exception 'FAIL schema_version is older than 2.13';
  end if;
end $$;

select 'chapter_tools_fixes: all assertions passed' as result;

rollback;
