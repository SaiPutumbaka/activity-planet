-- ============================================================================
-- Staging check for migration 20261117000100_security_fixes.sql (security
-- review fixes). One transaction: throwaway users, a chapter, events, a
-- series, a venue, an organization; DO blocks raise on failure; ROLLBACK at
-- the end. Prints only pass/fail, never user rows. Every numbered check fails
-- on the behaviour before migration 22.
--   1 an under-21 captain cannot manage a 21+ chapter event or series
--     (update, lower min_age, cancel, approve, remove, check in, broadcast,
--     series update and cancel, viewer_can_manage_event, series row) and gets
--     no attendee_joined for it; an adult captain cannot lower min_age; the
--     adult captain and the host still manage it.
--   2 upsert_venue: a public place_id saved by someone else is returned only
--     within 300 m of the caller's coordinates; otherwise a new own venue.
--   3 avatar_url and cover_url only under this project's Storage (avatars in
--     the owner's folder); nothing stored outside it.
--   4 the avatars bucket cannot be listed by anon or by another user.
--   5 create_verification_code answers the same shape for a free address and
--     one linked to another account; own true only for the caller's own.
--   6 a signed-in account that has not finished onboarding (no birth date)
--     reads no other profiles, rsvps, hub or chapter members, events or
--     addresses, but still reads its own row and the onboarding inputs, and
--     onboarding still works and opens the reads.
--   7 event_updated: two moves in one hour give one row (with the latest
--     time); title changes count toward the 3-a-day broadcast cap.
--   8 schema_version 2.18 or later.
-- ============================================================================
begin;

