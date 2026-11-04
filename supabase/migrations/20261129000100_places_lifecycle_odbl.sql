-- ============================================================================
-- Activity Planet schema v2 — migration 35: place tile retirement, the size
--   alarm, the moderator health panel, the monthly ODbL export, and the
--   groundwork for shows and games (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md sections 3.5, 4.4, 8 and 11;
--   build slices 10 (groundwork), 14 and 15).
--   Fixes forward; the one rebuilt function (feed_events_v2) starts from its
--   latest body (migration 26, 20261121000100_viewer_timezone.sql) and only
--   gains p_listing_kind and its filter. Checks:
--   supabase/tests/places_lifecycle.sql (schema_version 2.31).
--
--   What this file does
--     1. place_tiles.keep (never retired: Atlanta's seeded tiles, the
--        founder's outreach city) and place_tiles.idle_since. No user id.
--     2. place_ops_runs: one row per run of the nightly lifecycle job, the
--        size check and the monthly ODbL export (job, ran_at, counts). No
--        user id; moderators read; service role writes; the newest 400 rows
--        per job are kept.
--     3. place_size_status(): the places table and database sizes against
--        the 120 MB alarm, the 150 MB places cap and the 450 MB database
--        ceiling (design 4.5). Level ok, alarm or cap.
--     4. retire_place_tiles() (pg_cron nightly, retire-place-tiles):
--          * last_member_at, rounded down to the day, for every tile with an
--            active member's home in it (profile_private.home_point, else the
--            home area centre; seen in the last 90 days; account active).
--            Only the tile ids are computed, never stored per person;
--          * active or filling tiles with no active member for 90 days (and
--            no run in 90 days when no member was ever seen) become idle,
--            unless keep;
--          * an idle tile whose member came back is active again (filling
--            when it never had an OSM run);
--          * idle for 7 days: retired. OSM and Geoapify rows are deleted,
--            except rows a member corrected (locked_fields), rows a venue
--            points at, rows with member or moderator hub links and rows
--            with a pending edit or open report. Member and venue rows are
--            never deleted;
--          * a retired tile with an active member again is wanted;
--          * records the run and the size check in place_ops_runs.
--     5. The ODbL export (design 8): places_odbl_export, a view of public
--        active place facts (source, osm_ref, name, kind, lat, lng, tags,
--        opening_hours, website) with no ids or user data, and
--        places_odbl_page(after, limit), the paged read the collector
--        Edge Function serves to the monthly GitHub Action
--        (GET /collector/places/export). The cursor is opaque to the file:
--        no id is written to the dump. record_place_dump() stores the
--        Action's result (POST /collector/runs/dump). Service role only.
--     6. mod_place_health(): the admin health panel (tiles by status and
--        the 200 most recent tiles, rows by source and status, sizes and
--        the alarm level, the last extract, Geoapify, lifecycle, size and
--        dump runs, the pg_cron jobs' last runs, today's collector budget).
--        Moderators only (forbidden). Never member data.
--     7. Shows and games groundwork (slice 10): feed_sources of kind
--        ticketmaster or seatgeek are always listing_kind 'show'
--        (feed_sources_listing_kind_default trigger); an imported event is
--        a show while any of its live import rows comes from a show source
--        (event_imports_listing_kind trigger and event_listing_kind_sync;
--        import_upsert_batch is unchanged). feed_events_v2 gains
--        p_listing_kind (default 'plan'), so the feed's sections and the
--        imported shelf hold plans only and the "Shows and games" row asks
--        for 'show'. shows_available(): true while any published show has
--        not ended, so the row and the map layer stay hidden until then.
--     8. Grants (explicit) and meta.schema_version 2.31.
--
--   Account deletion: no new user-referencing table or column (place_tiles
--   and place_ops_runs have no user id), so request_account_deletion is
--   unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. place_tiles.keep and idle_since
-- ---------------------------------------------------------------------------
alter table public.place_tiles
  add column if not exists keep       boolean not null default false,
  add column if not exists idle_since timestamptz;
comment on column public.place_tiles.keep is
  'Never retired (design 3.5): Atlanta''s seeded tiles, the founder''s outreach city. Set by migrations only.';
comment on column public.place_tiles.idle_since is
  'When the tile became idle (no active member for 90 days); retire_place_tiles retires it 7 days later.';
comment on column public.place_tiles.last_member_at is
  'The last day (UTC midnight) an active member''s home was in the tile, set by retire_place_tiles. A day, never who.';

