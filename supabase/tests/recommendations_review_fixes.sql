-- ============================================================================
-- Staging check for migration 20261231000200_recommendations_review_fixes.sql
-- (migration 68). One transaction: throwaway accounts and synthetic vectors;
-- DO blocks that raise on failure, then ROLLBACK. Prints pass/fail only (no
-- user rows; the accounts are invented).
--
--   1 static: schema_version, RLS and grants on the two counter tables.
--   2 A deleted client's taste is not re-created: by re-embedding a listing
--     they completed a session of, by a booking completing after deletion, by
--     rec_taste_compute; purge_recs removes a leftover row.
--   3 Deleting an account removes other members' "Not interested" in them as
--     a coach.
--   4 Embed cap: every stored embedding counts (re-embeds included); a
--     subject embedded in the last hour is queued at priority 6 or later.
--   5 Weekly actives: a member's first visit of a week counts once.
-- ============================================================================
begin;

create function pg_temp.uid(p_name text) returns uuid language sql stable as $$
  select current_setting('test.' || p_name)::uuid;
$$;
create function pg_temp.act(p_name text) returns void language sql as $$
  select set_config('request.jwt.claims',
                    json_build_object('sub', current_setting('test.' || p_name), 'role', 'authenticated')::text, true);
$$;
create function pg_temp.vjson(p jsonb) returns jsonb language sql immutable as $$
  select jsonb_agg(coalesce((p ->> g::text)::double precision, 0) order by g) from generate_series(1, 384) g;
$$;
create function pg_temp.today() returns integer language sql stable as $$
  select coalesce((select d.embedded from public.rec_embed_daily d where d.day = (now() at time zone 'UTC')::date), 0);
$$;
create function pg_temp.week_active() returns integer language sql stable as $$
  select coalesce((select w.active from public.scorecard_active_weeks w
                    where w.week_start = private.scorecard_week_of(now())), 0);
$$;

-- ---------------------------------------------------------------------------
-- 1. Static
-- ---------------------------------------------------------------------------
do $$
declare
  t text;
begin
  if (select string_to_array(value, '.')::int[] from public.meta where key = 'schema_version') < array[2, 64] then
    raise exception 'FAIL 1 schema_version is older than 2.64';
  end if;
  foreach t in array array['rec_embed_daily', 'scorecard_active_weeks'] loop
    if not coalesce((select c.relrowsecurity from pg_class c where c.oid = ('public.' || t)::regclass), false) then
      raise exception 'FAIL 1 RLS is off on %', t;
    end if;
    if has_table_privilege('anon', 'public.' || t, 'select')
       or has_table_privilege('authenticated', 'public.' || t, 'select')
       or has_table_privilege('authenticated', 'public.' || t, 'insert')
       or has_table_privilege('authenticated', 'public.' || t, 'update') then
      raise exception 'FAIL 1 a client can read or write %', t;
    end if;
  end loop;
  foreach t in array array['private.rec_embedded_recently(public.rec_subject_kind,uuid)',
                           'private.scorecard_count_active()', 'public.purge_recs()', 'public.recs_embed_record(jsonb)'] loop
    if has_function_privilege('authenticated', t, 'execute') or has_function_privilege('anon', t, 'execute') then
      raise exception 'FAIL 1 a client can run %', t;
    end if;
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  -- k: coach. c: client who deletes the account. d: coach-like member m dismissed, deletes. m, a: members.
  v_names text[] := array['k', 'c', 'd', 'm', 'a'];
  v_id    uuid;
  v_tag   text := substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
  v_hub   uuid;
  v_l     uuid;
  v_pt    extensions.geography := extensions.ST_SetSRID(extensions.ST_MakePoint(-30.0, 47.0), 4326)::extensions.geography;
