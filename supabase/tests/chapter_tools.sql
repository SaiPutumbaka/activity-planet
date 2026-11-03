-- ============================================================================
-- Staging check for migration 20261113000100_chapter_tools.sql.
-- One transaction: throwaway users, an organization with a campus, claims,
-- chapters, a chapter event and a chapter series; DO blocks raise on failure;
-- ROLLBACK at the end. Prints only pass/fail.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_users  uuid[] := array[gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
                           gen_random_uuid(), gen_random_uuid(), gen_random_uuid()];
  v_names  text[] := array['a', 'b', 'c', 'x', 's', 'm'];
  v_hubs   uuid[];
  v_org    uuid;
  v_campus uuid;
  v_tag    text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  for i in 1..6 loop
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_users[i], '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'ct-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1995-05-05' where user_id = v_users[i];
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_users[i];
    perform set_config('test.' || v_names[i], v_users[i]::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (v_users[6], 'moderator');

  select array_agg(id order by slug) into v_hubs
    from (select h.id, h.slug from public.hubs h
           where h.is_active and h.min_age = 18 and h.scope = 'general'
             and not exists (select 1 from public.hub_chapters ch where ch.hub_id = h.id)
           order by h.slug limit 6) t;
  if coalesce(array_length(v_hubs, 1), 0) < 6 then
    raise exception 'setup: need six general hubs without chapters on staging';
  end if;
  for i in 1..6 loop
    perform set_config('test.hub' || i, v_hubs[i]::text, true);
  end loop;

  insert into public.organizations (slug, name, kind)
  values ('ct-org-' || v_tag, 'Chapter Tools Test University', 'university')
  returning id into v_org;
  insert into public.org_campuses (org_id, slug, name)
  values (v_org, 'main', 'Main Campus')
  returning id into v_campus;
  insert into public.org_memberships (user_id, org_id, campus_id, source)
  values (v_users[1], v_org, v_campus, 'manual');
  perform set_config('test.org', v_org::text, true);
  perform set_config('test.campus', v_campus::text, true);
  perform set_config('test.atl', (select id::text from public.areas where slug = 'atlanta'), true);
end $$;

set local role authenticated;

-- ---------------------------------------------------------------------------
-- 1. Org claim without a verified membership is refused; area claim accepted
-- ---------------------------------------------------------------------------
do $$
declare
  c public.chapter_claims;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  begin
    perform public.submit_chapter_claim(jsonb_build_object(
      'kind', 'org', 'hub_id', current_setting('test.hub1'), 'org_id', current_setting('test.org'),
      'campus_id', current_setting('test.campus'), 'proposed_name', 'Test Org Chapter', 'agreement_version', 'v1'));
    raise exception 'FAIL org claim without membership was accepted';
  exception when others then
    if sqlerrm <> 'membership_required' then raise exception 'FAIL 1 org claim: %', sqlerrm; end if;
  end;

  c := public.submit_chapter_claim(jsonb_build_object(
    'kind', 'area', 'hub_id', current_setting('test.hub2'), 'area_id', current_setting('test.atl'),
    'proposed_name', 'Test Area Chapter', 'reference_name', 'Ref', 'reference_contact', 'ref@example.com',
    'motivation', 'Weekly games', 'agreement_version', 'v1'));
  if c.status <> 'pending' or c.kind <> 'area' or c.chapter_id is not null then
    raise exception 'FAIL 1 area claim not pending';
  end if;
  perform set_config('test.claim_b', c.id::text, true);

  -- Same place again: refused.
  begin
    perform public.submit_chapter_claim(jsonb_build_object(
      'kind', 'area', 'hub_id', current_setting('test.hub2'), 'area_id', current_setting('test.atl'),
      'proposed_name', 'Test Area Chapter', 'agreement_version', 'v1'));
    raise exception 'FAIL duplicate pending claim accepted';
  exception when others then
    if sqlerrm <> 'claim_pending' then raise exception 'FAIL 1 duplicate: %', sqlerrm; end if;
  end;
  -- pin_url must be https.
  begin
    perform public.submit_chapter_claim(jsonb_build_object(
      'kind', 'area', 'hub_id', current_setting('test.hub3'), 'area_id', current_setting('test.atl'),
      'proposed_name', 'Test Area Chapter', 'pin_url', 'http://example.com', 'agreement_version', 'v1'));
    raise exception 'FAIL http pin_url accepted';
  exception when others then
    if sqlerrm <> 'pin_url_invalid' then raise exception 'FAIL 1 pin_url: %', sqlerrm; end if;
  end;
  -- No client writes.
  begin
    update public.chapter_claims set status = 'approved' where id = c.id;
    raise exception 'FAIL client update on chapter_claims allowed';
  exception when insufficient_privilege then null;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Submit, reject, resubmit, approve gives an organizer row
-- ---------------------------------------------------------------------------
do $$
declare
  c     public.chapter_claims;
  v_ch  public.hub_chapters;
  v_a   uuid := current_setting('test.a')::uuid;
  v_m   uuid := current_setting('test.m')::uuid;
  v_args jsonb := jsonb_build_object(
    'kind', 'org', 'hub_id', current_setting('test.hub1'), 'org_id', current_setting('test.org'),
    'campus_id', current_setting('test.campus'), 'proposed_name', 'Test Org Chapter',
    'rso_name', 'Test Club', 'pin_url', 'https://example.com/org', 'officer_role_text', 'President',
    'agreement_version', 'v1');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  c := public.submit_chapter_claim(v_args);
  -- A non-moderator cannot review.
  begin
    perform public.review_chapter_claim(c.id, true, null);
    raise exception 'FAIL non-moderator reviewed a claim';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 2 non-mod review: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_m, 'role', 'authenticated')::text, true);
  c := public.review_chapter_claim(c.id, false, 'Need a reference');
  if c.status <> 'rejected' or c.reviewed_by <> v_m or c.reviewed_at is null then
    raise exception 'FAIL 2 reject';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  c := public.submit_chapter_claim(v_args);
  if c.status <> 'pending' then raise exception 'FAIL 2 resubmit'; end if;
  if (select count(*) from public.my_chapter_claims()) <> 2 then
    raise exception 'FAIL 2 my_chapter_claims count';
  end if;

  perform set_config('request.jwt.claims', json_build_object('sub', v_m, 'role', 'authenticated')::text, true);
  c := public.review_chapter_claim(c.id, true, null);
  if c.status <> 'approved' or c.chapter_id is null then raise exception 'FAIL 2 approve'; end if;
  select * into v_ch from public.hub_chapters where id = c.chapter_id;
  if v_ch.claimed_by <> v_a or v_ch.claimed_at is null or v_ch.verified_at is null
     or v_ch.org_id <> current_setting('test.org')::uuid or v_ch.area_id is not null
     or v_ch.rso_name <> 'Test Club' or v_ch.pin_url <> 'https://example.com/org' then
    raise exception 'FAIL 2 chapter stamps';
  end if;
  if not exists (select 1 from public.chapter_members
                  where chapter_id = c.chapter_id and user_id = v_a and role = 'organizer') then
    raise exception 'FAIL 2 no organizer row';
  end if;
  if (select role from public.org_memberships where user_id = v_a and org_id = current_setting('test.org')::uuid) <> 'officer' then
    raise exception 'FAIL 2 org role not officer';
  end if;
  perform set_config('test.ch_org', c.chapter_id::text, true);

  -- Now the chapter has an organizer: new claims for it are refused.
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  begin
    perform public.submit_chapter_claim(jsonb_build_object(
      'chapter_id', c.chapter_id, 'hub_id', current_setting('test.hub1'), 'agreement_version', 'v1'));
    raise exception 'FAIL claim on an organized chapter accepted';
  exception when others then
    if sqlerrm <> 'chapter_has_organizer' then raise exception 'FAIL 2 organized: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Approving your own claim is refused; the area claim is approved
