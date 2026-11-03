-- ============================================================================
-- Staging re-check of migration 20261117000100_security_fixes.sql: the
-- legitimate paths the fixes must not break, plus a probe of the venue fix.
-- One transaction, throwaway rows, ROLLBACK at the end. Prints only pass/fail.
--   R1 an adult (21+) captain and the host still manage a 21+ chapter event
--      (edit, approve, check in, attendee list, approved-only address, series
--      row, remove, cancel); a 20-year-old captain still manages an 18+ one.
--   R2 a host picking an autocomplete place gets a working public venue, and
--      the same venue again on a second pick.
--   R3 the avatar URL shape the app saves (getPublicUrl) is accepted.
--   R4 a brand-new account onboards, then joins a chapter and a hub directly
--      and reads events and profiles.
--   R5 logged out: event_share_card, the anon events and address reads.
--   P1 probe (reported, not raised): can a public venue planted with a known
--      place_id and the real coordinates, but a false name and address, still
--      be handed to an honest host who picks that place?
-- ============================================================================
begin;

do $$
declare
  v_names text[] := array['h', 'c', 'y', 'a', 'o'];
  v_birth date[] := array[date '1990-03-03', date '1992-04-04', (current_date - interval '20 years')::date,
                          date '1995-05-05', date '1994-07-07'];
  v_id    uuid;
  v_hub   uuid;
  v_hub2  uuid;
  v_area  uuid;
  v_ch    uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  perform set_config('test.tag', v_tag, true);
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'secr-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = v_birth[i] where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  v_id := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'secr-n-' || v_tag || '@example.com', now(), now());
  perform set_config('test.n', v_id::text, true);

  select h.id, ar.id into v_hub, v_area
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
    cross join public.areas ar
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
     and not exists (select 1 from public.hub_chapters ch where ch.hub_id = h.id and ch.area_id = ar.id)
   order by h.slug, ar.slug
   limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub and free area'; end if;
  select h.id into v_hub2 from public.hubs h
   where h.is_active and h.min_age = 18 and h.id <> v_hub order by h.slug limit 1;
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.hub2', v_hub2::text, true);

  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_area, 'secr-' || v_tag, 'Security Recheck Chapter')
  returning id into v_ch;
  perform set_config('test.ch', v_ch::text, true);
  insert into public.chapter_members (user_id, chapter_id, role) values
    (current_setting('test.h')::uuid, v_ch, 'organizer'),
    (current_setting('test.c')::uuid, v_ch, 'captain'),
    (current_setting('test.y')::uuid, v_ch, 'captain'),
    (current_setting('test.a')::uuid, v_ch, 'member');

  -- E21: 21+ chapter event by h, starting in 30 minutes (check-in window), approved-only address.
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, min_age,
                             location_hint, address_visibility)
  values ('chapter', v_hub, v_ch, current_setting('test.h')::uuid, 'Security recheck 21 run',
          now() + interval '30 minutes', now() + interval '150 minutes', 21, 'Midtown', 'approved_only')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Recheck park');
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.a')::uuid, 'going');
  perform set_config('test.e21', v_e::text, true);

  -- E18c: 18+ chapter event by h.
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, min_age, location_hint)
  values ('chapter', v_hub, v_ch, current_setting('test.h')::uuid, 'Security recheck 18 chapter',
          date_trunc('hour', now()) + interval '3 days', date_trunc('hour', now()) + interval '3 days 2 hours',
          18, 'Midtown')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Recheck park two');
  perform set_config('test.e18c', v_e::text, true);

  -- E18: public 18+ member event by h, public address.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Security recheck 18 run',
          date_trunc('hour', now()) + interval '4 days', date_trunc('hour', now()) + interval '4 days 2 hours',
          'Midtown')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Recheck park three');
  perform set_config('test.e18', v_e::text, true);

  insert into public.event_series (kind, hub_id, chapter_id, host_id, title, weekday, start_time, duration_minutes,
                                   starts_on, min_age, location_text)
  values ('chapter', v_hub, v_ch, current_setting('test.h')::uuid, 'Security recheck series', 3, time '19:00', 120,
          current_date + 7, 21, 'Recheck park')
  returning id into v_e;
  perform set_config('test.s21', v_e::text, true);
end $$;

-- R1 ------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e21 uuid := current_setting('test.e21')::uuid;
  v_a   uuid := current_setting('test.a')::uuid;
  n     integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  if not public.viewer_can_manage_event(v_e21) then raise exception 'FAIL R1 adult captain viewer_can_manage_event'; end if;
  perform public.update_event(v_e21, jsonb_build_object('description', 'Edited by the adult captain'));
  perform public.approve_rsvp(v_e21, v_a, true);
  perform public.host_check_in(v_e21, v_a, true);
  select count(*) into n from public.event_attendees(v_e21);
  if n < 1 then raise exception 'FAIL R1 adult captain attendee list empty'; end if;
  if not exists (select 1 from public.event_addresses where event_id = v_e21) then
    raise exception 'FAIL R1 adult captain cannot read the approved-only address';
  end if;
  if not exists (select 1 from public.event_series where id = current_setting('test.s21')::uuid) then
    raise exception 'FAIL R1 adult captain cannot read the series';
  end if;
  perform public.update_event_series(current_setting('test.s21')::uuid, jsonb_build_object('description', 'Captain edit'));

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.y'), 'role', 'authenticated')::text, true);
  if not public.viewer_can_manage_event(current_setting('test.e18c')::uuid) then
    raise exception 'FAIL R1 20-year-old captain cannot manage an 18+ event';
  end if;
  perform public.update_event(current_setting('test.e18c')::uuid, jsonb_build_object('description', 'Young captain edit'));

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  if not public.viewer_can_manage_event(v_e21) then raise exception 'FAIL R1 host viewer_can_manage_event'; end if;
  perform public.update_event(v_e21, jsonb_build_object('title', 'Security recheck 21 renamed'));

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  perform public.remove_rsvp(v_e21, v_a, 'recheck');
  perform public.cancel_event(v_e21, 'recheck');
