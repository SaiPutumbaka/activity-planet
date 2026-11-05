-- ============================================================================
-- Staging check for migration 20261226000100_collector_completion.sql
-- (migration 62), organizer claims (docs/design/collector/COLLECTOR_COMPLETION.md
-- 2.2 and 2.3). One transaction: throwaway accounts and test sources on
-- invented hosts (aptest-<tag>-*.org; nothing is fetched); asserts in DO
-- blocks that raise on failure, then rolls everything back. Prints pass/fail
-- lines only, never ids, hosts or tokens.
--
--   1 Static: RLS, the token column is not readable by authenticated, grants.
--   2 start_organizer_claim: account age, host mismatch, denylisted host,
--     the token and proofs, the same claim again, 5 a day.
--   3 Owner-only reads: another member sees no row; my_organizer_claims.
--   4 Verification through collector_claims_due and collector_claims_record:
--     a miss counts an attempt; verified sets the owner; already_claimed for
--     a second person; 10 attempts fail a claim.
--   5 organizer_source_update: hub, hide and unhide, stop; a stranger is
--     refused.
--   6 Moderators: mod_queue lists the verified claim; revoke clears the owner.
--   7 Account deletion: claims gone, a found source kept on without an owner.
-- ============================================================================
begin;

create temp table oc_lines (n serial, line text);
grant insert, select on oc_lines to anon, authenticated, service_role;
grant usage on sequence oc_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.src(p_tag text, p_letter text) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-' || p_letter, 'kind', 'jsonld',
    'url', 'https://events.aptest-' || p_tag || '-' || p_letter || '.org/calendar',
    'homepage_url', 'https://aptest-' || p_tag || '-' || p_letter || '.org/',
    'name', 'Claim test source ' || p_letter, 'attribution', 'Listed from a test calendar (' || p_letter || ').',
    'lane', 'page', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.items(p_tag text, p_n integer) returns jsonb language sql as $$
  select jsonb_agg(jsonb_build_object(
    'external_id', 'ext-' || i, 'title', 'Claim test item ' || p_tag || ' ' || i,
    'starts_at', to_char(date_trunc('hour', now()) + make_interval(days => 3 + i), 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://events.aptest-' || p_tag || '-a.org/e/' || i, 'location', 'Test hall'))
    from generate_series(1, p_n) i;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if not (select relrowsecurity from pg_class where oid = 'public.organizer_claims'::regclass)
     or not (select relrowsecurity from pg_class where oid = 'public.organizer_oauth_states'::regclass) then
    raise exception 'FAIL 1 RLS off';
  end if;
  if has_column_privilege('authenticated', 'public.organizer_claims', 'token', 'select')
     or not has_column_privilege('authenticated', 'public.organizer_claims', 'status', 'select')
     or has_table_privilege('anon', 'public.organizer_claims', 'select')
     or has_table_privilege('authenticated', 'public.organizer_claims', 'insert')
     or has_table_privilege('authenticated', 'public.organizer_claims', 'update')
     or has_table_privilege('authenticated', 'public.organizer_oauth_states', 'select')
     or has_table_privilege('anon', 'public.organizer_oauth_states', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if has_function_privilege('anon', 'public.start_organizer_claim(uuid,uuid,text,text,text)', 'execute')
     or not has_function_privilege('authenticated', 'public.start_organizer_claim(uuid,uuid,text,text,text)', 'execute')
     or has_function_privilege('anon', 'public.organizer_claim_check(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_claims_due(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.collector_claims_record(jsonb)', 'execute')
     or not has_function_privilege('service_role', 'public.collector_claims_record(jsonb)', 'execute')
     or has_function_privilege('authenticated', 'public.organizer_eventbrite_sources(integer)', 'execute')
     or has_function_privilege('authenticated', 'public.organizer_eventbrite_store(uuid,text)', 'execute')
     or has_function_privilege('authenticated', 'public.organizer_oauth_take(uuid,text)', 'execute')
     or has_function_privilege('anon', 'public.organizer_source_update(uuid,jsonb)', 'execute')
     or has_function_privilege('anon', 'public.mod_organizer_claim_review(uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.organizer_claim_apply(uuid)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if public.registrable_domain('www.events.example.co.uk') <> 'example.co.uk'
     or public.registrable_domain('cal.Example.org.') <> 'example.org' then
    raise exception 'FAIL 1 registrable_domain';
  end if;
  insert into oc_lines (line) values ('1 static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- organizer
  u2 uuid := gen_random_uuid();   -- another member
  u3 uuid := gen_random_uuid();   -- new account
  um uuid := gen_random_uuid();   -- moderator
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'oc-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2, u3, um]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2, u3, um);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (u1, u2, u3, um);
  update public.profiles set created_at = now() - interval '3 days' where id in (u1, u2, um);
  insert into public.user_roles (user_id, role) values (um, 'moderator');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 3), true, true, 'oc-' || v_tag || '-1');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'b'), '[]'::jsonb, true, true, 'oc-' || v_tag || '-1');
  insert into public.collector_denylist (name, match, reason)
  values ('aptest-' || v_tag || '-b.org', 'domain', 'test');
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.u3', u3::text, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.sa', (select id::text from public.feed_sources where slug = 'aptest-' || v_tag || '-a'), true);
  perform set_config('t.sb', (select id::text from public.feed_sources where slug = 'aptest-' || v_tag || '-b'), true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. start_organizer_claim
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  sa uuid := current_setting('t.sa')::uuid;
  v jsonb;
  v2 jsonb;
  v_ev uuid;
  i integer;
begin
  perform pg_temp.as_user(current_setting('t.u3')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.start_organizer_claim(sa, null, 'aptest-' || v_tag || '-a.org');
    raise exception 'FAIL 2 a new account started a claim';
  exception when others then
    if sqlerrm <> 'account_too_new' then raise exception 'FAIL 2 account_too_new: %', sqlerrm; end if;
  end;
  execute 'reset role';

  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.start_organizer_claim(sa, null, 'aptest-' || v_tag || '-z.org');
    raise exception 'FAIL 2 a host that does not match';
  exception when others then
    if sqlerrm <> 'host_mismatch' then raise exception 'FAIL 2 host_mismatch: %', sqlerrm; end if;
  end;
  begin
    perform public.start_organizer_claim(current_setting('t.sb')::uuid, null, 'aptest-' || v_tag || '-b.org');
    raise exception 'FAIL 2 a denylisted host';
  exception when others then
    if sqlerrm <> 'host_denied' then raise exception 'FAIL 2 host_denied: %', sqlerrm; end if;
  end;
  begin
    perform public.start_organizer_claim(null, null, 'aptest-' || v_tag || '-a.org');
    raise exception 'FAIL 2 a claim without a source';
  exception when others then
    if sqlerrm <> 'source_required' then raise exception 'FAIL 2 source_required: %', sqlerrm; end if;
  end;
  -- The registrable domain of the page source's host, through one of its events.
  execute 'reset role';
  select ei.event_id into v_ev from public.event_imports ei where ei.source_id = sa limit 1;
  execute 'set local role authenticated';
  v := public.start_organizer_claim(null, v_ev, 'aptest-' || v_tag || '-a.org', 'meta');
  if coalesce(v ->> 'token', '') !~ '^ap-verify-[a-z2-7]{24}$'
     or v #>> '{proofs,dns_txt,name}' <> '_activityplanet.aptest-' || v_tag || '-a.org'
     or position(v ->> 'token' in v #>> '{proofs,meta}') = 0 then
    raise exception 'FAIL 2 token or proofs';
  end if;
  v2 := public.start_organizer_claim(sa, null, 'aptest-' || v_tag || '-a.org', 'meta');
  if v2 ->> 'claim_id' <> v ->> 'claim_id' then
    raise exception 'FAIL 2 the same claim again made a new one';
  end if;
  perform set_config('t.c1', v ->> 'claim_id', true);
  -- 5 a day (one made above).
  for i in 1..4 loop
    perform public.start_organizer_claim(null, null, null, 'feed', 'https://aptest-' || v_tag || '-f' || i || '.org/c.ics');
  end loop;
  begin
    perform public.start_organizer_claim(null, null, null, 'feed', 'https://aptest-' || v_tag || '-f9.org/c.ics');
    raise exception 'FAIL 2 a sixth claim in a day';
  exception when others then
    if sqlerrm <> 'rate_limited' then raise exception 'FAIL 2 rate_limited: %', sqlerrm; end if;
  end;
  execute 'reset role';
  insert into oc_lines (line) values ('2 start: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. Owner-only reads
-- ---------------------------------------------------------------------------
do $$
declare
  c1 uuid := current_setting('t.c1')::uuid;
  v jsonb;
  n integer;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  select count(*) into n from public.organizer_claims where id = c1;
  if n <> 0 then
    raise exception 'FAIL 3 another member sees the claim';
  end if;
  if jsonb_array_length(public.my_organizer_claims()) <> 0 then
    raise exception 'FAIL 3 another member''s claim list is not empty';
  end if;
  begin
    perform public.organizer_claim_check(c1);
    raise exception 'FAIL 3 another member checked the claim';
  exception when others then
    if sqlerrm <> 'not_found' then raise exception 'FAIL 3 check: %', sqlerrm; end if;
  end;
  begin
    perform token from public.organizer_claims;
    raise exception 'FAIL 3 the token column is readable';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  select count(*) into n from public.organizer_claims where id = c1;
  v := public.my_organizer_claims();
  if n <> 1 or not exists (select 1 from jsonb_array_elements(v) x
                            where x.value ->> 'claim_id' = c1::text and x.value ->> 'token' ~ '^ap-verify-') then
    raise exception 'FAIL 3 the owner does not see their claim and token';
  end if;
  v := public.organizer_claim_check(c1);
  execute 'reset role';
  if (select check_requested_at from public.organizer_claims where id = c1) is null then
    raise exception 'FAIL 3 check now did not mark the claim due';
  end if;
  insert into oc_lines (line) values ('3 owner-only reads: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Verification
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
  c1 uuid := current_setting('t.c1')::uuid;
  sa uuid := current_setting('t.sa')::uuid;
  v jsonb;
  v_due jsonb;
  c2 uuid;
  c3 uuid;
  i integer;
begin
  v_due := public.collector_claims_due(200);
  if not exists (select 1 from jsonb_array_elements(v_due) x
                  where x.value ->> 'claim_id' = c1::text
                    and x.value -> 'urls' ? ('https://aptest-' || v_tag || '-a.org/')
                    and jsonb_array_length(x.value -> 'urls') between 1 and 3) then
    raise exception 'FAIL 4 the claim is not due with its URLs';
  end if;
  v := public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c1, 'outcome', 'token_not_found')));
  if (v ->> 'pending')::int <> 1 or (select attempts from public.organizer_claims where id = c1) <> 1 then
    raise exception 'FAIL 4 a miss did not count an attempt';
  end if;
  begin
    perform public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c1, 'outcome', 'maybe')));
    raise exception 'FAIL 4 a bad outcome accepted';
  exception when others then
    if sqlerrm <> 'results_invalid' then raise exception 'FAIL 4 results_invalid: %', sqlerrm; end if;
  end;
  v := public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c1, 'outcome', 'verified', 'method', 'well_known')));
  if (v ->> 'verified')::int <> 1
     or (select status || ':' || method from public.organizer_claims where id = c1) <> 'verified:well_known'
     or (select organizer_id from public.feed_sources where id = sa) is distinct from current_setting('t.u1')::uuid then
    raise exception 'FAIL 4 verified did not set the owner';
  end if;
  -- A second person cannot take the source over.
  insert into public.organizer_claims (user_id, source_id, host, method, token)
  values (current_setting('t.u2')::uuid, sa, 'aptest-' || v_tag || '-a.org', 'dns_txt', public.organizer_token())
  returning id into c2;
  v := public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c2, 'outcome', 'verified')));
  if (select status || ':' || failure from public.organizer_claims where id = c2) <> 'failed:already_claimed'
     or (select organizer_id from public.feed_sources where id = sa) is distinct from current_setting('t.u1')::uuid then
    raise exception 'FAIL 4 already_claimed';
  end if;
  -- 10 misses fail a claim.
  insert into public.organizer_claims (user_id, source_id, host, method, token)
  values (current_setting('t.u2')::uuid, current_setting('t.sb')::uuid, 'aptest-' || v_tag || '-b.org', 'meta', public.organizer_token())
  returning id into c3;
  for i in 1..10 loop
    perform public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', c3, 'outcome', 'fetch_failed', 'reason', 'timeout')));
  end loop;
  if (select status from public.organizer_claims where id = c3) <> 'failed'
     or (select failure from public.organizer_claims where id = c3) <> 'fetch_failed:timeout' then
    raise exception 'FAIL 4 ten misses did not fail the claim';
  end if;
  insert into oc_lines (line) values ('4 verification: ok');
