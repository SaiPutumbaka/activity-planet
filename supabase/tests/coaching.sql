-- ============================================================================
-- Staging check for migration 20261224000100_coaching.sql (migration 60,
-- coaching slice 1). One transaction: throwaway accounts, DO blocks that
-- raise on failure, then ROLLBACK. Prints pass/fail only (no user rows; the
-- accounts are invented). Slot generation across time zones and daylight-
-- saving changes is in coaching_rules.sql; payments, refunds, the webhook
-- ledger, reports, bans and account deletion in coaching_payments.sql.
--
--   1 static: schema_version 2.56 or later; no client writes; column grants
--     (no service_point, no client_request_id, no review reply); sessions and
--     payment tables closed to clients; private helpers and service RPCs out
--     of reach; requests only by default; the launch-shape and no-overlap
--     constraints exist.
--   2 who can coach: 23-hour account, no photo, no guidelines refused; the
--     service point is rounded; a bad time zone refused; publish needs the
--     current Coach Terms, a listing and availability.
--   3 listings: online + group refused by the RPC and by the table
--     constraint; a delivery the coach does not offer; group capacity; price,
--     link and sensitive-hub refusals; a 21+ hub forces 21.
--   4 slots and booking: slots in the coach's zone; requests are idempotent
--     and need the policy acknowledgment and an offered start; requests do
--     not hold time; confirming declines the overlapping request (slot_taken)
--     and removes the slot and its buffer; the exclusion constraint refuses an
--     overlapping session; client_overlap; one open request per listing.
--   5 states: wrong actor, wrong state and early transitions refused;
--     stamps; complete, no-show and contest; expiry and auto-complete through
--     coaching_tick.
--   6 reviews: only after completion, once, editable 7 days, 30-day window,
--     no links; one coach reply, editable 7 days; ratings count.
--   7 RLS for non-participants; 18+ and 21+.
--   8 blocks: search, profile, slots, booking and reviews; a block ends the
--     pair's bookings.
--   9 search near, online and by hub, bands only; the booking arm of shared
--     context opens a DM without a request; booking notifications.
-- ============================================================================
begin;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  return 'ok';
exception when others then
  return sqlerrm;
end $$;
-- Runs a statement as the migration owner (backdating rows and reading closed tables).
create function pg_temp.own(p_sql text) returns void language plpgsql security definer as $$
begin
  execute p_sql;
end $$;
create function pg_temp.own_val(p_sql text) returns text language plpgsql security definer as $$
declare
  v text;
begin
  execute p_sql into v;
  return v;