update public.place_tiles t
   set keep = true
  from public.areas a
 where a.slug = 'atlanta' and a.center is not null
   and t.id in (public.place_tile_id_of(a.center),
                public.place_tile_id_of(a.center) - 1,
                public.place_tile_id_of(a.center) + 720)
   and not t.keep;

-- ---------------------------------------------------------------------------
-- 2. place_ops_runs (no user id)
-- ---------------------------------------------------------------------------
create table if not exists public.place_ops_runs (
  id      bigint generated always as identity primary key,
  job     text not null,
  ran_at  timestamptz not null default now(),
  stats   jsonb not null default '{}',
  constraint place_ops_runs_job check (job in ('retire', 'size', 'dump')),
  constraint place_ops_runs_stats_shape check (jsonb_typeof(stats) = 'object' and pg_column_size(stats) <= 8192)
);
create index if not exists place_ops_runs_job_idx on public.place_ops_runs (job, ran_at desc);
comment on table public.place_ops_runs is
  'Hub map operations log (D-041 slices 14 and 15): one row per lifecycle run (retire), size check (size) and monthly ODbL export (dump), with counts and sizes only. No user id. Service role and definer functions write; moderators read; the newest 400 rows per job are kept.';

alter table public.place_ops_runs enable row level security;
revoke all on public.place_ops_runs from public, anon, authenticated;
grant all on public.place_ops_runs to service_role;
grant select on public.place_ops_runs to authenticated;   -- rows only through the moderator policy
drop policy if exists "place_ops_runs_select_mod" on public.place_ops_runs;
create policy "place_ops_runs_select_mod" on public.place_ops_runs for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 3. place_size_status
-- ---------------------------------------------------------------------------
create or replace function public.place_size_status()
returns jsonb language sql stable security definer set search_path = '' as $$
  with s as (
    select pg_catalog.pg_total_relation_size('public.places'::regclass) as places_bytes,
           pg_catalog.pg_database_size(current_database()) as db_bytes
  )
  select jsonb_build_object(
           'places_bytes', s.places_bytes,
           'db_bytes', s.db_bytes,
           'alarm_bytes', 125829120,
           'cap_bytes', 157286400,
           'db_cap_bytes', 471859200,
           'level', case when s.places_bytes >= 157286400 or s.db_bytes >= 471859200 then 'cap'
                         when s.places_bytes >= 125829120 then 'alarm'
                         else 'ok' end)
    from s;
$$;
comment on function public.place_size_status() is
  'Hub map size check (D-041 slice 15, design 4.5): places_bytes (pg_total_relation_size of places) and db_bytes against alarm_bytes (120 MB: start the static-file fallback, design 9), cap_bytes (150 MB places cap, the extract job refuses to post past it) and db_cap_bytes (450 MB). level is ok, alarm or cap. Service role and definer functions only.';

-- ---------------------------------------------------------------------------
-- 4. retire_place_tiles (nightly)
-- ---------------------------------------------------------------------------
create or replace function public.retire_place_tiles()
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_today    timestamptz := date_trunc('day', now());
  v_cut      timestamptz := now() - interval '90 days';
  v_stamped  integer := 0;
  v_idled    integer := 0;
  v_woken    integer := 0;
  v_retired  integer := 0;
  v_deleted  integer := 0;
  v_kept     integer := 0;
  v_wanted   integer := 0;
  v_tiles    integer[];
  v_members  integer[];
  v_size     jsonb;
  v_stats    jsonb;
