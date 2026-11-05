-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67,
-- D-045 recommendations slice 1). One transaction: throwaway accounts, events
-- far out in the Atlantic (no other plans nearby) and synthetic one-hot
-- 384-dimension vectors written as the test owner; DO blocks that raise on
-- failure, then ROLLBACK. Prints pass/fail only (no user rows; the accounts
-- are invented).
--
--   1 static: schema_version, RLS, grants, invoker RPCs, service-only jobs.
--   2 For you: excludes RSVP'd, dismissed, own, blocked host, blocked attendee,
--     21+ for a 19-year-old, sensitive hub, campus-only to a non-member,
--     moderated, shows, another city's plans; orders by similarity at equal
--     distance and by distance at equal similarity; at most 2 per hub; chips
--     never name a sensitive hub; people met going.
--   3 Similar plans: refuses an unreadable anchor; keeps only similar plans.
--   4 Hubs: excludes joined, sensitive, campus-scope, 21+, moderated, dismissed.
--   5 Coaches: excludes blocked coaches and the caller.
--   6 Taste: weights, decay, sensitive and moderated inputs ignored,
--     personalize off; no client reads a taste vector.
--   7 Queue: triggers on insert and edit; claim builds text (no URL, email or
--     phone), skips an unchanged hash, drops ineligible subjects; record
--     validates length and norm and refuses a stale hash; fail after 5.
--   8 Account deletion: the member's taste, prefs and dismissals go, and
--     others' "Not interested" in them.
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
-- A unit-ish vector from {"dim": value} (dimensions 1 to 384; values already normalized).
create function pg_temp.vec(p jsonb) returns extensions.halfvec language sql immutable as $$
  select (select array_agg(coalesce((p ->> g::text)::real, 0) order by g) from generate_series(1, 384) g)
           ::real[]::extensions.vector(384)::extensions.halfvec(384);
$$;
create function pg_temp.vjson(p jsonb, p_len integer default 384) returns jsonb language sql immutable as $$
  select jsonb_agg(coalesce((p ->> g::text)::double precision, 0) order by g) from generate_series(1, p_len) g;
$$;
-- The test events in a For you answer (ids in rank order) and their reasons.
create function pg_temp.fy(p_lat double precision, p_lng double precision) returns uuid[] language sql as $$
  select coalesce(array_agg(f.id order by f.rank), '{}')
    from public.recs_for_you(p_lat, p_lng, 25, 'UTC', 30) f
   where f.id = any (string_to_array(current_setting('test.events'), ',')::uuid[]);
