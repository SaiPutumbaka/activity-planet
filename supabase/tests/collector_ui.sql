-- ============================================================================
-- Staging check for migration 20261229000100_collector_ui.sql (migration 65),
-- the reads behind the collector completion Slice 2 pages. One transaction:
-- throwaway accounts and a test source on an invented host (aptest-<tag>-*.org;
-- nothing is fetched); asserts in DO blocks that raise on failure, then rolls
-- everything back. Prints pass/fail lines only, never ids, hosts or names.
--
--   1 Static: grants on the new functions.
--   2 imported_event_labels: organizer_listed after a verified claim;
--     geocode_provider for a geocoded item.
--   3 organizer_claim_target: hosts, feed proof (migration 66: never the URL), claimed and mine.
--   4 organizer_source_detail: owner reads items and hidden flags; a stranger
--     gets not_found.
--   5 mod_organizer_claims: moderators only, no token, can_act.
-- ============================================================================
begin;

create temp table cu_lines (n serial, line text);
grant insert, select on cu_lines to anon, authenticated, service_role;
grant usage on sequence cu_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.src(p_tag text) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-a', 'kind', 'jsonld',
    'url', 'https://events.aptest-' || p_tag || '-a.org/calendar',
    'homepage_url', 'https://aptest-' || p_tag || '-a.org/',
    'name', 'UI test source', 'attribution', 'Listed from a test calendar.',
    'lane', 'page', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.items(p_tag text, p_n integer) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object(
    'external_id', 'ext-' || i, 'title', 'UI test item ' || p_tag || ' ' || i,
    'starts_at', to_char(date_trunc('hour', now()) + make_interval(days => 3 + i), 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://events.aptest-' || p_tag || '-a.org/e/' || i, 'location', 'Test hall'))
    from generate_series(1, p_n) i;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if has_function_privilege('anon', 'public.imported_event_labels(uuid[])', 'execute')
     or not has_function_privilege('authenticated', 'public.imported_event_labels(uuid[])', 'execute')
     or has_function_privilege('anon', 'public.organizer_claim_target(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.organizer_claim_target(uuid)', 'execute')
     or has_function_privilege('anon', 'public.organizer_source_detail(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.organizer_source_detail(uuid)', 'execute')
     or has_function_privilege('anon', 'public.mod_organizer_claims(boolean,integer)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_organizer_claims(boolean,integer)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  insert into cu_lines (line) values ('1 static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- organizer
  u2 uuid := gen_random_uuid();   -- another member
  um uuid := gen_random_uuid();   -- moderator
  sa uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'cu-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2, um]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2, um);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
                             created_at = now() - interval '3 days'
   where id in (u1, u2, um);
  insert into public.user_roles (user_id, role) values (um, 'moderator');
  perform public.collector_ingest_events(pg_temp.src(v_tag), pg_temp.items(v_tag, 3), true, true, 'cu-' || v_tag || '-1');
  select id into sa from public.feed_sources where slug = 'aptest-' || v_tag || '-a';
  if sa is null or (select count(*) from public.event_imports where source_id = sa) <> 3 then
    raise exception 'FAIL setup: the test source did not ingest';
  end if;
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.sa', sa::text, true);
  perform set_config('t.ev', (select ei.event_id::text from public.event_imports ei join public.events e on e.id = ei.event_id
                               where ei.source_id = sa order by e.starts_at limit 1), true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. imported_event_labels
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  sa uuid := current_setting('t.sa')::uuid;
  ev uuid := current_setting('t.ev')::uuid;
  v_listed boolean;
  v_geo text;
  v_key text;
  c1 uuid;
begin
  perform pg_temp.as_user(u1);
  execute 'set local role authenticated';
  select l.organizer_listed, l.geocode_provider into v_listed, v_geo from public.imported_event_labels(array[ev]) l;
  execute 'reset role';
  if v_listed is distinct from false or v_geo is not null then
    raise exception 'FAIL 2 a plain item says organizer or geocoded';
  end if;

  -- A verified owner and a geocoded point.
  insert into public.organizer_claims (user_id, source_id, host, method, token, status, verified_at)
  values (u1, sa, 'aptest-' || current_setting('t.tag') || '-a.org', 'meta', public.organizer_token(), 'verified', now())
  returning id into c1;
  perform public.organizer_claim_apply(c1);
  perform set_config('t.c1', c1::text, true);
  select public.import_location_key(e.location_hint, f.region_point) into v_key
    from public.events e join public.event_imports ei on ei.event_id = e.id and ei.is_primary
    join public.feed_sources f on f.id = ei.source_id where e.id = ev;
  if v_key is null then
    raise exception 'FAIL 2 setup: no location key';
  end if;
  insert into public.venue_geocodes (key, status, point, provider, checked_at, expires_at)
  values (v_key, 'ok', extensions.ST_SetSRID(extensions.ST_MakePoint(-125.0, -63.0), 4326)::extensions.geography,
          'nominatim', now(), now() + interval '180 days')
  on conflict (key) do update set status = 'ok', point = excluded.point, provider = 'nominatim';
  update public.event_imports set point_source = 'geocoded' where event_id = ev and is_primary;

  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  select l.organizer_listed, l.geocode_provider into v_listed, v_geo from public.imported_event_labels(array[ev]) l;
  execute 'reset role';
  if v_listed is distinct from true then
    raise exception 'FAIL 2 organizer_listed after a verified claim';
  end if;
  if v_geo is distinct from 'nominatim' then
    raise exception 'FAIL 2 geocode_provider';
  end if;
  insert into cu_lines (line) values ('2 labels: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. organizer_claim_target
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  ev uuid := current_setting('t.ev')::uuid;
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_claim_target(ev);
  if not (v -> 'hosts' ? ('aptest-' || v_tag || '-a.org'))
     or not (v -> 'hosts' ? ('events.aptest-' || v_tag || '-a.org'))
     or (v ->> 'claimed')::boolean is distinct from true
     or (v ->> 'mine')::boolean is distinct from false
     or jsonb_typeof(v -> 'source_id') <> 'null'
     or v ? 'feed_url'
     or (v ->> 'feed_proof')::boolean is distinct from false then
    raise exception 'FAIL 3 a stranger''s view of the target';
  end if;
  begin
    perform public.organizer_claim_target(gen_random_uuid());
    raise exception 'FAIL 3 an unknown event';
  exception when others then
    if sqlerrm <> 'not_imported' then raise exception 'FAIL 3 not_imported: %', sqlerrm; end if;
  end;
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_claim_target(ev);
  execute 'reset role';
  if (v ->> 'mine')::boolean is distinct from true or v ->> 'source_id' <> current_setting('t.sa') then
    raise exception 'FAIL 3 the owner''s view of the target';
  end if;
  perform pg_temp.as_user(null);
  execute 'set local role anon';
  begin
    perform public.organizer_claim_target(ev);
    raise exception 'FAIL 3 anon read the target';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  insert into cu_lines (line) values ('3 claim target: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. organizer_source_detail
-- ---------------------------------------------------------------------------
do $$
declare
  sa uuid := current_setting('t.sa')::uuid;
  ev uuid := current_setting('t.ev')::uuid;
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.organizer_source_detail(sa);
    raise exception 'FAIL 4 a stranger read the source';
  exception when others then
    if sqlerrm <> 'not_found' then raise exception 'FAIL 4 stranger: %', sqlerrm; end if;
  end;
  execute 'reset role';

  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_source_detail(sa);
  if jsonb_array_length(v -> 'items') <> 3 or (v ->> 'can_manage')::boolean is distinct from true
     or (v ->> 'verified')::boolean is distinct from true then
    raise exception 'FAIL 4 the owner''s view';
  end if;
  perform public.organizer_source_update(sa, jsonb_build_object('hide', ev));
  v := public.organizer_source_detail(sa);
  if jsonb_array_length(v -> 'items') <> 3
     or not exists (select 1 from jsonb_array_elements(v -> 'items') x
                     where x.value ->> 'event_id' = ev::text and (x.value ->> 'hidden')::boolean) then
    raise exception 'FAIL 4 a hidden item is missing or not flagged';
  end if;
  execute 'reset role';

  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_source_detail(sa);
  execute 'reset role';
  if (v ->> 'can_manage')::boolean is distinct from true then
    raise exception 'FAIL 4 a moderator cannot manage';
  end if;
  insert into cu_lines (line) values ('4 source detail: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. mod_organizer_claims
-- ---------------------------------------------------------------------------
do $$
declare
  c1 uuid := current_setting('t.c1')::uuid;
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.mod_organizer_claims(false, 50);
    raise exception 'FAIL 5 a member listed claims';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 5 forbidden: %', sqlerrm; end if;
  end;
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.mod_organizer_claims(false, 300);
  execute 'reset role';
  if not exists (select 1 from jsonb_array_elements(v) x
                  where x.value ->> 'id' = c1::text and x.value ->> 'status' = 'verified'
                    and (x.value ->> 'can_act')::boolean and not (x.value ? 'token')
                    and x.value #>> '{source,id}' = current_setting('t.sa')) then
    raise exception 'FAIL 5 the moderator list';
  end if;
  if position('ap-verify-' in v::text) > 0 then
    raise exception 'FAIL 5 a token in the moderator list';
  end if;
  insert into cu_lines (line) values ('5 moderator claims: ok');
end $$;

select line as collector_ui from (
  select 0 as n, 'collector_ui: all assertions passed' as line
  union all
  select n, line from cu_lines) x
order by n;

rollback;
