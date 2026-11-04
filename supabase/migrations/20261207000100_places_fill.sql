-- ============================================================================
-- Activity Planet schema v2 — migration 43: Geoapify quick fill for a new
--   place tile (D-042 slice 9, docs/design/auto-coverage/
--   AUTO_COVERAGE_DESIGN.md 5.2 and 7; docs/design/hub-map/HUB_MAP_DESIGN.md
--   3.2). New functions, one new column and two triggers; no existing
--   function is rebuilt. Checks: supabase/tests/places_fill.sql.
--
--   The places-fill Edge Function (supabase/functions/places-fill) does the
--   Geoapify calls with the Supabase secret GEOAPIFY_SERVER_KEY. Without the
--   key it answers {"skipped": "no_key"} and touches nothing (D-042 Keys).
--   Rows go through the existing ingest_places / finish_place_tile with
--   source 'geoapify' (wanted -> filling), so the nightly OSM build merges
--   each one by osm_ref (migration 28) and the tile becomes active.
--
--   What this file does
--     1. place_tiles.geoapify_claimed_at: a fill run's claim on a tile, so
--        two runs (the 15-minute job and the ping on a new tile) never fill
--        the same tile twice. A claim older than 15 minutes is free again.
--     2. places_fill_plan(p_limit default 2), service_role only: claims up to
--        5 tiles that are wanted or filling, have demand >= 1 (a member's
--        home; demand-0 neighbours wait for the nightly OSM run), no OSM run
--        and no Geoapify run yet, highest demand first. Returns them with
--        their bounding boxes, today's Geoapify places budget, the
--        Geoapify categories of active specific hubs (with how many hubs use
--        each) and the place rules and kind order the job matches OSM tags
--        against. No user data.
--     3. places_fill_spend(p_credits), service_role only: takes credits
--        from today's (UTC) collector_budget row 'geoapify_places' only when
--        the total stays within 500 a day (the free plan has 3,000; the rest
--        is for geocoding, design 7). Returns the credits left, or null when
--        refused. places_fill_release(p_tile_id) drops a claim.
--     4. places_fill_supersede(), definer, not client-callable: once a tile
--        has an OSM run, its Geoapify rows that no OSM row merged are
--        deleted (the design keeps Geoapify rows in Postgres only until the
--        tile is active), except rows something depends on: the same
--        exceptions as tile retirement (migration 35: locked fields, a venue,
--        member or moderator hub links, a pending edit, an open report, a
--        row merged into it). The tile's row_count is recomputed.
--     5. places_fill_dispatch(p_reason, p_force), definer, not
--        client-callable: POSTs to <project_url>/functions/v1/places-fill
--        with the collector secret (vault, migration 28) through pg_net when
--        a tile can be filled and today's budget has at least one page left
--        (p_force skips both checks, for the staging check). Returns the
--        pg_net request id, or null.
--     6. places_fill_tick() and pg_cron job places-fill every 15 minutes
--        (minute 7, 22, 37, 52): supersede, then dispatch.
--     7. Triggers place_tiles_fill_ping (insert; update of status or
--        demand): when a tile becomes fillable, one dispatch per
--        transaction, after commit through pg_net, so a new member's tile is
--        filled within about a minute. A failure only raises a warning; a
--        home save never fails because of it.
--     * meta.schema_version 2.39.
--
--   Account deletion: no user-referencing table or column (place_tiles and
--   collector_budget have no user id; Geoapify rows never carry one), so
--   request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_tiles.geoapify_claimed_at
-- ---------------------------------------------------------------------------
alter table public.place_tiles add column if not exists geoapify_claimed_at timestamptz;

comment on column public.place_tiles.geoapify_claimed_at is
  'When a places-fill run (D-042 slice 9) claimed this tile; a claim older than 15 minutes is free again. No user id.';

-- ---------------------------------------------------------------------------
-- 2. places_fill_plan
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_plan(p_limit integer default 2)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_cap   constant integer := 500;
  v_day   date := (now() at time zone 'utc')::date;
  v_used  integer;
  v_tiles jsonb;