begin
  -- Tiles with an active member's home in them, as tile ids only.
  select coalesce(array_agg(distinct public.place_tile_id_of(coalesce(pp.home_point, a.center))), '{}')
    into v_members
    from public.profile_private pp
    join public.profiles p on p.id = pp.user_id
    left join public.areas a on a.id = pp.home_area_id
   where p.status = 'active' and p.deleted_at is null
     and pp.last_seen_at >= v_cut
     and coalesce(pp.home_point, a.center) is not null;

  update public.place_tiles t
     set last_member_at = v_today
   where t.id = any (v_members)
     and t.last_member_at is distinct from v_today;
  get diagnostics v_stamped = row_count;

  -- An idle tile whose member came back: active again (filling without an OSM run).
  update public.place_tiles t
     set status = case when t.osm_run_at is not null then 'active'::public.place_tile_status
                       else 'filling'::public.place_tile_status end,
         idle_since = null
   where t.status = 'idle' and t.last_member_at >= v_cut;
  get diagnostics v_woken = row_count;

  -- A retired tile with an active member again: wanted, so the extract job picks it up.
  update public.place_tiles t
     set status = 'wanted', idle_since = null
   where t.status = 'retired' and t.last_member_at >= v_cut;
  get diagnostics v_wanted = row_count;

  -- No active member for 90 days (and, when none was ever seen, no run for 90 days): idle.
  update public.place_tiles t
     set status = 'idle', idle_since = now()
   where t.status in ('active', 'filling') and not t.keep
     and coalesce(t.last_member_at,
                  greatest(t.osm_run_at, t.geoapify_run_at, t.created_at)) < v_cut;
  get diagnostics v_idled = row_count;

  -- Idle for 7 days: retired.
  select coalesce(array_agg(t.id order by t.id), '{}') into v_tiles
    from public.place_tiles t
   where t.status = 'idle' and not t.keep and t.idle_since < now() - interval '7 days';

  if cardinality(v_tiles) > 0 then
    with gone as (
      delete from public.places p
       where p.tile_id = any (v_tiles)
         and p.source in ('osm', 'geoapify')
         and p.locked_fields = '{}'
         and not exists (select 1 from public.venues v where v.place_ref = p.id)
         and not exists (select 1 from public.place_hubs ph where ph.place_id = p.id and ph.via in ('member', 'moderator'))
         and not exists (select 1 from public.place_edits pe where pe.place_id = p.id and pe.status = 'pending')
         and not exists (select 1 from public.place_reports pr where pr.place_id = p.id and pr.status = 'open')
         and not exists (select 1 from public.places m where m.merged_into = p.id)
      returning 1
    )
    select count(*) into v_deleted from gone;

    update public.place_tiles t
       set status = 'retired',
           row_count = (select count(*) from public.places p where p.tile_id = t.id and p.source in ('osm', 'geoapify')),
           idle_since = null
     where t.id = any (v_tiles);
    v_retired := cardinality(v_tiles);

    select count(*) into v_kept from public.places p where p.tile_id = any (v_tiles);
  end if;

  v_size := public.place_size_status();
  v_stats := jsonb_build_object(
    'member_tiles', cardinality(v_members),
    'stamped', v_stamped, 'woken', v_woken, 'wanted', v_wanted, 'idled', v_idled,
    'retired', v_retired, 'deleted_rows', v_deleted, 'kept_rows', v_kept,
    'size_level', v_size->>'level', 'places_bytes', (v_size->>'places_bytes')::bigint);

  insert into public.place_ops_runs (job, stats) values ('retire', v_stats);
  insert into public.place_ops_runs (job, stats) values ('size', v_size);
  if v_size->>'level' <> 'ok' then
    raise warning 'place_size_%: places % bytes, database % bytes', v_size->>'level',
      v_size->>'places_bytes', v_size->>'db_bytes';
  end if;

  delete from public.place_ops_runs r
   where r.id in (select x.id from (
           select o.id, row_number() over (partition by o.job order by o.ran_at desc, o.id desc) as n
             from public.place_ops_runs o) x
          where x.n > 400);

  return v_stats;
end $$;
comment on function public.retire_place_tiles() is
  'Hub map region lifecycle (D-041 slice 15, design 3.5), pg_cron nightly (retire-place-tiles): stamps last_member_at (the day) on tiles with an active member''s home (home_point, else the home area centre; seen in 90 days), wakes idle tiles whose member came back (active, or filling without an OSM run), marks retired tiles with a member wanted, idles active or filling tiles with no member for 90 days (keep tiles never), and retires tiles idle for 7 days: their OSM and Geoapify rows are deleted except corrected rows (locked_fields), rows a venue or a merged row points at, rows with member or moderator hub links and rows with a pending edit or open report. Member and venue rows stay. Records the run and place_size_status() in place_ops_runs (a warning at alarm or cap). Returns the counts. Never stores who.';

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; retire-place-tiles not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'retire-place-tiles') then
    perform cron.unschedule('retire-place-tiles');
  end if;
  perform cron.schedule('retire-place-tiles', '23 4 * * *', 'select public.retire_place_tiles()');
end $$;

-- ---------------------------------------------------------------------------
-- 5. The monthly ODbL export
-- ---------------------------------------------------------------------------
create or replace view public.places_odbl_export as
  select p.id as cursor_id,
         p.source::text as source,
         p.osm_ref,
         p.name,
         p.kind,
         round(p.lat::numeric, 6)::double precision as lat,
         round(p.lng::numeric, 6)::double precision as lng,
         p.tags,
         p.opening_hours,
         p.website
    from public.places p
   where p.is_public and p.status = 'active' and p.merged_into is null;
