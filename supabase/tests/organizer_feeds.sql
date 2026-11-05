-- ============================================================================
-- Staging check for migration 20261226000100_collector_completion.sql
-- (migration 62), organizer-connected ICS feeds and the Eventbrite state rows
-- (docs/design/collector/COLLECTOR_COMPLETION.md 2.4 and 2.8). One
-- transaction: throwaway accounts, invented hosts (aptest-<tag>-*.org;
-- nothing is fetched) and a collector region in the Southern Ocean; asserts
-- in DO blocks that raise on failure, then rolls everything back. Prints
-- pass/fail lines only, never ids, hosts, tokens or points.
--
--   1 connect_organizer_feed: refused without a claim, for a host that does
--     not match, for a claim nobody verified; a pending feed claim connects
--     its own URL only.
--   2 A feed-token claim is verified and connected in one step; the feed is
--     listed for its region by collector_sources_for_regions; region
--     assignment from the owner's picked point when no home is stored.
--   3 The first good run switches the feed on; an empty run does not.
--   4 At most 3 live connected feeds a person.
--   5 Eventbrite: state single-use, bound to the person, expires; the token
--     is kept in the vault and is never readable by authenticated.
--   6 Account deletion: connected feeds off and without owner, items
--     withdrawn, vault secret and OAuth states gone.
-- ============================================================================
begin;

create temp table of_lines (n serial, line text);
grant insert, select on of_lines to anon, authenticated, service_role;
grant usage on sequence of_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.seed(p_slug text) returns jsonb language sql as $$
  select jsonb_build_object('slug', f.slug, 'kind', 'ics', 'url', f.url, 'name', f.name, 'attribution', f.attribution,
                            'lane', 'feed', 'enabled', true,
                            'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'))
    from public.feed_sources f where f.slug = p_slug;
$$;