begin
  for i in 1..array_length(v_names, 1) loop
    v_id := gen_random_uuid();
    insert into auth.users (id, instance_id, aud, role, email, email_confirmed_at, created_at, updated_at)
    values (v_id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
            'recsfix-' || v_names[i] || '-' || v_tag || '@example.com', now(), now(), now());
    update public.profile_private set birth_date = date '1990-04-04', home_area_id = null, home_point = null
     where user_id = v_id;
    update public.profiles
       set onboarding_completed_at = now(), first_name = 'Tester', guidelines_accepted_at = now(),
           created_at = now() - interval '3 days'
     where id = v_id;
    perform set_config('test.' || v_names[i], v_id::text, true);
  end loop;

  select h.id into v_hub from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and h.min_age = 18 and h.scope = 'general' and not c.is_sensitive and h.moderation_state is null
   order by h.slug limit 1;
  if v_hub is null then raise exception 'FAIL setup: no general hub'; end if;

  insert into public.coach_profiles (user_id, status, headline, timezone, in_person, service_point, service_radius_km, area_label)
  values (pg_temp.uid('k'), 'active', 'Recs fix coach', 'Europe/London', true, v_pt, 20, 'Test');
  insert into public.coach_listings (coach_id, hub_id, title, delivery, format, duration_minutes, price_minor, currency)
  values (pg_temp.uid('k'), v_hub, 'Recs fix lessons', 'in_person', 'one_on_one', 60, 0, 'usd')
  returning id into v_l;
  perform set_config('test.listing', v_l::text, true);

  -- c: a completed session 10 days ago, and a confirmed one that ended yesterday (deletion keeps both).
  insert into public.bookings (listing_id, coach_id, client_id, starts_at, ends_at, status, title, delivery, format,
                               price_minor, currency, payment_mode, payment_state, policy_version, free_cancel_until,
                               client_request_id, expires_at, confirmed_at, completed_at)
  values (v_l, pg_temp.uid('k'), pg_temp.uid('c'), now() - interval '10 days', now() - interval '10 days' + interval '1 hour',
          'completed', 'Done', 'in_person', 'one_on_one', 0, 'usd', 'none', 'none', '2026-12', now() - interval '11 days',
          gen_random_uuid(), now() - interval '11 days', now() - interval '12 days', now() - interval '8 days');
  insert into public.bookings (listing_id, coach_id, client_id, starts_at, ends_at, status, title, delivery, format,
                               price_minor, currency, payment_mode, payment_state, policy_version, free_cancel_until,
                               client_request_id, expires_at, confirmed_at)
  values (v_l, pg_temp.uid('k'), pg_temp.uid('c'), now() - interval '26 hours', now() - interval '25 hours',
          'confirmed', 'Yesterday', 'in_person', 'one_on_one', 0, 'usd', 'none', 'none', '2026-12', now() - interval '2 days',
          gen_random_uuid(), now() - interval '2 days', now() - interval '3 days')
  returning id into v_id;
  perform set_config('test.booking', v_id::text, true);
end $$;

-- m dismisses d as a coach and c as a person; then c and d delete their accounts.
set local role authenticated;
do $$
begin
  perform pg_temp.act('m');
  perform public.rec_dismiss('coach', pg_temp.uid('d'));
  perform public.rec_dismiss('person', pg_temp.uid('c'));
  perform pg_temp.act('c');
  perform public.request_account_deletion('recs fix test');
  perform pg_temp.act('d');
  perform public.request_account_deletion('recs fix test');
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;

-- ---------------------------------------------------------------------------
-- 2. A deleted client's taste is not re-created
-- ---------------------------------------------------------------------------
do $$
declare
  v_l    uuid := pg_temp.uid('listing');
  v_hash text := private.rec_hash(private.rec_text('coach', pg_temp.uid('listing')));
  v_n    integer;
begin
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 2 deletion left the client''s taste';
  end if;
  if not exists (select 1 from public.bookings where client_id = pg_temp.uid('c') and status = 'completed') then
    raise exception 'FAIL setup: the completed booking did not stay';
  end if;
  -- A: the listing is re-embedded.
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'coach', 'id', v_l, 'hash', v_hash, 'embedding', pg_temp.vjson('{"1":1}'))));
  if v_n <> 1 then
    raise exception 'FAIL 2 the listing embedding was not stored';
  end if;
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 2 re-embedding a listing re-created a deleted client''s taste';
  end if;
  -- B: the booking that ended yesterday completes.
  update public.bookings set status = 'completed', completed_at = now() where id = pg_temp.uid('booking');
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 2 a booking completing re-created a deleted client''s taste';
  end if;
  -- Direct: mark stale and compute.
  perform private.rec_mark_stale(pg_temp.uid('c'));
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 2 rec_mark_stale created a deleted account''s taste';
  end if;
  insert into public.rec_taste (user_id, stale) values (pg_temp.uid('c'), true);
  perform private.rec_taste_compute(pg_temp.uid('c'));
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c')) then
    raise exception 'FAIL 2 rec_taste_compute kept a deleted account''s taste';
  end if;
  -- Purge: a leftover row goes; a live member's stays.
  insert into public.rec_taste (user_id, stale) values (pg_temp.uid('c'), false);
  insert into public.rec_taste (user_id, stale) values (pg_temp.uid('a'), false) on conflict (user_id) do nothing;
  perform public.purge_recs();
  if exists (select 1 from public.rec_taste where user_id = pg_temp.uid('c'))
     or not exists (select 1 from public.rec_taste where user_id = pg_temp.uid('a')) then
    raise exception 'FAIL 2 purge_recs did not remove only the deleted account''s taste';
  end if;
  -- A live client still gets a stale mark.
  perform private.rec_mark_stale(pg_temp.uid('m'));
  if not exists (select 1 from public.rec_taste where user_id = pg_temp.uid('m') and stale) then
    raise exception 'FAIL 2 a live member''s taste was not marked stale';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Others' "Not interested" in a deleted coach
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from public.rec_dismissals where subject_kind in ('coach', 'person')
                                                   and subject_id in (pg_temp.uid('d'), pg_temp.uid('c'))) then
    raise exception 'FAIL 3 account deletion left others'' dismissals of the deleted account';
  end if;
  -- purge_recs removes a leftover one.
  insert into public.rec_dismissals (user_id, subject_kind, subject_id) values (pg_temp.uid('m'), 'coach', pg_temp.uid('d'));
  insert into public.rec_dismissals (user_id, subject_kind, subject_id) values (pg_temp.uid('m'), 'coach', pg_temp.uid('k'));
  perform public.purge_recs();
  if exists (select 1 from public.rec_dismissals where subject_id = pg_temp.uid('d'))
     or not exists (select 1 from public.rec_dismissals where subject_id = pg_temp.uid('k')) then
    raise exception 'FAIL 3 purge_recs did not remove only the dismissal of the deleted coach';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 4. Embed cap and queue order
