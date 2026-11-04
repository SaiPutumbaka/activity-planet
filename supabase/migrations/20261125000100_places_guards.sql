-- ============================================================================
-- Activity Planet schema v2 — migration 31: hub map ingest guards (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md 3.1; fix forward of migrations 28
--   and 30). Checks: supabase/tests/places_guards.sql (schema_version 2.27).
--
--   What this file does
--     1. finish_place_tile is rebuilt from its migration 28 body
--        (20261123000100_places_ingest.sql; no later migration changed it)
--        with one new argument, p_allow_drop boolean default false, and one
--        new check before any row is touched: when the tile's last finished
--        run of that source saw 50 or more rows and this run reports fewer
--        than 70% of them, it raises row_count_drop and nothing is missed,
--        closed or stamped. Before, the 30% drop check lived only in the
--        extract job, which skipped it for tiles outside the tiles queue
--        (force, or not due) and ran its second check after the rows had
--        already been missed and closed. The old four-argument signature is
--        dropped so a call by name stays unambiguous; a call without
--        p_allow_drop resolves to the new function. Grants unchanged:
--        service_role only.
--     2. place_rules_forget_deleted: an AFTER DELETE statement trigger on
--        place_rules (transition table) removes the deleted ids from
--        places.rule_ids. The rules seed deletes rules it no longer
--        generates; before, those ids stayed in rule_ids, and the
--        signed-out map's complement test (places_in_view, "not
--        rule_ids <@ the rules no specific hub uses") kept showing a place
--        whose only rule was gone. Now rule_ids only ever holds known rule
--        ids, as places_in_view assumes. The trigger function is definer,
--        not callable by any client.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. finish_place_tile with the drop guard
-- ---------------------------------------------------------------------------
drop function if exists public.finish_place_tile(integer, text, integer, text);

create or replace function public.finish_place_tile(
  p_tile_id integer,
  p_run_id  text,
  p_count   integer,
  p_source  text default 'osm',
  p_allow_drop boolean default false)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_src    public.place_source;
  v_tile   public.place_tiles%rowtype;
  v_run    public.place_tile_runs%rowtype;
  v_prev   integer;
  v_last   integer;
  v_missed integer;
  v_closed integer;
  v_seen   integer;
  v_active integer;
  v_rows   integer;
  v_result jsonb;
