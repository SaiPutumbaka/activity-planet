-- ============================================================================
-- Staging check for migration 20261231000100_recommendations.sql (migration 67):
-- recs_people, "People you might click with" (RECS_DESIGN.md section 7). One
-- transaction: throwaway accounts, DO blocks that raise on failure, then
-- ROLLBACK. Prints pass/fail only (the accounts are invented).
--
--   Only shared context counts: met, the same chapter, going to the same plan.
--   Hub co-membership alone gives nothing; a sensitive chapter or plan gives
--   nothing. Opt-out on either side; blocks either way; mutes; a recent DM.
--   No score, hub or location in the result.
-- ============================================================================
begin;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create function pg_temp.people() returns uuid[] language sql as $$
  select coalesce(array_agg(r.user_id order by r.rank), '{}') from public.recs_people(30) r;
$$;
create function pg_temp.pos(p_arr uuid[], p_name text) returns integer language sql as $$
  select array_position(p_arr, pg_temp.uid(p_name));
$$;

-- ---------------------------------------------------------------------------
-- Static: the result carries no score, hub, RSVP or location
-- ---------------------------------------------------------------------------
do $$
declare
  v text := pg_get_function_result('public.recs_people(integer)'::regprocedure);
begin
  if v ~* '(score|sim|hub|rsvp|lat|lng|location|distance|point|band)' then
    raise exception 'FAIL static: recs_people returns %', v;
  end if;
  if (select prosecdef from pg_proc where oid = 'public.recs_people(integer)'::regprocedure)
     or not (select prosecdef from pg_proc where oid = 'private.rec_people_scores(uuid[])'::regprocedure) then
    raise exception 'FAIL static: recs_people must be invoker and its scorer definer';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- a: the caller. met1: met a. ch1: same chapter. go1: going to the same plan. hub1: same hub
  -- only. sch: same sensitive chapter. splan: going to the same sensitive plan. opt: same chapter,
  -- opted out. blk1: same chapter, blocked a. blk2: same chapter, blocked by a. mut: same chapter,
  -- muted by a. dm: same chapter, recent DM. h: host.
  v_names text[] := array['a', 'met1', 'ch1', 'go1', 'hub1', 'sch', 'splan', 'opt', 'blk1', 'blk2', 'mut', 'dm', 'h'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_hub   uuid;
  v_sens  uuid;
  v_area  uuid;
  v_ch    uuid;
  v_sch   uuid;
  v_up    uuid;
  v_sup   uuid;
  v_past  uuid;
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
  v_t     timestamptz := now() + interval '3 days';
  n       text;
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recsp-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04' where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  select h.id into v_sens from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and c.is_sensitive and h.moderation_state is null order by h.slug limit 1;
  if v_hub is null or v_sens is null then raise exception 'FAIL setup: no general or sensitive hub'; end if;
  perform set_config('test.hub_name', (select name from public.hubs where id = v_hub), true);

  insert into public.areas (slug, name, kind, center)
  values ('recsp-' || v_tag, 'Recs test area', 'neighborhood', v_pt) returning id into v_area;
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_hub, v_area, 'recsp-' || v_tag, 'Recs test chapter') returning id into v_ch;
  insert into public.hub_chapters (hub_id, area_id, slug, name)
  values (v_sens, v_area, 'recsp-s-' || v_tag, 'Recs test sensitive chapter') returning id into v_sch;

  -- The same chapter: ch1, opt, blk1, blk2, mut, dm; the sensitive chapter: sch.
  insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid('a'), v_ch, 'member'), (pg_temp.uid('a'), v_sch, 'member');
  foreach n in array array['ch1', 'opt', 'blk1', 'blk2', 'mut', 'dm'] loop
    insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid(n), v_ch, 'member');
  end loop;
  insert into public.chapter_members (user_id, chapter_id, role) values (pg_temp.uid('sch'), v_sch, 'member');
  -- The same hub only.
  insert into public.hub_members (user_id, hub_id) values (pg_temp.uid('a'), v_hub), (pg_temp.uid('hub1'), v_hub)
  on conflict do nothing;

  -- Going to the same upcoming plan (go1), and to the same sensitive plan (splan).
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('h'), 'Recs people upcoming', v_t, v_t + interval '2 hours', v_pt) returning id into v_up;
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_sens, pg_temp.uid('h'), 'Recs people sensitive', v_t, v_t + interval '2 hours', v_pt) returning id into v_sup;
  insert into public.rsvps (event_id, user_id, status) values
    (v_up, pg_temp.uid('a'), 'going'), (v_up, pg_temp.uid('go1'), 'going'),
    (v_sup, pg_temp.uid('a'), 'going'), (v_sup, pg_temp.uid('splan'), 'going');

  -- Met: mutual picks at a past plan.
  insert into public.events (hub_id, host_id, title, starts_at, ends_at, approx_point)
  values (v_hub, pg_temp.uid('h'), 'Recs people past', now() - interval '10 days', now() - interval '10 days' + interval '2 hours', v_pt)
  returning id into v_past;
  insert into public.event_meets (event_id, user_id, met_user_id) values
    (v_past, pg_temp.uid('a'), pg_temp.uid('met1')), (v_past, pg_temp.uid('met1'), pg_temp.uid('a'));

  -- Opt-out, blocks, a mute and a recent DM.
  insert into public.rec_prefs (user_id, people_suggestions) values (pg_temp.uid('opt'), false);
  insert into public.blocks (blocker_id, blocked_id) values (pg_temp.uid('blk1'), pg_temp.uid('a')), (pg_temp.uid('a'), pg_temp.uid('blk2'));
  insert into public.mutes (muter_id, muted_id) values (pg_temp.uid('a'), pg_temp.uid('mut'));
  insert into public.conversations (kind, dm_key, last_message_at)
  values ('dm', private.chat_dm_key(pg_temp.uid('a'), pg_temp.uid('dm')), now() - interval '2 days');