comment on view public.places_odbl_export is
  'The monthly ODbL dump (D-041 slice 14, design 8): public active place facts (source, osm_ref, name, kind, lat, lng to 6 decimals, allowlisted tags, opening_hours, website). cursor_id pages the read and is never written to the dump. No user ids, no member data, no status or review fields. Service role only; read through places_odbl_page.';
revoke all on public.places_odbl_export from public, anon, authenticated;
grant select on public.places_odbl_export to service_role;

create or replace function public.places_odbl_page(p_after uuid default null, p_limit integer default 5000)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 5000), 1), 5000);
  v_rows  jsonb;
  v_last  uuid;
  v_n     integer;
begin
  with page as (
    select x.* from public.places_odbl_export x
     where p_after is null or x.cursor_id > p_after
     order by x.cursor_id
     limit v_limit
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'source', q.source, 'osm_ref', q.osm_ref, 'name', q.name, 'kind', q.kind,
           'lat', q.lat, 'lng', q.lng, 'tags', q.tags,
           'opening_hours', q.opening_hours, 'website', q.website) order by q.cursor_id), '[]'::jsonb),
         max(q.cursor_id::text)::uuid, count(*)
    into v_rows, v_last, v_n
    from page q;
  return jsonb_build_object('rows', v_rows, 'next', case when v_n = v_limit then v_last end);
end $$;
comment on function public.places_odbl_page(uuid, integer) is
  'One page (at most 5,000 rows, by cursor) of places_odbl_export for the monthly ODbL dump (D-041 slice 14). Returns {rows, next}; next is the cursor for the following page, or null on the last one. Rows carry only the export columns, never an id. Service role only (the collector Edge Function).';

create or replace function public.record_place_dump(
  p_month     text,
  p_rows      integer,
  p_bytes     bigint,
  p_sha256    text,
  p_published boolean,
  p_counts    jsonb default '{}'
)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_stats jsonb;
begin
  if p_month is null or p_month !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
    raise exception 'month_invalid' using errcode = 'check_violation';
  end if;
  if p_rows is null or p_rows < 0 or p_bytes is null or p_bytes < 0 then
    raise exception 'count_invalid' using errcode = 'check_violation';
  end if;
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then
    raise exception 'sha256_invalid' using errcode = 'check_violation';
  end if;
  if p_counts is null or jsonb_typeof(p_counts) <> 'object' or pg_column_size(p_counts) > 2048 then
    raise exception 'counts_invalid' using errcode = 'check_violation';
  end if;
  v_stats := jsonb_build_object('month', p_month, 'rows', p_rows, 'bytes', p_bytes, 'sha256', p_sha256,
                                'published', coalesce(p_published, false), 'counts', p_counts);
  insert into public.place_ops_runs (job, stats) values ('dump', v_stats);
  return v_stats;
end $$;
comment on function public.record_place_dump(text, integer, bigint, text, boolean, jsonb) is
  'Records a monthly ODbL dump run (D-041 slice 14) in place_ops_runs: month YYYY-MM, rows, gzip bytes, sha256, whether a GitHub release was published, counts by source. Errors: month_invalid, count_invalid, sha256_invalid, counts_invalid. Service role only (POST /collector/runs/dump).';