end $$;
reset role;

-- R2 and P1 -----------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_p1 text := 'secr-p1-' || current_setting('test.tag');
  v_p2 text := 'secr-p2-' || current_setting('test.tag');
  v1   public.venues;
  v2   public.venues;
  vo   public.venues;
  va   public.venues;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  v1 := public.upsert_venue(jsonb_build_object('name', 'Recheck Hall', 'place_id', v_p1, 'is_public', true,
          'address_line1', '10 Hall St', 'city', 'Atlanta', 'state', 'GA', 'postal_code', '30303',
          'lat', 33.7530, 'lng', -84.3860));
  if v1.id is null or not v1.is_public or v1.place_id is distinct from v_p1 or v1.location is null then
    raise exception 'FAIL R2 autocomplete pick did not give a public venue';
  end if;
  v2 := public.upsert_venue(jsonb_build_object('name', 'Recheck Hall', 'place_id', v_p1, 'is_public', true,
          'address_line1', '10 Hall St', 'city', 'Atlanta', 'state', 'GA', 'postal_code', '30303',
          'lat', 33.7530, 'lng', -84.3860));
  if v2.id is distinct from v1.id then raise exception 'FAIL R2 second pick made another venue'; end if;

  -- P1: o plants the place with the real coordinates and a false name and address.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.o'), 'role', 'authenticated')::text, true);
  vo := public.upsert_venue(jsonb_build_object('name', 'Planted Name', 'place_id', v_p2, 'is_public', true,
          'address_line1', '666 Wrong St', 'city', 'Atlanta', 'postal_code', '30318',
          'lat', 33.7800, 'lng', -84.3800));
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  va := public.upsert_venue(jsonb_build_object('name', 'Real Name', 'place_id', v_p2, 'is_public', true,
          'address_line1', '1 Real St', 'city', 'Atlanta', 'postal_code', '30309',
          'lat', 33.7800, 'lng', -84.3800));
  perform set_config('test.p1', case when va.id = vo.id then 'REPRODUCED' else 'not reproduced' end, true);

  -- The host attaches a picked venue to an event and the address follows.
  perform public.update_event(current_setting('test.e18')::uuid, jsonb_build_object('venue_id', va.id));
  if not exists (select 1 from public.event_addresses where event_id = current_setting('test.e18')::uuid
                  and venue_id = va.id) then
    raise exception 'FAIL R2 venue did not attach to the event';
  end if;
end $$;
reset role;

-- R4 and R3 -----------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_n uuid := current_setting('test.n')::uuid;
  p   public.profiles;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_n, 'role', 'authenticated')::text, true);
  if not exists (select 1 from public.profiles where id = v_n) then raise exception 'FAIL R4 own profile hidden'; end if;
  p := public.complete_onboarding('secr_' || current_setting('test.tag'), 'Tester', date '1993-02-02',
                                  array[current_setting('test.hub')::uuid]);
  if p.onboarding_completed_at is null then raise exception 'FAIL R4 onboarding did not complete'; end if;
  insert into public.chapter_members (user_id, chapter_id, role) values (v_n, current_setting('test.ch')::uuid, 'member');
  if current_setting('test.hub2', true) <> '' then
    insert into public.hub_members (user_id, hub_id) values (v_n, current_setting('test.hub2')::uuid)
    on conflict do nothing;
  end if;
  if not exists (select 1 from public.events where id = current_setting('test.e18')::uuid) then
    raise exception 'FAIL R4 new adult cannot read a public event';
  end if;
  if not exists (select 1 from public.profiles where id = current_setting('test.h')::uuid) then
    raise exception 'FAIL R4 new adult cannot read the host profile';
  end if;
  perform public.set_rsvp(current_setting('test.e18')::uuid, 'going');

  update public.profiles
     set avatar_url = public.project_url() || '/storage/v1/object/public/avatars/' || v_n || '/' ||
                      (extract(epoch from now()) * 1000)::bigint || '.jpg'
   where id = v_n;
  if not found then raise exception 'FAIL R3 own avatar URL refused'; end if;
  update public.profiles set avatar_url = null where id = v_n;
end $$;
reset role;

-- R5 ------------------------------------------------------------------------
set local role anon;
do $$
declare
  c jsonb;
begin
  perform set_config('request.jwt.claims', '', true);
  c := public.event_share_card(current_setting('test.e18')::uuid);
  if c ->> 'title' is distinct from 'Security recheck 18 run' then raise exception 'FAIL R5 share card'; end if;
  if not exists (select 1 from public.events where id = current_setting('test.e18')::uuid) then
    raise exception 'FAIL R5 anon cannot read the public event';
  end if;
  if not exists (select 1 from public.event_addresses where event_id = current_setting('test.e18')::uuid) then
    raise exception 'FAIL R5 anon cannot read the public address';
  end if;
end $$;
reset role;

select 'security_recheck: regressions PASS; P1 venue spoof ' || current_setting('test.p1') as result;

rollback;