do $$
declare
  v_names text[] := array['h', 'c', 'y', 'a', 'b', 'o'];
  v_birth date[] := array[date '1990-03-03', date '1992-04-04', (current_date - interval '20 years')::date,
                          date '1995-05-05', date '1996-06-06', date '1994-07-07'];
  v_id    uuid;
  v_hub   uuid;
  v_area  uuid;
  v_ch    uuid;
  v_e     uuid;
  v_org   uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  perform set_config('test.tag', v_tag, true);
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'secf-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = v_birth[i] where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  -- n: signed up, never onboarded, no birth date.
  v_id := gen_random_uuid();
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'secf-n-' || v_tag || '@example.com', now(), now());
  perform set_config('test.n', v_id::text, true);

  -- A general 18+ hub in a non-sensitive category, and an area it has no chapter in.
  select h.id, ar.id into v_hub, v_area
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
    cross join public.areas ar
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
     and not exists (select 1 from public.hub_chapters ch where ch.hub_id = h.id and ch.area_id = ar.id)
   order by h.slug, ar.slug
   limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub and free area'; end if;
  perform set_config('test.hub', v_hub::text, true);
  insert into public.hub_members (user_id, hub_id)
  select current_setting('test.' || x)::uuid, v_hub from unnest(array['h', 'a', 'b']) x
  on conflict do nothing;

  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_area, 'secf-' || v_tag, 'Security Fixes Chapter')
  returning id into v_ch;
  perform set_config('test.ch', v_ch::text, true);
  insert into public.chapter_members (user_id, chapter_id, role) values
    (current_setting('test.h')::uuid, v_ch, 'organizer'),
    (current_setting('test.c')::uuid, v_ch, 'captain'),
    (current_setting('test.y')::uuid, v_ch, 'captain'),
    (current_setting('test.a')::uuid, v_ch, 'member');

  -- E21: a 21+ chapter event hosted by h; a is going.
  insert into public.events (kind, hub_id, chapter_id, host_id, title, starts_at, ends_at, min_age, location_hint)
  values ('chapter', v_hub, v_ch, current_setting('test.h')::uuid, 'Security fixes 21 run',
          date_trunc('hour', now()) + interval '3 days', date_trunc('hour', now()) + interval '3 days 2 hours',
          21, 'Midtown')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Security park');
  insert into public.rsvps (event_id, user_id, status) values (v_e, current_setting('test.a')::uuid, 'going');
  perform set_config('test.e21', v_e::text, true);

  -- E18: a public 18+ member event hosted by h; a and b are going.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Security fixes 18 run',
          date_trunc('hour', now()) + interval '4 days', date_trunc('hour', now()) + interval '4 days 2 hours',
          'Midtown')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Security park two');
  insert into public.rsvps (event_id, user_id, status) values
    (v_e, current_setting('test.a')::uuid, 'going'),
    (v_e, current_setting('test.b')::uuid, 'going');
  perform set_config('test.e18', v_e::text, true);

  -- S21: a 21+ weekly chapter series hosted by h.
  insert into public.event_series (kind, hub_id, chapter_id, host_id, title, weekday, start_time, duration_minutes,
                                   starts_on, min_age, location_text)
  values ('chapter', v_hub, v_ch, current_setting('test.h')::uuid, 'Security fixes series', 3, time '19:00', 120,
          current_date + 7, 21, 'Security park')
  returning id into v_e;
  perform set_config('test.s21', v_e::text, true);

  -- An organization with a campus email domain; o verified taken@ already.
  insert into public.organizations (slug, name, kind)
  values ('secf-' || v_tag, 'Security Fixes Test University', 'university')
  returning id into v_org;
  insert into public.org_email_domains (domain, org_id) values ('secf' || v_tag || '.edu', v_org);
  insert into public.verified_emails (user_id, email, org_id)
  values (current_setting('test.o')::uuid, 'taken@secf' || v_tag || '.edu', v_org);

  -- An object in b's avatars folder.
  insert into storage.objects (bucket_id, name, owner)
  values ('avatars', current_setting('test.b') || '/secf-' || v_tag || '.jpg', current_setting('test.b')::uuid);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Under-21 captain (y) on a 21+ event and series
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e21 uuid := current_setting('test.e21')::uuid;
  v_s21 uuid := current_setting('test.s21')::uuid;
  v_a   uuid := current_setting('test.a')::uuid;
  v_ok  boolean;
  v_r   jsonb;
  n     integer;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.y'), 'role', 'authenticated')::text, true);

  begin
    perform public.update_event(v_e21, jsonb_build_object('title', 'Security fixes 21 run renamed'));
    raise exception 'FAIL 1 update_event succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 update_event: %', sqlerrm; end if;
  end;
  begin
    perform public.update_event(v_e21, jsonb_build_object('min_age', 18));
    raise exception 'FAIL 1 update_event min_age succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 update_event min_age: %', sqlerrm; end if;
  end;
  begin
    perform public.cancel_event(v_e21, null);
    raise exception 'FAIL 1 cancel_event succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 cancel_event: %', sqlerrm; end if;
  end;
  begin
    perform public.approve_rsvp(v_e21, v_a, true);
    raise exception 'FAIL 1 approve_rsvp succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 approve_rsvp: %', sqlerrm; end if;
  end;
  begin
    perform public.remove_rsvp(v_e21, v_a, null);
    raise exception 'FAIL 1 remove_rsvp succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 remove_rsvp: %', sqlerrm; end if;
  end;
  begin
    perform public.host_check_in(v_e21, v_a, true);
    raise exception 'FAIL 1 host_check_in succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 host_check_in: %', sqlerrm; end if;
  end;
  begin
    perform public.broadcast_to_event(v_e21, 'Security fixes hello');
    raise exception 'FAIL 1 broadcast_to_event succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 broadcast_to_event: %', sqlerrm; end if;
  end;
  begin
    perform public.update_event_series(v_s21, jsonb_build_object('title', 'Security fixes series renamed'));
    raise exception 'FAIL 1 update_event_series succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 update_event_series: %', sqlerrm; end if;
  end;
  begin
    perform public.cancel_event_series(v_s21, null);
    raise exception 'FAIL 1 cancel_event_series succeeded';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 cancel_event_series: %', sqlerrm; end if;
  end;
  if public.viewer_can_manage_event(v_e21) then raise exception 'FAIL 1 viewer_can_manage_event is true'; end if;
  select count(*) into n from public.event_attendees(v_e21);
  if n <> 0 then raise exception 'FAIL 1 event_attendees returned rows'; end if;
  select count(*) into n from public.event_series where id = v_s21;
  if n <> 0 then raise exception 'FAIL 1 under-21 captain reads the 21+ series row'; end if;

  -- An adult captain (c) manages it but cannot lower min_age.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  begin
    perform public.update_event(v_e21, jsonb_build_object('min_age', 18));
    raise exception 'FAIL 1 adult captain lowered min_age';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 adult captain lower: %', sqlerrm; end if;
  end;
  begin
    perform public.update_event_series(v_s21, jsonb_build_object('min_age', 18));
    raise exception 'FAIL 1 adult captain lowered the series min_age';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 1 adult captain series lower: %', sqlerrm; end if;
  end;
  perform public.update_event(v_e21, jsonb_build_object('description', 'Edited by the adult captain'));
  if not public.viewer_can_manage_event(v_e21) then raise exception 'FAIL 1 adult captain cannot manage'; end if;

  -- b joins: attendee_joined reaches h and c, not y.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  perform public.set_rsvp(v_e21, 'going');

  -- The host may lower it.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  perform public.update_event(v_e21, jsonb_build_object('min_age', 18));