-- ---------------------------------------------------------------------------
do $$
declare
  v_l      uuid := pg_temp.uid('listing');
  v_before integer := pg_temp.today();
  v_n      integer;
begin
  -- The same subject re-embedded counts each time.
  v_n := public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'coach', 'id', v_l, 'hash', private.rec_hash(private.rec_text('coach', v_l)),
           'embedding', pg_temp.vjson('{"2":1}'))));
  v_n := v_n + public.recs_embed_record(jsonb_build_array(jsonb_build_object(
           'kind', 'coach', 'id', v_l, 'hash', private.rec_hash(private.rec_text('coach', v_l)),
           'embedding', pg_temp.vjson('{"3":1}'))));
  if v_n <> 2 or pg_temp.today() <> v_before + 2 then
    raise exception 'FAIL 4 re-embeds are not counted toward the daily cap';
  end if;
  if private.rec_embedded_today() <> pg_temp.today() then
    raise exception 'FAIL 4 rec_embedded_today does not read the day counter';
  end if;
  -- An edit of a subject embedded in the last hour waits behind new subjects.
  update public.coach_listings set description = 'Recs fix edited ' || gen_random_uuid()::text where id = v_l;
  if coalesce((select q.priority from public.rec_embed_queue q where q.subject_kind = 'coach' and q.subject_id = v_l), 0) < 6 then
    raise exception 'FAIL 4 a recently embedded subject was queued ahead of new ones';
  end if;
  -- One embedded long ago keeps its priority.
  delete from public.rec_embed_queue q where q.subject_kind = 'coach' and q.subject_id = v_l;
  update public.coach_listing_embeddings set embedded_at = now() - interval '2 hours' where listing_id = v_l;
  update public.coach_listings set description = 'Recs fix edited again ' || gen_random_uuid()::text where id = v_l;
  if (select q.priority from public.rec_embed_queue q where q.subject_kind = 'coach' and q.subject_id = v_l) is distinct from 3 then
    raise exception 'FAIL 4 an edit of a subject embedded long ago lost its priority';
  end if;
  -- The cap binds on the counter.
  insert into public.meta (key, value) values ('recs_embed_daily_cap', '1')
    on conflict (key) do update set value = excluded.value;
  if public.recs_embed_dispatch() is not null then
    raise exception 'FAIL 4 the dispatch ran over the daily cap';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 5. Weekly actives
-- ---------------------------------------------------------------------------
do $$
declare
  v_before integer := pg_temp.week_active();
begin
  -- a was last seen in an earlier week.
  update public.profile_private set last_seen_at = now() - interval '8 days' where user_id = pg_temp.uid('a');
  update public.profile_private set last_seen_at = null where user_id = pg_temp.uid('m');
  if pg_temp.week_active() <> v_before then
    raise exception 'FAIL 5 a visit in an earlier week counted in this one';
  end if;
  perform set_config('test.wau_before', v_before::text, true);
end $$;
set local role authenticated;
do $$
begin
  perform pg_temp.act('m');
  perform public.touch_last_seen();
  perform public.touch_last_seen();
  perform pg_temp.act('a');
  perform public.touch_last_seen();
end $$;
reset role;
do $$ begin perform set_config('request.jwt.claims', '{}', true); end $$;
do $$
declare
  v_before integer := current_setting('test.wau_before')::integer;
begin
  if pg_temp.week_active() <> v_before + 2 then
    raise exception 'FAIL 5 first visits of the week were not counted once each';
  end if;
  -- A later visit in the same week does not count again.
  update public.profile_private set last_seen_at = now() + interval '1 minute' where user_id = pg_temp.uid('m');
  if pg_temp.week_active() <> v_before + 2 then
    raise exception 'FAIL 5 a second visit in the week counted again';
  end if;
  if (public.scorecard_week(private.scorecard_week_of(now())) -> 'people' ->> 'wau')::integer <> pg_temp.week_active() then
    raise exception 'FAIL 5 scorecard_week does not read the weekly counter';
  end if;
end $$;

select 'PASS recommendations_review_fixes' as result;
rollback;