-- ---------------------------------------------------------------------------
do $$
declare
  c   public.chapter_claims;
  v_m uuid := current_setting('test.m')::uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_m, 'role', 'authenticated')::text, true);
  c := public.submit_chapter_claim(jsonb_build_object(
    'kind', 'area', 'hub_id', current_setting('test.hub3'), 'area_id', current_setting('test.atl'),
    'proposed_name', 'Moderator Chapter', 'agreement_version', 'v1'));
  begin
    perform public.review_chapter_claim(c.id, true, null);
    raise exception 'FAIL moderator approved own claim';
  exception when others then
    if sqlerrm <> 'own_claim' then raise exception 'FAIL 3 own claim: %', sqlerrm; end if;
  end;

  c := public.review_chapter_claim(current_setting('test.claim_b')::uuid, true, null);
  if c.status <> 'approved' then raise exception 'FAIL 3 area approve'; end if;
  if not exists (select 1 from public.hub_chapters
                  where id = c.chapter_id and area_id = current_setting('test.atl')::uuid and org_id is null
                    and verified_at is not null) then
    raise exception 'FAIL 3 area chapter shape';
  end if;
  perform set_config('test.ch_area', c.chapter_id::text, true);
end $$;

-- C and X join the area chapter the way clients do (anyone may join an area chapter).
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  insert into public.chapter_members (user_id, chapter_id) values (auth.uid(), current_setting('test.ch_area')::uuid);
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  insert into public.chapter_members (user_id, chapter_id) values (auth.uid(), current_setting('test.ch_area')::uuid);
end $$;

