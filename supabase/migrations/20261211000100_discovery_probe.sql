-- ============================================================================
-- Activity Planet schema v2 — migration 47: the source discovery probe and
--   its Atlanta gate (D-042 slice 8, docs/design/auto-coverage/
--   AUTO_COVERAGE_DESIGN.md 6.1 to 6.4 and 7). New table and functions only;
--   no existing function is changed.
--   Checks: supabase/tests/discovery_probe.sql.
--
--   What this file does
--     1. source_discovery_gates: one row per run of the Atlanta quality gate
--        (design 6.4): the probe code's hash, how many of the hand-written
--        Atlanta sources that work today it rediscovered from scratch, how
--        many were required, and whether it passed (computed here, never
--        taken from the caller). The rediscovered sites are public
--        organisation hosts. No user id. Kept 180 days.
--     2. source_discovery_gate_record(p_gate), service role (POST
--        /collector/discovery/gate): stores a gate run.
--     3. source_discovery_gate_status(p_probe_hash), service role (GET
--        /collector/discovery/gate?hash=): the latest gate run for that probe
--        code within 30 days, and whether it passed.
--     4. source_discovery_probe_queue(p_probe_hash, p_regions, p_per_region,
--        p_limit), service role (GET /collector/discovery/queue): the
--        candidates the probe may read now. Refuses (discovery_gate_closed)
--        unless a gate run of the same probe code passed within 30 days, so
--        no region is probed by code that has not rediscovered Atlanta's
--        sources. The same rules as source_candidates_due (not locked,
--        member suggestions only once approved, not denylisted, the EU gate
--        of source_discovery_allowed), only candidates with a collector
--        region, and at most p_per_region (default 150, design 7) a region a
--        UTC day, counting the probes already recorded today (run ids
--        starting with "probe-").
--     5. source_discovery_regions_due(p_limit), service role (GET
--        /collector/discovery/regions): collector regions whose candidates
--        were never built or were built over 30 days ago, by priority, at
--        most p_limit (default 10, design 7: new event regions a day).
--        source_discovery_regions_record(p_ids), service role (POST
--        /collector/discovery/regions/record): stamps last_discovery_at
--        (the column migration 22 created and nothing wrote yet).
--     * meta.schema_version 2.43.
--
--   Account deletion: the new table and functions hold and return no user
--   id, so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. source_discovery_gates
-- ---------------------------------------------------------------------------
create table if not exists public.source_discovery_gates (
  id          bigint generated always as identity primary key,
  run_id      text not null,
  probe_hash  text not null,
  region      text not null,
  expected    smallint not null,
  required    smallint not null,
  found       smallint not null,
  passed      boolean not null,
  found_sites text[] not null default '{}',
  counts      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint source_discovery_gates_run_key unique (run_id),
  constraint source_discovery_gates_run_id_format check (run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'),
  constraint source_discovery_gates_hash_format check (probe_hash ~ '^[0-9a-f]{16,64}$'),
  constraint source_discovery_gates_region_format check (region ~ '^[a-z0-9-]{2,40}$'),
  constraint source_discovery_gates_counts_range check (expected between 1 and 100 and required between 1 and expected and found between 0 and expected),
  constraint source_discovery_gates_passed_rule check (passed = (found >= required)),
  constraint source_discovery_gates_sites_size check (cardinality(found_sites) <= 100),
  constraint source_discovery_gates_counts_object check (jsonb_typeof(counts) = 'object')
);
create index if not exists source_discovery_gates_hash_idx on public.source_discovery_gates (probe_hash, created_at desc);
comment on table public.source_discovery_gates is
  'Runs of the discovery quality gate (D-042 slice 8, design 6.4): an Atlanta dry run from scratch (OSM website tags and Wikidata only, no seed URLs) must rediscover at least `required` of the `expected` hand-written sources that work today before the probe may read candidates for any region (source_discovery_probe_queue). probe_hash names the probe code; passed is found >= required. found_sites are public organisation hosts. No user id; kept 180 days. Moderators read.';

alter table public.source_discovery_gates enable row level security;
revoke all on public.source_discovery_gates from public, anon, authenticated;
grant select on public.source_discovery_gates to authenticated;   -- rows only through the moderator policy
grant all on public.source_discovery_gates to service_role;
drop policy if exists "source_discovery_gates_select_mod" on public.source_discovery_gates;
create policy "source_discovery_gates_select_mod" on public.source_discovery_gates for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 2. source_discovery_gate_record
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_gate_record(p_gate jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_run      text := p_gate ->> 'run_id';
  v_hash     text := lower(coalesce(p_gate ->> 'probe_hash', ''));
  v_region   text := p_gate ->> 'region';
  v_expected integer;
  v_required integer;
  v_found    integer;
  v_sites    text[];
  v_counts   jsonb := coalesce(p_gate -> 'counts', '{}'::jsonb);
  v_id       bigint;
  v_int      text := '^[0-9]{1,3}$';
begin
  if p_gate is null or jsonb_typeof(p_gate) <> 'object'
     or coalesce(v_run, '') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'
     or v_hash !~ '^[0-9a-f]{16,64}$'
     or coalesce(v_region, '') !~ '^[a-z0-9-]{2,40}$'
     or jsonb_typeof(p_gate -> 'expected') is distinct from 'number' or (p_gate ->> 'expected') !~ v_int
     or jsonb_typeof(p_gate -> 'required') is distinct from 'number' or (p_gate ->> 'required') !~ v_int
     or jsonb_typeof(p_gate -> 'found') is distinct from 'number' or (p_gate ->> 'found') !~ v_int
     or jsonb_typeof(v_counts) <> 'object'
     or (select count(*) from jsonb_object_keys(v_counts)) > 40
     or exists (select 1 from jsonb_each(v_counts) e
                 where e.key !~ '^[a-z0-9_]{1,40}$' or jsonb_typeof(e.value) <> 'number' or (e.value #>> '{}') !~ '^[0-9]{1,7}$')
     or (p_gate ? 'found_sites' and jsonb_typeof(p_gate -> 'found_sites') <> 'array') then
    raise exception 'gate_invalid' using errcode = 'check_violation';
  end if;
  v_expected := (p_gate ->> 'expected')::integer;
  v_required := (p_gate ->> 'required')::integer;
  v_found := (p_gate ->> 'found')::integer;
  if v_expected < 1 or v_expected > 100 or v_required < 1 or v_required > v_expected or v_found > v_expected then
    raise exception 'gate_invalid' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(distinct lower(s.value #>> '{}')), '{}') into v_sites
    from jsonb_array_elements(coalesce(p_gate -> 'found_sites', '[]'::jsonb)) s;
  if cardinality(v_sites) > v_expected
     or exists (select 1 from unnest(v_sites) h
                 where h !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' or char_length(h) > 253) then
    raise exception 'gate_invalid' using errcode = 'check_violation';
  end if;

  delete from public.source_discovery_gates where created_at < now() - interval '180 days';
  insert into public.source_discovery_gates (run_id, probe_hash, region, expected, required, found, passed, found_sites, counts)
  values (v_run, v_hash, v_region, v_expected, v_required, v_found, v_found >= v_required, v_sites, v_counts)
  on conflict (run_id) do nothing
  returning id into v_id;
  if v_id is null then
    return jsonb_build_object('recorded', false, 'repeat', true,
                              'passed', (select g.passed from public.source_discovery_gates g where g.run_id = v_run));
  end if;
  return jsonb_build_object('recorded', true, 'repeat', false, 'passed', v_found >= v_required);
end $$;
comment on function public.source_discovery_gate_record(jsonb) is
  'Service role (D-042 slice 8; POST /collector/discovery/gate): records one run of the Atlanta discovery gate {run_id, probe_hash (16 to 64 hex), region, expected, required, found, found_sites?, counts?}. passed is computed here (found >= required). A repeated run_id is ignored. Returns {recorded, repeat, passed}. Error: gate_invalid.';

-- ---------------------------------------------------------------------------
-- 3. source_discovery_gate_status
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_gate_open(p_probe_hash text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.source_discovery_gates g
                  where g.probe_hash = lower(coalesce(p_probe_hash, ''))
                    and g.passed and g.created_at > now() - interval '30 days');
$$;
comment on function public.source_discovery_gate_open(text) is
  'D-042 slice 8: true when a gate run of this probe code passed within 30 days. Internal.';

create or replace function public.source_discovery_gate_status(p_probe_hash text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'open', public.source_discovery_gate_open(p_probe_hash),
           'last', (select jsonb_build_object('run_id', g.run_id, 'region', g.region, 'expected', g.expected,
                                              'required', g.required, 'found', g.found, 'passed', g.passed,
                                              'ran_at', g.created_at)
                      from public.source_discovery_gates g
                     where g.probe_hash = lower(coalesce(p_probe_hash, ''))
                       and g.created_at > now() - interval '30 days'
                     order by g.passed desc, g.created_at desc
                     limit 1));
$$;
comment on function public.source_discovery_gate_status(text) is
  'Service role (D-042 slice 8; GET /collector/discovery/gate?hash=): {open, last}: whether the probe code with this hash passed the Atlanta gate within 30 days, and its best recent run (a passing one first).';

-- ---------------------------------------------------------------------------
-- 4. source_discovery_probe_queue
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_probe_queue(
  p_probe_hash text,
  p_regions    uuid[]  default null,
  p_per_region integer default 150,
  p_limit      integer default 500)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_today date := (now() at time zone 'UTC')::date;
  v_cap   integer := least(500, greatest(1, coalesce(p_per_region, 150)));
  v_out   jsonb;
begin
  if not public.source_discovery_gate_open(p_probe_hash) then
    raise exception 'discovery_gate_closed' using errcode = 'check_violation';
  end if;
  with probed as (
    select c.region_id, count(distinct p.candidate_id)::integer as n
      from public.source_probe_results p
      join public.source_candidates c on c.id = p.candidate_id
     where p.run_on = v_today and p.run_id like 'probe-%' and c.region_id is not null
     group by c.region_id
  ), due as (
    select c.*, row_number() over (partition by c.region_id order by c.score desc, c.created_at, c.id) as rn
      from public.source_candidates c
     where not c.locked
       and c.region_id is not null
       and c.review_status in ('none', 'approved')
       and (c.status = 'discovered' or (c.status = 'rejected' and c.retry_after is not null))
       and (c.retry_after is null or c.retry_after <= now())
       and (p_regions is null or c.region_id = any (p_regions))
       and public.source_discovery_allowed(c.origin, c.country)
       and public.collector_host_denied(c.host) is null
  ), q as (
    select d.*, row_number() over (order by d.rn, d.score desc, d.created_at, d.id) as ord
      from due d
      left join probed p on p.region_id = d.region_id
     where d.rn <= v_cap - coalesce(p.n, 0)
     order by d.rn, d.score desc, d.created_at, d.id
     limit least(2000, greatest(1, coalesce(p_limit, 500)))
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'url', q.url, 'host', q.host, 'origin', q.origin, 'region_id', q.region_id,
           'name', q.name, 'place_kind', q.place_kind, 'wikidata_id', q.wikidata_id, 'country', q.country,
           'score', q.score, 'status', q.status) order by q.ord), '[]'::jsonb)
    into v_out
    from q;
  return v_out;
end $$;
comment on function public.source_discovery_probe_queue(text, uuid[], integer, integer) is
  'Service role (D-042 slice 8; GET /collector/discovery/queue): candidates the probe may read now. discovery_gate_closed unless the probe code (p_probe_hash) passed the Atlanta gate within 30 days. Same rules as source_candidates_due (not locked, member suggestions only once approved, not denylisted, not osm or wikidata candidates in the EU, EEA or UK while meta.eu_discovery is off), only candidates with a collector region, at most p_per_region (default 150) a region a UTC day less the probes recorded today (run ids probe-...), round-robin over regions by score; at most p_limit (default 500, up to 2,000). No user ids.';

-- ---------------------------------------------------------------------------
-- 5. source_discovery_regions_due and source_discovery_regions_record
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_regions_due(p_limit integer default 10)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id,
           'lat', q.lat,
           'lng', q.lng,
           'radius_km', q.radius_km,
           'label', q.label,
           'timezone', q.timezone,
           'priority', q.priority,
           'last_discovery_at', q.last_discovery_at) order by q.ord), '[]'::jsonb)
    from (select r.id,
                 round(extensions.ST_Y(r.point::extensions.geometry)::numeric, 4)::double precision as lat,
                 round(extensions.ST_X(r.point::extensions.geometry)::numeric, 4)::double precision as lng,
                 r.radius_km, r.label, r.timezone, r.priority,
                 to_char(r.last_discovery_at at time zone 'UTC', 'YYYY-MM-DD') as last_discovery_at,
                 row_number() over (order by r.priority, r.last_discovery_at nulls first, r.home_count desc, r.id) as ord
            from public.collector_regions r
           where r.last_discovery_at is null or r.last_discovery_at < now() - interval '30 days'
           order by r.priority, r.last_discovery_at nulls first, r.home_count desc, r.id
           limit greatest(1, least(coalesce(p_limit, 10), 100))) as q;
$$;
comment on function public.source_discovery_regions_due(integer) is
  'Service role (D-042 slice 8; GET /collector/discovery/regions): collector regions whose discovery candidates were never built or were built over 30 days ago, by priority, never-built first, then home_count; at most p_limit (default 10 a day, design 7). Point (0.1-degree), radius, label, timezone, priority and the last discovery day; never home_count or a user id.';

create or replace function public.source_discovery_regions_record(p_ids jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  if p_ids is null or jsonb_typeof(p_ids) <> 'array' or jsonb_array_length(p_ids) > 100
     or exists (select 1 from jsonb_array_elements(p_ids) e
                 where jsonb_typeof(e.value) <> 'string'
                    or (e.value #>> '{}') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') then
    raise exception 'regions_invalid' using errcode = 'check_violation';
  end if;
  update public.collector_regions r
     set last_discovery_at = date_trunc('day', now(), 'UTC')
   where r.id in (select (e.value #>> '{}')::uuid from jsonb_array_elements(p_ids) e);
  get diagnostics v_n = row_count;
  return jsonb_build_object('updated', v_n, 'unknown', jsonb_array_length(p_ids) - v_n);
end $$;
comment on function public.source_discovery_regions_record(jsonb) is
  'Service role (D-042 slice 8; POST /collector/discovery/regions/record): stamps last_discovery_at (the UTC day) on the collector regions whose candidates were just built ["<uuid>", ...] (at most 100). Returns {updated, unknown}. Error: regions_invalid.';

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function public.source_discovery_gate_record(jsonb) from public, anon, authenticated;
revoke all on function public.source_discovery_gate_open(text) from public, anon, authenticated;
revoke all on function public.source_discovery_gate_status(text) from public, anon, authenticated;
revoke all on function public.source_discovery_probe_queue(text, uuid[], integer, integer) from public, anon, authenticated;
revoke all on function public.source_discovery_regions_due(integer) from public, anon, authenticated;
revoke all on function public.source_discovery_regions_record(jsonb) from public, anon, authenticated;
grant execute on function public.source_discovery_gate_record(jsonb) to service_role;
grant execute on function public.source_discovery_gate_open(text) to service_role;
grant execute on function public.source_discovery_gate_status(text) to service_role;
grant execute on function public.source_discovery_probe_queue(text, uuid[], integer, integer) to service_role;
grant execute on function public.source_discovery_regions_due(integer) to service_role;
grant execute on function public.source_discovery_regions_record(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.43')
  on conflict (key) do update set value = excluded.value, updated_at = now();
