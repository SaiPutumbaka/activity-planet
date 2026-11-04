-- ============================================================================
-- Staging check for migration 20261121000100_viewer_timezone.sql (D-040).
-- One transaction: sets up throwaway users and events, asserts with DO blocks
-- that raise on failure, then rolls everything back. Prints pass/fail only.
-- Run as the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.22, profile_private.timezone owner-only, one
--     feed_events_v2 overload (invoker, authenticated only), set_my_timezone
--     granted to authenticated only, venues.country nullable without default,
--     account deletion still removes profile_private whole.
--   2 Sections: with nothing saved they follow the event's timezone; after
--     set_my_timezone they follow the saved zone; p_timezone wins; an unknown
--     p_timezone is ignored; clearing falls back to the event's zone.
--   3 set_my_timezone refuses abbreviations and unknown names; direct updates
--     are refused; the trigger refuses a bad zone from any writer; another
--     user cannot read the zone.
--   4 upsert_venue: no country stays null; a sent one is upper-cased; a bad
--     one is refused; the content match treats null and 'US' as different;
--     the creator's fill sets a null country.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   uuid := gen_random_uuid();   -- the viewer whose zone changes
  v_o   uuid := gen_random_uuid();   -- another user (host, venue owner)
  v_hub uuid;
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_id  uuid;
  v_ids uuid[] := '{}';
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'vtz-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[v_t, v_o]) as u;
  update public.profile_private set birth_date = date '1992-04-04' where user_id in (v_t, v_o);
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (v_t, v_o);

  select h.id into v_hub
    from public.hubs h
    join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive
   order by h.slug
   limit 1;
  if v_hub is null then raise exception 'setup: no general hub'; end if;
  insert into public.hub_members (user_id, hub_id) values (v_t, v_hub) on conflict do nothing;

  -- One event an hour for 30 hours, in London time, so every zone tried
  -- crosses a midnight somewhere in the run.
  for k in 1..30 loop
    insert into public.events (hub_id, host_id, title, starts_at, ends_at, timezone)
    values (v_hub, v_o, 'Viewer timezone ' || k,
            now() + make_interval(hours => k), now() + make_interval(hours => k + 1), 'Europe/London')
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;

  perform set_config('test.t', v_t::text, true);
  perform set_config('test.o', v_o::text, true);
  perform set_config('test.hub', v_hub::text, true);
  perform set_config('test.tag', v_tag, true);
  perform set_config('test.events', array_to_string(v_ids, ','), true);
end $$;

-- Static checks (as the owner)
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.22' then
    raise exception 'FAIL schema_version is not 2.22';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema = 'public' and table_name = 'profile_private' and column_name = 'timezone') then
    raise exception 'FAIL profile_private.timezone missing';
  end if;
  if has_column_privilege('authenticated', 'public.profile_private', 'timezone', 'update')
     or has_column_privilege('anon', 'public.profile_private', 'timezone', 'select') then
    raise exception 'FAIL profile_private.timezone is client-writable or anon-readable';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'feed_events_v2') <> 1 then
    raise exception 'FAIL feed_events_v2 does not have exactly one overload';
  end if;
  if (select p.prosecdef from pg_proc p
       where p.oid = 'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text)'::regprocedure) then
    raise exception 'FAIL feed_events_v2 became security definer';
  end if;
  if has_function_privilege('anon',
       'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text)', 'execute')
     or has_function_privilege('anon', 'public.set_my_timezone(text)', 'execute')
     or not has_function_privilege('authenticated',
       'public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text)', 'execute')
     or not has_function_privilege('authenticated', 'public.set_my_timezone(text)', 'execute') then
    raise exception 'FAIL feed_events_v2 or set_my_timezone grants are wrong';
  end if;
  if exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
              where n.nspname = 'public' and p.proname = 'feed_events_v2'
                and pg_get_function_result(p.oid) ~ '\m(lat|lng|location|approx_point|distance_m|origin)\M') then
    raise exception 'FAIL feed_events_v2 returns a location column';
  end if;
  if (select is_nullable from information_schema.columns
       where table_schema = 'public' and table_name = 'venues' and column_name = 'country') <> 'YES'
     or (select column_default from information_schema.columns
          where table_schema = 'public' and table_name = 'venues' and column_name = 'country') is not null then
    raise exception 'FAIL venues.country still has a default or is not null';
  end if;
  if pg_get_functiondef('public.request_account_deletion(text)'::regprocedure)
       !~ 'delete from public\.profile_private\s+where user_id = uid' then
    raise exception 'FAIL account deletion no longer removes profile_private';
  end if;
  -- The trigger refuses a bad zone from any writer, the owner included.
  begin
    update public.profile_private set timezone = 'Bogus/Zone' where user_id = current_setting('test.t')::uuid;
    raise exception 'FAIL the owner wrote an unknown time zone';
  exception when check_violation then
    if sqlerrm <> 'timezone_invalid' then raise exception 'FAIL unknown zone by owner gave %', sqlerrm; end if;
  end;
  begin
    update public.profile_private set timezone = 'EST' where user_id = current_setting('test.t')::uuid;
    raise exception 'FAIL the owner wrote an abbreviation as a time zone';
  exception when check_violation then
    if sqlerrm <> 'timezone_invalid' then raise exception 'FAIL abbreviation by owner gave %', sqlerrm; end if;
  end;