create function pg_temp.items(p_tag text, p_n integer) returns jsonb language sql as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'external_id', 'uid-' || i, 'title', 'Connected feed item ' || p_tag || ' ' || i,
    'starts_at', to_char(date_trunc('hour', now()) + make_interval(days => 2 + i), 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://aptest-' || p_tag || '-o.org/e/' || i, 'location', 'Test hall')), '[]'::jsonb)
    from generate_series(1, p_n) i;
$$;

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  u1 uuid := gen_random_uuid();   -- organizer with a home in the test region
  u2 uuid := gen_random_uuid();   -- organizer without a home
  v_r uuid;
  v_src uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'of-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[u1, u2]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (u1, u2);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
                             created_at = now() - interval '3 days'
   where id in (u1, u2);
  insert into public.collector_regions (point, radius_km, label, priority)
  values (extensions.ST_SetSRID(extensions.ST_MakePoint(-125.0, -63.0), 4326)::extensions.geography, 25, null, 100)
  returning id into v_r;
  update public.profile_private
     set home_point = extensions.ST_SetSRID(extensions.ST_MakePoint(-125.05, -63.05), 4326)::extensions.geography
   where user_id = u1;
  -- A found source on the organizer's site and u1's verified claim on it.
  perform public.collector_ingest_events(jsonb_build_object(
    'slug', 'aptest-' || v_tag || '-s', 'kind', 'jsonld', 'url', 'https://aptest-' || v_tag || '-o.org/events',
    'name', 'Feed test site', 'attribution', 'Listed from a test calendar.', 'lane', 'page', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC')),
    '[]'::jsonb, true, true, 'of-' || v_tag || '-1');
  select id into v_src from public.feed_sources where slug = 'aptest-' || v_tag || '-s';
  insert into public.organizer_claims (user_id, source_id, host, method, token, status, verified_at)
  values (u1, v_src, 'aptest-' || v_tag || '-o.org', 'meta', public.organizer_token(), 'verified', now());
  perform public.organizer_claim_apply((select id from public.organizer_claims where user_id = u1));
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.u2', u2::text, true);
  perform set_config('t.r', v_r::text, true);
  perform set_config('t.c1', (select id::text from public.organizer_claims where user_id = u1), true);
end $$;

-- ---------------------------------------------------------------------------
-- 1. Refusals
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  c1 uuid := current_setting('t.c1')::uuid;
  v jsonb;
  cp uuid;
begin
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.connect_organizer_feed('https://aptest-' || v_tag || '-o.org/cal.ics', c1);
    raise exception 'FAIL 1 connected to another person''s claim';
  exception when others then
    if sqlerrm <> 'not_found' then raise exception 'FAIL 1 not_found: %', sqlerrm; end if;
  end;
  -- A pending meta claim cannot connect anything.
  v := public.start_organizer_claim(null, null, null, 'feed', 'https://aptest-' || v_tag || '-p.org/c.ics');
  cp := (v ->> 'claim_id')::uuid;
  begin
    perform public.connect_organizer_feed('https://aptest-' || v_tag || '-q.org/other.ics', cp, -63.0, -125.0);
    raise exception 'FAIL 1 a pending feed claim connected another URL';
  exception when others then
    if sqlerrm <> 'host_mismatch' then raise exception 'FAIL 1 feed host_mismatch: %', sqlerrm; end if;
  end;
  execute 'reset role';
  perform set_config('t.cp', cp::text, true);

  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.connect_organizer_feed('https://aptest-' || v_tag || '-other.org/cal.ics', c1);
    raise exception 'FAIL 1 a host that does not match';
  exception when others then
    if sqlerrm <> 'host_mismatch' then raise exception 'FAIL 1 host_mismatch: %', sqlerrm; end if;
  end;
  begin
    perform public.connect_organizer_feed('https://localhost/cal.ics', c1);
    raise exception 'FAIL 1 a private host';
  exception when others then
    if sqlerrm <> 'url_private_host' then raise exception 'FAIL 1 url_private_host: %', sqlerrm; end if;
  end;
  execute 'reset role';
  insert into of_lines (line) values ('1 refusals: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 2. Verified claim connects; a feed-token claim verified and connected in one step
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  c1 uuid := current_setting('t.c1')::uuid;
  cp uuid := current_setting('t.cp')::uuid;
  v_r uuid := current_setting('t.r')::uuid;
  v jsonb;
  v2 jsonb;
  v_list jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  v := public.connect_organizer_feed('webcal://cal.aptest-' || v_tag || '-o.org/feed.ics', c1);
  execute 'reset role';
  if not (v ->> 'created')::boolean or (v ->> 'slug') !~ '^org-[0-9a-f]{12}$' or (v ->> 'enabled')::boolean then
    raise exception 'FAIL 2 connect result';
  end if;
  if not exists (select 1 from public.feed_sources where id = (v ->> 'source_id')::uuid and origin = 'organizer'
                    and url = 'https://cal.aptest-' || v_tag || '-o.org/feed.ics' and collector_region_id = v_r
                    and organizer_id = current_setting('t.u1')::uuid and not enabled and kind = 'ics' and lane = 'feed') then
    raise exception 'FAIL 2 the connected row';
  end if;
  perform set_config('t.f1', v ->> 'source_id', true);
  perform set_config('t.f1slug', v ->> 'slug', true);

  -- u2 has no home: the picked point decides the region (the test region).
  perform pg_temp.as_user(current_setting('t.u2')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.connect_organizer_feed('https://aptest-' || v_tag || '-p.org/c.ics', cp);
    raise exception 'FAIL 2 no point and no home';
  exception when others then
    if sqlerrm <> 'region_required' then raise exception 'FAIL 2 region_required: %', sqlerrm; end if;
  end;
  v2 := public.connect_organizer_feed('https://aptest-' || v_tag || '-p.org/c.ics', cp, -63.04, -125.04);
  execute 'reset role';
  if (select collector_region_id from public.feed_sources where id = (v2 ->> 'source_id')::uuid) is distinct from v_r
     or (select organizer_id from public.feed_sources where id = (v2 ->> 'source_id')::uuid) is not null then
    raise exception 'FAIL 2 region from the picked point, or an owner before verification';
  end if;
  -- Not listed until the token is found in the feed.
  v_list := public.collector_sources_for_regions(array[v_r]);
  if exists (select 1 from jsonb_array_elements(v_list) x where x.value #>> '{seed,id}' = v2 ->> 'slug') then
    raise exception 'FAIL 2 an unverified feed is listed';
  end if;
  perform public.collector_claims_record(jsonb_build_array(jsonb_build_object('claim_id', cp, 'outcome', 'verified')));
  if (select organizer_id from public.feed_sources where id = (v2 ->> 'source_id')::uuid) is distinct from current_setting('t.u2')::uuid then
    raise exception 'FAIL 2 feed-token verification did not set the owner';
  end if;
  v_list := public.collector_sources_for_regions(array[v_r]);
  if not exists (select 1 from jsonb_array_elements(v_list) x
                  where x.value #>> '{seed,id}' = v2 ->> 'slug' and x.value ->> 'status' = 'organizer'
                    and x.value ->> 'region_id' = v_r::text and x.value ->> 'candidate_id' is null
                    and x.value #>> '{seed,kind}' = 'ics')
     or not exists (select 1 from jsonb_array_elements(v_list) x where x.value #>> '{seed,id}' = current_setting('t.f1slug')) then
    raise exception 'FAIL 2 connected feeds are not listed for their region';
  end if;
  perform set_config('t.f2slug', v2 ->> 'slug', true);
  insert into of_lines (line) values ('2 connect: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 3. First good run enables
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_slug text := current_setting('t.f1slug');
  v jsonb;
begin
  v := public.collector_ingest_events(pg_temp.seed(v_slug), '[]'::jsonb, true, false, 'of-' || v_tag || '-e');
  if (select enabled from public.feed_sources where slug = v_slug) then
    raise exception 'FAIL 3 an empty run enabled the feed';
  end if;
  v := public.collector_ingest_events(pg_temp.seed(v_slug), pg_temp.items(v_tag, 2), false, false, 'of-' || v_tag || '-p');
  if (select enabled from public.feed_sources where slug = v_slug) then
    raise exception 'FAIL 3 a partial run enabled the feed';
  end if;
  v := public.collector_ingest_events(pg_temp.seed(v_slug) || jsonb_build_object('name', 'Renamed by a seed'),
                                      pg_temp.items(v_tag, 2), true, false, 'of-' || v_tag || '-g');
  if not (select enabled from public.feed_sources where slug = v_slug) or (v ->> 'inserted')::int <> 2 then
    raise exception 'FAIL 3 the first good run did not enable the feed';
  end if;
  if (select name from public.feed_sources where slug = v_slug) = 'Renamed by a seed' then
    raise exception 'FAIL 3 a seed renamed an organizer row';
  end if;
  begin
    perform public.collector_ingest_events(jsonb_build_object('slug', 'org-0123456789ab', 'kind', 'ics',
      'url', 'https://aptest-' || v_tag || '-o.org/x.ics', 'name', 'Made up', 'attribution', 'Listed from nowhere.',
      'lane', 'feed', 'enabled', true), '[]'::jsonb, true, true, 'of-' || v_tag || '-x');
    raise exception 'FAIL 3 the ingest created an org- row';
  exception when others then
    if sqlerrm <> 'source_invalid' then raise exception 'FAIL 3 org- slug: %', sqlerrm; end if;
  end;
  insert into of_lines (line) values ('3 first good run: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. At most 3 live connected feeds
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  u1 uuid := current_setting('t.u1')::uuid;
  i integer;
  c uuid;
begin
  for i in 2..4 loop
    insert into public.organizer_claims (user_id, host, method, feed_url, token, status, verified_at)
    values (u1, 'aptest-' || v_tag || '-m' || i || '.org', 'feed', 'https://aptest-' || v_tag || '-m' || i || '.org/c.ics',
            public.organizer_token(), 'verified', now())
    returning id into c;
    perform pg_temp.as_user(u1);
    execute 'set local role authenticated';
    if i < 4 then
      perform public.connect_organizer_feed('https://aptest-' || v_tag || '-m' || i || '.org/c.ics', c);
    else
      begin
        perform public.connect_organizer_feed('https://aptest-' || v_tag || '-m' || i || '.org/c.ics', c);
        raise exception 'FAIL 4 a fourth connected feed';
      exception when others then
        if sqlerrm <> 'feed_limit' then raise exception 'FAIL 4 feed_limit: %', sqlerrm; end if;
      end;
    end if;
    execute 'reset role';
  end loop;
  insert into of_lines (line) values ('4 feed limit: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Eventbrite state rows and the vault token
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  u2 uuid := current_setting('t.u2')::uuid;
  h1 text := encode(extensions.digest('state-one-' || current_setting('t.tag'), 'sha256'), 'hex');
  h2 text := encode(extensions.digest('state-two-' || current_setting('t.tag'), 'sha256'), 'hex');
  v jsonb;
begin
  perform public.organizer_oauth_start(u1, h1);
  if public.organizer_oauth_take(u2, h1) then
    raise exception 'FAIL 5 another person used the state';
  end if;
  if not public.organizer_oauth_take(u1, h1) or public.organizer_oauth_take(u1, h1) then
    raise exception 'FAIL 5 the state is not single-use';
  end if;
  perform public.organizer_oauth_start(u1, h2);
  update public.organizer_oauth_states set expires_at = now() - interval '1 minute' where state_hash = h2;
  if public.organizer_oauth_take(u1, h2) then
    raise exception 'FAIL 5 an expired state was taken';
  end if;
  v := public.organizer_eventbrite_store(u1, 'TESTTOKEN' || current_setting('t.tag'));
  if not (v ->> 'created')::boolean
     or not exists (select 1 from public.feed_sources where id = (v ->> 'source_id')::uuid and kind = 'eventbrite'
                      and origin = 'organizer' and organizer_id = u1 and not enabled) then
    raise exception 'FAIL 5 the eventbrite source';
  end if;
  if not exists (select 1 from jsonb_array_elements(public.organizer_eventbrite_sources(100)) x
                  where x.value ->> 'source_id' = v ->> 'source_id') then
    raise exception 'FAIL 5 the token is not readable by the service role';
  end if;
  insert into of_lines (line) values ('5 eventbrite state: ok');
end $$;
reset role;

do $$
begin
  if has_table_privilege('authenticated', 'vault.secrets', 'select')
     or has_table_privilege('authenticated', 'vault.decrypted_secrets', 'select')
     or exists (select 1 from information_schema.columns c
                 where c.table_schema = 'public' and c.table_name = 'feed_sources' and c.column_name ~ 'token') then
    raise exception 'FAIL 5 the token is readable or stored in a table column';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Account deletion
-- ---------------------------------------------------------------------------
do $$
declare
  u1 uuid := current_setting('t.u1')::uuid;
  v_slug text := current_setting('t.f1slug');
begin
  perform pg_temp.as_user(u1);
  execute 'set local role authenticated';
  perform public.request_account_deletion('test');
  execute 'reset role';
  if exists (select 1 from public.feed_sources f
              where f.origin = 'organizer' and (f.organizer_id = u1 or f.enabled)
                and (f.slug = v_slug or f.kind = 'eventbrite' and f.organizer_id = u1)) then
    raise exception 'FAIL 6 a connected feed kept its owner or stayed on';
  end if;
  if (select organizer_stopped_at from public.feed_sources where slug = v_slug) is null then
    raise exception 'FAIL 6 the connected feed is not stopped';
  end if;
  if exists (select 1 from public.events e join public.event_imports ei on ei.event_id = e.id
               join public.feed_sources f on f.id = ei.source_id
              where f.slug = v_slug and e.status = 'published' and e.starts_at > now()) then
    raise exception 'FAIL 6 upcoming items of the feed are still listed';
  end if;
  if exists (select 1 from vault.decrypted_secrets where name = 'eventbrite:' || u1::text and decrypted_secret <> 'revoked')
     or exists (select 1 from public.organizer_oauth_states where user_id = u1)
     or exists (select 1 from public.organizer_claims where user_id = u1) then
    raise exception 'FAIL 6 the token, states or claims were kept';
  end if;
  if exists (select 1 from jsonb_array_elements(public.collector_sources_for_regions(array[current_setting('t.r')::uuid])) x
              where x.value #>> '{seed,id}' = v_slug) then
    raise exception 'FAIL 6 the deleted owner''s feed is still listed';
  end if;
  insert into of_lines (line) values ('6 account deletion: ok');
end $$;

select line as organizer_feeds from (
  select 0 as n, 'organizer_feeds: all assertions passed' as line
  union all
  select n, line from of_lines) x
order by n;

rollback;
