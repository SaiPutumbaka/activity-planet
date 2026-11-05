-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67):
-- the weekly scorecard (scorecard_week, scorecard_runs, scorecard_record) and
-- the landing page's public_week_near. One transaction: throwaway accounts
-- and plans, DO blocks that raise on failure, then ROLLBACK. Prints pass/fail
-- only; the scorecard is checked by differences, never printed.
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
create function pg_temp.n(p jsonb, p_path text[]) returns numeric language sql immutable as $$
  select (p #>> p_path)::numeric;
$$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_names text[] := array['mod', 'mem', 'host', 'a1', 'a2', 'a3', 'a4', 'banned'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_week  date := (now() at time zone 'America/New_York')::date
                  - (extract(isodow from (now() at time zone 'America/New_York')::date)::integer - 1);
  v_before jsonb;
  v_hub   uuid;
  v_sens  uuid;
  v_e     uuid;
  v_q     extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_qfar  extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-29.34, 47.0), 4326)::extensions.geography;
  v_atl   extensions.geography;
  v_t     timestamptz := now() + interval '1 day';
  v_held  timestamptz;
  v_camp  uuid;
  r       record;
begin
  perform set_config('test.week', v_week::text, true);
  v_held := greatest((v_week::timestamp at time zone 'America/New_York') + interval '1 minute', now() - interval '2 hours');
  -- The counts before anything is seeded (as the owner: is_privileged).
  v_before := public.scorecard_week(v_week);
  perform set_config('test.before', v_before::text, true);

  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recss-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now()
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  insert into public.user_roles (user_id, role) values (pg_temp.uid('mod'), 'moderator');

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  select oc.id into v_camp from public.org_campuses oc order by oc.slug limit 1;
  v_atl := (select a.center from public.areas a where a.slug = 'atlanta');
  if v_hub is null or v_sens is null or v_atl is null or v_camp is null then
    raise exception 'FAIL setup: no general or sensitive hub, Atlanta area or campus';
  end if;

  -- A human-hosted plan held this week with four check-ins.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('host'), 'Scorecard held', v_held, v_held + interval '1 hour', v_q) returning id into v_e;
  insert into public.rsvps (event_id, user_id, status, checked_in_at)
  select v_e, u, 'going', now() from unnest(array[pg_temp.uid('a1'), pg_temp.uid('a2'), pg_temp.uid('a3'), pg_temp.uid('a4')]) u;

  -- Landing plans at the Atlantic point Q (pOK is the only one that may show).
  for r in select * from (values
      ('pOK',   'hub',  'q',    '1 day',  'public', 18, false, null::text, 'plan', 'host'),
      ('pCamp', 'hub',  'q',    '1 day',  'campus', 18, false, null,       'plan', 'host'),
      ('p21',   'hub',  'q',    '1 day',  'public', 21, false, null,       'plan', 'host'),
      ('pMod',  'hub',  'q',    '1 day',  'public', 18, false, 'hidden',   'plan', 'host'),
      ('pMem',  'hub',  'q',    '1 day',  'public', 18, true,  null,       'plan', 'host'),
      ('pSens', 'sens', 'q',    '1 day',  'public', 18, false, null,       'plan', 'host'),
      ('pLate', 'hub',  'q',    '8 days', 'public', 18, false, null,       'plan', 'host'),
      ('pFar',  'hub',  'qfar', '1 day',  'public', 18, false, null,       'plan', 'host'),
      ('pShow', 'hub',  'q',    '1 day',  'public', 18, false, null,       'show', 'host'),
      ('pBan',  'hub',  'q',    '1 day',  'public', 18, false, null,       'plan', 'banned'),
      ('pAtl',  'hub',  'atl',  '5 minutes', 'public', 18, false, null,    'plan', 'host')
    ) v(name, hub, place, start_in, vis, age, mem, moderated, lk, host)
  loop
    insert into public.events (hub_id, host_id, title, description, location_hint, starts_at, ends_at, approx_point,
                               visibility, campus_id, min_age, members_only, moderation_state, moderated_at, listing_kind)
    values (case when r.hub = 'sens' then v_sens else v_hub end, pg_temp.uid(r.host),
            'Landing ' || r.name, 'A private description', 'Behind the blue door',
            now() + r.start_in::interval, now() + r.start_in::interval + interval '1 hour',
            case r.place when 'q' then v_q when 'qfar' then v_qfar else v_atl end,
            r.vis::public.event_visibility, case when r.vis = 'campus' then v_camp end, r.age, r.mem,
            r.moderated, case when r.moderated is not null then now() end, r.lk)
    returning id into v_e;
    perform set_config('test.' || r.name, v_e::text, true);
  end loop;
  update public.profiles set status = 'banned' where id = pg_temp.uid('banned');

  insert into public.scorecard_runs (week_start, counts, status) values (date '2020-01-06', '{"people":{"signups":1}}', 'sent')
  on conflict (week_start) do nothing;
end $$;

-- ---------------------------------------------------------------------------
-- scorecard_week: counts on the seeded rows (as the owner)
-- ---------------------------------------------------------------------------
do $$
declare
  b jsonb := current_setting('test.before')::jsonb;
  a jsonb := public.scorecard_week(current_setting('test.week')::date);