$$;
create function pg_temp.pos(p_arr uuid[], p_name text) returns integer language sql as $$
  select array_position(p_arr, pg_temp.uid(p_name));
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 63] then
    raise exception 'FAIL 1 schema_version is older than 2.63';
  end if;
  if not exists (select 1 from pg_extension where extname = 'vector') then
    raise exception 'FAIL 1 vector extension missing';
  end if;
  foreach t in array array['hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue',
                           'rec_taste', 'rec_prefs', 'rec_dismissals', 'scorecard_runs'] loop
    if not coalesce((select c.relrowsecurity from pg_class c where c.oid = ('public.' || t)::regclass), false) then
      raise exception 'FAIL 1 RLS is off on %', t;
    end if;
    if has_table_privilege('anon', 'public.' || t, 'select')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update')
       or has_table_privilege('authenticated', 'public.' || t, 'delete') then
      raise exception 'FAIL 1 clients can write or anon can read %', t;
    end if;
  end loop;
  foreach t in array array['hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue', 'rec_taste'] loop
    if has_table_privilege('authenticated', 'public.' || t, 'select') then
      raise exception 'FAIL 1 authenticated can read %', t;
    end if;
  end loop;
  if exists (select 1 from information_schema.columns
              where table_schema = 'public'
                and table_name in ('hub_embeddings', 'event_embeddings', 'coach_listing_embeddings', 'rec_embed_queue', 'scorecard_runs')
                and (column_name ~ 'user|profile|created_by')) then
    raise exception 'FAIL 1 an embedding, queue or scorecard table has a user column';
  end if;
  foreach t in array array['public.recs_for_you(double precision,double precision,integer,text,integer)',
                           'public.recs_similar_events(uuid,double precision,double precision,integer,text,integer)',
                           'public.recs_hubs(double precision,double precision,integer,integer)',
                           'public.recs_coaches(double precision,double precision,integer,integer)',
                           'public.recs_people(integer)'] loop
    if (select prosecdef from pg_proc where oid = t::regprocedure) then
      raise exception 'FAIL 1 % is security definer', t;
    end if;
    if has_function_privilege('anon', t, 'execute') or not has_function_privilege('authenticated', t, 'execute') then
      raise exception 'FAIL 1 % grants', t;
    end if;
  end loop;
  foreach t in array array['public.recs_embed_dispatch()', 'public.recs_embed_claim(integer)', 'public.recs_embed_record(jsonb)',
                           'public.recs_embed_fail(public.rec_subject_kind,uuid,text)', 'public.recs_embed_verify_secret(text)',
                           'public.recs_taste_refresh(integer)', 'public.recs_tick()', 'public.purge_recs()',
                           'public.scorecard_dispatch()', 'public.scorecard_verify_secret(text)',
                           'public.scorecard_record(date,jsonb,text,text)', 'public.scorecard_run_state(date)',
                           'private.rec_taste_compute(uuid)', 'private.rec_text(public.rec_subject_kind,uuid)'] loop
    if has_function_privilege('authenticated', t, 'execute') or has_function_privilege('anon', t, 'execute') then
      raise exception 'FAIL 1 a client can run %', t;
    end if;
    if not (select prosecdef from pg_proc where oid = t::regprocedure)
       or not exists (select 1 from pg_proc where oid = t::regprocedure and proconfig @> array['search_path=""']) then
      raise exception 'FAIL 1 % is not definer with an empty search_path', t;
    end if;
  end loop;
  if not has_function_privilege('service_role', 'public.recs_embed_claim(integer)', 'execute')
     or has_function_privilege('anon', 'private.rec_event_scores(uuid[],uuid)', 'execute')
     or not has_function_privilege('authenticated', 'private.rec_event_scores(uuid[],uuid)', 'execute')
     or not has_function_privilege('anon', 'public.public_week_near(double precision,double precision,integer)', 'execute') then
    raise exception 'FAIL 1 scorer, service or landing grants';
  end if;
  if (select count(*) from cron.job where jobname in ('recs-embed', 'recs-tick', 'purge-recs', 'weekly-scorecard')) <> 4 then
    raise exception 'FAIL 1 a pg_cron job is missing';
  end if;
  if not exists (select 1 from vault.secrets where name = 'recs_embed_secret')
     or not exists (select 1 from vault.secrets where name = 'scorecard_secret') then
    raise exception 'FAIL 1 a vault secret is missing';
  end if;
  if public.recs_embed_verify_secret('x') or public.recs_embed_verify_secret(null) then
    raise exception 'FAIL 1 a wrong secret was accepted';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- m: main member. y: 19 years old. t: taste test. b: blocks m. x: blocked by m. h: host.
  -- p: met m. l: lives in London. c1, c2: coaches. z: deletes the account. u: RSVPs to a queued plan.
  v_names text[] := array['m', 'y', 't', 'b', 'x', 'h', 'p', 'l', 'c1', 'c2', 'z', 'u'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_h     uuid[];
  v_sens  uuid;
  v_camph uuid;
  v_h21   uuid;
  v_camp  uuid;
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_pt7   extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-29.908, 47.0), 4326)::extensions.geography;
  v_atl   extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-84.388, 33.776), 4326)::extensions.geography;
  v_t     timestamptz := date_trunc('hour', now()) + interval '2 days';
  v_ev    uuid[] := '{}';
  v_e     uuid;
  r       record;
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recs-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private
       set birth_date = case when v_names[i] = 'y' then (current_date - interval '19 years')::date else date '1990-04-04' end,
           home_area_id = null, home_point = null
     where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;
  update public.profile_private
     set home_point = extensions.ST_SetSRID(extensions.ST_MakePoint(-0.13, 51.53), 4326)::extensions.geography
   where user_id = pg_temp.uid('l');

  select array_agg(s.id order by s.slug) into v_h
    from (select h.id, h.slug from public.hubs h join public.hub_categories c on c.slug = h.category_slug
           where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
           order by h.slug limit 7) s;
  if coalesce(array_length(v_h, 1), 0) < 7 then raise exception 'FAIL setup: fewer than 7 general hubs'; end if;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  select h.id into v_camph from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.scope = 'campus' and not c.is_sensitive and h.moderation_state is null and h.min_age = 18
   order by h.slug limit 1;
  select h.id into v_h21 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 21 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select oc.id into v_camp from public.org_campuses oc order by oc.slug limit 1;
  if v_sens is null or v_camph is null or v_h21 is null or v_camp is null then
    raise exception 'FAIL setup: no sensitive, campus-scope or 21+ hub, or no campus';
  end if;
  for i in 1..7 loop perform set_config('test.h' || i, v_h[i]::text, true); end loop;
  perform set_config('test.hs', v_sens::text, true);
  perform set_config('test.hc', v_camph::text, true);
  perform set_config('test.h21', v_h21::text, true);
  perform set_config('test.hs_name', (select name from public.hubs where id = v_sens), true);
  perform set_config('test.h6_name', (select name from public.hubs where id = v_h[6]), true);

  -- Events at the Atlantic point P (or 7 km east of it, or Atlanta), all starting at v_t.
  for r in select * from (values
      ('eA',      1, 'h',  'p',   'plan', 18, 'public', false),
      ('eB',      2, 'h',  'p',   'plan', 18, 'public', false),
      ('eC',      3, 'h',  'p',   'plan', 18, 'public', false),
      ('eD1',     4, 'h',  'p',   'plan', 18, 'public', false),
      ('eD2',     4, 'h',  'p7',  'plan', 18, 'public', false),
      ('eF1',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eF2',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eF3',     5, 'h',  'p',   'plan', 18, 'public', false),
      ('eRsvp',   1, 'h',  'p',   'plan', 18, 'public', false),
      ('eDism',   1, 'h',  'p',   'plan', 18, 'public', false),
      ('eOwn',    2, 'm',  'p',   'plan', 18, 'public', false),
      ('eBHost',  2, 'b',  'p',   'plan', 18, 'public', false),
      ('eBAtt',   2, 'h',  'p',   'plan', 18, 'public', false),
      ('e21',     3, 'h',  'p',   'plan', 21, 'public', false),
      ('eSens',   0, 'h',  'p',   'plan', 18, 'public', false),
      ('eCampus', 3, 'h',  'p',   'plan', 18, 'campus', false),
      ('eMod',    3, 'h',  'p',   'plan', 18, 'public', true),
      ('eShow',   3, 'h',  'p',   'show', 18, 'public', false),
      ('eAtl',    1, 'h',  'atl', 'plan', 18, 'public', false)
    ) v(name, hub, host, place, lk, age, vis, moderated)
  loop
    insert into public.events (hub_id, host_id, title, description, starts_at, ends_at, approx_point, min_age,
                               visibility, campus_id, listing_kind, moderation_state, moderated_at)
    values (case when r.hub = 0 then v_sens else v_h[r.hub] end, pg_temp.uid(r.host),
            'Recs test ' || r.name, 'A test plan.', v_t, v_t + interval '2 hours',
            case r.place when 'p' then v_pt when 'p7' then v_pt7 else v_atl end,
            r.age, r.vis::public.event_visibility, case when r.vis = 'campus' then v_camp end, r.lk,
            case when r.moderated then 'hidden' end, case when r.moderated then now() end)
    returning id into v_e;
    perform set_config('test.' || r.name, v_e::text, true);
    v_ev := v_ev || v_e;
  end loop;
  perform set_config('test.events', array_to_string(v_ev, ','), true);

  -- Embeddings: m's taste is dimension 1.
  insert into public.event_embeddings (event_id, embedding, content_hash) values
    (pg_temp.uid('eA'),  pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eB'),  pg_temp.vec('{"1":0.8,"2":0.6}'), 'test'),
    (pg_temp.uid('eC'),  pg_temp.vec('{"2":1}'), 'test'),
    (pg_temp.uid('eD1'), pg_temp.vec('{"3":1}'), 'test'),
    (pg_temp.uid('eD2'), pg_temp.vec('{"3":1}'), 'test'),
    (pg_temp.uid('eF1'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eF2'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eF3'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eSens'), pg_temp.vec('{"1":1}'), 'test'),
    (pg_temp.uid('eMod'), pg_temp.vec('{"1":1}'), 'test')
  on conflict (event_id) do update set embedding = excluded.embedding;
  insert into public.hub_embeddings (hub_id, embedding, content_hash) values
    (v_h[5], pg_temp.vec('{"1":1}'), 'test'),
    (v_h[6], pg_temp.vec('{"1":1}'), 'test'),
    (v_sens, pg_temp.vec('{"1":1}'), 'test')
  on conflict (hub_id) do update set embedding = excluded.embedding;

  -- m: in the sensitive hub and in hub 6; RSVP'd, dismissed, blocked by b, blocks x (who is going).
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('m'), v_sens), (pg_temp.uid('m'), v_h[6])
  on conflict do nothing;
  insert into public.rsvps (event_id, user_id, status) values
    (pg_temp.uid('eRsvp'), pg_temp.uid('m'), 'going'),
    (pg_temp.uid('eBAtt'), pg_temp.uid('x'), 'going'),
    (pg_temp.uid('eC'), pg_temp.uid('p'), 'going');
  insert into public.rec_dismissals (user_id, subject_kind, subject_id) values (pg_temp.uid('m'), 'event', pg_temp.uid('eDism'));
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('b'), pg_temp.uid('m')), (pg_temp.uid('m'), pg_temp.uid('x'));
  -- m and p met (mutual picks) at a past plan.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[7], pg_temp.uid('h'), 'Recs test past', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', v_pt)
  returning id into v_e;
  insert into public.event_meets (event_id, user_id, met_user_id) values
    (v_e, pg_temp.uid('m'), pg_temp.uid('p')), (v_e, pg_temp.uid('p'), pg_temp.uid('m'));

  -- Coaches near P: c1 (listing embedding dimension 1), c2 (blocked by m), m itself.
  insert into public.coach_profiles (user_id, status, headline, timezone, in_person, service_point, service_radius_km, area_label)
  select u, 'active', 'Recs test coach', 'Europe/London', true, v_pt, 20, 'Test'
    from unnest(array[pg_temp.uid('c1'), pg_temp.uid('c2'), pg_temp.uid('m')]) u;
  for r in select u from unnest(array['c1', 'c2', 'm']) u loop
    insert into public.coach_listings (coach_id, hub_id, title, delivery, format, duration_minutes, price_minor, currency)
    values (pg_temp.uid(r.u), v_h[1], 'Recs test lessons', 'in_person', 'one_on_one', 60, 0, 'usd')
    returning id into v_e;
    insert into public.coach_listing_embeddings (listing_id, embedding, content_hash) values (v_e, pg_temp.vec('{"1":1}'), 'test');
  end loop;
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('m'), pg_temp.uid('c2'));

  -- Hub 7 is moderated (for the hubs row).
  update public.hubs set moderation_state = 'hidden', moderated_at = now() where id = v_h[7];

  -- m's taste: dimension 1 (written last, after the stale triggers).
  insert into public.rec_taste (user_id, embedding, inputs, stale, computed_at)
  values (pg_temp.uid('m'), pg_temp.vec('{"1":1}'), 1, false, now())
  on conflict (user_id) do update set embedding = excluded.embedding, inputs = 1, stale = false;