-- ---------------------------------------------------------------------------
-- 4. Roles: organizer makes a captain; a captain cannot grant organizer;
--    organizer cannot grant organizer; the last organizer cannot be demoted
-- ---------------------------------------------------------------------------
do $$
declare
  v_ch uuid := current_setting('test.ch_area')::uuid;
  v_b  uuid := current_setting('test.b')::uuid;
  v_c  uuid := current_setting('test.c')::uuid;
  v_x  uuid := current_setting('test.x')::uuid;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  perform public.set_chapter_role(v_ch, v_c, 'captain');
  if (select role from public.chapter_members where chapter_id = v_ch and user_id = v_c) <> 'captain' then
    raise exception 'FAIL 4 captain not set';
  end if;
  begin
    perform public.set_chapter_role(v_ch, v_x, 'organizer');
    raise exception 'FAIL organizer granted organizer';
  exception when others then
    if sqlerrm <> 'organizer_requires_moderator' then raise exception 'FAIL 4 organizer grant: %', sqlerrm; end if;
  end;
  begin
    perform public.set_chapter_role(v_ch, v_b, 'member');
    raise exception 'FAIL last organizer demoted';
  exception when others then
    if sqlerrm <> 'last_organizer' then raise exception 'FAIL 4 self demote: %', sqlerrm; end if;
  end;
  begin
    delete from public.chapter_members where chapter_id = v_ch and user_id = v_b;
    raise exception 'FAIL last organizer left';
  exception when others then
    if sqlerrm <> 'last_organizer' then raise exception 'FAIL 4 leave: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  begin
    perform public.set_chapter_role(v_ch, v_x, 'organizer');
    raise exception 'FAIL captain granted organizer';
  exception when others then
    if sqlstate <> '42501' then raise exception 'FAIL 4 captain grant: %', sqlerrm; end if;
  end;
  begin
    perform public.remove_chapter_member(v_ch, v_b);
    raise exception 'FAIL captain removed the organizer';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 4 captain remove organizer: %', sqlerrm; end if;
  end;

  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.m'), 'role', 'authenticated')::text, true);
  begin
    perform public.set_chapter_role(v_ch, v_b, 'captain');
    raise exception 'FAIL moderator demoted the last organizer';
  exception when others then
    if sqlerrm <> 'last_organizer' then raise exception 'FAIL 4 mod demote: %', sqlerrm; end if;
  end;
  begin
    perform public.remove_chapter_member(v_ch, v_b);
    raise exception 'FAIL moderator removed the last organizer';
  exception when others then
    if sqlerrm <> 'last_organizer' then raise exception 'FAIL 4 mod remove: %', sqlerrm; end if;
  end;

  -- my_managed_chapters for the captain.
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.my_managed_chapters() where chapter_id = v_ch and role = 'captain') then
    raise exception 'FAIL 4 my_managed_chapters';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Captain tools on a chapter event: attendees and host check-in
-- ---------------------------------------------------------------------------
reset role;
do $$
declare
  v_e uuid;
begin
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, location_hint)
  values ('chapter', current_setting('test.hub2')::uuid, current_setting('test.ch_area')::uuid,
          current_setting('test.b')::uuid, 'Chapter tools test run', now() + interval '30 minutes',
          now() + interval '2 hours', 'Near')
  returning id into v_e;
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.x')::uuid, 'going');
  perform set_config('test.event', v_e::text, true);
end $$;
set local role authenticated;