end $$;

-- ---------------------------------------------------------------------------
-- The caller's row
-- ---------------------------------------------------------------------------
set local role authenticated;
do $$
declare
  v uuid[];
  n text;
  r jsonb;
begin
  perform pg_temp.act('a');
  v := pg_temp.people();
  foreach n in array array['met1', 'go1', 'ch1'] loop
    if pg_temp.pos(v, n) is null then
      raise exception 'FAIL people misses the shared-context person %', n;
    end if;
  end loop;
  if not (pg_temp.pos(v, 'met1') < pg_temp.pos(v, 'go1') and pg_temp.pos(v, 'go1') < pg_temp.pos(v, 'ch1')) then
    raise exception 'FAIL people not ordered by context strength (met, same plan, chapter)';
  end if;
  foreach n in array array['hub1', 'sch', 'splan', 'opt', 'blk1', 'blk2', 'mut', 'dm', 'a'] loop
    if pg_temp.pos(v, n) is not null then
      raise exception 'FAIL people suggests % (no shared context, sensitive, opted out, blocked, muted, DM or self)', n;
    end if;
  end loop;
  -- Reasons: only the people codes, never a hub name.
  select jsonb_agg(p.reasons) into r from public.recs_people(30) p;
  if exists (select 1 from jsonb_array_elements(r) x, jsonb_array_elements(x) e
              where e ->> 'code' not in ('went_to_same', 'same_chapter', 'going_to_same'))
     or r::text like '%' || current_setting('test.hub_name') || '%' then
    raise exception 'FAIL people reasons carry another code or a hub name';
  end if;
  if not exists (select 1 from public.recs_people(30) p
                  where p.user_id = pg_temp.uid('ch1') and p.reasons @> '[{"code":"same_chapter","chapter_name":"Recs test chapter"}]')
     or not exists (select 1 from public.recs_people(30) p
                     where p.user_id = pg_temp.uid('go1') and p.reasons @> '[{"code":"going_to_same","title":"Recs people upcoming"}]')
     or not exists (select 1 from public.recs_people(30) p
                     where p.user_id = pg_temp.uid('met1') and p.reasons @> '[{"code":"went_to_same","title":"Recs people past"}]') then
    raise exception 'FAIL people reasons are wrong';
  end if;
  -- Dismissing a person removes them.
  perform public.rec_dismiss('person', pg_temp.uid('ch1'));
  if pg_temp.pos(pg_temp.people(), 'ch1') is not null then
    raise exception 'FAIL people shows a dismissed person';
  end if;

  -- The other side opts out: ch1's view of a; then a opts out: no row, and a is in nobody's row.
  perform pg_temp.act('go1');
  if pg_temp.pos(pg_temp.people(), 'a') is null then
    raise exception 'FAIL people: go1 does not get a';
  end if;
  perform pg_temp.act('a');
  perform public.set_recommendation_prefs(null, false);
  if coalesce(array_length(pg_temp.people(), 1), 0) <> 0 then
    raise exception 'FAIL people: a member who opted out still gets a row';
  end if;
  perform pg_temp.act('go1');
  if pg_temp.pos(pg_temp.people(), 'a') is not null then
    raise exception 'FAIL people: a member who opted out is still suggested';
  end if;
end $$;

select 'PASS recommendations_people' as result;
rollback;