end $$;
reset role;

do $$
begin
  if exists (select 1 from public.notifications
              where user_id = current_setting('test.y')::uuid and event_id = current_setting('test.e21')::uuid) then
    raise exception 'FAIL 1 under-21 captain got a notification about the 21+ event';
  end if;
  if not exists (select 1 from public.notifications
                  where user_id = current_setting('test.c')::uuid and event_id = current_setting('test.e21')::uuid
                    and kind = 'attendee_joined') then
    raise exception 'FAIL 1 adult captain got no attendee_joined';
  end if;
  if (select min_age from public.events where id = current_setting('test.e21')::uuid) <> 18 then
    raise exception 'FAIL 1 host could not lower min_age';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. upsert_venue place_id takeover
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_pid text := 'secf-place-' || current_setting('test.tag');
  v_o   public.venues;
  v     public.venues;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.o'), 'role', 'authenticated')::text, true);
  v_o := public.upsert_venue(jsonb_build_object('name', 'Security Place', 'place_id', v_pid, 'is_public', true,
           'address_line1', '1 Real St', 'city', 'Atlanta', 'postal_code', '30309', 'lat', 33.7800, 'lng', -84.3800));

  -- a: same place_id, coordinates about 9 km away.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  v := public.upsert_venue(jsonb_build_object('name', 'Security Place', 'place_id', v_pid, 'is_public', true,
         'address_line1', '9 Other St', 'city', 'Atlanta', 'postal_code', '30310', 'lat', 33.7000, 'lng', -84.3800));
  if v.id = v_o.id or v.created_by is distinct from current_setting('test.a')::uuid or not v.is_public then
    raise exception 'FAIL 2 far coordinates returned another user''s venue';
  end if;

  -- b: same place_id, no coordinates.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  v := public.upsert_venue(jsonb_build_object('name', 'Security Place', 'place_id', v_pid, 'is_public', true,
         'city', 'Atlanta'));
  if v.id = v_o.id or v.created_by is distinct from current_setting('test.b')::uuid then
    raise exception 'FAIL 2 no coordinates returned another user''s venue';
  end if;

  -- c: within about 55 m shares o's row.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.c'), 'role', 'authenticated')::text, true);
  v := public.upsert_venue(jsonb_build_object('name', 'Security Place', 'place_id', v_pid, 'is_public', true,
         'city', 'Atlanta', 'lat', 33.7805, 'lng', -84.3800));
  if v.id is distinct from v_o.id then raise exception 'FAIL 2 nearby request did not share the public venue'; end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. Image URLs under this project's Storage only
-- ---------------------------------------------------------------------------
do $$
begin
  if public.project_url() is null then raise exception 'FAIL 3 meta.project_url is not set'; end if;
end $$;

set local role authenticated;
do $$
declare
  v_a    uuid := current_setting('test.a')::uuid;
  v_base text := public.project_url() || '/storage/v1/object/public/';
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_a, 'role', 'authenticated')::text, true);
  begin
    update public.profiles set avatar_url = 'https://attacker.example/p.png?u=1' where id = v_a;
    raise exception 'FAIL 3 foreign avatar_url accepted';
  exception when others then
    if sqlerrm <> 'profiles_avatar_url_storage' then raise exception 'FAIL 3 foreign avatar: %', sqlerrm; end if;
  end;
  begin
    update public.profiles
       set avatar_url = 'https://abcdefghijabcdefghij.supabase.co/storage/v1/object/public/avatars/' || v_a || '/1.jpg'
     where id = v_a;
    raise exception 'FAIL 3 another project''s avatar_url accepted';
  exception when others then
    if sqlerrm <> 'profiles_avatar_url_storage' then raise exception 'FAIL 3 other project avatar: %', sqlerrm; end if;
  end;
  begin
    update public.profiles set avatar_url = v_base || 'avatars/' || current_setting('test.b') || '/1.jpg' where id = v_a;
    raise exception 'FAIL 3 another user''s avatar folder accepted';
  exception when others then
    if sqlerrm <> 'profiles_avatar_url_storage' then raise exception 'FAIL 3 other folder avatar: %', sqlerrm; end if;
  end;
  update public.profiles set avatar_url = v_base || 'avatars/' || v_a || '/1700000000000.jpg' where id = v_a;
  if not found then raise exception 'FAIL 3 own avatar_url refused'; end if;

  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  begin
    perform public.update_event(current_setting('test.e18')::uuid,
                                jsonb_build_object('cover_url', 'https://attacker.example/x.gif'));
    raise exception 'FAIL 3 foreign cover_url accepted';
  exception when others then
    if sqlerrm <> 'events_cover_url_storage' then raise exception 'FAIL 3 foreign cover: %', sqlerrm; end if;
  end;
  begin
    perform public.update_event_series(current_setting('test.s21')::uuid,
                                       jsonb_build_object('cover_url', 'https://attacker.example/x.gif'));
    raise exception 'FAIL 3 foreign series cover_url accepted';
  exception when others then
    if sqlerrm <> 'event_series_cover_url_storage' then raise exception 'FAIL 3 foreign series cover: %', sqlerrm; end if;
  end;