end $$;
-- A start in the coach's zone: local date (today + p_days) at p_time.
create function pg_temp.at_local(p_tz text, p_days integer, p_time time) returns timestamptz language sql stable as $$
  select (((now() at time zone p_tz)::date + p_days) + p_time) at time zone p_tz;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 56] then
    raise exception 'FAIL 1 schema_version is older than 2.56';
  end if;
  if not exists (select 1 from pg_extension where extname = 'btree_gist') then
    raise exception 'FAIL 1 btree_gist missing';
  end if;
  if has_table_privilege('authenticated', 'public.coach_profiles', 'insert')
     or has_table_privilege('authenticated', 'public.coach_profiles', 'update')
     or has_table_privilege('authenticated', 'public.coach_listings', 'insert')
     or has_table_privilege('authenticated', 'public.bookings', 'insert')
     or has_table_privilege('authenticated', 'public.bookings', 'update')
     or has_table_privilege('authenticated', 'public.coach_reviews', 'insert')
     or has_table_privilege('authenticated', 'public.coach_sessions', 'select')
     or has_table_privilege('authenticated', 'public.booking_private', 'select')
     or has_table_privilege('authenticated', 'public.booking_payments', 'select')
     or has_table_privilege('authenticated', 'public.coach_stripe_accounts', 'select')
     or has_table_privilege('authenticated', 'public.stripe_events', 'select')
     or has_table_privilege('authenticated', 'public.stripe_jobs', 'select')
     or has_table_privilege('authenticated', 'public.coach_fee_minimums', 'select')
     or has_table_privilege('anon', 'public.coach_profiles', 'select')
     or has_table_privilege('anon', 'public.bookings', 'select')
     or has_column_privilege('authenticated', 'public.coach_profiles', 'service_point', 'select')
     or has_column_privilege('authenticated', 'public.coach_profiles', 'terms_version', 'select')
     or has_column_privilege('authenticated', 'public.bookings', 'client_request_id', 'select')
     or has_column_privilege('authenticated', 'public.coach_reviews', 'reply', 'select')
     or not has_column_privilege('authenticated', 'public.coach_profiles', 'headline', 'select')
     or not has_column_privilege('authenticated', 'public.bookings', 'status', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if exists (select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
              where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity
                and c.relname in ('coach_profiles', 'coach_credentials', 'coach_photos', 'coach_hubs', 'coach_listings',
                                  'coach_listing_private', 'coach_availability_rules', 'coach_availability_exceptions',
                                  'coach_sessions', 'bookings', 'booking_private', 'coach_reviews',
                                  'coach_stripe_accounts', 'booking_payments', 'stripe_events', 'coach_fee_minimums',
                                  'stripe_jobs')) then
    raise exception 'FAIL 1 a coaching table has RLS off';
  end if;
  if has_function_privilege('anon', 'public.request_booking(uuid,timestamptz,text,text,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.request_booking(uuid,timestamptz,text,text,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.coaching_tick()', 'execute')
     or has_function_privilege('authenticated', 'public.booking_checkout_params(uuid,uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.booking_mark_paid(uuid,text,text,integer)', 'execute')
     or has_function_privilege('authenticated', 'public.stripe_event_begin(text,text,text,text,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.stripe_dispatch_verify_secret(text)', 'execute')
     or has_function_privilege('authenticated', 'private.coach_slot_candidates(uuid,date,date)', 'execute')
     or has_function_privilege('authenticated', 'private.booking_cancel(uuid,text,text,text,boolean)', 'execute')
     or has_function_privilege('authenticated', 'private.chat_shared_context(uuid,uuid)', 'execute')
     or not has_function_privilege('authenticated', 'private.coach_visible(uuid)', 'execute')
     or has_function_privilege('anon', 'private.coach_visible(uuid)', 'execute')
     or not has_function_privilege('service_role', 'public.coaching_tick()', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if (select value from public.meta where key = 'coach_payments') is distinct from 'off' then
    raise exception 'FAIL 1 payments are not off by default';
  end if;
  if not exists (select 1 from pg_constraint where conname = 'coach_listings_launch_shape')
     or not exists (select 1 from pg_constraint where conname = 'coach_sessions_no_overlap' and contype = 'x') then
    raise exception 'FAIL 1 launch-shape or no-overlap constraint missing';
  end if;
  if (select min_fee_minor from public.coach_fee_minimums where currency = 'usd') is distinct from 300 then
    raise exception 'FAIL 1 usd minimum fee is not 300';
  end if;
  if not exists (select 1 from pg_enum e join pg_type t on t.oid = e.enumtypid
                  where t.typname = 'notification_kind' and e.enumlabel = 'booking_requested') then
    raise exception 'FAIL 1 booking notification kinds missing';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- c: in-person coach (New York). d: online coach (Berlin). a, b: clients. x: a stranger.
  -- y: 19 years old. k: client who blocks c later. n: 23-hour account. p: no photo.
  -- q: guidelines not accepted. s: a stranger who blocks a.
  v_names text[] := array['c', 'd', 'a', 'b', 'x', 'y', 'k', 'n', 'p', 'q', 's'];
  v_id    uuid;
  v_ids   uuid[] := '{}';
  v_hub   uuid;
  v_sens  uuid;
  v_h21   uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
begin
  if public.project_url() is null then
    raise exception 'FAIL setup: meta.project_url is not set';
  end if;
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'coach-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private
       set birth_date = case when v_names[i] = 'y' then (current_date - interval '19 years')::date else date '1990-04-04' end
     where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester',
           guidelines_accepted_at = case when v_names[i] = 'q' then null else now() end,
           created_at = case when v_names[i] = 'n' then now() - interval '23 hours' else now() - interval '3 days' end,
           avatar_url = case when v_names[i] = 'p' then null
                             else public.project_url() || '/storage/v1/object/public/avatars/' || v_id || '/a.jpg' end
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
    v_ids := v_ids || v_id;
  end loop;
  perform set_config('test.ids', array_to_string(v_ids, ','), true);

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive order by h.slug limit 1;
  select h.id into v_h21 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 21 and not c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.sens', coalesce(v_sens::text, ''), true);
  perform set_config('test.h21', coalesce(v_h21::text, ''), true);
  insert into public.notification_prefs (user_id) select u from unnest(v_ids) u on conflict do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Who can coach
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_p text := '{"headline":"Tennis for every level","timezone":"America/New_York","in_person":true,"lat":33.77561,"lng":-84.39634,"radius_km":10,"area_label":"Midtown"}';
begin
  perform pg_temp.act('n');
  if pg_temp.err(format('select public.upsert_coach_profile(%L::jsonb)', v_p)) <> 'account_too_new' then
    raise exception 'FAIL 2 a 23-hour account became a coach';
  end if;
  perform pg_temp.act('p');
  if pg_temp.err(format('select public.upsert_coach_profile(%L::jsonb)', v_p)) <> 'photo_required' then
    raise exception 'FAIL 2 an account without a photo became a coach';
  end if;
  perform pg_temp.act('q');
  if pg_temp.err(format('select public.upsert_coach_profile(%L::jsonb)', v_p)) <> 'guidelines_required' then
    raise exception 'FAIL 2 guidelines were not required';
  end if;
  perform pg_temp.act('c');
  if pg_temp.err($q$select public.upsert_coach_profile('{"timezone":"Mars/Olympus","in_person":true,"lat":1,"lng":1,"radius_km":5}'::jsonb)$q$)
     <> 'timezone_invalid' then
    raise exception 'FAIL 2 a bad time zone was accepted';
  end if;
  if pg_temp.err($q$select public.upsert_coach_profile('{"timezone":"America/New_York","in_person":true}'::jsonb)$q$)
     <> 'invalid_area' then
    raise exception 'FAIL 2 in person without an area was accepted';
  end if;
  perform public.upsert_coach_profile(v_p::jsonb);
  if pg_temp.err('select public.publish_coach_profile()') <> 'coach_terms_required' then
    raise exception 'FAIL 2 published without Coach Terms';
  end if;
  if pg_temp.err($q$select public.accept_coach_terms('2020-01')$q$) <> 'unknown_version' then
    raise exception 'FAIL 2 an old Coach Terms version was accepted';
  end if;
  perform public.accept_coach_terms((public.coaching_config() ->> 'coach_terms_version'));
  if pg_temp.err('select public.publish_coach_profile()') <> 'incomplete_profile' then
    raise exception 'FAIL 2 published without a listing and availability';
  end if;
  -- d coaches online only, from Berlin.
  perform pg_temp.act('d');
  perform public.upsert_coach_profile('{"headline":"Chess lessons online","timezone":"Europe/Berlin","in_person":false,"online":true}'::jsonb);
  perform public.accept_coach_terms((public.coaching_config() ->> 'coach_terms_version'));
end $$;
reset role;
do $$
begin
  if pg_temp.own_val(format($q$select round(extensions.ST_Y(service_point::extensions.geometry)::numeric, 5)::text
                                from public.coach_profiles where user_id = %L$q$, pg_temp.uid('c'))) <> '33.78000'
     or pg_temp.own_val(format($q$select round(extensions.ST_X(service_point::extensions.geometry)::numeric, 5)::text
                                from public.coach_profiles where user_id = %L$q$, pg_temp.uid('c'))) <> '-84.40000' then
    raise exception 'FAIL 2 the service point was not rounded to 0.01 degree';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Listings
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v jsonb;
begin
  perform pg_temp.act('d');
  if pg_temp.err($q$select public.upsert_listing('{"title":"Group chess","delivery":"online","format":"group","capacity":6,"duration_minutes":60,"price_minor":2000,"currency":"usd"}'::jsonb)$q$)
     <> 'invalid_shape' then
    raise exception 'FAIL 3 online + group was accepted';
  end if;
  if pg_temp.err($q$select public.upsert_listing('{"title":"Chess in the park","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":2000,"currency":"usd"}'::jsonb)$q$)
     <> 'delivery_not_offered' then
    raise exception 'FAIL 3 a delivery the coach does not offer was accepted';
  end if;
  v := public.upsert_listing('{"title":"Chess, one hour","delivery":"online","format":"one_on_one","duration_minutes":60,"price_minor":3000,"currency":"eur","min_notice_hours":1,"slot_step_minutes":60,"online_link":"https://meet.example.com/abc"}'::jsonb);
  perform set_config('test.ld', v ->> 'id', true);
  perform public.set_availability('[{"weekday":1,"start":"07:00","end":"22:00"},{"weekday":2,"start":"07:00","end":"22:00"},{"weekday":3,"start":"07:00","end":"22:00"},{"weekday":4,"start":"07:00","end":"22:00"},{"weekday":5,"start":"07:00","end":"22:00"},{"weekday":6,"start":"07:00","end":"22:00"},{"weekday":7,"start":"07:00","end":"22:00"}]'::jsonb);
  perform public.publish_coach_profile();

  perform pg_temp.act('c');
  if pg_temp.err($q$select public.upsert_listing('{"title":"Group tennis","delivery":"in_person","format":"group","capacity":1,"duration_minutes":60,"price_minor":2000,"currency":"usd"}'::jsonb)$q$)
     <> 'invalid_shape' then
    raise exception 'FAIL 3 a group of one was accepted';
  end if;
  if pg_temp.err($q$select public.upsert_listing('{"title":"Tennis","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":-5,"currency":"usd"}'::jsonb)$q$)
     <> 'invalid_price' then
    raise exception 'FAIL 3 a negative price was accepted';
  end if;
  if pg_temp.err($q$select public.upsert_listing('{"title":"Tennis","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":100,"currency":"US$"}'::jsonb)$q$)
     <> 'invalid_price' then
    raise exception 'FAIL 3 a bad currency was accepted';
  end if;
  if pg_temp.err($q$select public.upsert_listing('{"title":"Tennis","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":100,"currency":"usd","online_link":"http://x.example.com"}'::jsonb)$q$)
     <> 'invalid_link' then
    raise exception 'FAIL 3 a non-https link was accepted';
  end if;
  if current_setting('test.sens') <> ''
     and pg_temp.err(format($q$select public.set_coach_hubs(array[%L]::uuid[])$q$, current_setting('test.sens'))) <> 'hub_not_allowed' then
    raise exception 'FAIL 3 a sensitive hub was accepted';
  end if;
  if pg_temp.err(format($q$select public.set_coach_photos(array[%L])$q$,
                        public.project_url() || '/storage/v1/object/public/avatars/' || pg_temp.uid('a') || '/coach/1.jpg')) <> 'invalid_photo' then
    raise exception 'FAIL 3 someone else''s photo was accepted';
  end if;
  perform public.set_coach_photos(array[public.project_url() || '/storage/v1/object/public/avatars/' || pg_temp.uid('c') || '/coach/1.jpg']);
  perform public.set_coach_hubs(array[current_setting('test.hub')::uuid]);
  perform public.set_coach_credentials('[{"title":"Certified tennis instructor","issuer":"A coaching body","year":2018}]'::jsonb);

  -- L1: one hour, 15-minute buffer, slots on the hour. L2: the same coach, 30 minutes.
  v := public.upsert_listing(format('{"title":"Tennis, one hour","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","buffer_minutes":15,"min_notice_hours":1,"slot_step_minutes":60,"hub_id":"%s","meeting_note":"North gate of the courts"}',
                                    current_setting('test.hub'))::jsonb);
  perform set_config('test.l1', v ->> 'id', true);
  if (v ->> 'payable')::boolean then raise exception 'FAIL 3 payable while payments are off'; end if;
  v := public.upsert_listing('{"title":"Tennis, half hour","delivery":"in_person","format":"one_on_one","duration_minutes":30,"price_minor":0,"currency":"usd","min_notice_hours":1,"slot_step_minutes":30}'::jsonb);
  perform set_config('test.l2', v ->> 'id', true);
  v := public.upsert_listing('{"title":"Tennis for 21 and over","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","min_age":21,"min_notice_hours":1,"slot_step_minutes":60}'::jsonb);
  perform set_config('test.l21', v ->> 'id', true);
  if current_setting('test.h21') <> '' then
    v := public.upsert_listing(format('{"title":"Tennis at the club","delivery":"in_person","format":"one_on_one","duration_minutes":60,"price_minor":4000,"currency":"usd","hub_id":"%s"}',
                                      current_setting('test.h21'))::jsonb);
    if (select l.min_age from public.coach_listings l where l.id = (v ->> 'id')::uuid) <> 21 then
      raise exception 'FAIL 3 a 21+ hub did not force 21';
    end if;
    perform public.set_listing_status((v ->> 'id')::uuid, 'archived');
  end if;
  -- Every day, 08:00 to 20:00 in New York.
  perform public.set_availability('[{"weekday":1,"start":"08:00","end":"20:00"},{"weekday":2,"start":"08:00","end":"20:00"},{"weekday":3,"start":"08:00","end":"20:00"},{"weekday":4,"start":"08:00","end":"20:00"},{"weekday":5,"start":"08:00","end":"20:00"},{"weekday":6,"start":"08:00","end":"20:00"},{"weekday":7,"start":"08:00","end":"20:00"}]'::jsonb);
  if pg_temp.err($q$select public.set_availability('[{"weekday":8,"start":"08:00","end":"09:00"}]'::jsonb)$q$) <> 'invalid_rule'
     or pg_temp.err($q$select public.set_availability('[{"weekday":1,"start":"10:00","end":"09:00"}]'::jsonb)$q$) <> 'invalid_rule' then
    raise exception 'FAIL 3 a bad weekly window was accepted';
  end if;
  if (select count(*) from public.coach_availability_rules where coach_id = pg_temp.uid('c')) <> 7 then
    raise exception 'FAIL 3 a refused set_availability changed the rules';
  end if;
  perform public.publish_coach_profile();
end $$;
reset role;
do $$
begin
  -- The table constraint itself refuses the shape, whatever the caller.
  if pg_temp.err(format($q$insert into public.coach_listings (coach_id, title, delivery, format, capacity, duration_minutes, price_minor, currency)
                          values (%L, 'Direct online group', 'online', 'group', 5, 60, 1000, 'usd')$q$, pg_temp.uid('d')))
     not like '%coach_listings_launch_shape%' then
    raise exception 'FAIL 3 the table accepted online + group';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Slots and booking
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_tz  text := 'America/New_York';
  v_d   integer := 3;
  v_s1  timestamptz := pg_temp.at_local('America/New_York', 3, time '10:00');
  v     jsonb;
  v_req uuid := gen_random_uuid();
  v_pol text := public.coaching_config() ->> 'policy_version';
  v_n   integer;
begin
  perform set_config('test.s1', v_s1::text, true);
  perform pg_temp.act('a');
  select count(*) into v_n from public.coach_slots(pg_temp.uid('l1'::text)::uuid,
                                                   (now() at time zone v_tz)::date + v_d, (now() at time zone v_tz)::date + v_d);
  if v_n <> 12 then raise exception 'FAIL 4 expected 12 hourly slots between 08:00 and 20:00, got %', v_n; end if;
  if exists (select 1 from public.coach_slots(current_setting('test.l1')::uuid, current_date, current_date + 20) s
              where (s.starts_at at time zone v_tz)::time < time '08:00' or (s.ends_at at time zone v_tz)::time > time '20:00'
                 or s.starts_at < now() + interval '1 hour') then
    raise exception 'FAIL 4 a slot outside the window or the minimum notice';
  end if;
  if pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date, current_date + 40)', current_setting('test.l1')))
     <> 'range_too_long' then
    raise exception 'FAIL 4 a 40-day range was accepted';
  end if;

  -- Requests: policy, offered start, idempotency.
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.l1'), v_s1, '', '1999-01', v_req))
     <> 'policy_ack_required' then
    raise exception 'FAIL 4 a request without the current policy';
  end if;
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.l1'),
                        v_s1 + interval '30 minutes', '', v_pol, gen_random_uuid())) <> 'slot_unavailable' then
    raise exception 'FAIL 4 a start the server does not offer was accepted';
  end if;
  v := public.request_booking(current_setting('test.l1')::uuid, v_s1, 'First lesson', v_pol, v_req);
  if v ->> 'status' <> 'requested' or v ->> 'payment_mode' <> 'off_platform' or (v ->> 'duplicate')::boolean then
    raise exception 'FAIL 4 request: %', v;
  end if;
  perform set_config('test.ba', v ->> 'id', true);
  if (public.request_booking(current_setting('test.l1')::uuid, v_s1, 'First lesson', v_pol, v_req) ->> 'id') <> v ->> 'id' then
    raise exception 'FAIL 4 the same client request id made a second booking';
  end if;
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.l1'),
                        v_s1 + interval '2 hours', '', v_pol, gen_random_uuid())) <> 'too_many_open' then
    raise exception 'FAIL 4 two open requests on one listing';
  end if;
  -- Requests do not hold time: b asks for the same hour.
  perform pg_temp.act('b');
  v := public.request_booking(current_setting('test.l1')::uuid, v_s1, '', v_pol, gen_random_uuid());
  perform set_config('test.bb', v ->> 'id', true);
  if v ->> 'status' <> 'requested' then raise exception 'FAIL 4 a second request for the same hour was refused'; end if;
  -- The other party and a stranger cannot act on a's booking.
  if pg_temp.err(format('select public.confirm_booking(%L)', current_setting('test.ba'))) <> 'not_found' then
    raise exception 'FAIL 4 a client confirmed someone else''s booking';
  end if;
  perform pg_temp.act('x');
  if pg_temp.err(format('select public.cancel_booking(%L)', current_setting('test.ba'))) <> 'not_found'
     or pg_temp.err(format('select public.get_booking(%L)', current_setting('test.ba'))) <> 'not_found' then
    raise exception 'FAIL 4 a stranger reached a booking';
  end if;

  -- The coach confirms a: b's request is declined (slot_taken); the hour and its buffer are gone.
  perform pg_temp.act('c');
  perform public.confirm_booking(current_setting('test.ba')::uuid);
  if pg_temp.err(format('select public.confirm_booking(%L)', current_setting('test.ba'))) <> 'invalid_state' then
    raise exception 'FAIL 4 a booking was confirmed twice';
  end if;
  if pg_temp.err(format('select public.confirm_booking(%L)', current_setting('test.bb'))) <> 'invalid_state' then
    raise exception 'FAIL 4 the overlapping request could still be confirmed';
  end if;
  perform pg_temp.act('b');
  v := public.get_booking(current_setting('test.bb')::uuid);
  if v ->> 'status' <> 'declined' or v ->> 'cancel_reason' <> 'slot_taken' or v ->> 'declined_at' is null then
    raise exception 'FAIL 4 the overlapping request was not declined as slot_taken: %', v ->> 'status';
  end if;
  if exists (select 1 from public.coach_slots(current_setting('test.l1')::uuid,
                                               (now() at time zone v_tz)::date + v_d, (now() at time zone v_tz)::date + v_d) s
              where s.starts_at in (v_s1, v_s1 + interval '1 hour')) then
    raise exception 'FAIL 4 the booked hour or the slot inside its buffer is still offered';
  end if;
  if not exists (select 1 from public.coach_slots(current_setting('test.l1')::uuid,
                                                   (now() at time zone v_tz)::date + v_d, (now() at time zone v_tz)::date + v_d) s
                  where s.starts_at = v_s1 + interval '2 hours') then
    raise exception 'FAIL 4 the slot after the buffer is missing';
  end if;
  -- The half-hour listing of the same coach loses the held time too (any listing).
  if exists (select 1 from public.coach_slots(current_setting('test.l2')::uuid,
                                               (now() at time zone v_tz)::date + v_d, (now() at time zone v_tz)::date + v_d) s
              where s.starts_at >= v_s1 - interval '15 minutes' and s.starts_at < v_s1 + interval '1 hour 15 minutes') then
    raise exception 'FAIL 4 another listing offers time the session holds';
  end if;
  -- client_overlap: a is confirmed at s1, and asks d for the same hour online.
  perform pg_temp.act('a');
  v := public.get_booking(current_setting('test.ba')::uuid);
  if v ->> 'status' <> 'confirmed' or v ->> 'confirmed_at' is null or v ->> 'meeting_note' <> 'North gate of the courts'
     or (v ->> 'expires_at')::timestamptz > v_s1 - interval '2 hours' or (v ->> 'free_cancel_until')::timestamptz <> v_s1 - interval '24 hours' then
    raise exception 'FAIL 4 confirmed booking state or stamps';
  end if;
  if pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.ld'), v_s1, '', v_pol,
                        gen_random_uuid())) <> 'client_overlap' then
    raise exception 'FAIL 4 a client double-booked themselves';
  end if;
