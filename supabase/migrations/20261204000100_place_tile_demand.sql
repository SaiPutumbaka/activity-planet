-- ============================================================================
-- Activity Planet schema v2 — migration 40: place tile demand from home saves
--   (D-042 slice 1, docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md
--   section 10). The one rebuilt function, collector_note_home_point, starts
--   from its latest body (migration 25, 20261120000100_location_region_limits.sql)
--   and changes only the lines marked "Migration 40".
--   Checks: supabase/tests/place_tile_demand.sql.
--
--   What this file does
--     1. profile_private.home_tile_noted_at: owner-only stamp of when this
--        person's home save last counted on a place tile's demand. At most one
--        count per person per 24 hours. Deleted with the row on account
--        deletion (delete-account removes profile_private whole). No client
--        UPDATE grant.
--     2. place_tiles times rounded to the UTC day on every write (created_at,
--        updated_at), like collector_regions (migration 25): a tile row cannot
--        be matched to one person's onboarding or home change. The per-row
--        set_updated_at trigger is replaced by the rounding trigger; existing
--        rows are rounded.
--     3. place_tile_note_home(point, old_point), internal, called by
--        collector_note_home_point (so by set_home_location, set_home_area
--        and complete_onboarding):
--        - the home's 0.5-degree tile: a new row is wanted with demand 1; an
--          existing row gets demand + 1 (once per person per 24 hours, and not
--          when the previous home was in the same tile), last_member_at the
--          UTC day, retired becomes wanted, idle wakes (active after an OSM
--          run, else filling) as in retire_place_tiles;
--        - each neighbouring tile within 10 km of the home: added as wanted
--          with demand 0 when it has no row (existing neighbours unchanged);
--        - at most 50 new tile rows per UTC day worldwide, counted in
--          collector_budget (source place_tiles_new, a number per day, no
--          user id); the home tile goes before its neighbours. A home whose
--          tile is skipped by the cap is not stamped, and the nightly job (4)
--          adds the tile on a later day.
--        Never stores who, the exact point or the time of day.
--     4. place_tiles_note_member_homes(): pg_cron nightly
--        (note-member-home-tiles, 04:13 UTC, before retire-place-tiles at
--        04:23): adds the missing tiles of active members' homes (home_point,
--        else the home area centre; seen in 90 days, the same rule as
--        retire_place_tiles) as wanted, demand = the number of such homes,
--        most homes first, within what is left of the day's 50. Run once here
--        as the backfill. Returns counts only.
--     5. collector_note_home_point (migration 25 body): calls
--        place_tile_note_home first; at most 10 new collector regions per UTC
--        day across everyone (was 100). Nothing else changes.
--     * meta.schema_version 2.36.
--
--   Account deletion: no new user-referencing table; the new column is on
--   profile_private, which account deletion removes whole. place_tiles and
--   collector_budget hold no user id. request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Per-person stamp (owner-only)
-- ---------------------------------------------------------------------------
alter table public.profile_private
  add column if not exists home_tile_noted_at timestamptz;

comment on column public.profile_private.home_tile_noted_at is
  'When this person''s home save last counted on a place tile''s demand (D-042). place_tile_note_home counts at most once per 24 hours per person. Owner-only.';

revoke update (home_tile_noted_at) on public.profile_private from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. place_tiles times rounded to the UTC day
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_round_times()
returns trigger language plpgsql set search_path = '' as $$
begin
  if tg_op = 'UPDATE' then
    new.updated_at := now();
  end if;
  new.created_at := date_trunc('day', new.created_at, 'UTC');
  new.updated_at := date_trunc('day', new.updated_at, 'UTC');
  return new;
end $$;
comment on function public.place_tiles_round_times() is
  'Trigger: rounds place_tiles.created_at and updated_at to the UTC day on every insert and update (D-042: a tile is a place and a count, never linkable to one person''s save time). Sets updated_at on update.';

drop trigger if exists place_tiles_set_updated_at on public.place_tiles;
drop trigger if exists place_tiles_round_times on public.place_tiles;
create trigger place_tiles_round_times
  before insert or update on public.place_tiles
  for each row execute function public.place_tiles_round_times();

