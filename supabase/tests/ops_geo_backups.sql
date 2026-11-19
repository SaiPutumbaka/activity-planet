-- ============================================================================
-- Staging check for migration 20270112000100_ops_geo_backups.sql (migration
-- 80). One transaction, asserts in DO blocks that raise on failure, rolled
-- back at the end. Prints pass/fail only, never ids or rows (the repo and its
-- Action logs are public). Run as the staging_file of a staging_only
-- migrate.yml run.
--   1 Static: schema_version 2.76 or later; grants; RLS on the new tables; a
--     member cannot read them; staging has the private prod-backups bucket
--     with no policy naming it.
--   2 ops_uptime_alert: one site_down notice per moderator per window, a
--     member cannot call it.
--   3 geo_search_take / geo_search_store: the per-member cap, the cache, the
--     global cap (which does not count against the member), bad keys.
--   4 Account deletion removes the member's counters.
-- ============================================================================
begin;

create function pg_temp.member(p_tag text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ogb-' || p_tag || '-' || substr(md5(random()::text), 1, 8) || '@example.com', now(), now(), now());
  update public.profile_private set birth_date = date '1990-02-02' where user_id = v_id;
  update public.profiles
     set onboarding_completed_at = now(), guidelines_accepted_at = now(), first_name = 'Tester',
         created_at = now() - interval '5 days'
   where id = v_id;
  perform set_config('test.' || p_tag, v_id::text, true);
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  f text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 76] then
    raise exception 'FAIL 1 schema_version is older than 2.76';
  end if;
  foreach f in array array['public.ops_uptime_alert(integer)', 'public.geo_search_take(uuid,text)',
                           'public.geo_search_store(text,jsonb)'] loop
    if has_function_privilege('anon', f, 'execute') or has_function_privilege('authenticated', f, 'execute')
       or not has_function_privilege('service_role', f, 'execute') then
      raise exception 'FAIL 1 grants on %', f;
    end if;
  end loop;
  if not (select c.relrowsecurity from pg_class c where c.oid = 'public.geo_search_usage'::regclass)
     or not (select c.relrowsecurity from pg_class c where c.oid = 'public.geo_search_cache'::regclass) then
    raise exception 'FAIL 1 RLS is off on a new table';
  end if;
  if has_table_privilege('authenticated', 'public.geo_search_usage', 'select')
     or has_table_privilege('anon', 'public.geo_search_cache', 'select') then
    raise exception 'FAIL 1 a client can read a geo_search table';
  end if;
  if public.project_url() like '%gzrscndzzggxmcwnvvcq%' then
    if not exists (select 1 from storage.buckets b where b.id = 'prod-backups' and not b.public) then
      raise exception 'FAIL 1 staging has no private prod-backups bucket';
    end if;
    if exists (select 1 from pg_policies p where p.schemaname = 'storage' and p.tablename = 'objects'
                and (coalesce(p.qual, '') like '%prod-backups%' or coalesce(p.with_check, '') like '%prod-backups%')) then
      raise exception 'FAIL 1 a storage policy names prod-backups';
    end if;
  elsif exists (select 1 from storage.buckets b where b.id = 'prod-backups') then
    raise exception 'FAIL 1 prod-backups exists outside staging';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Uptime alerts
-- ---------------------------------------------------------------------------
do $$
declare
  v_n integer;
begin
  perform pg_temp.member('m'); perform pg_temp.member('a'); perform pg_temp.member('b');
  insert into public.user_roles (user_id, role) values (current_setting('test.m')::uuid, 'moderator');
  v_n := public.ops_uptime_alert(2);
  if v_n < 1 then raise exception 'FAIL 2 no notice queued'; end if;
  if not exists (select 1 from public.notifications n
                  where n.user_id = current_setting('test.m')::uuid and n.kind = 'ops_alert'
                    and n.payload ->> 'alert' = 'site_down' and (n.payload ->> 'count')::int = 2) then
    raise exception 'FAIL 2 the moderator has no site_down notice';
  end if;
  if exists (select 1 from public.notifications n
              where n.user_id = current_setting('test.a')::uuid and n.kind = 'ops_alert') then
    raise exception 'FAIL 2 a member got an ops alert';
  end if;
  if public.ops_uptime_alert(1) <> 0 then raise exception 'FAIL 2 a second alert in the window'; end if;
end $$;

