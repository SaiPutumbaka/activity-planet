-- ============================================================================
-- Staging check for migration 20270111000100_launch_audit_followups.sql
-- (migration 79). One transaction, asserts in DO blocks that raise on
-- failure, rolled back at the end. Prints pass/fail only, never ids or rows
-- (the repo and its Action logs are public). Run as the staging_file of a
-- staging_only migrate.yml run.
--   1 Static: schema_version 2.75 or later; event_owner_ok(hub, host) is gone
--     and event_owner_ok(event) is callable by the read rules; grants.
--   2 Email budget: verification and scorecard emails leave
--     meta.email_staff_reserve of the day.
--   3 event_owner_ok(event): false for an unknown id and for a profile id
--     (no ban lookup), true for a normal plan, false once its host is banned.
--   4 set_rsvp: a banned host's plan answers event_not_found to a member;
--     after the ban is lifted the member can RSVP.
-- ============================================================================
begin;

create function pg_temp.member(p_tag text) returns uuid language plpgsql as $$
declare
  v_id uuid := gen_random_uuid();
begin
  insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
  values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'laf-' || p_tag || '-' || substr(md5(random()::text), 1, 8) || '@example.com', now(), now(), now());
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
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 75] then
    raise exception 'FAIL 1 schema_version is older than 2.75';
  end if;
  if to_regprocedure('public.event_owner_ok(uuid,uuid)') is not null then
    raise exception 'FAIL 1 event_owner_ok(hub, host) still exists';
  end if;
  if not has_function_privilege('anon', 'public.event_owner_ok(uuid)', 'execute')
     or not has_function_privilege('authenticated', 'public.event_owner_ok(uuid)', 'execute')
     or has_function_privilege('authenticated', 'public.email_budget_take(text,integer)', 'execute')
     or not has_function_privilege('service_role', 'public.email_budget_take(text,integer)', 'execute')
     or has_function_privilege('anon', 'public.set_rsvp(uuid,public.rsvp_status)', 'execute') then
    raise exception 'FAIL 1 grants';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname = 'public' and p.proname = 'event_owner_ok' and p.prosecdef
                    and p.proconfig @> array['search_path=""']) then
    raise exception 'FAIL 1 event_owner_ok is not definer with an empty search_path';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. Email budget: the staff reserve
-- ---------------------------------------------------------------------------
do $$
declare
  v_today integer := coalesce((select sum(sent) from public.email_send_days
                                where day = (now() at time zone 'UTC')::date), 0);
begin
  insert into public.meta (key, value) values ('email_daily_cap_total', (v_today + 3)::text)
    on conflict (key) do update set value = excluded.value;
  insert into public.meta (key, value) values ('email_monthly_cap_total', '9999999')
    on conflict (key) do update set value = excluded.value;
  insert into public.meta (key, value) values ('email_staff_reserve', '2')
    on conflict (key) do update set value = excluded.value;
  if not public.email_budget_take('verification') then
    raise exception 'FAIL 2 an email outside the reserve was refused';
  end if;
  if public.email_budget_take('verification') or public.email_budget_take('scorecard') then
    raise exception 'FAIL 2 a verification or scorecard email used the staff reserve';
  end if;
  if (select sum(sent) from public.email_send_days where day = (now() at time zone 'UTC')::date) <> v_today + 1 then
    raise exception 'FAIL 2 the day''s count is wrong';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup: b member, h host, a plan in an active general hub.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hub uuid;
  v_e   uuid;
begin
  perform pg_temp.member('b'); perform pg_temp.member('h');
  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, location_hint)
  values (v_hub, current_setting('test.h')::uuid, 'Zzq launch audit follow-up plan', now() + interval '3 days',
          now() + interval '3 days 2 hours', 'Park')
  returning id into v_e;
  perform set_config('test.e', v_e::text, true);
end $$;

-- ---------------------------------------------------------------------------
-- 3. event_owner_ok(event), as anon
-- ---------------------------------------------------------------------------
set local role anon;
do $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  if public.event_owner_ok(gen_random_uuid()) then
    raise exception 'FAIL 3 an unknown id answered true';
  end if;
  if public.event_owner_ok(current_setting('test.h')::uuid) then
    raise exception 'FAIL 3 a profile id answered true';
  end if;
  if not public.event_owner_ok(current_setting('test.e')::uuid) then
    raise exception 'FAIL 3 a normal plan answered false';
  end if;
end $$;
reset role;

update public.profiles set status = 'banned' where id = current_setting('test.h')::uuid;
set local role anon;
do $$
begin
  if public.event_owner_ok(current_setting('test.e')::uuid) then
    raise exception 'FAIL 3 a banned host''s plan answered true';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 4. set_rsvp on a banned host's plan
-- ---------------------------------------------------------------------------
do $$
begin
  perform set_config('request.jwt.claims',
                     json_build_object('sub', current_setting('test.b'), 'role', 'authenticated')::text, true);
end $$;
set local role authenticated;
do $$
begin
  begin
    perform public.set_rsvp(current_setting('test.e')::uuid, 'going');
    raise exception 'FAIL 4 a member RSVPed to a banned host''s plan';
  exception when others then
    if sqlerrm <> 'event_not_found' then raise exception 'FAIL 4 banned host: %', sqlerrm; end if;
  end;
  if public.can_read_event(current_setting('test.e')::uuid)
     or exists (select 1 from public.events where id = current_setting('test.e')::uuid) then
    raise exception 'FAIL 4 a member reads a banned host''s plan';
  end if;
end $$;
reset role;

update public.profiles set status = 'active' where id = current_setting('test.h')::uuid;
set local role authenticated;
do $$
declare
  r public.rsvps;
begin
  r := public.set_rsvp(current_setting('test.e')::uuid, 'going');
  if r.status is distinct from 'going' then
    raise exception 'FAIL 4 a member could not RSVP once the ban was lifted';
  end if;
  if not public.can_read_event(current_setting('test.e')::uuid) then
    raise exception 'FAIL 4 a member cannot read the plan once the ban was lifted';
  end if;
end $$;
reset role;

select 'launch_audit_followups: PASS' as result;

rollback;