end $$;

-- ---------------------------------------------------------------------------
-- 2. For you
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v   uuid[];
  n   text;
  rs  jsonb;
begin
  perform pg_temp.act('m');
  v := pg_temp.fy(47.0, -30.0);
  foreach n in array array['eRsvp', 'eDism', 'eOwn', 'eBHost', 'eBAtt', 'eSens', 'eCampus', 'eMod', 'eShow', 'eAtl'] loop
    if pg_temp.pos(v, n) is not null then
      raise exception 'FAIL 2 For you shows the excluded plan %', n;
    end if;
  end loop;
  foreach n in array array['eA', 'eB', 'eC', 'eD1', 'eD2'] loop
    if pg_temp.pos(v, n) is null then
      raise exception 'FAIL 2 For you misses %', n;
    end if;
  end loop;
  if not (pg_temp.pos(v, 'eA') < pg_temp.pos(v, 'eB') and pg_temp.pos(v, 'eB') < pg_temp.pos(v, 'eC')) then
    raise exception 'FAIL 2 not ordered by similarity at equal distance';
  end if;
  if not (pg_temp.pos(v, 'eD1') < pg_temp.pos(v, 'eD2')) then
    raise exception 'FAIL 2 not ordered by distance at equal similarity';
  end if;
  if (select count(*) from unnest(v) i where i in (pg_temp.uid('eF1'), pg_temp.uid('eF2'), pg_temp.uid('eF3'))) <> 2 then
    raise exception 'FAIL 2 the per-hub cap of 2 does not hold';
  end if;
  -- Chips: never a sensitive hub; like_hub names the joined hub 6; people met going on eC.
  select jsonb_agg(f.reasons) into rs from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f;
  if rs::text like '%' || current_setting('test.hs_name') || '%' then
    raise exception 'FAIL 2 a chip names a sensitive hub';
  end if;
  if not exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
                  where f.id = pg_temp.uid('eA')
                    and f.reasons @> jsonb_build_array(jsonb_build_object('code', 'like_hub', 'hub_name', current_setting('test.h6_name')))) then
    raise exception 'FAIL 2 eA has no like_hub chip for the joined hub';
  end if;
  if not exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
                  where f.id = pg_temp.uid('eC') and f.reasons @> '[{"code":"people_met_going","n":1}]') then
    raise exception 'FAIL 2 eC has no people_met_going chip';
  end if;
  if exists (select 1 from public.recs_for_you(47.0, -30.0, 25, 'UTC', 30) f
              where jsonb_array_length(f.reasons) = 0
                 or (select count(*) from jsonb_array_elements(f.reasons) e where e ->> 'code' <> 'from_source') > 2) then
    raise exception 'FAIL 2 a card has no chip or more than two';
  end if;
  -- Dismissing removes a card.
  perform public.rec_dismiss('event', pg_temp.uid('eD2'));
  if pg_temp.pos(pg_temp.fy(47.0, -30.0), 'eD2') is not null then
    raise exception 'FAIL 2 a dismissed plan is still recommended';
  end if;

  -- A 19-year-old never gets the 21+ plan.
  perform pg_temp.act('y');
  v := pg_temp.fy(47.0, -30.0);
  if pg_temp.pos(v, 'e21') is not null then
    raise exception 'FAIL 2 a 19-year-old gets a 21+ plan';
  end if;

  -- The London member: the Atlanta plan never, the plans at P only with a point there.
  perform pg_temp.act('l');
  if pg_temp.pos(pg_temp.fy(51.53, -0.13), 'eAtl') is not null or pg_temp.pos(pg_temp.fy(51.53, -0.13), 'eA') is not null then
    raise exception 'FAIL 2 a London member gets another city''s plan';
  end if;
  if pg_temp.pos(pg_temp.fy(47.0, -30.0), 'eA') is null then
    raise exception 'FAIL 2 a member with a point at P does not get the plans there (rules only)';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Similar plans
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  if pg_temp.err(format('select * from public.recs_similar_events(%L, 47.0, -30.0, 25, %L, 6)', pg_temp.uid('eMod'), 'UTC'))
     <> 'not_found' then
    raise exception 'FAIL 3 Similar plans accepts a moderated anchor';
  end if;
  select coalesce(array_agg(s.id order by s.rank), '{}') into v
    from public.recs_similar_events(pg_temp.uid('eA'), 47.0, -30.0, 25, 'UTC', 10) s;
  if not (pg_temp.uid('eF1') = any (v) or pg_temp.uid('eF2') = any (v) or pg_temp.uid('eF3') = any (v)) then
    raise exception 'FAIL 3 Similar plans misses a similar plan';
  end if;
  if pg_temp.uid('eB') = any (v) or pg_temp.uid('eC') = any (v) or pg_temp.uid('eA') = any (v)
     or pg_temp.uid('eSens') = any (v) or pg_temp.uid('eMod') = any (v) then
    raise exception 'FAIL 3 Similar plans shows the anchor, a plan below the floor, a sensitive or a moderated plan';
  end if;
  perform pg_temp.act('y');
  if pg_temp.err(format('select * from public.recs_similar_events(%L)', pg_temp.uid('e21'))) <> 'not_found' then
    raise exception 'FAIL 3 Similar plans accepts an anchor the caller cannot read';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Hubs you may like
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  perform public.rec_dismiss('hub', pg_temp.uid('h2'));
  select array_agg(h.id) into v from public.recs_hubs(47.0, -30.0, 25, 30) h;
  if pg_temp.uid('h6') = any (v) or pg_temp.uid('hs') = any (v) or pg_temp.uid('hc') = any (v)
     or pg_temp.uid('h7') = any (v) or pg_temp.uid('h2') = any (v) then
    raise exception 'FAIL 4 hubs shows a joined, sensitive, campus-scope, moderated or dismissed hub';
  end if;
  if not (pg_temp.uid('h5') = any (v)) then
    raise exception 'FAIL 4 hubs misses the similar hub with nearby plans';
  end if;
  if not exists (select 1 from public.recs_hubs(47.0, -30.0, 25, 30) h
                  where h.id = pg_temp.uid('h5') and h.reasons @> '[{"code":"nearby_plans","n":3}]') then
    raise exception 'FAIL 4 the nearby_plans chip is wrong';
  end if;
  perform pg_temp.act('y');
  if exists (select 1 from public.recs_hubs(47.0, -30.0, 25, 30) h where h.id = pg_temp.uid('h21')) then
    raise exception 'FAIL 4 a 19-year-old gets a 21+ hub';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Coaches for you
