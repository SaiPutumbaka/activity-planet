-- ============================================================================
-- Activity Planet schema v2 — migration 45: the nightly event collector runs
--   per collector region (D-042 slice 6, docs/design/auto-coverage/
--   AUTO_COVERAGE_DESIGN.md 5.3). New columns and two new functions; no
--   existing function is rebuilt.
--   Checks: supabase/tests/collector_regions_nightly.sql.
--
--   What this file does
--     1. collector_regions gains timezone (IANA name, filled by the job from
--        the region's point, offline), last_collected_at (the UTC day of the
--        last collector run that covered the region) and the counts that run
--        found there (last_collect_sources, last_collect_items). No user id.
--     2. collector_regions_due(p_limit, p_all), service_role only (the
--        collector Edge Function's GET /collector/regions): regions not yet
--        collected today (UTC), or all with p_all, by priority, then the
--        never-collected and least recently collected, then home_count;
--        at most 100. Returns id, point (lat, lng), radius_km, label,
--        timezone, priority and last_collected_at. Never home_count, never a
--        user id.
--     3. collector_regions_record(p_regions), service_role only (POST
--        /collector/regions/record): [{id, sources, items, timezone?}] from
--        the job after it posted the run. Stamps last_collected_at with the
--        UTC day, stores the counts, and fills timezone when it is still null
--        and the name is one Postgres knows. Returns counts.
--     * meta.schema_version 2.41.
--
--   Account deletion: the new columns reference no user (a region is a point
--   rounded to 0.1 degree and a count, D-040), so request_account_deletion is
--   unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Columns
-- ---------------------------------------------------------------------------
alter table public.collector_regions add column if not exists timezone text;
alter table public.collector_regions add column if not exists last_collected_at timestamptz;
alter table public.collector_regions add column if not exists last_collect_sources integer;
alter table public.collector_regions add column if not exists last_collect_items integer;

do $$ begin
  alter table public.collector_regions add constraint collector_regions_timezone_shape
    check (timezone is null or (char_length(timezone) between 1 and 64 and timezone ~ '^[A-Za-z0-9_+/-]+$'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.collector_regions add constraint collector_regions_collect_counts_nonneg
    check (coalesce(last_collect_sources, 0) >= 0 and coalesce(last_collect_items, 0) >= 0);
exception when duplicate_object then null; end $$;

comment on column public.collector_regions.timezone is
  'IANA time zone of the region''s point (D-042 slice 6), resolved offline by the collector job (tz-lookup) and stored through collector_regions_record. Floating and date-only event times from the region''s discovered sources are read in it.';
comment on column public.collector_regions.last_collected_at is
  'UTC day of the last collector run that covered this region (collector_regions_record). collector_regions_due offers regions not collected today.';
comment on column public.collector_regions.last_collect_sources is
  'Sources that gave at least one item inside the region on the last collector run.';
comment on column public.collector_regions.last_collect_items is
  'Items inside the region the last collector run sent (before the database''s own checks).';

-- ---------------------------------------------------------------------------
-- 2. collector_regions_due
-- ---------------------------------------------------------------------------
create or replace function public.collector_regions_due(p_limit integer default 20, p_all boolean default false)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id,
           'lat', q.lat,
           'lng', q.lng,
           'radius_km', q.radius_km,
           'label', q.label,
           'timezone', q.timezone,
           'priority', q.priority,
           'last_collected_at', q.last_collected_at) order by q.ord), '[]'::jsonb)
    from (select r.id,
                 round(extensions.ST_Y(r.point::extensions.geometry)::numeric, 4)::double precision as lat,
                 round(extensions.ST_X(r.point::extensions.geometry)::numeric, 4)::double precision as lng,
                 r.radius_km, r.label, r.timezone, r.priority,
                 to_char(r.last_collected_at at time zone 'UTC', 'YYYY-MM-DD') as last_collected_at,
                 row_number() over (order by r.priority, r.last_collected_at nulls first, r.home_count desc, r.id) as ord
            from public.collector_regions r
           where coalesce(p_all, false)
              or r.last_collected_at is null
              or r.last_collected_at < date_trunc('day', now(), 'UTC')
           order by r.priority, r.last_collected_at nulls first, r.home_count desc, r.id
           limit greatest(1, least(coalesce(p_limit, 20), 100))) as q;