begin
  select b.used into v_used from public.collector_budget b
   where b.day = v_day and b.source = 'geoapify_places';
  v_used := coalesce(v_used, 0);

  if v_used + 5 > c_cap then
    v_tiles := '[]'::jsonb;
  else
    with picked as (
      select t.id from public.place_tiles t
       where t.status in ('wanted', 'filling')
         and t.osm_run_at is null and t.geoapify_run_at is null
         and t.demand >= 1
         and (t.geoapify_claimed_at is null or t.geoapify_claimed_at < now() - interval '15 minutes')
       order by t.demand desc, t.created_at, t.id
       limit least(5, greatest(1, coalesce(p_limit, 2)))
       for update skip locked
    ), claimed as (
      update public.place_tiles t set geoapify_claimed_at = now()
        from picked where t.id = picked.id
      returning t.id, t.demand, t.created_at
    )
    select coalesce(jsonb_agg(jsonb_build_object(
             'id', c.id,
             'bbox', jsonb_build_array((c.id % 720) * 0.5 - 180, (c.id / 720) * 0.5 - 90,
                                       (c.id % 720) * 0.5 - 179.5, (c.id / 720) * 0.5 - 89.5))
             order by c.demand desc, c.created_at, c.id), '[]'::jsonb)
      into v_tiles from claimed c;
  end if;

  return jsonb_build_object(
    'tiles', v_tiles,
    'budget', jsonb_build_object('day', v_day, 'cap', c_cap, 'used', v_used, 'left', greatest(0, c_cap - v_used)),
    'categories', case when jsonb_array_length(v_tiles) = 0 then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_array(x.cat, x.n) order by x.n desc, x.cat), '[]'::jsonb)
         from (select c.cat, count(*)::integer as n
                 from public.hubs h cross join lateral unnest(h.geoapify_categories) as c(cat)
                where h.is_active and h.place_mode = 'specific'
                group by c.cat) as x) end,
    'kinds', case when jsonb_array_length(v_tiles) = 0 then '[]'::jsonb else
      (select coalesce(jsonb_agg(k.slug order by k.sort, k.slug), '[]'::jsonb) from public.place_kinds k) end,
    'rules', case when jsonb_array_length(v_tiles) = 0 then '[]'::jsonb else
      (select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'key', r.osm_key, 'value', r.osm_value,
                                                    'extra', r.extra, 'osm_type', r.osm_type, 'kind', r.kind)
                                 order by r.id), '[]'::jsonb)
         from public.place_rules r) end);
end $$;

comment on function public.places_fill_plan(integer) is
  'D-042 slice 9, service_role only (places-fill Edge Function): claims up to p_limit (1 to 5) tiles that are wanted or filling with demand >= 1 and no OSM or Geoapify run, highest demand first, and returns {tiles [{id, bbox [w,s,e,n]}], budget {day, cap 500, used, left}, categories [[geoapify category, hub count]] of active specific hubs, kinds (display order), rules [{id, key, value, extra, osm_type, kind}]}. No tile when fewer than 5 credits are left today. No user data.';