end $$;
reset role;
do $$
declare
  v_s1 timestamptz := current_setting('test.s1')::timestamptz;
begin
  -- The exclusion constraint refuses an overlapping session for the coach, whatever the path.
  if pg_temp.err(format($q$insert into public.coach_sessions (coach_id, listing_id, starts_at, ends_at, busy, capacity)
                          values (%L, %L, %L, %L, tstzrange(now(), now()), 1)$q$,
                        pg_temp.uid('c'), current_setting('test.l2'), v_s1 + interval '30 minutes', v_s1 + interval '1 hour'))
     not like '%coach_sessions_no_overlap%' then
    raise exception 'FAIL 4 the exclusion constraint did not refuse an overlapping session';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. States
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v_pol text := public.coaching_config() ->> 'policy_version';
  v     jsonb;
begin
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.complete_booking(%L)', current_setting('test.ba'))) <> 'too_early'
     or pg_temp.err(format('select public.mark_no_show(%L)', current_setting('test.ba'))) <> 'too_early' then
    raise exception 'FAIL 5 complete or no-show before the session';
  end if;
  if pg_temp.err(format('select public.decline_booking(%L)', current_setting('test.ba'))) <> 'invalid_state' then
    raise exception 'FAIL 5 a confirmed booking was declined';
  end if;
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.complete_booking(%L)', current_setting('test.ba'))) <> 'not_found' then
    raise exception 'FAIL 5 the client completed a booking';
  end if;
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', current_setting('test.ba'), 'Great')) <> 'not_completed' then
    raise exception 'FAIL 6 a review before completion';
  end if;
  -- More bookings for the state tests: e (to complete), f (no-show), g (to expire), h (auto-complete).
  perform pg_temp.act('b');
  v := public.request_booking(current_setting('test.l1')::uuid, pg_temp.at_local('America/New_York', 4, time '09:00'), '', v_pol, gen_random_uuid());
  perform set_config('test.be', v ->> 'id', true);
  perform pg_temp.act('k');
  v := public.request_booking(current_setting('test.l1')::uuid, pg_temp.at_local('America/New_York', 4, time '12:00'), '', v_pol, gen_random_uuid());
  perform set_config('test.bk', v ->> 'id', true);
  perform pg_temp.act('x');
  v := public.request_booking(current_setting('test.l2')::uuid, pg_temp.at_local('America/New_York', 4, time '15:00'), '', v_pol, gen_random_uuid());
  perform set_config('test.bg', v ->> 'id', true);
  if v ->> 'payment_mode' <> 'none' then raise exception 'FAIL 5 a free listing is not payment mode none'; end if;
  v := public.request_booking(current_setting('test.ld')::uuid, pg_temp.at_local('Europe/Berlin', 5, time '18:00'), '', v_pol, gen_random_uuid());
  perform set_config('test.bh', v ->> 'id', true);
  perform pg_temp.act('c');
  perform public.confirm_booking(current_setting('test.be')::uuid);
  perform public.confirm_booking(current_setting('test.bk')::uuid);
  perform pg_temp.act('d');
  perform public.confirm_booking(current_setting('test.bh')::uuid);
