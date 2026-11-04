-- ============================================================================
-- Staging check for migration 20261125000100_places_guards.sql (D-041, hub
-- map ingest guards). One transaction with a fixture tile in the Southern
-- Ocean (no real places there), asserts with DO blocks that raise on failure,
-- then rolls everything back. Prints pass/fail only, never rows.
-- Run as the staging_file of a staging_only migrate.yml run.
--   1 Static: schema_version 2.27; finish_place_tile has only the
--     five-argument signature, service_role only (authenticated is refused);
--     the place_rules_forget_deleted trigger exists and no client can call
--     its function.
--   2 Drop guard (as service_role): a 60-row run finishes; a 41-row run is
--     refused with row_count_drop and nothing is missed, closed or stamped;
--     a 42-row run (exactly 70%) finishes; a 10-row run is refused, then
--     finishes with p_allow_drop; a 5-row run after it is not guarded (the
--     last run saw fewer than 50 rows).
--   3 Deleted rules: deleting a rule removes its id from places.rule_ids
--     (order of the rest kept); signed out, a place whose only rule was
--     deleted no longer shows and a place that still has a specific hub's
--     rule does.
-- ============================================================================
begin;

-- ---------------------------------------------------------------------------
-- Setup (as the migration owner)
-- ---------------------------------------------------------------------------
do $$
declare
  v_t   integer := public.place_tile_id(-62.25, -152.25);
  v_k   text;
  v_r   smallint;
  v_a   uuid;
  v_id  uuid;
begin
  if exists (select 1 from public.place_tiles where id = v_t) then
    raise exception 'setup: the fixture tile already exists';
  end if;
  if exists (select 1 from public.places
              where source_id like 'n92000%'
                 or geom operator(extensions.&&) extensions.ST_MakeEnvelope(-153, -63, -151, -61, 4326)) then
    raise exception 'setup: the fixture area is not empty';
  end if;
  if exists (select 1 from public.place_rules where id between 32101 and 32103) then
    raise exception 'setup: fixture rule ids are taken';
  end if;
  select slug into v_k from public.place_kinds order by slug limit 1;
  select id into v_r from public.place_rules order by id limit 1;
  select h.id into v_a from public.hubs h join public.hub_categories c on c.slug = h.category_slug
   where h.is_active and not c.is_sensitive and h.place_mode = 'specific' order by h.slug limit 1;
  if v_k is null or v_r is null or v_a is null then
    raise exception 'setup: no kind, rule or specific hub';
  end if;

  insert into public.place_tiles (id, status) values (v_t, 'wanted');

  -- Rules: 32101 belongs to no hub, 32102 to the specific hub, 32103 to no hub.
  insert into public.place_rules (id, osm_key, osm_value, kind, verified, rules_version) values
    (32101, 'pgd_test', 'orphan', v_k, true, 1), (32102, 'pgd_test', 'a', v_k, true, 1),
    (32103, 'pgd_test', 'other', v_k, true, 1);
  insert into public.hub_place_rules (hub_id, rule_id) values (v_a, 32102);

  -- Places for the deleted-rule check (outside the drop guard tile).
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9200100001', 'Guard test only orphan', v_k,
          extensions.ST_SetSRID(extensions.ST_MakePoint(-151.80, -61.80), 4326)::extensions.geography,
          true, 'active', 'x', '{32101}')
  returning id into v_id;
  perform set_config('test.p_orphan', v_id::text, true);
  insert into public.places (source, source_id, name, kind, location, is_public, status, attribution, rule_ids)
  values ('osm', 'n9200100002', 'Guard test mixed', v_k,
          extensions.ST_SetSRID(extensions.ST_MakePoint(-151.81, -61.81), 4326)::extensions.geography,
          true, 'active', 'x', '{32103,32101,32102}')
  returning id into v_id;
  perform set_config('test.p_mixed', v_id::text, true);

  perform set_config('test.t', v_t::text, true);
  perform set_config('test.k', v_k, true);
  perform set_config('test.r', v_r::text, true);
end $$;

-- Every finish in this one transaction has the same now(), so finished runs are moved a minute
-- back after each finish to keep "the last finished run" well defined, as it is across real runs.
create function pg_temp.age_runs() returns void language sql as $$
  update public.place_tile_runs
     set finished_at = finished_at - interval '1 minute', started_at = started_at - interval '1 minute'
   where tile_id = current_setting('test.t')::integer and finished_at is not null;
