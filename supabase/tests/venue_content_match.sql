-- ============================================================================
-- Staging check of migration 20261118000100_venue_content_match.sql.
-- One transaction, throwaway rows, ROLLBACK at the end. Prints only pass/fail.
--   1 A public venue planted with the real place_id and coordinates but a
--     different name, address line, city or postal code is not handed to an
--     honest host who picks that place; the host gets their own public row.
--   2 Another user's public venue with the same name and address (case aside)
--     and a point within 300 m is still shared.
--   3 Once another host's event uses a venue, its creator can no longer fill
--     its empty fields (address_line2) through upsert_venue; before that the
--     creator still can.
--   4 schema_version 2.19 or later.
-- ============================================================================
begin;

do $$
declare
  v_names text[] := array['h', 'o', 'b'];
  v_id    uuid;
  v_hub   uuid;
  v_e     uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  perform set_config('test.tag', v_tag, true);
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'vcm-' || v_names[i] || '-' || v_tag || '@example.com', now(), now());
    update public.profile_private set birth_date = date '1992-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;

  select h.id into v_hub
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
   order by h.slug
   limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  insert into public.hub_members (user_id, hub_id) values (current_setting('test.h')::uuid, v_hub)
  on conflict do nothing;

  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Venue content match run',
          date_trunc('hour', now()) + interval '4 days', date_trunc('hour', now()) + interval '4 days 2 hours',
          'Midtown')
  returning id into v_e;
  insert into public.event_addresses (event_id, location_text) values (v_e, 'Venue check park');
  perform set_config('test.e', v_e::text, true);
end $$;

set local role authenticated;
do $$
declare
  v_tag  text := current_setting('test.tag');
  v_h    uuid := current_setting('test.h')::uuid;
  v_o    uuid := current_setting('test.o')::uuid;
  real   jsonb := jsonb_build_object('name', 'Real Hall', 'is_public', true, 'address_line1', '1 Real St',
                                     'city', 'Atlanta', 'state', 'GA', 'postal_code', '30309',
                                     'lat', 33.7800, 'lng', -84.3800);
  fakes  jsonb[] := array[
    jsonb_build_object('name', 'Planted Name'),
    jsonb_build_object('address_line1', '666 Wrong St'),
    jsonb_build_object('city', 'Decatur'),
    jsonb_build_object('postal_code', '30318')];
  vo     public.venues;
  vh     public.venues;
  vx     public.venues;
begin
  -- 1. Each planted variant differs from the real place in one field.
  for i in 1..array_length(fakes, 1) loop
    perform set_config('request.jwt.claims', json_build_object('sub', v_o, 'role', 'authenticated')::text, true);
    vo := public.upsert_venue(real || fakes[i] || jsonb_build_object('place_id', 'vcm-p' || i || '-' || v_tag));
    if vo.created_by is distinct from v_o then raise exception 'FAIL setup 1.% plant not created', i; end if;
    perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
    vh := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-p' || i || '-' || v_tag));
    if vh.id = vo.id or vh.created_by is distinct from v_h or not vh.is_public
       or vh.name <> 'Real Hall' or vh.address_line1 <> '1 Real St' or vh.postal_code <> '30309' then
      raise exception 'FAIL 1.% planted venue with a different field was handed over', i;
    end if;
  end loop;

  -- 2. Same content (name in another case) and a point about 55 m away is shared.
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
  vx := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-share-' || v_tag));
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  vh := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-share-' || v_tag, 'name', 'REAL HALL',
                                                       'lat', 33.7805));
  if vh.id is distinct from vx.id then raise exception 'FAIL 2 matching public venue was not shared'; end if;

  -- 3. o creates a place; h gets it and attaches it to h's event. A fresh name, so the
  --    (name, postal code) fallback cannot return a row from the steps above.
  real := real || jsonb_build_object('name', 'Fill Hall');
  perform set_config('request.jwt.claims', json_build_object('sub', v_o, 'role', 'authenticated')::text, true);
  vo := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-fill-' || v_tag));
  perform set_config('request.jwt.claims', json_build_object('sub', v_h, 'role', 'authenticated')::text, true);
  vh := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-fill-' || v_tag));
  if vh.id is distinct from vo.id then raise exception 'FAIL setup 3 venue not shared'; end if;
  perform public.update_event(current_setting('test.e')::uuid, jsonb_build_object('venue_id', vh.id));
  if not exists (select 1 from public.event_addresses where event_id = current_setting('test.e')::uuid
                  and venue_id = vh.id) then
    raise exception 'FAIL setup 3 venue did not attach';
  end if;
  perform set_config('request.jwt.claims', json_build_object('sub', v_o, 'role', 'authenticated')::text, true);
  vx := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-fill-' || v_tag,
                                                       'address_line2', 'Actually 666 Wrong St'));
  if vx.id is distinct from vo.id then raise exception 'FAIL setup 3 creator did not match own row'; end if;
  if (select address_line2 from public.venues where id = vo.id) <> '' then
    raise exception 'FAIL 3 creator changed a venue another host''s event uses';
  end if;

  -- 3b. o's own unused row still gets empty fields filled.
  real := real || jsonb_build_object('name', 'Own Hall');
  vo := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-own-' || v_tag));
  vx := public.upsert_venue(real || jsonb_build_object('place_id', 'vcm-own-' || v_tag, 'address_line2', 'Suite 2'));
  if vx.id is distinct from vo.id or vx.address_line2 <> 'Suite 2' then
    raise exception 'FAIL 3b creator could not fill an unused own venue';
  end if;
end $$;
reset role;

do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 19] then
    raise exception 'FAIL 4 schema_version is too old';
  end if;
end $$;

select 'venue_content_match: PASS' as result;

rollback;