update public.place_tiles
   set created_at = date_trunc('day', created_at, 'UTC')
 where created_at <> date_trunc('day', created_at, 'UTC')
    or updated_at <> date_trunc('day', updated_at, 'UTC');

comment on table public.place_tiles is
  'Hub map regions (D-041, design 3.5): one 0.5-degree tile per row with its lifecycle status, a demand counter and run stamps. Rows are added when a member saves a home (place_tile_note_home, at most 50 new rows per UTC day) and by the nightly note-member-home-tiles job (D-042). No user id; created_at and updated_at are rounded to the UTC day. Service role writes; moderators read.';
comment on column public.place_tiles.demand is
  'Home saves counted on this tile (at most one per person per 24 hours; 0 for a tile added only as a neighbour within 10 km of a home). A count, never who.';

-- ---------------------------------------------------------------------------
-- 3. place_tile_note_home
-- ---------------------------------------------------------------------------
create or replace function public.place_tile_note_home(
  p_point extensions.geography, p_old_point extensions.geography default null)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  c_new_cap  constant integer := 50;
  c_edge_m   constant double precision := 10000;
  v_day      date := (now() at time zone 'UTC')::date;
  v_today    timestamptz := date_trunc('day', now(), 'UTC');
  v_tile     integer;
  v_old_tile integer;
  v_noted_at timestamptz;
  v_count    boolean;
  v_row      integer;
  v_col      integer;
  v_n        integer;
  v_used     integer;
  v_added    integer := 0;
  v_home_ok  boolean := false;
  dr         integer;
  dc         integer;
begin
  if p_point is null then
    return 0;
  end if;
  perform pg_advisory_xact_lock(hashtext('public.place_tiles'));

  v_tile := public.place_tile_id_of(p_point);
  if p_old_point is not null then
    v_old_tile := public.place_tile_id_of(p_old_point);
  end if;
  if uid is not null then
    select pp.home_tile_noted_at into v_noted_at
      from public.profile_private pp where pp.user_id = uid;
  end if;
  v_count := v_old_tile is distinct from v_tile
             and (v_noted_at is null or v_noted_at <= now() - interval '24 hours');

  select coalesce(b.used, 0) into v_used
    from public.collector_budget b where b.day = v_day and b.source = 'place_tiles_new';
  v_used := coalesce(v_used, 0);

  -- The home tile.
  update public.place_tiles t
     set demand         = t.demand + case when v_count then 1 else 0 end,
         last_member_at = v_today,
         status         = case t.status
                            when 'retired' then 'wanted'::public.place_tile_status
                            when 'idle' then case when t.osm_run_at is not null then 'active'::public.place_tile_status
                                                  else 'filling'::public.place_tile_status end
                            else t.status end,
         idle_since     = case when t.status in ('retired', 'idle') then null else t.idle_since end
   where t.id = v_tile;
  if found then
    v_home_ok := true;
  elsif v_used < c_new_cap then
    insert into public.place_tiles (id, status, demand, last_member_at)
    values (v_tile, 'wanted', case when v_count then 1 else 0 end, v_today);
    v_used := v_used + 1;
    v_added := v_added + 1;
    v_home_ok := true;
  end if;

  -- Neighbours within 10 km of the home: added wanted with demand 0 if new.
  v_row := v_tile / 720;
  v_col := v_tile % 720;
  for dr in -1 .. 1 loop
    for dc in -1 .. 1 loop
      continue when (dr = 0 and dc = 0) or v_row + dr < 0 or v_row + dr > 359;
      exit when v_used >= c_new_cap;
      v_n := (v_row + dr) * 720 + ((v_col + dc + 720) % 720);
      continue when v_n = v_tile;
      continue when exists (select 1 from public.place_tiles t where t.id = v_n);
      continue when not extensions.ST_DWithin(public.place_tile_bbox(v_n)::extensions.geography, p_point, c_edge_m);
      insert into public.place_tiles (id, status, demand) values (v_n, 'wanted', 0)
        on conflict (id) do nothing;
      if found then
        v_used := v_used + 1;
        v_added := v_added + 1;
      end if;
    end loop;
  end loop;

  if v_added > 0 then
    insert into public.collector_budget (day, source, used) values (v_day, 'place_tiles_new', v_added)
      on conflict (day, source) do update set used = public.collector_budget.used + excluded.used;
  end if;

  if v_count and v_home_ok and uid is not null then
    update public.profile_private set home_tile_noted_at = now() where user_id = uid;
  end if;
  return v_added;