-- ---------------------------------------------------------------------------
-- 6. mod_place_health (the admin health panel)
-- ---------------------------------------------------------------------------
create or replace function public.mod_place_health()
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_cron  jsonb := '[]'::jsonb;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not public.is_moderator() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- pg_cron's own tables: read dynamically so a database without pg_cron still answers.
  if to_regclass('cron.job') is not null and to_regclass('cron.job_run_details') is not null then
    begin
      execute $q$
        select coalesce(jsonb_agg(jsonb_build_object(
                 'job', j.jobname, 'schedule', j.schedule, 'active', j.active,
                 'last_start', d.start_time, 'last_status', d.status) order by j.jobname), '[]'::jsonb)
          from cron.job j
          left join lateral (select r.start_time, r.status from cron.job_run_details r
                              where r.jobid = j.jobid order by r.start_time desc limit 1) d on true
         where j.jobname in ('retire-place-tiles', 'refresh-meeting-spots')
      $q$ into v_cron;
    exception when others then
      v_cron := '[]'::jsonb;
    end;
  end if;

  return jsonb_build_object(
    'tiles', jsonb_build_object(
      'by_status', coalesce((select jsonb_object_agg(s.status, s.n)
                               from (select t.status::text as status, count(*) as n
                                       from public.place_tiles t group by t.status) s), '{}'::jsonb),
      'list', coalesce((select jsonb_agg(jsonb_build_object(
                          'id', t.id, 'status', t.status, 'keep', t.keep, 'rows', t.row_count,
                          'demand', t.demand, 'osm_run_at', t.osm_run_at,
                          'geoapify_run_at', t.geoapify_run_at, 'last_member_at', t.last_member_at,
                          'idle_since', t.idle_since,
                          'west', (t.id % 720) * 0.5 - 180, 'south', (t.id / 720) * 0.5 - 90)
                          order by t.updated_at desc, t.id)
                          from (select * from public.place_tiles order by updated_at desc, id limit 200) t), '[]'::jsonb),
      'total', (select count(*) from public.place_tiles)),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('source', r.source, 'status', r.status,
                                                          'public', r.is_public, 'n', r.n)
                                       order by r.source, r.status, r.is_public)
                        from (select p.source::text as source, p.status::text as status, p.is_public, count(*) as n
                                from public.places p group by 1, 2, 3) r), '[]'::jsonb),
    'size', public.place_size_status(),
    'runs', jsonb_build_object(
      'extract', (select jsonb_build_object('finished_at', r.finished_at, 'tile_id', r.tile_id,
                                            'received', r.received)
                    from public.place_tile_runs r
                   where r.source = 'osm' and r.finished_at is not null
                   order by r.finished_at desc limit 1),
      'geoapify', (select jsonb_build_object('finished_at', r.finished_at, 'tile_id', r.tile_id,
                                             'received', r.received)
                     from public.place_tile_runs r
                    where r.source = 'geoapify' and r.finished_at is not null
                    order by r.finished_at desc limit 1),
      'retire', (select jsonb_build_object('ran_at', o.ran_at, 'stats', o.stats)
                   from public.place_ops_runs o where o.job = 'retire' order by o.ran_at desc, o.id desc limit 1),
      'size', (select jsonb_build_object('ran_at', o.ran_at, 'stats', o.stats)
                 from public.place_ops_runs o where o.job = 'size' order by o.ran_at desc, o.id desc limit 1),
      'dump', (select jsonb_build_object('ran_at', o.ran_at, 'stats', o.stats)
                 from public.place_ops_runs o where o.job = 'dump' order by o.ran_at desc, o.id desc limit 1),
      'cron', v_cron),
    'budget', coalesce((select jsonb_agg(jsonb_build_object(
                          'source', b.source, 'day', b.day, 'used', b.used,
                          'cap', case b.source when 'geoapify_places' then 500 end)
                          order by b.source)
                          from public.collector_budget b where b.day = (now() at time zone 'utc')::date), '[]'::jsonb),
    'budget_caps', jsonb_build_object('geoapify_places', 500));
end $$;
comment on function public.mod_place_health() is
  'Hub map health panel (D-041 slice 15), moderators only (forbidden): tiles (count by status, the 200 most recently changed tiles with status, keep, rows, demand, run stamps, last_member_at day, idle_since and south-west corner), place rows by source, status and public, place_size_status(), the last OSM extract and Geoapify runs, the last lifecycle, size and dump runs, the hub map pg_cron jobs'' last runs, and today''s collector budget against its cap. No member data. Stores nothing.';

-- ---------------------------------------------------------------------------
-- 7. Shows and games groundwork (slice 10)
-- ---------------------------------------------------------------------------
create or replace function public.feed_sources_listing_kind_default()
returns trigger language plpgsql set search_path = '' as $$
begin
  -- Ticketed APIs list shows and games only (D-041): never plans.
  if new.kind in ('ticketmaster', 'seatgeek') then
    new.listing_kind := 'show';
  end if;
  return new;
end $$;
comment on function public.feed_sources_listing_kind_default() is
  'Trigger on feed_sources (D-041 slice 10): a ticketmaster or seatgeek source is always listing_kind show.';

drop trigger if exists feed_sources_listing_kind_default on public.feed_sources;
create trigger feed_sources_listing_kind_default before insert or update of kind, listing_kind on public.feed_sources
  for each row execute function public.feed_sources_listing_kind_default();

update public.feed_sources set listing_kind = 'show'
 where kind in ('ticketmaster', 'seatgeek') and listing_kind <> 'show';

create or replace function public.event_listing_kind_sync(p_event_id uuid)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_event_id is null then
    return;
  end if;
  update public.events e
     set listing_kind = k.kind
    from (select case when exists (
                   select 1 from public.event_imports ei
                     join public.feed_sources fs on fs.id = ei.source_id
                    where ei.event_id = p_event_id and ei.removed_at is null and fs.listing_kind = 'show')
                 then 'show' else 'plan' end as kind) k
   where e.id = p_event_id and e.kind = 'imported' and e.listing_kind is distinct from k.kind;