end $$;
reset role;
-- Time passes: e and k ended two hours ago, k started 20 minutes ago for the no-show window,
-- g's request expired, h ended three days ago.
do $$
begin
  perform pg_temp.own(format($q$update public.bookings set starts_at = now() - interval '3 hours', ends_at = now() - interval '2 hours' where id = %L$q$, current_setting('test.be')));
  perform pg_temp.own(format($q$update public.bookings set starts_at = now() - interval '20 minutes', ends_at = now() + interval '40 minutes' where id = %L$q$, current_setting('test.bk')));
  perform pg_temp.own(format($q$update public.bookings set expires_at = now() - interval '1 minute' where id = %L$q$, current_setting('test.bg')));
  perform pg_temp.own(format($q$update public.bookings set starts_at = now() - interval '4 days', ends_at = now() - interval '3 days', confirmed_at = now() - interval '5 days' where id = %L$q$, current_setting('test.bh')));
  perform public.coaching_tick();
  if pg_temp.own_val(format('select status::text from public.bookings where id = %L', current_setting('test.bg'))) <> 'expired'
     or pg_temp.own_val(format('select (expired_at is not null)::text from public.bookings where id = %L', current_setting('test.bg'))) <> 'true' then
    raise exception 'FAIL 5 coaching_tick did not expire the request';
  end if;
  if pg_temp.own_val(format('select status::text from public.bookings where id = %L', current_setting('test.bh'))) <> 'completed'
     or pg_temp.own_val(format('select (completed_at is not null)::text from public.bookings where id = %L', current_setting('test.bh'))) <> 'true' then
    raise exception 'FAIL 5 coaching_tick did not complete a booking 48 hours after its end';
  end if;
  if pg_temp.own_val(format('select status::text from public.bookings where id = %L', current_setting('test.be'))) <> 'confirmed' then
    raise exception 'FAIL 5 coaching_tick completed a booking before 48 hours';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v jsonb;