revoke all on function public.places_fill_plan(integer) from public, anon, authenticated;
grant execute on function public.places_fill_plan(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 3. places_fill_spend and places_fill_release
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_spend(p_credits integer)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_cap  constant integer := 500;
  v_day  date := (now() at time zone 'utc')::date;
  v_used integer;
begin
  if p_credits is null or p_credits < 1 or p_credits > 100 then
    raise exception 'credits_invalid' using errcode = 'check_violation';
  end if;
  if p_credits > c_cap then
    return null;
  end if;
  insert into public.collector_budget (day, source, used) values (v_day, 'geoapify_places', p_credits)
  on conflict (day, source) do update set used = public.collector_budget.used + excluded.used
   where public.collector_budget.used + excluded.used <= c_cap
  returning used into v_used;
  if v_used is null then
    return null;
  end if;
  return c_cap - v_used;
end $$;

comment on function public.places_fill_spend(integer) is
  'D-042 slice 9, service_role only: adds p_credits (1 to 100) to today''s (UTC) collector_budget geoapify_places row when the total stays within 500; returns the credits left, or null when refused (nothing is added).';

revoke all on function public.places_fill_spend(integer) from public, anon, authenticated;
grant execute on function public.places_fill_spend(integer) to service_role;

create or replace function public.places_fill_release(p_tile_id integer)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with u as (
    update public.place_tiles set geoapify_claimed_at = null
     where id = p_tile_id and geoapify_claimed_at is not null
    returning 1)
  select exists (select 1 from u);
$$;

comment on function public.places_fill_release(integer) is
  'D-042 slice 9, service_role only: drops a places-fill claim on a tile it could not fill (budget or a Geoapify error), so the next run can take it.';

revoke all on function public.places_fill_release(integer) from public, anon, authenticated;
grant execute on function public.places_fill_release(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 4. places_fill_supersede
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_supersede()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tiles   integer[];
  v_deleted integer := 0;
begin
  with gone as (
    delete from public.places p
     using public.place_tiles t
     where t.id = p.tile_id
       and t.osm_run_at is not null
       and p.source = 'geoapify'
       and p.locked_fields = '{}'
       and not exists (select 1 from public.venues v where v.place_ref = p.id)
       and not exists (select 1 from public.place_hubs ph where ph.place_id = p.id and ph.via in ('member', 'moderator'))
       and not exists (select 1 from public.place_edits pe where pe.place_id = p.id and pe.status = 'pending')
       and not exists (select 1 from public.place_reports pr where pr.place_id = p.id and pr.status = 'open')
       and not exists (select 1 from public.places m where m.merged_into = p.id)
    returning p.tile_id
  )
  select coalesce(array_agg(distinct g.tile_id), '{}'), count(*) into v_tiles, v_deleted from gone g;

  if cardinality(v_tiles) > 0 then
    update public.place_tiles t
       set row_count = (select count(*) from public.places p
                         where p.tile_id = t.id and p.status = 'active' and p.is_public)
     where t.id = any (v_tiles);
  end if;
  return v_deleted;
end $$;

comment on function public.places_fill_supersede() is
  'D-042 slice 9 (pg_cron places-fill): deletes the Geoapify rows of tiles that have an OSM run (the OSM build merged the ones it matched by osm_ref), except rows with locked fields, a venue, member or moderator hub links, a pending edit, an open report or a row merged into them (the retirement exceptions). Recomputes row_count. Returns the rows deleted.';

revoke all on function public.places_fill_supersede() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 5. places_fill_dispatch
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_dispatch(p_reason text default 'cron', p_force boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base   text := public.project_url();
  v_secret text;
  v_used   integer;
begin
  if v_base is null then
    raise notice 'places-fill: project_url not set; nothing sent';
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'collector_secret' limit 1;
  end if;
  if v_secret is null then
    raise notice 'places-fill: collector secret not configured; nothing sent';
    return null;
  end if;
  if not coalesce(p_force, false) then
    if not exists (select 1 from public.place_tiles t
                    where t.status in ('wanted', 'filling')
                      and t.osm_run_at is null and t.geoapify_run_at is null
                      and t.demand >= 1
                      and (t.geoapify_claimed_at is null or t.geoapify_claimed_at < now() - interval '15 minutes')) then
      return null;
    end if;
    select b.used into v_used from public.collector_budget b
     where b.day = (now() at time zone 'utc')::date and b.source = 'geoapify_places';
    if coalesce(v_used, 0) + 5 > 500 then
      return null;
    end if;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/places-fill',
    body := jsonb_build_object('reason', left(coalesce(p_reason, 'cron'), 20)),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-collector-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

comment on function public.places_fill_dispatch(text, boolean) is
  'D-042 slice 9: asks the places-fill Edge Function (pg_net, collector secret) to fill tiles when one is fillable and today''s Geoapify budget has a page left (p_force skips both checks). Returns the pg_net request id or null. Not client-callable.';

revoke all on function public.places_fill_dispatch(text, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 6. places_fill_tick and the 15-minute job
-- ---------------------------------------------------------------------------
create or replace function public.places_fill_tick()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_deleted integer;
begin
  v_deleted := public.places_fill_supersede();
  return jsonb_build_object('superseded', v_deleted, 'request', public.places_fill_dispatch('cron', false));
end $$;

comment on function public.places_fill_tick() is
  'D-042 slice 9, pg_cron places-fill every 15 minutes: places_fill_supersede, then places_fill_dispatch.';

revoke all on function public.places_fill_tick() from public, anon, authenticated;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; places-fill not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'places-fill') then
    perform cron.unschedule('places-fill');
  end if;
  perform cron.schedule('places-fill', '7,22,37,52 * * * *', 'select public.places_fill_tick()');
end $$;

-- ---------------------------------------------------------------------------
-- 7. Ping when a tile becomes fillable (once per transaction)
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_fill_ping()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(current_setting('ap.places_fill_pinged', true), '') = '1' then
    return null;
  end if;
  perform set_config('ap.places_fill_pinged', '1', true);
  begin
    perform public.places_fill_dispatch('tile', false);
  exception when others then
    raise warning 'places-fill ping failed: %', sqlstate;
  end;
  return null;
end $$;

comment on function public.place_tiles_fill_ping() is
  'D-042 slice 9: row trigger on place_tiles; when a tile becomes fillable (wanted or filling, demand >= 1, no OSM or Geoapify run), calls places_fill_dispatch once per transaction. Never fails the write.';

revoke all on function public.place_tiles_fill_ping() from public, anon, authenticated;

drop trigger if exists place_tiles_fill_ping_insert on public.place_tiles;
create trigger place_tiles_fill_ping_insert after insert on public.place_tiles
  for each row
  when (new.status in ('wanted', 'filling') and new.demand >= 1
        and new.osm_run_at is null and new.geoapify_run_at is null)
  execute function public.place_tiles_fill_ping();

drop trigger if exists place_tiles_fill_ping_update on public.place_tiles;
create trigger place_tiles_fill_ping_update after update of status, demand on public.place_tiles
  for each row
  when (new.status in ('wanted', 'filling') and new.demand >= 1
        and new.osm_run_at is null and new.geoapify_run_at is null
        and (new.demand > old.demand or new.status is distinct from old.status))
  execute function public.place_tiles_fill_ping();

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.39')
  on conflict (key) do update set value = excluded.value, updated_at = now();