end $$;
reset role;

do $$
begin
  if exists (select 1 from public.profiles where avatar_url is not null
              and not public.is_own_storage_url(avatar_url, 'avatars', id)) then
    raise exception 'FAIL 3 a stored avatar_url is outside this project''s Storage';
  end if;
  if exists (select 1 from public.events where cover_url is not null and kind <> 'imported'
              and not public.is_own_storage_url(cover_url)) then
    raise exception 'FAIL 3 a stored event cover_url is outside this project''s Storage';
  end if;
  if exists (select 1 from public.event_series where cover_url is not null
              and not public.is_own_storage_url(cover_url)) then
    raise exception 'FAIL 3 a stored series cover_url is outside this project''s Storage';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. avatars bucket listing
-- ---------------------------------------------------------------------------
set local role anon;
do $$
begin
  if exists (select 1 from storage.objects where bucket_id = 'avatars') then
    raise exception 'FAIL 4 anon lists the avatars bucket';
  end if;
end $$;
reset role;
set local role authenticated;
do $$
declare
  v_b text := current_setting('test.b');
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  if exists (select 1 from storage.objects where bucket_id = 'avatars' and name like v_b || '/%') then
    raise exception 'FAIL 4 another user lists the folder';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_b, 'role', 'authenticated')::text, true);
  if not exists (select 1 from storage.objects where bucket_id = 'avatars' and name like v_b || '/%') then
    raise exception 'FAIL 4 the owner cannot list their own folder';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 5. create_verification_code: no enumeration
-- ---------------------------------------------------------------------------
do $$
declare
  v_dom   text := 'secf' || current_setting('test.tag') || '.edu';
  r_taken jsonb;
  r_free  jsonb;
  r_own   jsonb;
begin
  perform set_config('request.jwt.claims', '', true);
  r_taken := public.create_verification_code(current_setting('test.a')::uuid, 'taken@' || v_dom);
  r_free  := public.create_verification_code(current_setting('test.b')::uuid, 'free@' || v_dom);
  r_own   := public.create_verification_code(current_setting('test.o')::uuid, 'taken@' || v_dom);
  if r_taken ->> 'status' is distinct from r_free ->> 'status' or r_taken ->> 'status' is distinct from 'sent' then
    raise exception 'FAIL 5 a linked address answers status %', coalesce(r_taken ->> 'status', 'null');
  end if;
  if (select array_agg(k order by k) from jsonb_object_keys(r_taken) k)
     is distinct from (select array_agg(k order by k) from jsonb_object_keys(r_free) k) then
    raise exception 'FAIL 5 a linked address answers a different shape';
  end if;
  if (r_taken ->> 'own')::boolean is distinct from false or (r_free ->> 'own')::boolean is distinct from false
     or r_taken ->> 'expires_at' is null or r_taken ->> 'code' is not null then
    raise exception 'FAIL 5 linked address own/expires_at/code';
  end if;
  if r_own ->> 'status' is distinct from 'already_verified' or (r_own ->> 'own')::boolean is distinct from true then
    raise exception 'FAIL 5 own address is not already_verified with own true';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. 18+ reads need a finished onboarding and a birth date
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_n uuid := current_setting('test.n')::uuid;
  p   public.profiles;