end $$;

-- A helper (created inside this transaction and rolled back with it) that compares the feed's sections for the
-- test events with the ones expected in a zone. Returns the number of test
-- events seen, or raises.
create function public.vtz_test_check(p_zone text, p_label text, p_tz_arg text default null)
returns integer language plpgsql as $$
declare
  v_ids  uuid[] := string_to_array(current_setting('test.events'), ',')::uuid[];
  v_bad  integer;
  v_seen integer;
begin
  with f as (
    select x.id, x.starts_at, x.section
      from public.feed_events_v2(now(), now() + interval '32 hours',
                                 p_hub_ids => array[current_setting('test.hub')::uuid],
                                 p_limit => 200, p_timezone => p_tz_arg) x
     where x.id = any (v_ids)
  )
  select count(*) filter (where f.section is distinct from
           case when (f.starts_at at time zone p_zone)::date <= (now() at time zone p_zone)::date then 'today'
                when (f.starts_at at time zone p_zone)::date <  (now() at time zone p_zone)::date + 7 then 'this_week'
                else 'later' end),
         count(*)
    into v_bad, v_seen
    from f;
  if v_seen <> 30 then
    raise exception 'FAIL % saw % of the 30 test events', p_label, v_seen;
  end if;
  if v_bad <> 0 then
    raise exception 'FAIL % filed % test events outside the % day', p_label, v_bad, p_zone;
  end if;
  return v_seen;
end $$;

-- Only meaningful when the zones disagree on at least one test event.
do $$
declare
  v_ids uuid[] := string_to_array(current_setting('test.events'), ',')::uuid[];
  z     text[];
begin
  foreach z slice 1 in array array[['Europe/London', 'America/New_York'],
                                   ['Asia/Tokyo', 'Europe/London'],
                                   ['Pacific/Honolulu', 'Asia/Tokyo']] loop
    if not exists (
      select 1 from public.events e
       where e.id = any (v_ids)
         and ((e.starts_at at time zone z[1])::date - (now() at time zone z[1])::date)
             <> ((e.starts_at at time zone z[2])::date - (now() at time zone z[2])::date)) then
      raise exception 'setup: % and % agree on every test event', z[1], z[2];
    end if;
  end loop;
end $$;