end $$;
comment on function public.event_listing_kind_sync(uuid) is
  'An imported event is a show (its own "Shows and games" row and map layer, D-041) while any of its live import rows (removed_at null) comes from a feed source with listing_kind show; otherwise a plan. Events people post are never touched. Internal.';

create or replace function public.event_imports_listing_kind()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op in ('UPDATE', 'DELETE') then
    perform public.event_listing_kind_sync(old.event_id);
  end if;
  if tg_op in ('INSERT', 'UPDATE') and (tg_op = 'INSERT' or new.event_id is distinct from old.event_id
       or new.removed_at is distinct from old.removed_at or new.source_id is distinct from old.source_id) then
    perform public.event_listing_kind_sync(new.event_id);
  end if;
  return null;
end $$;
comment on function public.event_imports_listing_kind() is
  'Trigger on event_imports (D-041 slice 10): keeps the linked event''s listing_kind in step with its sources (event_listing_kind_sync).';

drop trigger if exists event_imports_listing_kind on public.event_imports;
create trigger event_imports_listing_kind
  after insert or delete or update of event_id, removed_at, source_id on public.event_imports
  for each row execute function public.event_imports_listing_kind();

create or replace function public.feed_sources_listing_kind_sync()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_event uuid;
begin
  for v_event in select distinct ei.event_id from public.event_imports ei
                  where ei.source_id = new.id and ei.event_id is not null
  loop
    perform public.event_listing_kind_sync(v_event);
  end loop;
  return null;
end $$;
comment on function public.feed_sources_listing_kind_sync() is
  'Trigger on feed_sources (D-041 slice 10): a source whose listing_kind changes re-files its events (event_listing_kind_sync).';

drop trigger if exists feed_sources_listing_kind_sync on public.feed_sources;
create trigger feed_sources_listing_kind_sync after update of listing_kind on public.feed_sources
  for each row when (new.listing_kind is distinct from old.listing_kind)
  execute function public.feed_sources_listing_kind_sync();

-- Events already imported from a show source (none on staging or production today).
do $$
declare
  v_event uuid;
begin
  for v_event in select distinct ei.event_id from public.event_imports ei
                   join public.feed_sources fs on fs.id = ei.source_id
                  where fs.listing_kind = 'show' and ei.event_id is not null
  loop
    perform public.event_listing_kind_sync(v_event);
  end loop;
end $$;

create or replace function public.shows_available()
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.events e
                  where e.listing_kind = 'show' and e.status = 'published'
                    and e.visibility = 'public' and e.ends_at > now());
$$;
comment on function public.shows_available() is
  'True while any published public show or game has not ended (D-041 slice 10). The "Shows and games" feed row and map layer stay hidden while it is false. Returns only this boolean.';

-- ---------------------------------------------------------------------------
-- 7b. feed_events_v2 (migration 26 body): p_listing_kind, default plan
-- ---------------------------------------------------------------------------
drop function if exists public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text);