begin
  perform pg_temp.act('c');
  v := public.complete_booking(current_setting('test.be')::uuid);
  if v ->> 'status' <> 'completed' then raise exception 'FAIL 5 complete'; end if;
  if pg_temp.err(format('select public.complete_booking(%L)', current_setting('test.be'))) <> 'invalid_state' then
    raise exception 'FAIL 5 completed twice';
  end if;
  -- k did not come: the coach marks it; k contests once.
  perform public.mark_no_show(current_setting('test.bk')::uuid);
  perform pg_temp.act('k');
  if pg_temp.err(format('select public.write_review(%L, 1, %L)', current_setting('test.bk'), 'No')) <> 'not_completed' then
    raise exception 'FAIL 6 a no-show was reviewed';
  end if;
  v := public.contest_no_show(current_setting('test.bk')::uuid, 'I was there at the north gate');
  if v ->> 'report_id' is null then raise exception 'FAIL 5 a contest did not open a report'; end if;
  if pg_temp.err(format('select public.contest_no_show(%L, %L)', current_setting('test.bk'), 'again')) <> 'invalid_state' then
    raise exception 'FAIL 5 contested twice';
  end if;
  v := public.get_booking(current_setting('test.bk')::uuid);
  if v ->> 'status' <> 'no_show' or v ->> 'no_show_party' <> 'client' or v ->> 'no_show_at' is null
     or v ->> 'no_show_contested_at' is null then
    raise exception 'FAIL 5 no-show stamps';
  end if;
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.contest_no_show(%L, %L)', current_setting('test.bk'), 'me too')) <> 'not_found'
     and pg_temp.err(format('select public.contest_no_show(%L, %L)', current_setting('test.bk'), 'me too')) <> 'invalid_state' then
    raise exception 'FAIL 5 the coach contested their own no-show mark';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Reviews
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.write_review(%L, 6, %L)', current_setting('test.be'), 'Great')) <> 'invalid_rating' then
    raise exception 'FAIL 6 a rating of 6';
  end if;
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', current_setting('test.be'), 'Book me at tennis.example.com')) <> 'review_filtered' then
    raise exception 'FAIL 6 a link in a review';
  end if;
  v := public.write_review(current_setting('test.be')::uuid, 4, 'Patient and clear');
  if (v ->> 'edited')::boolean then raise exception 'FAIL 6 the first review was an edit'; end if;
  v := public.write_review(current_setting('test.be')::uuid, 5, 'Patient and clear, and on time');
  if not (v ->> 'edited')::boolean then raise exception 'FAIL 6 a second review within 7 days did not edit'; end if;
  perform pg_temp.act('x');
  if pg_temp.err(format('select public.write_review(%L, 1, %L)', current_setting('test.be'), 'Bad')) <> 'not_found' then
    raise exception 'FAIL 6 a stranger reviewed a booking';
  end if;
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', current_setting('test.be'), 'Me')) <> 'not_found' then
    raise exception 'FAIL 6 the coach reviewed their own booking';
  end if;
  perform public.reply_to_review(current_setting('test.be')::uuid, 'Thanks, see you next week');
  v := public.reply_to_review(current_setting('test.be')::uuid, 'Thanks, see you soon');
  if not (v ->> 'edited')::boolean then raise exception 'FAIL 6 a reply edit within 7 days'; end if;
  perform pg_temp.act('d');
  if pg_temp.err(format('select public.reply_to_review(%L, %L)', current_setting('test.be'), 'Not mine')) <> 'not_found' then
    raise exception 'FAIL 6 another coach replied';
  end if;
  if (select cp.rating_count from public.coach_profiles cp where cp.user_id = pg_temp.uid('c')) <> 1
     or (select cp.rating_avg from public.coach_profiles cp where cp.user_id = pg_temp.uid('c')) <> 5.00
     or (select cp.completed_count from public.coach_profiles cp where cp.user_id = pg_temp.uid('c')) <> 1 then
    raise exception 'FAIL 6 rating or completed counts';
  end if;