$$;

-- n rows of the drop-guard tile, ids n9200000001 upward.
create function pg_temp.rows(p_n integer) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'source_id', 'n92' || lpad(i::text, 8, '0'), 'name', 'Guard test court ' || i,
           'kind', current_setting('test.k'), 'rule_ids', jsonb_build_array(current_setting('test.r')::integer),
           'lat', -62.30 + i * 0.002, 'lng', -152.30 + i * 0.001) order by i), '[]'::jsonb)
    from generate_series(1, p_n) as i;
$$;

-- ---------------------------------------------------------------------------
-- 1. Static checks
-- ---------------------------------------------------------------------------
do $$
begin
  if (select value from public.meta where key = 'schema_version') <> '2.27' then
    raise exception 'FAIL schema_version is not 2.27';
  end if;
  if to_regprocedure('public.finish_place_tile(integer,text,integer,text)') is not null then
    raise exception 'FAIL the four-argument finish_place_tile still exists';
  end if;
  if to_regprocedure('public.finish_place_tile(integer,text,integer,text,boolean)') is null then
    raise exception 'FAIL the five-argument finish_place_tile is missing';
  end if;
  if (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
       where n.nspname = 'public' and p.proname = 'finish_place_tile') <> 1 then
    raise exception 'FAIL more than one finish_place_tile';
  end if;
  if not (select prosecdef from pg_proc where oid = 'public.finish_place_tile(integer,text,integer,text,boolean)'::regprocedure) then
    raise exception 'FAIL finish_place_tile is not security definer';
  end if;
  if not has_function_privilege('service_role', 'public.finish_place_tile(integer,text,integer,text,boolean)', 'execute')
     or has_function_privilege('anon', 'public.finish_place_tile(integer,text,integer,text,boolean)', 'execute')
     or has_function_privilege('authenticated', 'public.finish_place_tile(integer,text,integer,text,boolean)', 'execute') then
    raise exception 'FAIL finish_place_tile grants';
  end if;
  if has_function_privilege('anon', 'public.place_rules_forget_deleted()', 'execute')
     or has_function_privilege('authenticated', 'public.place_rules_forget_deleted()', 'execute') then
    raise exception 'FAIL a client can call place_rules_forget_deleted';
  end if;
  if not exists (select 1 from pg_trigger
                  where tgrelid = 'public.place_rules'::regclass and tgname = 'place_rules_forget_deleted'
                    and not tgisinternal) then
    raise exception 'FAIL the place_rules_forget_deleted trigger is missing';
  end if;
end $$;

set local role authenticated;
select set_config('request.jwt.claims',
  json_build_object('sub', gen_random_uuid()::text, 'role', 'authenticated')::text, true);
do $$
begin
  begin
    perform public.finish_place_tile(current_setting('test.t')::integer, 'x', 0);
    raise exception 'FAIL authenticated called finish_place_tile';
  exception when insufficient_privilege then null;
  end;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 2. The drop guard
-- ---------------------------------------------------------------------------
set local role service_role;
do $$
declare
  v_t     integer := current_setting('test.t')::integer;
  v_res   jsonb;
  v_ok    boolean;
  v_at    timestamptz;