begin
  if p_source is null or p_source not in ('osm', 'geoapify') then
    raise exception 'source_invalid' using errcode = 'check_violation';
  end if;
  v_src := p_source::public.place_source;
  if p_run_id is null or p_run_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$' then
    raise exception 'run_id_invalid' using errcode = 'check_violation';
  end if;
  if p_count is null or p_count < 0 then
    raise exception 'count_invalid' using errcode = 'check_violation';
  end if;

  select * into v_tile from public.place_tiles where id = p_tile_id for update;
  if not found then
    raise exception 'tile_unknown' using errcode = 'P0002';
  end if;

  select * into v_run from public.place_tile_runs
   where tile_id = p_tile_id and source = v_src and run_id = p_run_id for update;
  if not found then
    if p_count <> 0 then
      raise exception 'run_unknown' using errcode = 'P0002';
    end if;
    insert into public.place_tile_runs (tile_id, source, run_id) values (p_tile_id, v_src, p_run_id)
    returning * into v_run;
  end if;
  if v_run.finished_at is not null then
    return v_run.stats || jsonb_build_object('already_finished', true);
  end if;
  if v_run.received <> p_count then
    raise exception 'count_mismatch' using errcode = 'check_violation',
      detail = format('The run received %s rows; the job reported %s.', v_run.received, p_count);
  end if;

  select count(*) into v_prev from public.places
   where tile_id = p_tile_id and source = v_src and status = 'active';
  -- The previous finished run's seen count, for the job's 30% drop check.
  select (r.stats ->> 'seen')::integer into v_last from public.place_tile_runs r
   where r.tile_id = p_tile_id and r.source = v_src and r.finished_at is not null
   order by r.finished_at desc, r.started_at desc limit 1;
  if p_count = 0 and v_prev > 0 then
    raise exception 'empty_run' using errcode = 'check_violation',
      hint = 'An empty run on a tile with places is treated as a broken extract; nothing was closed.';
  end if;
  -- The 30% drop check (design 3.1), before any row is touched: a tile whose
  -- last finished run saw 50 or more rows and now reports fewer than 70% of
  -- them is refused, so a broken extract never adds misses or closes rows.
  if v_last >= 50 and p_count < 0.7 * v_last and not coalesce(p_allow_drop, false) then
    raise exception 'row_count_drop' using errcode = 'check_violation',
      detail = format('The last run saw %s rows; this run reported %s.', v_last, p_count),
      hint = 'More than a 30% drop is treated as a broken extract; nothing was missed or closed. Finish with allow_drop to accept it.';
  end if;

  -- One more miss for every active row of this source and tile the run did not see;
  -- two in a row closes it, unless a moderator locked its status.
  with m as (
    update public.places
       set missed_runs = least(missed_runs + 1, 100),
           status = case when missed_runs + 1 >= 2 and not ('closed' = any (locked_fields))
                         then 'closed'::public.place_status else status end
     where tile_id = p_tile_id and source = v_src and status = 'active'
       and last_run_id is distinct from p_run_id
    returning status
  )
  select count(*), count(*) filter (where status = 'closed') into v_missed, v_closed from m;

  select count(*) into v_seen from public.places
   where tile_id = p_tile_id and source = v_src and last_run_id = p_run_id;
  select count(*) into v_active from public.places
   where tile_id = p_tile_id and source = v_src and status = 'active';
  select count(*) into v_rows from public.places
   where tile_id = p_tile_id and status = 'active' and is_public;

  update public.place_tiles
     set row_count       = v_rows,
         osm_run_at      = case when v_src = 'osm' then now() else osm_run_at end,
         geoapify_run_at = case when v_src = 'geoapify' then now() else geoapify_run_at end,
         status          = case when v_src = 'osm' and status in ('wanted', 'filling') then 'active'::public.place_tile_status
                                when v_src = 'geoapify' and status = 'wanted' then 'filling'::public.place_tile_status
                                else status end
   where id = p_tile_id;

  v_result := jsonb_build_object(
    'tile_id', p_tile_id, 'run_id', p_run_id, 'source', p_source, 'count', p_count,
    'seen', v_seen, 'missed', v_missed, 'closed', v_closed,
    'previous_seen', v_last, 'active', v_active, 'row_count', v_rows,
    'inserted', coalesce((v_run.stats ->> 'inserted')::integer, 0),
    'updated', coalesce((v_run.stats ->> 'updated')::integer, 0),
    'merged', coalesce((v_run.stats ->> 'merged')::integer, 0));
  update public.place_tile_runs
     set finished_at = now(), stats = v_result
   where tile_id = p_tile_id and source = v_src and run_id = p_run_id;

  -- Keep the latest 10 finished runs per tile and source.
  delete from public.place_tile_runs r
   where r.tile_id = p_tile_id and r.source = v_src and r.finished_at is not null
     and r.run_id not in (select k.run_id from public.place_tile_runs k
                           where k.tile_id = p_tile_id and k.source = v_src and k.finished_at is not null
                           order by k.finished_at desc, k.started_at desc limit 10);

  return v_result;
end $$;

comment on function public.finish_place_tile(integer, text, integer, text, boolean) is
  'Collector run end (D-041 slice 4), service_role only: checks the reported count against the rows the run received (count_mismatch), refuses an empty run on a tile with places (empty_run), refuses a count under 70% of the last finished run''s seen count when that was 50 or more (row_count_drop, unless p_allow_drop), adds a miss to every active row of that source and tile the run did not see and closes rows at two misses in a row (not when closed is locked), stamps the tile (run time, row_count, status) and returns the counts (previous_seen, the last run''s count, for the 30% drop check). Repeat calls for a finished run return the stored result.';

revoke all on function public.finish_place_tile(integer, text, integer, text, boolean) from public, anon, authenticated;
grant execute on function public.finish_place_tile(integer, text, integer, text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- 2. Deleted rules leave places.rule_ids
-- ---------------------------------------------------------------------------
create or replace function public.place_rules_forget_deleted()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_ids smallint[];
begin
  select coalesce(array_agg(d.id), '{}') into v_ids from deleted_rules d;
  if cardinality(v_ids) > 0 then
    update public.places p
       set rule_ids = array(select x from unnest(p.rule_ids) with ordinality u(x, o)
                             where x <> all (v_ids) order by o)
     where p.rule_ids && v_ids;
  end if;
  return null;
end $$;

comment on function public.place_rules_forget_deleted() is
  'Statement trigger on place_rules (D-041): removes deleted rule ids from places.rule_ids, so a place whose rules are all gone matches no hub (the signed-out map tests the complement of the specific hubs'' rules).';

revoke all on function public.place_rules_forget_deleted() from public, anon, authenticated;

drop trigger if exists place_rules_forget_deleted on public.place_rules;
create trigger place_rules_forget_deleted after delete on public.place_rules
  referencing old table as deleted_rules
  for each statement execute function public.place_rules_forget_deleted();

-- ---------------------------------------------------------------------------
-- 3. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.27')
  on conflict (key) do update set value = excluded.value, updated_at = now();