end $$;
reset role;
do $$
begin
  perform pg_temp.own(format($q$update public.coach_reviews set created_at = now() - interval '8 days', replied_at = now() - interval '8 days' where booking_id = %L$q$, current_setting('test.be')));
  perform pg_temp.own(format($q$update public.bookings set completed_at = now() - interval '31 days' where id = %L$q$, current_setting('test.bh')));
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('b');
  if pg_temp.err(format('select public.write_review(%L, 1, %L)', current_setting('test.be'), 'Changed my mind')) <> 'already_reviewed' then
    raise exception 'FAIL 6 a review edited after 7 days';
  end if;
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.reply_to_review(%L, %L)', current_setting('test.be'), 'Late edit')) <> 'reply_locked' then
    raise exception 'FAIL 6 a reply edited after 7 days';
  end if;
  perform pg_temp.act('a');
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', current_setting('test.bh'), 'Late')) <> 'not_found' then
    raise exception 'FAIL 6 a non-client reviewed';
  end if;
  perform pg_temp.act('x');
  if pg_temp.err(format('select public.write_review(%L, 5, %L)', current_setting('test.bh'), 'Late')) <> 'review_window_closed' then
    raise exception 'FAIL 6 a review after 30 days';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. RLS for non-participants; 18+ and 21+
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform pg_temp.act('x');
  if exists (select 1 from public.bookings where id in (current_setting('test.ba')::uuid, current_setting('test.be')::uuid)) then
    raise exception 'FAIL 7 a stranger selected other people''s bookings';
  end if;
  if exists (select 1 from public.coach_listing_private) or exists (select 1 from public.coach_availability_rules)
     or exists (select 1 from public.coach_availability_exceptions where coach_id = pg_temp.uid('c')) then
    raise exception 'FAIL 7 a stranger read a coach''s private rows';
  end if;
  if pg_temp.err('select count(*) from public.coach_sessions') not like '%permission denied%'
     or pg_temp.err('select count(*) from public.booking_private') not like '%permission denied%'
     or pg_temp.err('select service_point from public.coach_profiles') not like '%permission denied%'
     or pg_temp.err('select client_request_id from public.bookings') not like '%permission denied%' then
    raise exception 'FAIL 7 a closed table or column was readable';
  end if;
  if not exists (select 1 from public.coach_profiles where user_id = pg_temp.uid('c'))
     or not exists (select 1 from public.coach_listings where id = current_setting('test.l1')::uuid) then
    raise exception 'FAIL 7 an adult cannot see an active coach and listing';
  end if;
  v := public.get_coach((select handle from public.profiles where id = pg_temp.uid('c')));
  if v ? 'service_point' or v::text like '%33.78%' then
    raise exception 'FAIL 7 get_coach returned the service point';
  end if;
  if not (v -> 'credentials' -> 0 ->> 'self_reported')::boolean then
    raise exception 'FAIL 7 credentials are not marked self-reported';
  end if;
  if jsonb_array_length(v -> 'reviews' -> 'items') <> 1 or v -> 'reviews' -> 'items' -> 0 ->> 'reply' is null then
    raise exception 'FAIL 7 the review and its reply are not on the coach page';
  end if;
  -- 19 years old: the 21+ listing does not exist for them.
  perform pg_temp.act('y');
  if exists (select 1 from public.coach_listings where id = current_setting('test.l21')::uuid)
     or exists (select 1 from jsonb_array_elements(public.get_coach((select handle from public.profiles where id = pg_temp.uid('c'))) -> 'listings') e
                 where e ->> 'id' = current_setting('test.l21'))
     or pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date, current_date + 5)', current_setting('test.l21'))) <> 'not_found'
     or pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.l21'),
                           pg_temp.at_local('America/New_York', 6, time '10:00'), '', public.coaching_config() ->> 'policy_version',
                           gen_random_uuid())) <> 'not_found' then
    raise exception 'FAIL 7 a 19-year-old reached a 21+ listing';
  end if;
  if not exists (select 1 from public.coach_listings where id = current_setting('test.l1')::uuid) then
    raise exception 'FAIL 7 a 19-year-old cannot see an 18+ listing';
  end if;
