-- ============================================================================
-- Staging check for migration 20261230000100_collector_review_fixes.sql
-- (migration 66). One transaction: throwaway accounts and test sources on
-- invented hosts (aptest-<tag>-*.org; nothing is fetched); asserts in DO
-- blocks that raise on failure, then rolls everything back. Prints pass/fail
-- lines only, never ids, hosts, URLs or tokens.
--
--   1 A feed claim on a source is on that source's own feed: another calendar
--     is refused (feed_mismatch), a source without a feed too
--     (feed_unavailable), a host other than the feed's (host_mismatch); the
--     claim's feed and host are the source's, and my_organizer_claims hides
--     that URL while pending.
--   2 organizer_claim_apply: an older feed claim on a source naming another
--     calendar is verified without taking the source; the real one takes it.
--   3 organizer_claim_target: feed_proof, never the feed URL; an organizer-
--     connected feed's URL host is not in hosts.
--   4 collector_claims_due: a pending claim whose host became denylisted
--     fails (host_denied) and is not listed.
-- ============================================================================
begin;

create temp table rf_lines (n serial, line text);
grant insert, select on rf_lines to anon, authenticated, service_role;
grant usage on sequence rf_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.src(p_tag text, p_letter text, p_kind text) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-' || p_letter, 'kind', p_kind,
    'url', case when p_kind = 'ics' then 'https://cal.aptest-' || p_tag || '-' || p_letter || '.org/club/c.ics'
                else 'https://events.aptest-' || p_tag || '-' || p_letter || '.org/calendar' end,
    'homepage_url', 'https://aptest-' || p_tag || '-' || p_letter || '.org/',
    'name', 'Review fix source ' || p_letter, 'attribution', 'Listed from a test calendar (' || p_letter || ').',
    'lane', case when p_kind = 'ics' then 'feed' else 'page' end, 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.items(p_tag text, p_letter text, p_n integer) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object(
    'external_id', 'ext-' || i, 'title', 'Review fix item ' || p_tag || ' ' || p_letter || ' ' || i,
    'starts_at', to_char(date_trunc('hour', now()) + make_interval(days => 3 + i), 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://aptest-' || p_tag || '-' || p_letter || '.org/e/' || i, 'location', 'Test hall'))
    from generate_series(1, p_n) i;
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- the organizer
  u2 uuid := gen_random_uuid();   -- another member
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'rf-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
                             created_at = now() - interval '3 days'
   where id in (u1, u2);
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a', 'ics'), pg_temp.items(v_tag, 'a', 2), true, true, 'rf-' || v_tag || '-1');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'b', 'jsonld'), pg_temp.items(v_tag, 'b', 2), true, true, 'rf-' || v_tag || '-1');
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.sa', (select id::text from public.feed_sources where slug = 'aptest-' || v_tag || '-a'), true);
  perform set_config('t.sb', (select id::text from public.feed_sources where slug = 'aptest-' || v_tag || '-b'), true);
  perform set_config('t.eva', (select min(ei.event_id::text) from public.event_imports ei
                                where ei.source_id = current_setting('t.sa')::uuid), true);
  perform set_config('t.evb', (select min(ei.event_id::text) from public.event_imports ei
                                where ei.source_id = current_setting('t.sb')::uuid), true);
  if current_setting('t.eva', true) is null or current_setting('t.evb', true) is null then
    raise exception 'FAIL setup: the test sources did not ingest';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. start_organizer_claim, feed
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  eva uuid := current_setting('t.eva')::uuid;
  v jsonb;
  v_row public.organizer_claims%rowtype;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.start_organizer_claim(null, eva, null, 'feed', 'https://aptest-' || v_tag || '-x.org/cal.ics');
    raise exception 'FAIL 1 a feed claim on a source named another calendar';
  exception when others then
    if sqlerrm <> 'feed_mismatch' then raise exception 'FAIL 1 feed_mismatch: %', sqlerrm; end if;
  end;
  begin
    perform public.start_organizer_claim(null, current_setting('t.evb')::uuid, null, 'feed',
                                         'https://aptest-' || v_tag || '-x.org/cal.ics');
    raise exception 'FAIL 1 a feed claim on a source without a feed';
  exception when others then
    if sqlerrm <> 'feed_unavailable' then raise exception 'FAIL 1 feed_unavailable: %', sqlerrm; end if;
  end;
  begin
    perform public.start_organizer_claim(null, null, 'aptest-' || v_tag || '-a.org', 'feed',
                                         'https://aptest-' || v_tag || '-x.org/cal.ics');
    raise exception 'FAIL 1 a feed claim named a host other than the feed''s';
  exception when others then
    if sqlerrm <> 'host_mismatch' then raise exception 'FAIL 1 host_mismatch: %', sqlerrm; end if;
  end;
  -- The organizer's own claim on the source's feed (no URL needed).
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  v := public.start_organizer_claim(null, eva, null, 'feed', null);
  if v ->> 'host' <> 'cal.aptest-' || v_tag || '-a.org' then
    raise exception 'FAIL 1 the claim host is not the feed''s';
  end if;
  if exists (select 1 from jsonb_array_elements(public.my_organizer_claims()) x
              where x.value ->> 'claim_id' = v ->> 'claim_id' and jsonb_typeof(x.value -> 'feed_url') <> 'null') then
    raise exception 'FAIL 1 my_organizer_claims showed the found source''s URL while pending';
  end if;
  execute 'reset role';
  select * into v_row from public.organizer_claims where id = (v ->> 'claim_id')::uuid;
  if v_row.source_id is distinct from current_setting('t.sa')::uuid
     or v_row.feed_url is distinct from 'https://cal.aptest-' || v_tag || '-a.org/club/c.ics' then
    raise exception 'FAIL 1 the claim is not on the source''s own feed';
  end if;
  perform set_config('t.c1', v ->> 'claim_id', true);
  insert into rf_lines (line) values ('1 feed claims: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. organizer_claim_apply
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
  sa uuid := current_setting('t.sa')::uuid;
  c_bad uuid;
begin
  -- A claim as migration 62 accepted it: the source, with someone else's calendar.
  insert into public.organizer_claims (user_id, source_id, host, method, feed_url, token)
  values (current_setting('t.u2')::uuid, sa, 'aptest-' || v_tag || '-x.org', 'feed',
          'https://aptest-' || v_tag || '-x.org/cal.ics', public.organizer_token())
  returning id into c_bad;
  perform public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c_bad, 'outcome', 'verified')));
  if (select organizer_id from public.feed_sources where id = sa) is not null then
    raise exception 'FAIL 2 a feed claim on another calendar took the source';
  end if;
  perform public.collector_claims_record(jsonb_build_array(
    jsonb_build_object('claim_id', current_setting('t.c1')::uuid, 'outcome', 'verified')));
  if (select organizer_id from public.feed_sources where id = sa) is distinct from current_setting('t.u1')::uuid then
    raise exception 'FAIL 2 the source''s own feed claim did not set the owner';
  end if;
  insert into rf_lines (line) values ('2 claim apply: ok');
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. organizer_claim_target
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  eva uuid := current_setting('t.eva')::uuid;
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_claim_target(eva);
  if v ? 'feed_url' or position('c.ics' in v::text) > 0 or (v ->> 'feed_proof')::boolean is distinct from true then
    raise exception 'FAIL 3 the target shows the feed URL or no feed proof';
  end if;
  v := public.organizer_claim_target(current_setting('t.evb')::uuid);
  if (v ->> 'feed_proof')::boolean is distinct from false then
    raise exception 'FAIL 3 feed proof on a page source';
  end if;
  execute 'reset role';
  -- As an organizer-connected feed: its URL's host is the owner's, not listed.
  update public.feed_sources set origin = 'organizer', slug = 'org-' || substr(md5(v_tag), 1, 12)
   where id = current_setting('t.sa')::uuid;
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  v := public.organizer_claim_target(eva);
  execute 'reset role';
  if v -> 'hosts' ? ('cal.aptest-' || v_tag || '-a.org') or not (v -> 'hosts' ? ('aptest-' || v_tag || '-a.org')) then
    raise exception 'FAIL 3 hosts of an organizer-connected feed';
  end if;
  insert into rf_lines (line) values ('3 claim target: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. collector_claims_due and the denylist
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  c_meta uuid;
  v_due jsonb;
begin
  insert into public.organizer_claims (user_id, source_id, host, method, token)
  values (current_setting('t.u2')::uuid, current_setting('t.sb')::uuid, 'aptest-' || v_tag || '-b.org', 'meta',
          public.organizer_token())
  returning id into c_meta;
  insert into public.collector_denylist (name, match, reason) values ('aptest-' || v_tag || '-b.org', 'domain', 'test');
  v_due := public.collector_claims_due(200);
  if exists (select 1 from jsonb_array_elements(v_due) x where x.value ->> 'claim_id' = c_meta::text) then
    raise exception 'FAIL 4 a claim on a denylisted host is still due';
  end if;
  if (select status || ':' || failure from public.organizer_claims where id = c_meta) <> 'failed:host_denied' then
    raise exception 'FAIL 4 the claim on a denylisted host did not fail';
  end if;
  insert into rf_lines (line) values ('4 claims due and the denylist: ok');
end $$;

select line as collector_review_fixes from (
  select 0 as n, 'collector_review_fixes: all assertions passed' as line
  union all
  select n, line from rf_lines) x
order by n;

rollback;