-- ---------------------------------------------------------------------------
do $$
declare
  v uuid[];
begin
  perform pg_temp.act('m');
  select coalesce(array_agg(c.user_id), '{}') into v from public.recs_coaches(47.0, -30.0, 25, 20) c;
  if not (pg_temp.uid('c1') = any (v)) then
    raise exception 'FAIL 5 coaches misses the nearby coach';
  end if;
  if pg_temp.uid('c2') = any (v) or pg_temp.uid('m') = any (v) then
    raise exception 'FAIL 5 coaches shows a blocked coach or the caller';
  end if;
  perform pg_temp.act('c2');
  if exists (select 1 from public.recs_coaches(47.0, -30.0, 25, 20) c where c.user_id = pg_temp.uid('m')) then
    raise exception 'FAIL 5 a blocked member is shown as a coach';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 6. Taste vectors
-- ---------------------------------------------------------------------------
do $$
begin
  perform pg_temp.act('m');
  if pg_temp.err('select count(*) from public.rec_taste') not like '%permission denied%' then
    raise exception 'FAIL 6 a member can read rec_taste';
  end if;
  if pg_temp.err('select count(*) from public.event_embeddings') not like '%permission denied%' then
    raise exception 'FAIL 6 a member can read embeddings';
  end if;
  if pg_temp.err(format('select private.rec_taste_compute(%L)', pg_temp.uid('m'))) not like '%permission denied%' then
    raise exception 'FAIL 6 a member can run the taste computation';
  end if;
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;