grant execute on function public.vtz_test_check(text, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- The viewer
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.t'), 'role', 'authenticated')::text, true);

do $$
declare
  v_res jsonb;
begin
  if (select pp.timezone from public.profile_private pp where pp.user_id = auth.uid()) is not null then
    raise exception 'FAIL a new profile has a time zone';
  end if;
  -- Nothing saved, nothing sent: the event's own zone.
  perform public.vtz_test_check('Europe/London', 'unknown viewer');

  -- Saved zone.
  v_res := public.set_my_timezone(' Asia/Tokyo ');
  if v_res ->> 'timezone' is distinct from 'Asia/Tokyo'
     or (select pp.timezone from public.profile_private pp where pp.user_id = auth.uid()) is distinct from 'Asia/Tokyo' then
    raise exception 'FAIL set_my_timezone did not save Asia/Tokyo';
  end if;
  perform public.vtz_test_check('Asia/Tokyo', 'saved zone');

  -- The zone sent wins; an unknown or abbreviated one is ignored.
  perform public.vtz_test_check('Pacific/Honolulu', 'sent zone', 'Pacific/Honolulu');
  perform public.vtz_test_check('Asia/Tokyo', 'unknown sent zone', 'Not/AZone');
  perform public.vtz_test_check('Asia/Tokyo', 'abbreviated sent zone', 'EST');

  -- Validation.
  begin
    perform public.set_my_timezone('EST');
    raise exception 'FAIL set_my_timezone accepted EST';
  exception when check_violation then
    if sqlerrm <> 'timezone_invalid' then raise exception 'FAIL EST gave %', sqlerrm; end if;
  end;
  begin
    perform public.set_my_timezone('Mars/Olympus_Mons');
    raise exception 'FAIL set_my_timezone accepted an unknown zone';
  exception when check_violation then
    if sqlerrm <> 'timezone_invalid' then raise exception 'FAIL unknown zone gave %', sqlerrm; end if;
  end;
  if (select pp.timezone from public.profile_private pp where pp.user_id = auth.uid()) is distinct from 'Asia/Tokyo' then
    raise exception 'FAIL a refused zone changed the saved one';
  end if;
  begin
    update public.profile_private set timezone = 'Europe/Paris' where user_id = auth.uid();
    raise exception 'FAIL direct update of timezone allowed';
  exception when insufficient_privilege then null;
  end;

  -- Clearing falls back to the event's zone.
  v_res := public.set_my_timezone(null);
  if (select pp.timezone from public.profile_private pp where pp.user_id = auth.uid()) is not null then
    raise exception 'FAIL set_my_timezone(null) did not clear';
  end if;
  perform public.vtz_test_check('Europe/London', 'cleared zone');
  perform public.set_my_timezone('Asia/Tokyo');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- The other user: cannot read the viewer's zone; venue country rules
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.o'), 'role', 'authenticated')::text, true);

do $$
declare
  v_tag  text := current_setting('test.tag');
  base   jsonb := jsonb_build_object('name', 'Zone Hall', 'is_public', true, 'address_line1', '1 Zone St',
                                     'city', 'Lisbon', 'state', '', 'postal_code', '1100-001',
                                     'lat', 38.7100, 'lng', -9.1400, 'place_id', 'vtz-' || v_tag);
  vo     public.venues;
  vx     public.venues;
begin
  if exists (select 1 from public.profile_private pp where pp.user_id = current_setting('test.t')::uuid) then
    raise exception 'FAIL another user can read the viewer''s profile_private row';
  end if;

  vo := public.upsert_venue(base);
  if vo.country is not null then
    raise exception 'FAIL upsert_venue without a country stored %', vo.country;
  end if;
  vx := public.upsert_venue(jsonb_build_object('name', 'Zone Shop', 'country', ' gb ', 'postal_code', 'N1 1AA'));
  if vx.country is distinct from 'GB' then
    raise exception 'FAIL upsert_venue did not store GB from '' gb '' (got %)', vx.country;
  end if;
  begin
    perform public.upsert_venue(jsonb_build_object('name', 'Zone Bad', 'country', 'USA'));
    raise exception 'FAIL upsert_venue accepted country USA';
  exception when check_violation then
    if sqlerrm <> 'country_invalid' then raise exception 'FAIL country USA gave %', sqlerrm; end if;
  end;
  perform set_config('test.vo', vo.id::text, true);
end $$;
reset role;

-- The viewer picks the same place: same content with no country shares the
-- row; with 'US' it is a different place, so the viewer gets their own.
set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.t'), 'role', 'authenticated')::text, true);
do $$
declare
  v_tag  text := current_setting('test.tag');
  base   jsonb := jsonb_build_object('name', 'Zone Hall', 'is_public', true, 'address_line1', '1 Zone St',
                                     'city', 'Lisbon', 'state', '', 'postal_code', '1100-001',
                                     'lat', 38.7100, 'lng', -9.1400, 'place_id', 'vtz-' || v_tag);
  v      public.venues;
begin
  v := public.upsert_venue(base || jsonb_build_object('country', 'US'));
  if v.id = current_setting('test.vo')::uuid or v.created_by <> auth.uid() or v.country is distinct from 'US' then
    raise exception 'FAIL a null-country venue was handed over to a request with country US';
  end if;
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.o'), 'role', 'authenticated')::text, true);
do $$
declare
  v_tag text := current_setting('test.tag');
  v     public.venues;
begin
  -- The creator's own row (no other host uses it) gains a country when one is sent.
  v := public.upsert_venue(jsonb_build_object('name', 'Zone Hall', 'is_public', true, 'address_line1', '1 Zone St',
                                              'city', 'Lisbon', 'state', '', 'postal_code', '1100-001',
                                              'lat', 38.7100, 'lng', -9.1400, 'place_id', 'vtz-' || v_tag,
                                              'country', 'pt'));
  if v.id <> current_setting('test.vo')::uuid or v.country is distinct from 'PT' then
    raise exception 'FAIL the creator''s re-pick did not fill the null country (got %)', v.country;
  end if;
  -- And a null-country row from another user is shared when nothing differs.
  perform set_config('test.vo2', (public.upsert_venue(jsonb_build_object(
    'name', 'Zone Cafe', 'is_public', true, 'address_line1', '2 Zone St', 'city', 'Lisbon', 'state', '',
    'postal_code', '1100-002', 'lat', 38.7110, 'lng', -9.1410, 'place_id', 'vtz2-' || v_tag))).id::text, true);
end $$;
reset role;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', current_setting('test.t'), 'role', 'authenticated')::text, true);
do $$
declare
  v_tag text := current_setting('test.tag');
  v     public.venues;
begin
  v := public.upsert_venue(jsonb_build_object(
    'name', 'zone cafe', 'is_public', true, 'address_line1', '2 Zone St', 'city', 'Lisbon', 'state', '',
    'postal_code', '1100-002', 'lat', 38.7111, 'lng', -9.1411, 'place_id', 'vtz2-' || v_tag));
  if v.id <> current_setting('test.vo2')::uuid or v.country is not null then
    raise exception 'FAIL a matching null-country public venue was not shared unchanged';
  end if;
end $$;
reset role;

select 'viewer_timezone: all assertions passed' as result;

rollback;