do $$
declare
  v_e uuid := current_setting('test.event')::uuid;
  v_c uuid := current_setting('test.c')::uuid;
  v_x uuid := current_setting('test.x')::uuid;
  r   public.rsvps;
  n   integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_c, 'role', 'authenticated')::text, true);
  if not public.viewer_can_manage_event(v_e) then raise exception 'FAIL 5 captain cannot manage'; end if;
  select count(*) into n from public.event_attendees(v_e);
  if n <> 2 then raise exception 'FAIL 5 captain sees % attendee rows', n; end if;
  r := public.host_check_in(v_e, v_x, true);
  if r.checked_in_at is null or r.checked_in_by <> v_c then raise exception 'FAIL 5 host_check_in'; end if;
  r := public.host_check_in(v_e, v_x, false);
  if r.checked_in_at is not null or r.checked_in_by is not null then raise exception 'FAIL 5 undo check-in'; end if;
  r := public.host_check_in(v_e, v_x, true);

  -- The attendee checking in themselves stamps their own id.
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  r := public.check_in(v_e);
  if r.checked_in_by <> current_setting('test.b')::uuid then raise exception 'FAIL 5 check_in stamp'; end if;

  -- A stranger cannot.
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.s'), 'role', 'authenticated')::text, true);
  if public.viewer_can_manage_event(v_e) then raise exception 'FAIL 5 stranger can manage'; end if;
  select count(*) into n from public.event_attendees(v_e);
  if n <> 0 then raise exception 'FAIL 5 stranger sees % attendee rows', n; end if;
  begin
    perform public.host_check_in(v_e, v_x, false);
    raise exception 'FAIL stranger used host_check_in';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 5 stranger check-in: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 6. A captain posts as the chapter: one event and a series from 2027-01-12
-- ---------------------------------------------------------------------------
do $$
declare
  s public.event_series;
  e public.events;
  n integer;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  s := public.create_event_series(jsonb_build_object(
    'kind', 'chapter', 'chapter_id', current_setting('test.ch_area'), 'hub_id', current_setting('test.hub2'),
    'title', 'Chapter tools weekly', 'weekday', 2, 'start_time', '19:00', 'duration_minutes', 90,
    'starts_on', '2027-01-12', 'ends_on', '2027-05-04', 'location_text', 'Test park'));
  select count(*) into n from public.events
   where series_id = s.id and kind = 'chapter' and chapter_id = current_setting('test.ch_area')::uuid
     and occurrence_date >= date '2027-01-12';
  if n < 1 then raise exception 'FAIL 6 series materialized % rows', n; end if;

  e := public.create_event(jsonb_build_object(
    'kind', 'chapter', 'chapter_id', current_setting('test.ch_area'), 'hub_id', current_setting('test.hub2'),
    'title', 'Chapter tools one-off', 'starts_at', now() + interval '3 days',
    'ends_at', now() + interval '3 days 2 hours', 'location_text', 'Test park'));
  if e.kind <> 'chapter' or e.chapter_id <> current_setting('test.ch_area')::uuid then
    raise exception 'FAIL 6 chapter event';
  end if;

  -- A plain member cannot post as the chapter.
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.x'), 'role', 'authenticated')::text, true);
  begin
    perform public.create_event(jsonb_build_object(
      'kind', 'chapter', 'chapter_id', current_setting('test.ch_area'), 'hub_id', current_setting('test.hub2'),
      'title', 'Not allowed', 'starts_at', now() + interval '3 days',
      'ends_at', now() + interval '3 days 2 hours', 'location_text', 'Test park'));
    raise exception 'FAIL member posted as the chapter';
  exception when others then
    if sqlerrm <> 'not_chapter_captain' then raise exception 'FAIL 6 member post: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Claims: RLS, withdraw, limit of three open claims