do $$
declare
  v_h   uuid[];
  v_e   uuid;
  v_pt  extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_arr real[];
  v_n   integer;
begin
  v_h := array[pg_temp.uid('h1'), pg_temp.uid('h2'), pg_temp.uid('h3')];
  -- Joined hub 1 (dimension 10): weight 1.
  insert into public.hub_embeddings (hub_id, embedding, content_hash) values (v_h[1], pg_temp.vec('{"10":1}'), 'test')
  on conflict (hub_id) do update set embedding = excluded.embedding;
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('t'), v_h[1]), (pg_temp.uid('t'), pg_temp.uid('hs'))
  on conflict do nothing;
  -- Going 90 days ago (dimension 11): 1.5 x 0.5.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[2], pg_temp.uid('h'), 'Recs test going', now() - interval '90 days', now() - interval '90 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"11":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status) values (v_e, pg_temp.uid('t'), 'going');
  -- Checked in an hour ago (dimension 12): 2.5.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[3], pg_temp.uid('h'), 'Recs test checked in', now() - interval '1 hour', now() + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"12":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());
  -- Ignored: a moderated plan (dimension 13) and a plan in a sensitive hub (dimension 14).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_h[2], pg_temp.uid('h'), 'Recs test moderated', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"13":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());
  update public.events set moderation_state = 'hidden', moderated_at = now() where id = v_e;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('hs'), pg_temp.uid('h'), 'Recs test sensitive', now() - interval '5 days', now() - interval '5 days' + interval '1 hour', v_pt)
  returning id into v_e;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_e, pg_temp.vec('{"14":1}'), 'test');
  insert into public.rsvps (event_id, user_id, status, checked_in_at) values (v_e, pg_temp.uid('t'), 'going', now());

  if not (select stale from public.rec_taste where user_id = pg_temp.uid('t')) then
    raise exception 'FAIL 6 joining a hub or an RSVP did not mark the taste stale';
  end if;
  perform private.rec_taste_compute(pg_temp.uid('t'));
  select embedding::extensions.vector::real[], inputs into v_arr, v_n from public.rec_taste where user_id = pg_temp.uid('t');
  -- (1, 0.75, 2.5) normalized: 0.3578, 0.2683, 0.8944.
  if v_n <> 3 or v_arr is null
     or abs(v_arr[10] - 0.3578) > 0.01 or abs(v_arr[11] - 0.2683) > 0.01 or abs(v_arr[12] - 0.8944) > 0.01
     or abs(v_arr[1]) > 0.001 or abs(v_arr[13]) > 0.001 or abs(v_arr[14]) > 0.001 then
    raise exception 'FAIL 6 taste weights or decay are wrong, or a sensitive or moderated input counted';
  end if;
  if (select stale from public.rec_taste where user_id = pg_temp.uid('t')) then
    raise exception 'FAIL 6 the taste is still stale after the refresh';
  end if;