begin
  if a ->> 'week_start' <> current_setting('test.week') then
    raise exception 'FAIL scorecard week_start';
  end if;
  if pg_temp.n(a, '{people,signups}') - pg_temp.n(b, '{people,signups}') <> 8
     or pg_temp.n(a, '{people,onboarded}') - pg_temp.n(b, '{people,onboarded}') <> 8 then
    raise exception 'FAIL scorecard signups or onboarded';
  end if;
  if pg_temp.n(a, '{plans,human_hosted_held}') - pg_temp.n(b, '{plans,human_hosted_held}') < 1
     or pg_temp.n(a, '{plans,four_plus_checked_in}') - pg_temp.n(b, '{plans,four_plus_checked_in}') <> 1
     or pg_temp.n(a, '{plans,unique_attendees}') - pg_temp.n(b, '{plans,unique_attendees}') <> 4 then
    raise exception 'FAIL scorecard plans counts';
  end if;
  if not (a ? 'people' and a ? 'plans' and a ? 'chapters_active' and a ? 'messages' and a ? 'coaching'
          and a ? 'collector' and a ? 'recs' and a ? 'trust' and a ? 'launch_gate') then
    raise exception 'FAIL scorecard sections missing';
  end if;
  if (a #>> '{launch_gate,week_2027_01_11,target}')::integer <> 10
     or (a #>> '{launch_gate,chapters_live,target}')::integer <> 5 then
    raise exception 'FAIL scorecard launch gate';
  end if;
  -- Counts only: no uuid, no email address anywhere.
  if a::text ~ '[0-9a-f]{8}-[0-9a-f]{4}-' or a::text like '%@%' then
    raise exception 'FAIL scorecard carries an id or an address';
  end if;
  if pg_temp.err($q$select public.scorecard_week(date '2026-11-03')$q$) <> 'invalid_week' then
    raise exception 'FAIL scorecard accepts a week that does not start on Monday';
  end if;
  -- scorecard_record never overwrites a sent week.
  perform public.scorecard_record(date '2020-01-06', '{}'::jsonb, 'failed', 'x');
  if (select status from public.scorecard_runs where week_start = date '2020-01-06') <> 'sent' then
    raise exception 'FAIL scorecard_record overwrote a sent week';
  end if;
  if (public.scorecard_run_state(date '2020-01-13') -> 'previous_counts') is null then
    raise exception 'FAIL scorecard_run_state misses the previous week';
  end if;
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.act('mem');
  if pg_temp.err('select public.scorecard_week()') <> 'forbidden' then
    raise exception 'FAIL scorecard_week allowed for a member';
  end if;
  if (select count(*) from public.scorecard_runs) <> 0 then
    raise exception 'FAIL scorecard_runs readable by a member';
  end if;
  if pg_temp.err('select public.recs_status()') <> 'forbidden' then
    raise exception 'FAIL recs_status allowed for a member';
  end if;
  perform pg_temp.act('mod');
  if pg_temp.err('select public.scorecard_week()') <> 'ok' then
    raise exception 'FAIL scorecard_week refused for a moderator';
  end if;
  if not exists (select 1 from public.scorecard_runs where week_start = date '2020-01-06') then
    raise exception 'FAIL scorecard_runs not readable by a moderator';
  end if;
  if (public.recs_status() -> 'embeddings') is null then
    raise exception 'FAIL recs_status for a moderator';
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- public_week_near as anon
-- ---------------------------------------------------------------------------
do $$
declare
  v text := pg_get_function_result('public.public_week_near(double precision,double precision,integer)'::regprocedure);
begin
  if v ~* '(host|description|location_hint|lat|lng|point|address|venue)' then
    raise exception 'FAIL public_week_near returns %', v;
  end if;
end $$;

set local role anon;
do $$
declare
  ids uuid[];
  n   text;
begin
  perform set_config('request.jwt.claims', '{"role":"anon"}', true);
  if pg_temp.err('select count(*) from public.scorecard_runs') not like '%permission denied%' then
    raise exception 'FAIL anon can read scorecard_runs';
  end if;
  select coalesce(array_agg(w.id), '{}') into ids from public.public_week_near(47.03, -30.04, 24) w;
  if not (pg_temp.uid('pOK') = any (ids)) then
    raise exception 'FAIL public_week_near misses the public plan near the point';
  end if;
  foreach n in array array['pCamp', 'p21', 'pMod', 'pMem', 'pSens', 'pLate', 'pFar', 'pShow', 'pBan', 'pAtl'] loop
    if pg_temp.uid(n) = any (ids) then
      raise exception 'FAIL public_week_near shows %', n;
    end if;
  end loop;
  if not exists (select 1 from public.public_week_near(47.03, -30.04, 24) w
                  where w.id = pg_temp.uid('pOK') and w.distance_band = '<1 mi' and not w.is_imported
                    and (w.hub ->> 'name') is not null and w.going_bucket is null) then
    raise exception 'FAIL public_week_near columns for the public plan';
  end if;
  -- No point: Atlanta.
  select coalesce(array_agg(w.id), '{}') into ids from public.public_week_near(null, null, 24) w;
  if not (pg_temp.uid('pAtl') = any (ids)) or pg_temp.uid('pOK') = any (ids) then
    raise exception 'FAIL public_week_near without a point is not Atlanta';
  end if;
  if (select count(*) from public.public_week_near(null, null, 500)) > 24 then
    raise exception 'FAIL public_week_near returns more than 24';
  end if;
end $$;
reset role;

select 'PASS scorecard_landing' as result;
rollback;