end $$;
reset role;
do $$
begin
  -- Not onboarded (no adult on record): nothing coaching is readable.
  perform pg_temp.own(format('update public.profiles set onboarding_completed_at = null where id = %L', pg_temp.uid('q')));
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('q');
  if exists (select 1 from public.coach_profiles where user_id = pg_temp.uid('c'))
     or pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date, current_date + 5)', current_setting('test.l1'))) <> 'onboarding_required'
     or pg_temp.err('select count(*) from public.search_coaches()') <> 'onboarding_required' then
    raise exception 'FAIL 7 an account that is not onboarded read coaching';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Blocks
-- ---------------------------------------------------------------------------
do $$
declare
  v_pol text := public.coaching_config() ->> 'policy_version';
  v     jsonb;
  v_h   text := (select handle from public.profiles where id = pg_temp.uid('c'));
begin
  -- s blocks b: b's review of c disappears for s; the rating does not change.
  perform pg_temp.act('s');
  if jsonb_array_length(public.coach_reviews_page(pg_temp.uid('c')) -> 'items') <> 1 then
    raise exception 'FAIL 8 s cannot see the review before the block';
  end if;
  perform public.block_user(pg_temp.uid('b'));
  if jsonb_array_length(public.coach_reviews_page(pg_temp.uid('c')) -> 'items') <> 0
     or exists (select 1 from public.coach_reviews where booking_id = current_setting('test.be')::uuid) then
    raise exception 'FAIL 8 a review by someone the viewer blocked is visible';
  end if;
  if (select cp.rating_count from public.coach_profiles cp where cp.user_id = pg_temp.uid('c')) <> 1 then
    raise exception 'FAIL 8 a block changed the coach''s rating';
  end if;

  -- a has a confirmed booking with c, and a new request; a blocks c.
  perform pg_temp.act('a');
  v := public.request_booking(current_setting('test.l2')::uuid, pg_temp.at_local('America/New_York', 6, time '16:00'), '', v_pol, gen_random_uuid());
  perform set_config('test.ba2', v ->> 'id', true);
  perform public.block_user(pg_temp.uid('c'));
  v := public.get_booking(current_setting('test.ba')::uuid);
  if v ->> 'status' <> 'cancelled' or v ->> 'cancel_reason' <> 'blocked' or v ->> 'cancelled_by' <> 'system' then
    raise exception 'FAIL 8 a block did not cancel the confirmed booking';
  end if;
  if public.get_booking(current_setting('test.ba2')::uuid) ->> 'status' <> 'declined' then
    raise exception 'FAIL 8 a block did not decline the open request';
  end if;
  if exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_radius_km => 25) s where s.user_id = pg_temp.uid('c'))
     or exists (select 1 from public.coach_profiles where user_id = pg_temp.uid('c'))
     or exists (select 1 from public.coach_listings where coach_id = pg_temp.uid('c'))
     or pg_temp.err(format('select public.get_coach(%L)', v_h)) <> 'not_found'
     or pg_temp.err(format('select count(*) from public.coach_slots(%L, current_date, current_date + 5)', current_setting('test.l1'))) <> 'not_found'
     or pg_temp.err(format('select public.request_booking(%L, %L, %L, %L, %L)', current_setting('test.l1'),
                           pg_temp.at_local('America/New_York', 7, time '10:00'), '', v_pol, gen_random_uuid())) <> 'not_found'
     or pg_temp.err(format('select public.coach_reviews_page(%L)', pg_temp.uid('c'))) <> 'not_found' then
    raise exception 'FAIL 8 the blocker still reaches the coach';
  end if;
  -- Symmetric: the coach does not find a's bookings actionable either.
  perform pg_temp.act('c');
  if pg_temp.err(format('select public.confirm_booking(%L)', current_setting('test.ba2'))) not in ('not_found', 'invalid_state') then
    raise exception 'FAIL 8 the coach acted across a block';
  end if;
  if (select count(*) from public.notifications n where n.user_id = pg_temp.uid('c') and n.kind = 'booking_cancelled'
         and n.payload ->> 'booking_id' = current_setting('test.ba')) > 0 then
    raise exception 'FAIL 8 a block sent a cancellation notice';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 9. Search, shared context, notifications