create or replace function public.feed_events_v2(
  p_from      timestamptz,
  p_to        timestamptz,
  p_lat       double precision default null,
  p_lng       double precision default null,
  p_radius_km integer default null,
  p_hub_ids   uuid[] default null,
  p_free_only boolean default false,
  p_limit     integer default 60,
  p_timezone  text default null,
  p_listing_kind text default 'plan'
)
returns table (
  id                 uuid,
  kind               public.event_kind,
  hub_id             uuid,
  hub_slug           text,
  hub_name           text,
  hub_emoji          text,
  chapter_id         uuid,
  campus_id          uuid,
  host_id            uuid,
  series_id          uuid,
  occurrence_date    date,
  title              text,
  description        text,
  cover_url          text,
  starts_at          timestamptz,
  ends_at            timestamptz,
  timezone           text,
  min_age            smallint,
  capacity           integer,
  waitlist_enabled   boolean,
  min_headcount      integer,
  members_only       boolean,
  is_free            boolean,
  price_text         text,
  status             public.event_status,
  visibility         public.event_visibility,
  address_visibility public.address_visibility,
  location_hint      text,
  going_count        integer,
  waitlist_count     integer,
  interested_count   integer,
  external_url       text,
  source_name        text,
  created_at         timestamptz,
  updated_at         timestamptz,
  distance_band      text,
  section            text,
  is_imported        boolean,
  matched_by         text
)
language plpgsql stable set search_path = '' as $$
#variable_conflict use_column
declare
  uid        uuid := (select auth.uid());
  v_origin   extensions.geography;
  v_radius_m double precision;
  v_tz       text;
  v_zones    text[];
  v_limit    integer := greatest(1, least(coalesce(p_limit, 60), 200));
  v_kind     text := coalesce(p_listing_kind, 'plan');
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_to <= p_from then
    raise exception 'invalid_window' using errcode = 'check_violation';
  end if;
  if p_to - p_from > interval '93 days' then
    raise exception 'window_too_long' using errcode = 'check_violation', hint = 'Up to 93 days.';
  end if;
  if (p_lat is null) <> (p_lng is null)
     or (p_lat is not null and (p_lat not between -90 and 90 or p_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_kind not in ('plan', 'show') then
    raise exception 'listing_kind_invalid' using errcode = 'check_violation';
  end if;

  -- Origin: the device point (about 1 km, never stored), else the saved home
  -- point (D-040, about 1 km), else the home area, else Atlanta. A declared
  -- campus is never the origin (D-036).
  v_origin := coalesce(
    case when p_lat is not null then
      extensions.ST_SetSRID(extensions.ST_MakePoint(
        round(p_lng::numeric, 2)::double precision,
        round(p_lat::numeric, 2)::double precision), 4326)::extensions.geography
    end,
    (select pp.home_point from public.profile_private pp where pp.user_id = uid),
    (select a.center from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.center from public.areas a where a.slug = 'atlanta'));

  v_radius_m := 1000.0 * greatest(1, least(50, coalesce(
    p_radius_km,
    (select pp.feed_radius_km::integer from public.profile_private pp where pp.user_id = uid),
    (select a.default_radius_km::integer from public.profile_private pp join public.areas a on a.id = pp.home_area_id where pp.user_id = uid),
    (select a.default_radius_km::integer from public.areas a where a.slug = 'atlanta'),
    10)));

  -- Day boundaries (migration 26): the zone the app sent when it is a known
  -- IANA name, else the saved profile_private.timezone, else (per event) the
  -- event's own timezone, else America/New_York. An unknown zone is ignored.
  select t.tz into v_tz
    from (values (1, nullif(btrim(coalesce(p_timezone, '')), '')),
                 (2, (select pp.timezone from public.profile_private pp where pp.user_id = uid))) t(o, tz)
   where t.tz is not null and char_length(t.tz) <= 64 and t.tz like '%/%'
     and exists (select 1 from pg_catalog.pg_timezone_names z where z.name = t.tz)
   order by t.o
   limit 1;
  if v_tz is null then
    v_zones := array(select z.name from pg_catalog.pg_timezone_names z where z.name like '%/%');
  end if;

  return query
  with my_hubs as (
    select hm.hub_id from public.hub_members hm where hm.user_id = uid
  ), my_campuses as (
    select m.campus_id from public.org_memberships m
     where m.user_id = uid and m.campus_id is not null
       and (m.expires_at is null or m.expires_at > now())
  ), cand as (
    select e.*,
           h.slug  as h_slug,
           h.name  as h_name,
           h.emoji as h_emoji,
           (e.hub_id in (select hub_id from my_hubs)) as by_hub,
           (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses)) as by_campus
      from public.events e
      join public.hubs h on h.id = e.hub_id
     where e.status = 'published'
       and e.starts_at >= p_from and e.starts_at < p_to
       and e.listing_kind = v_kind
       and (p_hub_ids is null or e.hub_id = any (p_hub_ids))
       and (not coalesce(p_free_only, false) or e.is_free)
       and (
         e.hub_id in (select hub_id from my_hubs)
         or (e.campus_id is not null and e.campus_id in (select campus_id from my_campuses))
         or (
           e.visibility = 'public'
           and e.approx_point is not null
           and extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m + 8000)
           and (e.address_visibility = 'approved_only'
                or extensions.ST_DWithin(e.approx_point, v_origin, v_radius_m))
         )
       )
  ), zoned as (
    select c.*,
           case when v_tz is not null then v_tz
                when c.timezone = any (v_zones) then c.timezone
                else 'America/New_York' end as day_tz
      from cand c
  ), banded as (
    select z.*,
           case when z.approx_point is null then null::double precision
                else extensions.ST_Distance(z.approx_point, v_origin) end as dist_m,
           (z.starts_at at time zone z.day_tz)::date as local_day,
           (now() at time zone z.day_tz)::date as today_day
      from zoned z
  )
  select b.id, b.kind, b.hub_id, b.h_slug, b.h_name, b.h_emoji, b.chapter_id, b.campus_id, b.host_id,
         b.series_id, b.occurrence_date, b.title, b.description, b.cover_url, b.starts_at, b.ends_at,
         b.timezone, b.min_age, b.capacity, b.waitlist_enabled, b.min_headcount, b.members_only,
         b.is_free, b.price_text, b.status, b.visibility, b.address_visibility, b.location_hint,
         b.going_count, b.waitlist_count, b.interested_count, b.external_url, b.source_name,
         b.created_at, b.updated_at,
         case
           when b.dist_m is null then null::text
           when b.address_visibility = 'approved_only' then 'approximate'
           when b.dist_m < 1609.344  then '<1 mi'
           when b.dist_m < 8046.72   then '1-5 mi'
           when b.dist_m < 16093.44  then '5-10 mi'
           when b.dist_m < 40233.6   then '10-25 mi'
           else '25+ mi'
         end,
         case
           when b.local_day <= b.today_day     then 'today'
           when b.local_day <  b.today_day + 7 then 'this_week'
           else 'later'
         end,
         (b.kind = 'imported'),
         case when b.by_hub then 'hub' when b.by_campus then 'campus' else 'nearby' end
    from banded b
   -- Human-hosted rows by start time (hub or campus matches first only on a
   -- tie), so a busy hub list cannot push every nearby event past the limit.
   order by (b.kind = 'imported'), b.starts_at, (not (b.by_hub or b.by_campus)), b.id
   limit v_limit;