$$;

comment on function public.collector_regions_due(integer, boolean) is
  'D-042 slice 6, service_role only (collector Edge Function GET /collector/regions): collector regions not yet collected today (UTC), or every region with p_all, by priority, never-collected first, then home_count; at most 100 (default 20). Point (0.1-degree), radius, label, timezone, priority and the last collected day; never home_count or a user id.';

-- ---------------------------------------------------------------------------
-- 3. collector_regions_record
-- ---------------------------------------------------------------------------
create or replace function public.collector_regions_record(p_regions jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  e          jsonb;
  v_id       uuid;
  v_tz       text;
  v_sources  integer;
  v_items    integer;
  v_updated  integer := 0;
  v_unknown  integer := 0;
  v_tz_set   integer := 0;
  v_tz_bad   integer := 0;
  v_n        integer;
begin
  if p_regions is null or jsonb_typeof(p_regions) <> 'array' or jsonb_array_length(p_regions) > 100 then
    raise exception 'regions_invalid';
  end if;
  for e in select * from jsonb_array_elements(p_regions) loop
    if jsonb_typeof(e) <> 'object'
       or jsonb_typeof(e->'id') is distinct from 'string'
       or (e->>'id') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
       or jsonb_typeof(e->'sources') is distinct from 'number'
       or jsonb_typeof(e->'items') is distinct from 'number'
       or (e ? 'timezone' and jsonb_typeof(e->'timezone') not in ('string', 'null')) then
      raise exception 'regions_invalid';
    end if;
    if (e->>'sources') !~ '^[0-9]{1,6}$' or (e->>'items') !~ '^[0-9]{1,7}$' then
      raise exception 'regions_invalid';
    end if;
    v_id := (e->>'id')::uuid;
    v_sources := (e->>'sources')::integer;
    v_items := (e->>'items')::integer;
    v_tz := nullif(e->>'timezone', '');
    if v_tz is not null and (char_length(v_tz) > 64 or v_tz !~ '^[A-Za-z0-9_+/-]+$'
                             or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = v_tz)) then
      v_tz_bad := v_tz_bad + 1;
      v_tz := null;
    end if;

    update public.collector_regions r
       set last_collected_at = date_trunc('day', now(), 'UTC'),
           last_collect_sources = v_sources,
           last_collect_items = v_items,
           timezone = coalesce(r.timezone, v_tz)
     where r.id = v_id;
    get diagnostics v_n = row_count;
    if v_n = 0 then
      v_unknown := v_unknown + 1;
    else
      v_updated := v_updated + 1;
    end if;
  end loop;
  select count(*) into v_tz_set
    from public.collector_regions r
   where r.id in (select (x->>'id')::uuid from jsonb_array_elements(p_regions) x)
     and r.timezone is not null;
  return jsonb_build_object('updated', v_updated, 'unknown', v_unknown,
                            'with_timezone', v_tz_set, 'timezone_invalid', v_tz_bad);
end $$;

comment on function public.collector_regions_record(jsonb) is
  'D-042 slice 6, service_role only (collector Edge Function POST /collector/regions/record): [{id, sources, items, timezone?}] (at most 100) after a collector run. Sets last_collected_at to the UTC day and the run''s counts; fills timezone only while it is null and only with a zone name Postgres knows. Returns updated, unknown (no such region), with_timezone and timezone_invalid counts.';

-- ---------------------------------------------------------------------------
-- Grants (explicit): service_role only
-- ---------------------------------------------------------------------------
revoke all on function public.collector_regions_due(integer, boolean) from public, anon, authenticated;
revoke all on function public.collector_regions_record(jsonb) from public, anon, authenticated;
grant execute on function public.collector_regions_due(integer, boolean) to service_role;
grant execute on function public.collector_regions_record(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.41')
  on conflict (key) do update set value = excluded.value, updated_at = now();