end $$;
reset role;

do $$
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.start_organizer_claim(current_setting('t.sa')::uuid, null, 'aptest-' || current_setting('t.tag') || '-a.org');
    raise exception 'FAIL 4 a claim on an owned source started';
  exception when others then
    if sqlerrm <> 'already_claimed' then raise exception 'FAIL 4 start already_claimed: %', sqlerrm; end if;
  end;
  execute 'reset role';
end $$;

-- ---------------------------------------------------------------------------
-- 5. organizer_source_update
-- ---------------------------------------------------------------------------
do $$
declare
  sa uuid := current_setting('t.sa')::uuid;
  v_tag text := current_setting('t.tag');
  v_ev uuid;
  v_hub text;
begin
  select ei.event_id into v_ev from public.event_imports ei where ei.source_id = sa and ei.external_id = 'ext-1';
  select h.slug into v_hub from public.hubs h where h.is_active and h.min_age = 18 and h.slug <> 'happening-nearby'
   order by h.slug limit 1;
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.organizer_source_update(sa, jsonb_build_object('stop', true));
    raise exception 'FAIL 5 a stranger changed the source';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 5 stranger: %', sqlerrm; end if;
  end;
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  perform public.organizer_source_update(sa, jsonb_build_object('default_hub', v_hub));
  perform public.organizer_source_update(sa, jsonb_build_object('hide', v_ev));
  execute 'reset role';
  if (select h.slug from public.feed_sources f join public.hubs h on h.id = f.organizer_hub_id where f.id = sa) <> v_hub then
    raise exception 'FAIL 5 default hub';
  end if;
  if (select status::text from public.events where id = v_ev) <> 'cancelled'
     or not exists (select 1 from public.event_imports where event_id = v_ev and removed_reason = 'organizer_hidden') then
    raise exception 'FAIL 5 hide';
  end if;
  -- A later run keeps the item hidden and the owner's hub.
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 3), true, true, 'oc-' || v_tag || '-2');
  if (select status::text from public.events where id = v_ev) <> 'cancelled'
     or (select h.slug from public.feed_sources f join public.hubs h on h.id = f.default_hub_id where f.id = sa) <> v_hub then
    raise exception 'FAIL 5 a run undid the owner''s changes';
  end if;
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  perform public.organizer_source_update(sa, jsonb_build_object('unhide', v_ev));
  execute 'reset role';
  if (select status::text from public.events where id = v_ev) <> 'published' then
    raise exception 'FAIL 5 unhide';
  end if;
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  perform public.organizer_source_update(sa, jsonb_build_object('stop', true));
  execute 'reset role';
  if (select enabled from public.feed_sources where id = sa)
     or exists (select 1 from public.events e join public.event_imports ei on ei.event_id = e.id
                 where ei.source_id = sa and e.status = 'published') then
    raise exception 'FAIL 5 stop';
  end if;
  -- A staging run with --enable does not switch a stopped source back on.
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 3), true, true, 'oc-' || v_tag || '-3');
  if (select enabled from public.feed_sources where id = sa) then
    raise exception 'FAIL 5 a run switched a stopped source on';
  end if;
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  perform public.organizer_source_update(sa, jsonb_build_object('stop', false));
  execute 'reset role';
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 3), true, true, 'oc-' || v_tag || '-4');
  if not (select enabled from public.feed_sources where id = sa) then
    raise exception 'FAIL 5 resume';
  end if;
  insert into oc_lines (line) values ('5 owner updates: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Moderators
-- ---------------------------------------------------------------------------
do $$
declare
  c1 uuid := current_setting('t.c1')::uuid;
  sa uuid := current_setting('t.sa')::uuid;
begin
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  if not exists (select 1 from jsonb_array_elements(public.mod_queue(500)) x
                  where x.value ->> 'source' = 'organizer_claim' and x.value ->> 'id' = c1::text) then
    raise exception 'FAIL 6 mod_queue does not list the verified claim';
  end if;
  perform public.mod_organizer_claim_review(c1, 'revoke', 'test');
  execute 'reset role';
  if (select status from public.organizer_claims where id = c1) <> 'revoked'
     or (select organizer_id from public.feed_sources where id = sa) is not null then
    raise exception 'FAIL 6 revoke';
  end if;
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.mod_organizer_claim_review(c1, 'ok', null);
    raise exception 'FAIL 6 a member reviewed a claim';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 6 member: %', sqlerrm; end if;
  end;
  execute 'reset role';
  insert into oc_lines (line) values ('6 moderators: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Account deletion: claims gone, the found source stays on without an owner
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  sa uuid := current_setting('t.sa')::uuid;
  c4 uuid;
begin
  insert into public.organizer_claims (user_id, source_id, host, method, token, status, verified_at)
  values (u1, sa, 'aptest-' || current_setting('t.tag') || '-a.org', 'meta', public.organizer_token(), 'verified', now())
  returning id into c4;
  perform public.organizer_claim_apply(c4);
  if (select organizer_id from public.feed_sources where id = sa) is distinct from u1 then
    raise exception 'FAIL 7 setup';
  end if;
  perform pg_temp.as_user(u1);
  execute 'set local role authenticated';
  perform public.request_account_deletion('test');
  execute 'reset role';
  if exists (select 1 from public.organizer_claims where user_id = u1) then
    raise exception 'FAIL 7 claims kept';
  end if;
  if (select organizer_id from public.feed_sources where id = sa) is not null
     or not (select enabled from public.feed_sources where id = sa) then
    raise exception 'FAIL 7 the found source lost its state or kept the owner';
  end if;
  insert into oc_lines (line) values ('7 account deletion: ok');
end $$;

select line as organizer_claims from (
  select 0 as n, 'organizer_claims: all assertions passed' as line
  union all
  select n, line from oc_lines) x
order by n;

rollback;
