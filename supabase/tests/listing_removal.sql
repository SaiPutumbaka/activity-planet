-- ============================================================================
-- Staging check for migration 20261226000100_collector_completion.sql
-- (migration 62), listing removal (docs/design/collector/COLLECTOR_COMPLETION.md
-- 2.1). One transaction: throwaway accounts, test sources on invented hosts
-- (aptest-<tag>-*.org; nothing is fetched) and a collector area in the
-- Southern Ocean; asserts in DO blocks that raise on failure, then rolls
-- everything back. Prints pass/fail lines only, never ids, URLs or names.
--
--   1 Static: version, RLS, table and function grants, the cron job.
--   2 submit_listing_removal (service role, the site's route): validation,
--     not_imported, 3 a day per email, 5 a day per client hash.
--   3 Queue: members forbidden; moderators see the request; mod_queue lists it.
--   4 Item removal with a linked copy from a second source: every import row
--     removed and the event removed; re-ingesting both sources (new runs,
--     changed text) never republishes it or makes a new event.
--   5 Source removal: the row off and denylisted, the host on
--     collector_denylist ("owner request <reference>"), source_url_check
--     refuses the host; a shared calendar host is never denylisted.
--   6 Reject needs a note; reopen.
--   7 Contacts cleared a year after closing (clock faked with resolved_at).
--   8 Account deletion clears the resolver stamp.
-- ============================================================================
begin;

create temp table lr_lines (n serial, line text);
grant insert, select on lr_lines to anon, authenticated, service_role;
grant usage on sequence lr_lines_n_seq to anon, authenticated, service_role;

create function pg_temp.as_user(p_uid uuid) returns void language sql as $$
  select set_config('request.jwt.claims',
    case when p_uid is null then json_build_object('role', 'anon')::text
         else json_build_object('sub', p_uid, 'role', 'authenticated')::text end, true);
$$;

create function pg_temp.src(p_tag text, p_letter text, p_host text default null) returns jsonb language sql as $$
  select jsonb_build_object(
    'slug', 'aptest-' || p_tag || '-' || p_letter, 'kind', 'ics',
    'url', 'https://' || coalesce(p_host, 'aptest-' || p_tag || '-' || p_letter || '.org') || '/cal-' || p_tag || '-' || p_letter || '.ics',
    'name', 'Test source ' || p_letter, 'attribution', 'Listed from a test calendar (' || p_letter || ').',
    'lane', 'feed', 'enabled', true,
    'region', jsonb_build_object('lat', -63.0, 'lng', -125.0, 'radius_km', 25, 'timezone', 'UTC'));
$$;

create function pg_temp.items(p_tag text, p_letter text, p_title text) returns jsonb language sql as $$
  select jsonb_build_array(jsonb_build_object(
    'external_id', 'ext-' || p_letter, 'title', p_title,
    'starts_at', to_char(date_trunc('hour', now()) + interval '5 days', 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'ends_at', to_char(date_trunc('hour', now()) + interval '5 days 2 hours', 'YYYY-MM-DD"T"HH24:00:00"Z"'),
    'url', 'https://aptest-' || p_tag || '-' || p_letter || '.org/e/1', 'location', 'Test hall'));
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 58] then
    raise exception 'FAIL 1 schema_version is older than 2.58';
  end if;
  if not (select relrowsecurity from pg_class where oid = 'public.listing_removal_requests'::regclass) then
    raise exception 'FAIL 1 RLS off';
  end if;
  if has_table_privilege('anon', 'public.listing_removal_requests', 'select')
     or has_table_privilege('anon', 'public.listing_removal_requests', 'insert')
     or has_table_privilege('authenticated', 'public.listing_removal_requests', 'select')
     or has_table_privilege('authenticated', 'public.listing_removal_requests', 'insert')
     or not has_table_privilege('service_role', 'public.listing_removal_requests', 'select') then
    raise exception 'FAIL 1 table grants';
  end if;
  if has_function_privilege('anon', 'public.submit_listing_removal(uuid,text,text,text,text,text,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.submit_listing_removal(uuid,text,text,text,text,text,text,text)', 'execute')
     or not has_function_privilege('service_role', 'public.submit_listing_removal(uuid,text,text,text,text,text,text,text)', 'execute')
     or has_function_privilege('anon', 'public.mod_listing_removal_queue(integer,boolean)', 'execute')
     or not has_function_privilege('authenticated', 'public.mod_listing_removal_queue(integer,boolean)', 'execute')
     or has_function_privilege('anon', 'public.mod_listing_removal_resolve(uuid,text,text)', 'execute')
     or has_function_privilege('authenticated', 'public.purge_listing_removal_contacts()', 'execute')
     or has_function_privilege('authenticated', 'public.feed_source_withdraw(uuid,text,text)', 'execute')
     or has_function_privilege('anon', 'public.feed_source_withdraw(uuid,text,text)', 'execute') then
    raise exception 'FAIL 1 function grants';
  end if;
  if to_regclass('cron.job') is not null
     and not exists (select 1 from cron.job where jobname = 'listing-removal-contacts-purge') then
    raise exception 'FAIL 1 purge job not scheduled';
  end if;
  insert into lr_lines (line) values ('1 static: ok');
end $$;

-- ---------------------------------------------------------------------------
-- Setup: accounts, two sources listing the same item, a third source.
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  um uuid := gen_random_uuid();   -- moderator
  u1 uuid := gen_random_uuid();   -- member
  v_title text := 'Removal test listing ' || v_tag;
  v_ev uuid;
  v_ev_c uuid;
begin
  insert into auth.users (id, instance_id, aud, role, email, created_at, updated_at)
  select u, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         'lr-' || substr(u::text, 1, 8) || '-' || v_tag || '@example.com', now(), now()
    from unnest(array[um, u1]) as u;
  update public.profile_private set birth_date = date '1990-05-05' where user_id in (um, u1);
  update public.profiles set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester'
   where id in (um, u1);
  insert into public.user_roles (user_id, role) values (um, 'moderator');

  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 'a', v_title), true, true, 'lr-' || v_tag || '-1');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'b'), pg_temp.items(v_tag, 'b', v_title), true, true, 'lr-' || v_tag || '-1');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'c'), pg_temp.items(v_tag, 'c', 'Source removal test ' || v_tag), true, true, 'lr-' || v_tag || '-1');
  select ei.event_id into v_ev from public.event_imports ei join public.feed_sources f on f.id = ei.source_id
   where f.slug = 'aptest-' || v_tag || '-a';
  select ei.event_id into v_ev_c from public.event_imports ei join public.feed_sources f on f.id = ei.source_id
   where f.slug = 'aptest-' || v_tag || '-c';
  if v_ev is null or v_ev_c is null then
    raise exception 'FAIL setup: no imported events';
  end if;
  if (select count(*) from public.event_imports where event_id = v_ev) <> 2 then
    raise exception 'FAIL setup: the second source did not link to the first one''s event';
  end if;
  perform set_config('t.tag', v_tag, true);
  perform set_config('t.um', um::text, true);
  perform set_config('t.u1', u1::text, true);
  perform set_config('t.ev', v_ev::text, true);
  perform set_config('t.evc', v_ev_c::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 2. submit_listing_removal
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_tag text := current_setting('t.tag');
  v_ev uuid := current_setting('t.ev')::uuid;
  v jsonb;
  v_err text;
  i integer;
begin
  v := public.submit_listing_removal(v_ev, null, 'item', 'Test Person', 'lr-a-' || v_tag || '@example.com', 'organizer', 'Please take it down.');
  if coalesce(v ->> 'reference', '') !~ '^RM-[0-9A-F]{8}$' then
    raise exception 'FAIL 2 no reference';
  end if;
  perform set_config('t.req_item', (select id::text from public.listing_removal_requests where reference = v ->> 'reference'), true);
  if (select source_id from public.listing_removal_requests where reference = v ->> 'reference') is null then
    raise exception 'FAIL 2 the source was not resolved from the event';
  end if;
  begin
    perform public.submit_listing_removal(v_ev, null, 'item', 'Test Person', 'not-an-email', 'organizer', '');
    raise exception 'FAIL 2 bad email accepted';
  exception when others then
    if sqlerrm <> 'invalid_email' then raise exception 'FAIL 2 bad email: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_listing_removal(gen_random_uuid(), null, 'item', 'Test Person', 'lr-b-' || v_tag || '@example.com', 'organizer', '');
    raise exception 'FAIL 2 a non-imported event accepted';
  exception when others then
    if sqlerrm <> 'not_imported' then raise exception 'FAIL 2 not_imported: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_listing_removal(v_ev, null, 'everything', 'Test Person', 'lr-b-' || v_tag || '@example.com', 'organizer', '');
    raise exception 'FAIL 2 bad scope accepted';
  exception when others then
    if sqlerrm <> 'invalid_scope' then raise exception 'FAIL 2 invalid_scope: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_listing_removal(null, null, 'item', 'Test Person', 'lr-b-' || v_tag || '@example.com', 'organizer', '');
    raise exception 'FAIL 2 no listing accepted';
  exception when others then
    if sqlerrm <> 'listing_required' then raise exception 'FAIL 2 listing_required: %', sqlerrm; end if;
  end;
  -- 3 a day per email.
  for i in 1..3 loop
    perform public.submit_listing_removal(null, 'https://aptest-' || v_tag || '-x.org/e/' || i, 'item', 'Test Person',
                                          'lr-rate-' || v_tag || '@example.com', 'venue', '');
  end loop;
  begin
    perform public.submit_listing_removal(null, 'https://aptest-' || v_tag || '-x.org/e/4', 'item', 'Test Person',
                                          'lr-rate-' || v_tag || '@example.com', 'venue', '');
    raise exception 'FAIL 2 fourth request from one email accepted';
  exception when others then
    if sqlerrm <> 'rate_limited' then raise exception 'FAIL 2 email limit: %', sqlerrm; end if;
  end;
  -- 5 a day per client hash.
  for i in 1..5 loop
    perform public.submit_listing_removal(null, 'https://aptest-' || v_tag || '-y.org/e/' || i, 'item', 'Test Person',
                                          'lr-c' || i || '-' || v_tag || '@example.com', 'other', '', repeat('ab', 32));
  end loop;
  begin
    perform public.submit_listing_removal(null, 'https://aptest-' || v_tag || '-y.org/e/6', 'item', 'Test Person',
                                          'lr-c6-' || v_tag || '@example.com', 'other', '', repeat('ab', 32));
    raise exception 'FAIL 2 sixth request from one client accepted';
  exception when others then
    if sqlerrm <> 'rate_limited' then raise exception 'FAIL 2 client limit: %', sqlerrm; end if;
  end;
  begin
    perform public.submit_listing_removal(null, 'https://aptest-' || v_tag || '-y.org/e/7', 'item', 'Test Person',
                                          'lr-c7-' || v_tag || '@example.com', 'other', '', 'nothex');
    raise exception 'FAIL 2 bad client hash accepted';
  exception when others then
    if sqlerrm <> 'bad_request' then raise exception 'FAIL 2 bad_request: %', sqlerrm; end if;
  end;
  -- The source request for source c.
  v := public.submit_listing_removal(current_setting('t.evc')::uuid, null, 'source', 'Test Person',
                                     'lr-src-' || v_tag || '@example.com', 'rights_holder', 'All of it.');
  perform set_config('t.req_src', (select id::text from public.listing_removal_requests where reference = v ->> 'reference'), true);
  perform set_config('t.ref_src', v ->> 'reference', true);
  insert into lr_lines (line) values ('2 submit: ok');
end $$;
reset role;

do $$
begin
  perform pg_temp.as_user(null);
  execute 'set local role anon';
  begin
    perform public.submit_listing_removal(current_setting('t.ev')::uuid, null, 'item', 'Test Person', 'anon@example.com', 'other', '');
    raise exception 'FAIL 2 anon can submit directly';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
end $$;

-- ---------------------------------------------------------------------------
-- 3. Queue
-- ---------------------------------------------------------------------------
do $$
declare
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.u1')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.mod_listing_removal_queue(50, false);
    raise exception 'FAIL 3 a member read the queue';
  exception when others then
    if sqlerrm <> 'forbidden' then raise exception 'FAIL 3 member: %', sqlerrm; end if;
  end;
  begin
    perform 1 from public.listing_removal_requests;
    raise exception 'FAIL 3 a member read the table';
  exception when insufficient_privilege then null;
  end;
  execute 'reset role';
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.mod_listing_removal_queue(500, false);
  if not exists (select 1 from jsonb_array_elements(v) x where x.value ->> 'id' = current_setting('t.req_item')) then
    raise exception 'FAIL 3 the moderator does not see the request';
  end if;
  if not exists (select 1 from jsonb_array_elements(public.mod_queue(500)) x
                  where x.value ->> 'source' = 'listing_removal' and x.value ->> 'id' = current_setting('t.req_item')) then
    raise exception 'FAIL 3 mod_queue does not list it';
  end if;
  execute 'reset role';
  insert into lr_lines (line) values ('3 queue: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 4. Item removal with a linked copy, then re-ingest of both sources
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_ev uuid := current_setting('t.ev')::uuid;
  v_title text := 'Removal test listing ' || v_tag;
  v jsonb;
begin
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.mod_listing_removal_resolve(current_setting('t.req_item')::uuid, 'removed', null);
  execute 'reset role';
  if v ->> 'status' <> 'removed' then
    raise exception 'FAIL 4 status %', v ->> 'status';
  end if;
  if exists (select 1 from public.event_imports where event_id = v_ev and removed_at is null) then
    raise exception 'FAIL 4 an import row of the event is not removed';
  end if;
  if (select moderation_state from public.events where id = v_ev) is distinct from 'removed' then
    raise exception 'FAIL 4 the event is not removed';
  end if;
  if not exists (select 1 from public.moderation_actions where action = 'listing_remove'
                  and target_id = current_setting('t.req_item')::uuid) then
    raise exception 'FAIL 4 not logged';
  end if;
  -- Both sources list it again (new runs), one with changed text.
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'a'), pg_temp.items(v_tag, 'a', v_title || ' updated'), true, true, 'lr-' || v_tag || '-2');
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'b'), pg_temp.items(v_tag, 'b', v_title), true, true, 'lr-' || v_tag || '-2');
  if (select moderation_state from public.events where id = v_ev) is distinct from 'removed' then
    raise exception 'FAIL 4 a re-ingest republished the event';
  end if;
  if exists (select 1 from public.events e where e.kind = 'imported' and e.id <> v_ev
                and e.title like 'Removal test listing ' || v_tag || '%' and e.moderation_state is null) then
    raise exception 'FAIL 4 a re-ingest made a new event';
  end if;
  if (select title from public.events where id = v_ev) <> v_title then
    raise exception 'FAIL 4 a re-ingest rewrote the removed event';
  end if;
  insert into lr_lines (line) values ('4 item removal: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 5. Source removal
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_host text := 'aptest-' || v_tag || '-c.org';
  v jsonb;
  v_chk jsonb;
  v_shared uuid;
  v_req uuid;
begin
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.mod_listing_removal_resolve(current_setting('t.req_src')::uuid, 'removed', null);
  execute 'reset role';
  if not (v ->> 'host_denylisted')::boolean then
    raise exception 'FAIL 5 host not denylisted';
  end if;
  if exists (select 1 from public.feed_sources where slug = 'aptest-' || v_tag || '-c' and (enabled or not denylisted)) then
    raise exception 'FAIL 5 the source is still on';
  end if;
  if not exists (select 1 from public.collector_denylist where name = v_host and match = 'domain'
                  and reason = 'owner request ' || current_setting('t.ref_src')) then
    raise exception 'FAIL 5 no denylist row';
  end if;
  v_chk := public.source_url_check('https://' || v_host || '/other.ics');
  if (v_chk ->> 'ok')::boolean or v_chk ->> 'error' <> 'url_denylisted' then
    raise exception 'FAIL 5 source_url_check accepts the host';
  end if;
  if exists (select 1 from public.events e join public.event_imports ei on ei.event_id = e.id
               join public.feed_sources f on f.id = ei.source_id
              where f.slug = 'aptest-' || v_tag || '-c' and e.moderation_state is null) then
    raise exception 'FAIL 5 an item of the source is still listed';
  end if;
  -- A shared calendar host is never denylisted.
  perform public.collector_ingest_events(pg_temp.src(v_tag, 'g', 'calendar.google.com'),
                                         pg_temp.items(v_tag, 'g', 'Shared host test ' || v_tag), true, true, 'lr-' || v_tag || '-1');
  insert into public.listing_removal_requests (reference, source_id, scope, requester_name, requester_email, email_hash, relationship)
  select 'RM-' || upper(substr(md5(v_tag), 1, 8)), f.id, 'source', 'Test', 'shared@example.com', repeat('0', 64), 'organizer'
    from public.feed_sources f where f.slug = 'aptest-' || v_tag || '-g'
  returning id into v_req;
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  v := public.mod_listing_removal_resolve(v_req, 'removed', null);
  execute 'reset role';
  if (v ->> 'host_denylisted')::boolean
     or exists (select 1 from public.collector_denylist where name = 'calendar.google.com') then
    raise exception 'FAIL 5 a shared host was denylisted';
  end if;
  if exists (select 1 from public.feed_sources where slug = 'aptest-' || v_tag || '-g' and enabled) then
    raise exception 'FAIL 5 the shared-host source is still on';
  end if;
  insert into lr_lines (line) values ('5 source removal: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 6. Reject and reopen
-- ---------------------------------------------------------------------------
do $$
declare
  v_tag text := current_setting('t.tag');
  v_req uuid;
begin
  select id into v_req from public.listing_removal_requests where url = 'https://aptest-' || v_tag || '-x.org/e/1';
  perform pg_temp.as_user(current_setting('t.um')::uuid);
  execute 'set local role authenticated';
  begin
    perform public.mod_listing_removal_resolve(v_req, 'rejected', '');
    raise exception 'FAIL 6 reject without a note';
  exception when others then
    if sqlerrm <> 'note_required' then raise exception 'FAIL 6 note_required: %', sqlerrm; end if;
  end;
  perform public.mod_listing_removal_resolve(v_req, 'rejected', 'Not a listing of ours.');
  begin
    perform public.mod_listing_removal_resolve(v_req, 'rejected', 'again');
    raise exception 'FAIL 6 a closed request resolved twice';
  exception when others then
    if sqlerrm <> 'request_closed' then raise exception 'FAIL 6 request_closed: %', sqlerrm; end if;
  end;
  perform public.mod_listing_removal_resolve(v_req, 'reopen', null);
  execute 'reset role';
  if (select status from public.listing_removal_requests where id = v_req) <> 'open' then
    raise exception 'FAIL 6 reopen';
  end if;
  insert into lr_lines (line) values ('6 reject and reopen: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Retention
-- ---------------------------------------------------------------------------
do $$
declare
  v_req uuid := current_setting('t.req_item')::uuid;
begin
  update public.listing_removal_requests set resolved_at = now() - interval '400 days',
                                             created_at = now() - interval '401 days' where id = v_req;
  perform public.purge_listing_removal_contacts();
  if exists (select 1 from public.listing_removal_requests
              where id = v_req and (requester_email <> '' or requester_name <> '' or reason <> ''
                                    or contact_cleared_at is null or client_hash is not null)) then
    raise exception 'FAIL 7 contact not cleared';
  end if;
  if not exists (select 1 from public.listing_removal_requests where id = v_req and status = 'removed' and reference ~ '^RM-') then
    raise exception 'FAIL 7 the outcome went too';
  end if;
  insert into lr_lines (line) values ('7 retention: ok');
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion
-- ---------------------------------------------------------------------------
do $$
declare
  um uuid := current_setting('t.um')::uuid;
begin
  perform pg_temp.as_user(um);
  execute 'set local role authenticated';
  perform public.request_account_deletion('test');
  execute 'reset role';
  if exists (select 1 from public.listing_removal_requests where resolved_by = um) then
    raise exception 'FAIL 8 resolver stamp kept';
  end if;
  insert into lr_lines (line) values ('8 account deletion: ok');
end $$;

select line as listing_removal from (
  select 0 as n, 'listing_removal: all assertions passed' as line
  union all
  select n, line from lr_lines) x
order by n;

rollback;