end $$;

comment on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) is
  'Feed v2 (D-036): published events starting in [p_from, p_to) (at most 93 days) that are in the caller''s hubs, tagged to the caller''s verified campus, or public within the radius of the origin (p_lat/p_lng rounded to 0.01 degree, else profile_private.home_point, else profile_private.home_area_id, else Atlanta, never the declared campus; radius p_radius_km, else profile_private.feed_radius_km, else the area default, capped at 50 km). Events without a point come only through hubs or campus. Approved-only events get 8 km of slack and distance_band ''approximate''; others ''<1 mi'', ''1-5 mi'', ''5-10 mi'', ''10-25 mi'', ''25+ mi''. Never returns a distance, a coordinate or the origin. section is today / this_week / later in the viewer''s zone: p_timezone when it is a known IANA name (an unknown one is ignored), else profile_private.timezone, else the event''s timezone, else America/New_York; matched_by is hub / campus / nearby. Order: human-hosted before imported, then start time, hub or campus matches first on a tie. p_listing_kind (migration 35, D-041) is plan (the default: plans and the imported shelf) or show (the "Shows and games" row). Runs as the caller, so RLS applies. Errors: not_authenticated, invalid_window, window_too_long, invalid_coordinates, listing_kind_invalid.';

-- ---------------------------------------------------------------------------
-- 8. Grants
-- ---------------------------------------------------------------------------
revoke all on function public.place_size_status() from public, anon, authenticated;
grant execute on function public.place_size_status() to service_role;
revoke all on function public.retire_place_tiles() from public, anon, authenticated;
grant execute on function public.retire_place_tiles() to service_role;
revoke all on function public.places_odbl_page(uuid, integer) from public, anon, authenticated;
grant execute on function public.places_odbl_page(uuid, integer) to service_role;
revoke all on function public.record_place_dump(text, integer, bigint, text, boolean, jsonb) from public, anon, authenticated;
grant execute on function public.record_place_dump(text, integer, bigint, text, boolean, jsonb) to service_role;
revoke all on function public.mod_place_health() from public, anon;
grant execute on function public.mod_place_health() to authenticated, service_role;
revoke all on function public.feed_sources_listing_kind_default() from public, anon, authenticated, service_role;
revoke all on function public.feed_sources_listing_kind_sync() from public, anon, authenticated, service_role;
revoke all on function public.event_imports_listing_kind() from public, anon, authenticated, service_role;
revoke all on function public.event_listing_kind_sync(uuid) from public, anon, authenticated;
grant execute on function public.event_listing_kind_sync(uuid) to service_role;
revoke all on function public.shows_available() from public;
grant execute on function public.shows_available() to anon, authenticated, service_role;
revoke all on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) from public, anon;
grant execute on function public.feed_events_v2(timestamptz, timestamptz, double precision, double precision, integer, uuid[], boolean, integer, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 9. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.31')
  on conflict (key) do update set value = excluded.value, updated_at = now();