set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  begin
    perform public.ops_uptime_alert(1);
    raise exception 'FAIL 2 a member called ops_uptime_alert';
  exception when insufficient_privilege then null;
  end;
  begin
    perform public.geo_search_take(current_setting('test.a')::uuid, repeat('a', 64));
    raise exception 'FAIL 2 a member called geo_search_take';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;
select set_config('request.jwt.claims', '', true);

-- ---------------------------------------------------------------------------
-- 3. Search counters and cache
-- ---------------------------------------------------------------------------
do $$
declare
  v_a    uuid := current_setting('test.a')::uuid;
  v_k1   text := encode(extensions.digest('ogb-test-1-' || random()::text, 'sha256'), 'hex');
  v_k2   text := encode(extensions.digest('ogb-test-2-' || random()::text, 'sha256'), 'hex');
  v_day  date := (now() at time zone 'UTC')::date;
  v_r    jsonb;
  v_used integer;
begin
  insert into public.meta (key, value) values ('geo_search_user_daily_cap', '3')
    on conflict (key) do update set value = '3';
  insert into public.meta (key, value) values ('geo_search_daily_cap', '1000000')
    on conflict (key) do update set value = '1000000';

  v_r := public.geo_search_take(v_a, v_k1);
  if v_r ->> 'allowed' <> 'true' or v_r ? 'cached' then raise exception 'FAIL 3 first take'; end if;
  perform public.geo_search_store(v_k1, '[{"place_id":"x","lat":1,"lon":2}]'::jsonb);
  v_r := public.geo_search_take(v_a, v_k1);
  if v_r ->> 'allowed' <> 'true' or jsonb_array_length(v_r -> 'cached') <> 1 then
    raise exception 'FAIL 3 the cached answer did not come back';
  end if;
  v_r := public.geo_search_take(v_a, v_k2);
  if v_r ->> 'allowed' <> 'true' then raise exception 'FAIL 3 third take'; end if;
  v_r := public.geo_search_take(v_a, v_k2);
  if v_r ->> 'allowed' <> 'false' or v_r ->> 'limit' <> 'user' then
    raise exception 'FAIL 3 the per-member cap did not hold';
  end if;

  -- The global cap: b's search is refused and not counted against b.
  update public.meta set value = '100' where key = 'geo_search_user_daily_cap';
  select coalesce((select b.used from public.collector_budget b
                    where b.day = v_day and b.source = 'geoapify_autocomplete'), 0) into v_used;
  update public.meta set value = v_used::text where key = 'geo_search_daily_cap';
  v_r := public.geo_search_take(current_setting('test.b')::uuid, v_k2);
  if v_r ->> 'allowed' <> 'false' or v_r ->> 'limit' <> 'global' then
    raise exception 'FAIL 3 the global cap did not hold';
  end if;
  if coalesce((select u.used from public.geo_search_usage u
                where u.user_id = current_setting('test.b')::uuid and u.day = v_day), 0) <> 0 then
    raise exception 'FAIL 3 a refused global search counted against the member';
  end if;
  -- A cached answer needs no credit.
  v_r := public.geo_search_take(current_setting('test.b')::uuid, v_k1);
  if v_r ->> 'allowed' <> 'true' or not v_r ? 'cached' then raise exception 'FAIL 3 cache under the global cap'; end if;

  begin
    perform public.geo_search_take(v_a, 'not-a-hash');
    raise exception 'FAIL 3 a bad key was accepted';
  exception when invalid_parameter_value then null;
  end;
  begin
    perform public.geo_search_store(v_k2, '{"a":1}'::jsonb);
    raise exception 'FAIL 3 a non-array answer was stored';
  exception when invalid_parameter_value then null;
  end;
  if (public.geo_search_take(gen_random_uuid(), v_k1)) ->> 'limit' <> 'user_not_found' then
    raise exception 'FAIL 3 an unknown member was served';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', current_setting('test.a'), 'role', 'authenticated')::text, true);
  perform public.request_account_deletion('test');
end $$;
reset role;
select set_config('request.jwt.claims', '', true);
do $$
begin
  if exists (select 1 from public.geo_search_usage u where u.user_id = current_setting('test.a')::uuid) then
    raise exception 'FAIL 4 the deleted member''s counters stayed';
  end if;
  if (public.geo_search_take(current_setting('test.a')::uuid, repeat('b', 64))) ->> 'limit' <> 'user_not_found' then
    raise exception 'FAIL 4 a deleted member was served';
  end if;
end $$;

select 'ops_geo_backups: PASS' as result;
rollback;