begin
  -- Run 1: 60 rows.
  perform public.ingest_places(v_t, 'pgd-r1', pg_temp.rows(60));
  v_res := public.finish_place_tile(v_t, 'pgd-r1', 60);
  if (v_res ->> 'seen')::integer <> 60 or (v_res ->> 'missed')::integer <> 0 then
    raise exception 'FAIL run 1: %', v_res;
  end if;
  perform pg_temp.age_runs();
  select osm_run_at into v_at from public.place_tiles where id = v_t;

  -- Run 2: 41 of 60 (68%) is refused before anything changes.
  perform public.ingest_places(v_t, 'pgd-r2', pg_temp.rows(41));
  v_ok := false;
  begin
    perform public.finish_place_tile(v_t, 'pgd-r2', 41);
  exception when check_violation then
    v_ok := sqlerrm = 'row_count_drop';
  end;
  if not v_ok then
    raise exception 'FAIL a 32%% drop was not refused with row_count_drop';
  end if;
  if exists (select 1 from public.places where tile_id = v_t and (missed_runs > 0 or status <> 'active')) then
    raise exception 'FAIL a refused run missed or closed rows';
  end if;
  if (select osm_run_at from public.place_tiles where id = v_t) is distinct from v_at
     or exists (select 1 from public.place_tile_runs where tile_id = v_t and run_id = 'pgd-r2' and finished_at is not null) then
    raise exception 'FAIL a refused run was stamped or finished';
  end if;

  -- Run 3: 42 of 60 (exactly 70%) finishes; 18 rows get one miss, none close.
  perform public.ingest_places(v_t, 'pgd-r3', pg_temp.rows(42));
  v_res := public.finish_place_tile(v_t, 'pgd-r3', 42);
  if (v_res ->> 'previous_seen')::integer <> 60 or (v_res ->> 'seen')::integer <> 42
     or (v_res ->> 'missed')::integer <> 18 or (v_res ->> 'closed')::integer <> 0 then
    raise exception 'FAIL run 3 at 70%%: %', v_res;
  end if;
  perform pg_temp.age_runs();

  -- Run 4: 10 of 42 is refused, then accepted with p_allow_drop (50 missed; the 18 missed
  -- in run 3 close).
  perform public.ingest_places(v_t, 'pgd-r4', pg_temp.rows(10));
  v_ok := false;
  begin
    perform public.finish_place_tile(v_t, 'pgd-r4', 10, 'osm');
  exception when check_violation then
    v_ok := sqlerrm = 'row_count_drop';
  end;
  if not v_ok then
    raise exception 'FAIL run 4 was not refused';
  end if;
  if (select count(*) from public.places where tile_id = v_t and status = 'closed') <> 0 then
    raise exception 'FAIL refused run 4 closed rows';
  end if;
  v_res := public.finish_place_tile(v_t, 'pgd-r4', 10, 'osm', true);
  if (v_res ->> 'seen')::integer <> 10 or (v_res ->> 'missed')::integer <> 50
     or (v_res ->> 'closed')::integer <> 18 then
    raise exception 'FAIL run 4 with allow_drop: %', v_res;
  end if;
  v_res := public.finish_place_tile(v_t, 'pgd-r4', 10, 'osm', false);
  if not coalesce((v_res ->> 'already_finished')::boolean, false) then
    raise exception 'FAIL a finished run was not returned as already finished';
  end if;
  perform pg_temp.age_runs();

  -- Run 5: the last run saw 10 (< 50), so 5 is not guarded.
  perform public.ingest_places(v_t, 'pgd-r5', pg_temp.rows(5));
  v_res := public.finish_place_tile(v_t, 'pgd-r5', 5);
  if (v_res ->> 'seen')::integer <> 5 or (v_res ->> 'previous_seen')::integer <> 10 then
    raise exception 'FAIL run 5 on a small tile: %', v_res;
  end if;
end $$;
reset role;

-- ---------------------------------------------------------------------------
-- 3. Deleted rules leave rule_ids, and the signed-out map
-- ---------------------------------------------------------------------------
delete from public.place_rules where id = 32101;

do $$
begin
  if (select rule_ids from public.places where id = current_setting('test.p_orphan')::uuid) <> '{}'::smallint[] then
    raise exception 'FAIL the deleted rule id stayed on the orphan place';
  end if;
  if (select rule_ids from public.places where id = current_setting('test.p_mixed')::uuid) <> '{32103,32102}'::smallint[] then
    raise exception 'FAIL the mixed place lost the wrong ids or their order';
  end if;
  if exists (select 1 from public.places where 32101 = any (rule_ids)) then
    raise exception 'FAIL a place still holds the deleted rule id';
  end if;
end $$;

set local role anon;
select set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
do $$
declare
  r   jsonb;
  ids text[];
begin
  r := public.places_in_view(-152.0, -62.0, -151.5, -61.5);
  if r -> 'places' is null or jsonb_typeof(r -> 'places') <> 'array' then
    raise exception 'FAIL signed-out view returned no places array';
  end if;
  ids := array(select f.value ->> 0 from jsonb_array_elements(r -> 'places') f);
  if current_setting('test.p_orphan') = any (ids) then
    raise exception 'FAIL signed out still shows a place whose only rule was deleted';
  end if;
  if not (current_setting('test.p_mixed') = any (ids)) then
    raise exception 'FAIL signed out hides a place that has a specific hub''s rule';
  end if;
end $$;
reset role;

select 'places_guards: all assertions passed' as result;

rollback;