end $$;
comment on function public.place_tile_note_home(extensions.geography, extensions.geography) is
  'Internal (D-042 slice 1): records place tile demand for a saved home. The home''s 0.5-degree tile: added wanted with demand 1, or demand + 1 on an existing row (at most once per 24 hours for the calling person, auth.uid(), and not when p_old_point was in the same tile), last_member_at the UTC day, retired to wanted, idle woken (active after an OSM run, else filling). Neighbouring tiles within 10 km of the point: added wanted with demand 0 when missing. At most 50 new rows per UTC day worldwide (collector_budget source place_tiles_new); the home tile first. Returns the number of rows added. Never stores who. Called only by collector_note_home_point.';

-- ---------------------------------------------------------------------------
-- 4. place_tiles_note_member_homes (nightly; also the backfill)
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_note_member_homes()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  c_new_cap constant integer := 50;
  v_day     date := (now() at time zone 'UTC')::date;
  v_today   timestamptz := date_trunc('day', now(), 'UTC');
  v_cut     timestamptz := now() - interval '90 days';
  v_used    integer;
  v_missing integer := 0;
  v_added   integer := 0;
begin
  perform pg_advisory_xact_lock(hashtext('public.place_tiles'));

  select coalesce(b.used, 0) into v_used
    from public.collector_budget b where b.day = v_day and b.source = 'place_tiles_new';
  v_used := coalesce(v_used, 0);

  with homes as (
    select public.place_tile_id_of(coalesce(pp.home_point, a.center)) as id, count(*)::integer as homes
      from public.profile_private pp
      join public.profiles p on p.id = pp.user_id
      left join public.areas a on a.id = pp.home_area_id
     where p.status = 'active' and p.deleted_at is null
       and pp.last_seen_at >= v_cut
       and coalesce(pp.home_point, a.center) is not null
     group by 1
  ), missing as (
    select h.id, h.homes from homes h
     where not exists (select 1 from public.place_tiles t where t.id = h.id)
  ), pick as (
    select m.id, m.homes from missing m
     order by m.homes desc, m.id
     limit greatest(0, c_new_cap - v_used)
  ), ins as (
    insert into public.place_tiles (id, status, demand, last_member_at)
    select pick.id, 'wanted', pick.homes, v_today from pick
    on conflict (id) do nothing
    returning 1
  )
  select (select count(*) from missing), (select count(*) from ins) into v_missing, v_added;

  if v_added > 0 then
    insert into public.collector_budget (day, source, used) values (v_day, 'place_tiles_new', v_added)
      on conflict (day, source) do update set used = public.collector_budget.used + excluded.used;
  end if;

  return jsonb_build_object('missing', v_missing, 'added', v_added,
                            'left_today', greatest(0, c_new_cap - v_used - v_added));
end $$;
comment on function public.place_tiles_note_member_homes() is
  'D-042 slice 1, pg_cron nightly (note-member-home-tiles): adds the place tiles of active members'' homes (home_point, else the home area centre; seen in 90 days) that have no row, as wanted with demand = the number of such homes, most homes first, within what is left of the day''s 50 new tiles (collector_budget source place_tiles_new). Picks up tiles a capped day skipped; also the migration 40 backfill. Existing rows are unchanged. Returns counts only; never stores who.';

-- ---------------------------------------------------------------------------
-- 5. collector_note_home_point (migration 25 body) with tile demand and a
--    10-a-day region cap
-- ---------------------------------------------------------------------------
create or replace function public.collector_note_home_point(
  p_point extensions.geography, p_label text, p_old_point extensions.geography default null)
returns boolean language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_region  uuid;
  v_region_at timestamptz;
  v_count_at  timestamptz;
  c_daily_cap constant integer := 10;   -- Migration 40: was 100 (D-042)