begin
  perform set_config('request.jwt.claims', json_build_object('sub', v_n, 'role', 'authenticated')::text, true);
  if public.viewer_is_adult() then raise exception 'FAIL 6 viewer_is_adult true before onboarding'; end if;
  if exists (select 1 from public.profiles where id <> v_n) then raise exception 'FAIL 6 reads other profiles'; end if;
  if exists (select 1 from public.rsvps r where r.event_id is not null) then raise exception 'FAIL 6 reads rsvps'; end if;
  if exists (select 1 from public.hub_members) then raise exception 'FAIL 6 reads hub_members'; end if;
  if exists (select 1 from public.chapter_members) then raise exception 'FAIL 6 reads chapter_members'; end if;
  if exists (select 1 from public.events) then raise exception 'FAIL 6 reads events'; end if;
  if exists (select 1 from public.event_addresses) then raise exception 'FAIL 6 reads event_addresses'; end if;
  if public.can_read_event(current_setting('test.e18')::uuid) then raise exception 'FAIL 6 can_read_event true'; end if;
  -- Onboarding inputs and the own row stay readable.
  if not exists (select 1 from public.profiles where id = v_n) then raise exception 'FAIL 6 own profile hidden'; end if;
  if not exists (select 1 from public.profile_private where user_id = v_n) then raise exception 'FAIL 6 own private row hidden'; end if;
  if not exists (select 1 from public.hubs) then raise exception 'FAIL 6 hubs hidden'; end if;
  if not exists (select 1 from public.areas) then raise exception 'FAIL 6 areas hidden'; end if;
  if not exists (select 1 from public.organizations) then raise exception 'FAIL 6 organizations hidden'; end if;
  if not exists (select 1 from public.org_campuses) then raise exception 'FAIL 6 campuses hidden'; end if;

  p := public.complete_onboarding('secf_' || current_setting('test.tag'), 'Tester', date '1992-02-02',
                                  array[current_setting('test.hub')::uuid]);
  if p.onboarding_completed_at is null then raise exception 'FAIL 6 onboarding did not complete'; end if;
  if not public.viewer_is_adult() then raise exception 'FAIL 6 viewer_is_adult false after onboarding'; end if;
  if not exists (select 1 from public.events where id = current_setting('test.e18')::uuid) then
    raise exception 'FAIL 6 onboarded adult cannot read a public event';
  end if;
  if not exists (select 1 from public.profiles where id = current_setting('test.h')::uuid) then
    raise exception 'FAIL 6 onboarded adult cannot read profiles';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 7. event_updated fan-out
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_e  uuid := current_setting('test.e18')::uuid;
  v_t  timestamptz;
begin
  select starts_at into v_t from public.events where id = v_e;
  perform set_config('test.t2', (v_t + interval '2 hours')::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.h'), 'role', 'authenticated')::text, true);
  perform public.update_event(v_e, jsonb_build_object('starts_at', v_t + interval '1 hour', 'ends_at', v_t + interval '3 hours'));
  perform public.update_event(v_e, jsonb_build_object('starts_at', v_t + interval '2 hours', 'ends_at', v_t + interval '4 hours'));
  perform public.update_event(v_e, jsonb_build_object('title', 'Security fixes title one'));
  perform public.update_event(v_e, jsonb_build_object('title', 'Security fixes title two'));
  perform public.update_event(v_e, jsonb_build_object('title', 'Security fixes title three'));
  begin
    perform public.update_event(v_e, jsonb_build_object('title', 'Security fixes title four'));
    raise exception 'FAIL 7 a fourth title change in a day was accepted';
  exception when others then
    if sqlerrm <> 'broadcast_limit' then raise exception 'FAIL 7 fourth title change: %', sqlerrm; end if;
  end;
end $$;
reset role;

do $$
declare
  n integer;
  x public.notifications;
begin
  select count(*) into n from public.notifications
   where user_id = current_setting('test.a')::uuid and event_id = current_setting('test.e18')::uuid
     and kind = 'event_updated';
  if n <> 1 then raise exception 'FAIL 7 two moves in one hour gave % event_updated rows', n; end if;
  select * into x from public.notifications
   where user_id = current_setting('test.a')::uuid and event_id = current_setting('test.e18')::uuid
     and kind = 'event_updated';
  if (x.payload ->> 'starts_at')::timestamptz is distinct from current_setting('test.t2')::timestamptz then
    raise exception 'FAIL 7 the hourly row does not carry the latest time';
  end if;
  if (select count(*) from public.event_broadcasts where event_id = current_setting('test.e18')::uuid) <> 3 then
    raise exception 'FAIL 7 title changes not counted toward the broadcast cap';
  end if;

  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 18] then
    raise exception 'FAIL 8 schema_version is too old';
  end if;
end $$;

select 'security_fixes: PASS' as result;

rollback;