end $$;

set local role authenticated;
do $$
begin
  perform pg_temp.act('t');
  if (public.set_recommendation_prefs(false, null) ->> 'personalize')::boolean is distinct from false
     or (public.my_recommendation_prefs() ->> 'people_suggestions')::boolean is distinct from true then
    raise exception 'FAIL 6 set_recommendation_prefs did not save';
  end if;
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
do $$
begin
  if (select embedding from public.rec_taste where user_id = pg_temp.uid('t')) is not null then
    raise exception 'FAIL 6 personalize off did not clear the taste';
  end if;
  perform private.rec_taste_compute(pg_temp.uid('t'));
  if (select embedding from public.rec_taste where user_id = pg_temp.uid('t')) is not null then
    raise exception 'FAIL 6 a taste was computed with personalize off';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 7. Queue, claim, record, fail (as the owner, i.e. the service role's rights)
-- ---------------------------------------------------------------------------
do $$
declare
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_q     uuid; v_gone uuid; v_same uuid; v_fail uuid;
  v_t     timestamptz := now() + interval '3 days';
  v_hash  text;
  v_text  text;
  v_ids   uuid[];
  v_n     integer;
begin
  -- Insert queues; an edit resets the row.
  insert into public.events (hub_id, host_id, title, description, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test run',
          'Join us at https://example.com/join or www.example.org, mail someone@example.com, call +1 404 555 0100.',
          v_t, v_t + interval '1 hour', v_pt)
  returning id into v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q and priority = 2) then
    raise exception 'FAIL 7 an inserted plan was not queued';
  end if;
  update public.rec_embed_queue set attempts = 3, claimed_at = now(), last_error = 'x' where subject_kind = 'event' and subject_id = v_q;
  update public.events set title = 'Queue test run again' where id = v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q
                    and attempts = 0 and claimed_at is null and last_error is null) then
    raise exception 'FAIL 7 an edit did not reset the queue row';
  end if;
  update public.events set going_count = going_count where id = v_q;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'event' and subject_id = v_q) then
    raise exception 'FAIL 7 queue row lost';
  end if;
  if not exists (select 1 from public.rec_embed_queue where subject_kind = 'hub' and subject_id = pg_temp.uid('h7')) then
    raise exception 'FAIL 7 moderating a hub did not queue it';
  end if;

  -- A cancelled plan with an embedding; a plan whose embedding matches its text.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test gone', v_t, v_t + interval '1 hour', v_pt) returning id into v_gone;
  insert into public.event_embeddings (event_id, embedding, content_hash) values (v_gone, pg_temp.vec('{"5":1}'), 'old');
  update public.events set status = 'cancelled', cancelled_at = now() where id = v_gone;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test same', v_t, v_t + interval '1 hour', v_pt) returning id into v_same;
  insert into public.event_embeddings (event_id, embedding, content_hash)
  values (v_same, pg_temp.vec('{"5":1}'), private.rec_hash(private.rec_text('event', v_same)));
  update public.rec_embed_queue set priority = 0, queued_at = now() - interval '1 day'
   where subject_kind = 'event' and subject_id in (v_q, v_gone, v_same);
  if (select count(*) from public.rec_embed_queue where subject_id in (v_q, v_gone, v_same)) <> 3 then
    raise exception 'FAIL 7 setup: the three queue rows are not there';
  end if;

  select array_agg(c.subject_id), max(c.text) filter (where c.subject_id = v_q),
         max(c.content_hash) filter (where c.subject_id = v_q)
    into v_ids, v_text, v_hash
    from public.recs_embed_claim(24) c;
  if not (v_q = any (v_ids)) or v_gone = any (v_ids) or v_same = any (v_ids) then
    raise exception 'FAIL 7 claim returned the wrong rows';
  end if;
  if v_text not like (select name from public.hubs where id = pg_temp.uid('h1')) || ': Queue test run again. Join us%'
     or v_text ~ '(https?://|www\.|@|555)' then
    raise exception 'FAIL 7 claim text is wrong or keeps a URL, an email or a phone number';
  end if;
  if exists (select 1 from public.rec_embed_queue where subject_id in (v_gone, v_same))
     or exists (select 1 from public.event_embeddings where event_id = v_gone)
     or not exists (select 1 from public.event_embeddings where event_id = v_same) then
    raise exception 'FAIL 7 claim did not drop the ineligible row and its embedding, or the unchanged row';
  end if;
  if not exists (select 1 from public.rec_embed_queue where subject_id = v_q and attempts = 1 and claimed_at is not null) then
    raise exception 'FAIL 7 claim did not lease the row';
  end if;
  if exists (select 1 from public.recs_embed_claim(24) c where c.subject_id = v_q) then
    raise exception 'FAIL 7 a leased row was claimed again';
  end if;

  -- Record: wrong length, not normalized, stale hash, then the real one.
  insert into public.rsvps (event_id, user_id, status) values (v_q, pg_temp.uid('u'), 'going');
  update public.rec_taste set stale = false where user_id = pg_temp.uid('u');
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":1}', 383))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q)
     or (select last_error from public.rec_embed_queue where subject_id = v_q) is distinct from 'bad_vector' then
    raise exception 'FAIL 7 a 383-number vector was stored';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":0.5,"2":0.5}'))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q) then
    raise exception 'FAIL 7 a vector that is not normalized was stored';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', 'stale', 'embedding', pg_temp.vjson('{"1":1}'))));
  if v_n <> 0 or exists (select 1 from public.event_embeddings where event_id = v_q)
     or (select claimed_at from public.rec_embed_queue where subject_id = v_q) is not null then
    raise exception 'FAIL 7 a stale hash was stored or the row was not released';
  end if;
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'event', 'id', v_q, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":0.6,"2":0.8}'))));
  if v_n <> 1 or not exists (select 1 from public.event_embeddings where event_id = v_q and content_hash = v_hash)
     or exists (select 1 from public.rec_embed_queue where subject_id = v_q) then
    raise exception 'FAIL 7 a valid vector was not stored or the queue row stayed';
  end if;
  if abs(private.rec_ip((select embedding from public.event_embeddings where event_id = v_q), pg_temp.vec('{"2":1}')) - 0.8) > 0.01 then
    raise exception 'FAIL 7 the stored vector is not the recorded one';
  end if;
  if not (select stale from public.rec_taste where user_id = pg_temp.uid('u')) then
    raise exception 'FAIL 7 recording did not mark the attendee''s taste stale';
  end if;

  -- Fail: a code only; failed after 5 attempts.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (pg_temp.uid('h1'), pg_temp.uid('h'), 'Queue test fail', v_t, v_t + interval '1 hour', v_pt) returning id into v_fail;
  update public.rec_embed_queue set attempts = 2 where subject_kind = 'event' and subject_id = v_fail;
  perform public.recs_embed_fail('event', v_fail, 'Some Error! with text');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is not null
     or (select last_error from public.rec_embed_queue where subject_id = v_fail) <> 'someerrorwithtext' then
    raise exception 'FAIL 7 fail before 5 attempts';
  end if;
  update public.rec_embed_queue set attempts = 5 where subject_kind = 'event' and subject_id = v_fail;
  perform public.recs_embed_fail('event', v_fail, 'model_error');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is null then
    raise exception 'FAIL 7 not failed after 5 attempts';
  end if;
  -- The backfill retries failed rows.
  perform public.recs_backfill('event');
  if (select failed_at from public.rec_embed_queue where subject_id = v_fail) is not null then
    raise exception 'FAIL 7 the backfill did not retry a failed row';
  end if;
  -- recs_tick and purge_recs run.
  perform public.recs_tick();
  perform public.purge_recs();
end $$;

-- ---------------------------------------------------------------------------
-- 8. Account deletion
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
begin
  perform pg_temp.act('z');
  perform public.set_recommendation_prefs(true, false);
  perform public.rec_dismiss('event', pg_temp.uid('eC'));
  perform pg_temp.act('m');
  perform public.rec_dismiss('person', pg_temp.uid('z'));
  if pg_temp.err(format('select public.recs_backfill()')) <> 'forbidden' then
    raise exception 'FAIL 8 a member ran the backfill';
  end if;
  perform pg_temp.act('z');
  perform public.request_account_deletion('recs test');
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
do $$
begin
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_prefs where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_dismissals where user_id = pg_temp.uid('z'))
     or exists (select 1 from public.rec_dismissals where subject_kind = 'person' and subject_id = pg_temp.uid('z')) then
    raise exception 'FAIL 8 account deletion left recommendation rows';
  end if;
end $$;

select 'PASS recommendations' as result;
rollback;