-- ---------------------------------------------------------------------------
do $$
declare
  c public.chapter_claims;
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.s'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.chapter_claims) then raise exception 'FAIL 7 stranger reads claims'; end if;

  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  if exists (select 1 from public.chapter_claims where user_id <> auth.uid()) then
    raise exception 'FAIL 7 claimant reads other claims';
  end if;
  c := public.submit_chapter_claim(jsonb_build_object('kind', 'area', 'hub_id', current_setting('test.hub4'),
         'area_id', current_setting('test.atl'), 'proposed_name', 'Claim four', 'agreement_version', 'v1'));
  c := public.withdraw_chapter_claim(c.id);
  if c.status <> 'withdrawn' then raise exception 'FAIL 7 withdraw'; end if;
  perform public.submit_chapter_claim(jsonb_build_object('kind', 'area', 'hub_id', current_setting('test.hub4'),
            'area_id', current_setting('test.atl'), 'proposed_name', 'Claim four', 'agreement_version', 'v1'));
  perform public.submit_chapter_claim(jsonb_build_object('kind', 'area', 'hub_id', current_setting('test.hub5'),
            'area_id', current_setting('test.atl'), 'proposed_name', 'Claim five', 'agreement_version', 'v1'));
  perform public.submit_chapter_claim(jsonb_build_object('kind', 'area', 'hub_id', current_setting('test.hub6'),
            'area_id', current_setting('test.atl'), 'proposed_name', 'Claim six', 'agreement_version', 'v1'));
  begin
    perform public.submit_chapter_claim(jsonb_build_object('kind', 'area', 'hub_id', current_setting('test.hub3'),
              'area_id', current_setting('test.atl'), 'proposed_name', 'Claim three', 'agreement_version', 'v1'));
    raise exception 'FAIL fourth open claim accepted';
  exception when others then
    if sqlerrm <> 'too_many_claims' then raise exception 'FAIL 7 limit: %', sqlerrm; end if;
  end;
end $$;

-- ---------------------------------------------------------------------------
-- 8. chapter_public_card as anon: no personal fields
-- ---------------------------------------------------------------------------
set local role anon;
do $$
declare
  v_card jsonb;
  v_slug text;
  k      text;
  u      text;
begin
  select slug into v_slug from public.hub_chapters where id = current_setting('test.ch_area')::uuid;
  v_card := public.chapter_public_card(v_slug);
  if v_card is null then raise exception 'FAIL 8 no card by slug'; end if;
  if public.chapter_public_card(current_setting('test.ch_area')) is distinct from v_card then
    raise exception 'FAIL 8 card by id differs';
  end if;
  for k in select jsonb_object_keys(v_card) loop
    if k not in ('id', 'slug', 'name', 'description', 'cover_url', 'hub', 'owner_kind', 'org', 'campus', 'area',
                 'place_label', 'rso_name', 'pin_url', 'verified', 'member_count', 'upcoming_public_events') then
      raise exception 'FAIL 8 unexpected key %', k;
    end if;
  end loop;
  foreach u in array array[current_setting('test.a'), current_setting('test.b'), current_setting('test.c'),
                           current_setting('test.x'), current_setting('test.s'), current_setting('test.m')] loop
    if position(u in v_card::text) > 0 then raise exception 'FAIL 8 card contains a user id'; end if;
  end loop;
  if position('Tester' in v_card::text) > 0 then raise exception 'FAIL 8 card contains a person''s name'; end if;
  if v_card ->> 'owner_kind' <> 'area' or (v_card ->> 'member_count')::int <> 3
     or (v_card ->> 'upcoming_public_events')::int < 2 or (v_card ->> 'verified')::boolean is not true then
    raise exception 'FAIL 8 card values';
  end if;
  if public.chapter_public_card('no-such-chapter-slug') is not null then raise exception 'FAIL 8 missing slug'; end if;
  begin
    perform public.submit_chapter_claim('{}'::jsonb);
    raise exception 'FAIL anon can submit claims';
  exception when insufficient_privilege then null;
  end;
end $$;
set local role authenticated;

-- ---------------------------------------------------------------------------
-- 9. Account deletion covers claims, claimed_by and the organizer row
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion(null);
end $$;
reset role;
do $$
declare
  v_a uuid := current_setting('test.a')::uuid;
begin
  if exists (select 1 from public.chapter_claims where user_id = v_a) then
    raise exception 'FAIL 9 claims survive deletion';
  end if;
  if exists (select 1 from public.hub_chapters where claimed_by = v_a) then
    raise exception 'FAIL 9 claimed_by survives deletion';
  end if;
  if exists (select 1 from public.chapter_members where user_id = v_a) then
    raise exception 'FAIL 9 chapter membership survives deletion';
  end if;
  -- 2.12 or later (migration 17 moved it to 2.13).
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 12] then
    raise exception 'FAIL schema_version is older than 2.12';
  end if;
end $$;

select 'chapter_tools: all assertions passed' as result;

rollback;