-- ---------------------------------------------------------------------------
do $$
declare
  r record;
  v jsonb;
begin
  perform pg_temp.act('x');
  -- Near the coach (Atlanta): c with a band; d online; never a coordinate.
  select * into r from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_radius_km => 25) s where s.user_id = pg_temp.uid('c');
  if r.user_id is null or r.distance_band not in ('<1 mi', '1-5 mi') or r.from_price_minor <> 0 or r.from_currency <> 'usd' then
    raise exception 'FAIL 9 the nearby coach is missing or has the wrong band';
  end if;
  if not exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396) s
                  where s.user_id = pg_temp.uid('d') and s.distance_band = 'online') then
    raise exception 'FAIL 9 the online coach is missing near Atlanta';
  end if;
  -- From London: no in-person Atlanta coach; the online coach is there.
  if exists (select 1 from public.search_coaches(p_lat => 51.5072, p_lng => -0.1276) s where s.user_id = pg_temp.uid('c'))
     or not exists (select 1 from public.search_coaches(p_lat => 51.5072, p_lng => -0.1276) s where s.user_id = pg_temp.uid('d')) then
    raise exception 'FAIL 9 search from another city';
  end if;
  if exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_delivery => 'online') s where s.user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 9 the online filter kept an in-person coach';
  end if;
  if not exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_hub_id => current_setting('test.hub')::uuid) s
                  where s.user_id = pg_temp.uid('c'))
     or exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_hub_id => current_setting('test.hub')::uuid) s
                 where s.user_id = pg_temp.uid('d')) then
    raise exception 'FAIL 9 the hub filter';
  end if;
  if not exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_query => 'tennis') s where s.user_id = pg_temp.uid('c'))
     or exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_query => 'tennis') s where s.user_id = pg_temp.uid('d')) then
    raise exception 'FAIL 9 the text query';
  end if;
  if exists (select 1 from information_schema.routines rt
               join information_schema.parameters pa on pa.specific_name = rt.specific_name
              where rt.routine_schema = 'public' and rt.routine_name = 'search_coaches' and pa.parameter_mode = 'OUT'
                and pa.parameter_name in ('lat', 'lng', 'distance', 'distance_m', 'service_point')) then
    raise exception 'FAIL 9 search_coaches returns a coordinate or a distance';
  end if;
  -- Keyset: a page of one, then the next, without repeats.
  select * into r from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_limit => 1) s;
  if exists (select 1 from public.search_coaches(p_lat => 33.776, p_lng => -84.396, p_before => r.page_key, p_limit => 50) s
              where s.user_id = r.user_id) then
    raise exception 'FAIL 9 the next page repeats a coach';
  end if;
end $$;
reset role;
do $$
begin
  -- The booking arm of shared context: b and c have a completed booking, b and d none.
  if not private.chat_shared_context(pg_temp.uid('b'), pg_temp.uid('c')) then
    raise exception 'FAIL 9 a booking is not shared context';
  end if;
  if private.chat_shared_context(pg_temp.uid('x'), pg_temp.uid('a')) then
    raise exception 'FAIL 9 strangers share context';
  end if;
  -- Notifications: requested to the coach (email), confirmed to the client (email), declined (no email).
  if not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('c') and n.kind = 'booking_requested'
                    and n.email_status = 'pending' and n.payload ->> 'booking_id' = current_setting('test.be'))
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('b') and n.kind = 'booking_confirmed'
                       and n.email_status = 'pending' and n.payload ->> 'booking_id' = current_setting('test.be'))
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('b') and n.kind = 'booking_declined'
                       and n.email_status = 'skipped' and n.payload ->> 'reason' = 'slot_taken')
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('c') and n.kind = 'review_received')
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('b') and n.kind = 'review_reply')
     or not exists (select 1 from public.notifications n where n.user_id = pg_temp.uid('k') and n.kind = 'booking_no_show') then
    raise exception 'FAIL 9 booking notifications';
  end if;
  if exists (select 1 from public.notifications n where n.kind::text like 'booking%' and n.payload ? 'client_note') then
    raise exception 'FAIL 9 a notification carries the client''s note';
  end if;
end $$;
set local role authenticated;
do $$
declare
  v jsonb;
begin
  -- b and c have a booking: the DM opens without a request.
  perform pg_temp.act('b');
  v := public.start_dm(pg_temp.uid('c'));
  if v ->> 'state' <> 'open' then raise exception 'FAIL 9 the booking did not open a DM: %', v ->> 'state'; end if;
  if public.my_bookings_with(pg_temp.uid('c')) is not null then
    raise exception 'FAIL 9 my_bookings_with shows a past booking';
  end if;
  if jsonb_array_length(public.my_bookings('client', 'past') -> 'items') < 2 then
    raise exception 'FAIL 9 my_bookings past';
  end if;
end $$;
reset role;

select 'coaching: PASS' as result;

rollback;