begin
  if p_point is null then
    return false;
  end if;
  perform public.place_tile_note_home(p_point, p_old_point);   -- Migration 40 (D-042 slice 1)
  perform pg_advisory_xact_lock(hashtext('public.collector_regions'));

  if uid is not null then
    select pp.home_region_noted_at, pp.home_count_noted_at into v_region_at, v_count_at
      from public.profile_private pp where pp.user_id = uid;
  end if;

  select r.id into v_region
    from public.collector_regions r
   where extensions.ST_DWithin(r.point, p_point, r.radius_km * 1000.0)
   order by extensions.ST_Distance(r.point, p_point)
   limit 1;

  if v_region is not null then
    if (v_count_at is null or v_count_at <= now() - interval '24 hours')
       and (p_old_point is null or not exists (
         select 1 from public.collector_regions r
          where r.id = v_region and extensions.ST_DWithin(r.point, p_old_point, r.radius_km * 1000.0))) then
      update public.collector_regions set home_count = home_count + 1 where id = v_region;
      if uid is not null then
        update public.profile_private set home_count_noted_at = now() where user_id = uid;
      end if;
    end if;
    return false;
  end if;

  -- One new region per person per 24 hours; 10 per UTC day across everyone (Migration 40).
  if v_region_at is not null and v_region_at > now() - interval '24 hours' then
    return false;
  end if;
  if (select count(*) from public.collector_regions r
       where r.first_user_at is not null
         and r.created_at >= date_trunc('day', now(), 'UTC')) >= c_daily_cap then
    return false;
  end if;

  insert into public.collector_regions (point, radius_km, label, first_user_at, priority, home_count)
  values (
    extensions.ST_SetSRID(extensions.ST_MakePoint(
      round(extensions.ST_X(p_point::extensions.geometry)::numeric, 1)::double precision,
      round(extensions.ST_Y(p_point::extensions.geometry)::numeric, 1)::double precision),
      4326)::extensions.geography,
    25,
    null,
    date_trunc('day', now(), 'UTC'),
    10,
    1);
  if uid is not null then
    update public.profile_private
       set home_region_noted_at = now(), home_count_noted_at = now()
     where user_id = uid;
  end if;
  return true;
end $$;
comment on function public.collector_note_home_point(extensions.geography, text, extensions.geography) is
  'Internal (D-040, D-042): first records place tile demand (place_tile_note_home). Then adds a collector_regions row (point rounded to 0.1 degree, 25 km, priority 10, no label, first_user_at the UTC day) when p_point is outside every region, at most once per 24 hours for the calling person (auth.uid()) and 10 times per UTC day overall; else counts the save on the nearest containing region if p_old_point was not already in it, at most once per 24 hours per person. p_label is ignored. Returns true when a region was added. Called only by set_home_location, set_home_area and complete_onboarding.';

comment on table public.collector_regions is
  'Collector discovery queue (D-040): places where sources should be found, as a point rounded to 0.1 degree plus a radius. Added when someone saves a home point outside every region (collector_note_home_point; at most one per person per 24 hours and 10 per UTC day, D-042). User-added rows carry no label; times are rounded to the UTC day; never a user id. Service role writes; moderators read.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.place_tiles_round_times() from public, anon, authenticated, service_role;
revoke all on function public.place_tile_note_home(extensions.geography, extensions.geography) from public, anon, authenticated, service_role;
revoke all on function public.place_tiles_note_member_homes() from public, anon, authenticated;
grant execute on function public.place_tiles_note_member_homes() to service_role;
revoke all on function public.collector_note_home_point(extensions.geography, text, extensions.geography) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Schedule and backfill
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; note-member-home-tiles not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'note-member-home-tiles') then
    perform cron.unschedule('note-member-home-tiles');
  end if;
  perform cron.schedule('note-member-home-tiles', '13 4 * * *', 'select public.place_tiles_note_member_homes()');
end $$;

select public.place_tiles_note_member_homes();

-- Version stamp
insert into public.meta (key, value) values ('schema_version', '2.36')
  on conflict (key) do update set value = excluded.value, updated_at = now();
