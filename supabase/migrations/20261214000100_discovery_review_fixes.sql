-- ============================================================================
-- Activity Planet schema v2 — migration 50: review fixes for D-042 slices 7
--   to 11 (discovery lifecycle, Suggest a calendar, the Atlanta gate, the EU
--   gate, ticketing text, place-files). Rebuilt functions start from their
--   latest bodies (source_candidates_record and source_candidates_due:
--   migration 46; the gate functions and
--   source_discovery_probe_queue: migration 47; collector_api_shows_sweep:
--   migration 48); each change is marked "Migration 50".
--   Checks: supabase/tests/discovery_review_fixes.sql.
--
--   What this file does
--     1. A live discovered source that keeps failing: source_candidates gains
--        error_since. source_candidates_record pauses a probation, enabled or
--        paused source after 3 error runs with no good run between (retry in
--        7 days) and rejects it after 30 days of errors (errors_30_days,
--        retry in 30 days). A good run resets the error count. (The collector
--        now reports 401/403 as blocked and an unreadable robots.txt as
--        robots, both already handled.)
--     2. Who suggested a calendar is not kept: place_rate_log rows older than
--        a day are deleted every hour (pg_cron job prune-place-rate-log), and a
--        member candidate's created_at, updated_at and status_at are stored
--        to the hour (trigger source_candidates_member_hour; existing member
--        rows are rounded once), so a candidate cannot be matched to a rate
--        row by its timestamp.
--     3. The Atlanta gate: at most 2 gate runs are recorded in 24 hours
--        (gate_rate_limited); source_discovery_gate_status also answers
--        runs_24h and max_runs_24h, so the CLI stops before probing.
--     4. The gate's pass threshold has a floor: meta
--        discovery_gate_min_required (6). source_discovery_gate_record
--        refuses a lower required (gate_invalid) and source_discovery_gate_open
--        ignores runs recorded with one.
--     5. EU gate across borders: source_discovery_allowed(origin, country,
--        region_id) also refuses osm and wikidata candidates without a
--        country of their own in a region whose zone is European, unknown,
--        or another gated country's zone (source_discovery_zone_needs_country).
--        source_candidates_due and source_discovery_probe_queue use it. The
--        collector now gives each candidate the country of its own point.
--     6. collector_api_shows_sweep also removes ticketing-only events 7 days
--        after they ended or after they were cancelled as no longer listed:
--        deleted with their import rows when nothing refers to them (RSVPs,
--        notifications, broadcasts, meets), else their description, image
--        and price text are blanked.
--     7. place_file_request_take(user_id), service role: the place-files
--        Edge Function's POST /place is for active, onboarded members, 60
--        calls an hour each (place_rate_log kind file).
--     * meta.schema_version 2.46.
--
--   Account deletion: place_rate_log already cascades with the profile; the
--   new column and meta keys hold no user id. request_account_deletion is
--   unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Live sources that keep failing
-- ---------------------------------------------------------------------------
alter table public.source_candidates add column if not exists error_since date;
comment on column public.source_candidates.error_since is
  'UTC day of the first error run since the last good run (migration 50); null when the last run that counted was good. A live source is rejected after 30 days of errors.';

-- source_candidates_record: latest body (migration 46).
create or replace function public.source_candidates_record(p_results jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  r          jsonb;
  v_c        public.source_candidates%rowtype;
  v_today    date := (now() at time zone 'UTC')::date;
  v_id       uuid;
  v_run      text;
  v_out      text;
  v_kind     text;
  v_url      text;
  v_plat     text;
  v_items    integer;
  v_inreg    integer;
  v_req      integer;
  v_err      integer;
  v_complete boolean;
  v_good     boolean;
  v_status   text;
  v_reason   text;
  v_retry    timestamptz;
  v_lock     boolean;
  v_slug     text;
  v_name     text;
  v_attr     text;
  v_rpoint   extensions.geography;
  v_rradius  smallint;
  v_rlabel   text;
  v_rtz      text;
  v_chk      jsonb;
  v_counts   jsonb := jsonb_build_object('recorded', 0, 'repeat', 0, 'skipped', 0, 'unknown', 0,
                                         'probation', 0, 'enabled', 0, 'paused', 0, 'rejected', 0);
  v_int      text := '^[0-9]{1,7}$';
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' or jsonb_array_length(p_results) > 500 then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  -- Every entry is checked before anything is written.
  if exists (select 1 from jsonb_array_elements(p_results) e
              where jsonb_typeof(e.value) <> 'object'
                 or coalesce(e.value ->> 'candidate_id', '') !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
                 or coalesce(e.value ->> 'run_id', '') !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'
                 or coalesce(e.value ->> 'outcome', '') not in ('ok', 'empty', 'no_feed', 'error', 'blocked', 'robots', 'noindex', 'needs_permission', 'denylisted')
                 or (e.value ? 'kind' and jsonb_typeof(e.value -> 'kind') <> 'null' and coalesce(e.value ->> 'kind', '') not in ('ics', 'rss', 'page'))
                 or (e.value ? 'platform' and jsonb_typeof(e.value -> 'platform') <> 'null' and coalesce(e.value ->> 'platform', '') !~ '^[a-z0-9_]{1,40}$')
                 or (e.value ? 'complete' and jsonb_typeof(e.value -> 'complete') not in ('boolean', 'null'))
                 or exists (select 1 from unnest(array['items', 'in_region', 'requests', 'errors']) k
                             where e.value ? k and jsonb_typeof(e.value -> k) <> 'null'
                               and (jsonb_typeof(e.value -> k) <> 'number' or (e.value ->> k) !~ v_int))) then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;

  delete from public.source_probe_results where created_at < now() - interval '90 days';

  for r in select value from jsonb_array_elements(p_results) loop
    v_id := (r ->> 'candidate_id')::uuid;
    v_run := r ->> 'run_id';
    select * into v_c from public.source_candidates where id = v_id for update;
    if not found then
      v_counts := jsonb_set(v_counts, '{unknown}', to_jsonb((v_counts ->> 'unknown')::int + 1));
      continue;
    end if;
    if exists (select 1 from public.source_probe_results p where p.candidate_id = v_id and p.run_id = v_run) then
      v_counts := jsonb_set(v_counts, '{repeat}', to_jsonb((v_counts ->> 'repeat')::int + 1));
      continue;
    end if;
    -- Locked, moderator-rejected, unapproved and needs_permission rows take no results.
    if v_c.locked or v_c.status = 'needs_permission' or v_c.review_status in ('pending', 'rejected') then
      v_counts := jsonb_set(v_counts, '{skipped}', to_jsonb((v_counts ->> 'skipped')::int + 1));
      continue;
    end if;

    v_out := r ->> 'outcome';
    v_kind := nullif(r ->> 'kind', '');
    v_plat := nullif(r ->> 'platform', '');
    v_items := (r ->> 'items')::integer;
    v_inreg := (r ->> 'in_region')::integer;
    v_req := (r ->> 'requests')::integer;
    v_err := (r ->> 'errors')::integer;
    v_complete := coalesce((r ->> 'complete')::boolean, true);
    v_url := null;
    if r ? 'url' and jsonb_typeof(r -> 'url') = 'string' then
      v_chk := public.source_url_check(r ->> 'url');
      -- A feed on another host (a calendar vendor) is fine; source_url_check applied the denylist.
      if (v_chk ->> 'ok')::boolean then
        v_url := v_chk ->> 'url';
      elsif v_chk ->> 'error' = 'url_denylisted' then
        v_out := 'denylisted';
      end if;
    end if;
    if public.collector_host_denied(v_c.host) is not null then
      v_out := 'denylisted';
    end if;

    -- A good run (design 6.3): valid in-window items inside the region, a complete read, under
    -- 20% errors, and a feed to read next time.
    v_good := v_out = 'ok' and coalesce(v_items, 0) >= 1 and coalesce(v_inreg, 0) >= 1 and v_complete
              and (coalesce(v_req, 0) = 0 or coalesce(v_err, 0)::numeric / v_req < 0.2)
              and coalesce(v_kind, v_c.feed_kind) is not null and coalesce(v_url, v_c.feed_url) is not null;
    if v_out = 'ok' and not v_good then
      v_out := case when coalesce(v_inreg, 0) = 0 or coalesce(v_items, 0) = 0 then 'empty' else 'error' end;
    end if;

    insert into public.source_probe_results
      (candidate_id, run_id, run_on, outcome, good, feed_kind, platform, items, in_region, requests, errors, complete)
    values (v_id, v_run, v_today, v_out, v_good, v_kind, v_plat, v_items, v_inreg, v_req, v_err, v_complete);

    v_status := v_c.status;
    v_reason := v_c.reason;
    v_retry := v_c.retry_after;
    v_lock := false;

    if v_good then
      v_c.ok_runs := v_c.ok_runs + 1;
      v_c.empty_runs := 0;
      v_c.empty_since := null;
      -- Migration 50: a good run ends a run of errors.
      v_c.error_runs := 0;
      v_c.error_since := null;
      v_c.feed_kind := coalesce(v_kind, v_c.feed_kind);
      v_c.feed_url := coalesce(v_url, v_c.feed_url);
      v_c.platform := coalesce(v_plat, v_c.platform);
      -- Two separate UTC days: a second good run on the same day does not count.
      if v_c.last_ok_on is distinct from v_today then
        v_c.ok_days := least(32000, v_c.ok_days + 1);
        v_c.last_ok_on := v_today;
      end if;
      v_reason := null;
      v_retry := null;
      if v_c.ok_days >= 2 then
        -- At most 40 enabled discovered sources a region (design 7).
        if v_c.status <> 'enabled' and v_c.region_id is not null
           and (select count(*) from public.source_candidates x
                 where x.region_id = v_c.region_id and x.status = 'enabled' and x.id <> v_id) >= 40 then
          v_status := 'probation';
          v_reason := 'region_cap';
        else
          v_status := 'enabled';
        end if;
      else
        v_status := 'probation';
      end if;
    elsif v_out in ('empty', 'no_feed') then
      v_c.empty_runs := v_c.empty_runs + 1;
      v_c.empty_since := coalesce(v_c.empty_since, v_today);
      if v_c.status in ('discovered', 'rejected') then
        v_status := 'rejected';
        v_reason := case when v_out = 'no_feed' then 'no_feed' else 'no_events_in_region' end;
        v_retry := now() + interval '30 days';
      elsif v_today - v_c.empty_since >= 30 then
        v_status := 'rejected';
        v_reason := 'empty_30_days';
        v_retry := now() + interval '30 days';
      elsif v_c.empty_runs >= 3 then
        v_status := 'paused';
        v_reason := 'empty_runs';
        v_retry := now() + interval '7 days';
      end if;
    elsif v_out = 'error' then
      v_c.error_runs := v_c.error_runs + 1;
      -- Migration 50: a live source that keeps failing is paused after 3 error runs with no good
      -- run between (retried weekly) and rejected after 30 days of errors (retry in 30 days).
      v_c.error_since := coalesce(v_c.error_since, v_today);
      if v_c.status in ('discovered', 'rejected') and v_c.error_runs >= 3 then
        v_status := 'rejected';
        v_reason := 'errors';
        v_retry := now() + interval '30 days';
      elsif v_c.status in ('probation', 'enabled', 'paused') and v_today - v_c.error_since >= 30 then
        v_status := 'rejected';
        v_reason := 'errors_30_days';
        v_retry := now() + interval '30 days';
      elsif v_c.status in ('probation', 'enabled', 'paused') and v_c.error_runs >= 3 then
        v_status := 'paused';
        v_reason := 'error_runs';
        v_retry := now() + interval '7 days';
      end if;
    elsif v_out = 'blocked' then
      -- 401, 403 or a bot challenge: rejected at once, never retried automatically.
      v_status := 'rejected';
      v_reason := 'blocked';
      v_retry := null;
    elsif v_out in ('robots', 'noindex') then
      v_status := 'rejected';
      v_reason := v_out;
      v_retry := now() + interval '30 days';
    elsif v_out = 'needs_permission' then
      v_status := 'needs_permission';
      v_reason := coalesce(v_plat, 'needs_permission');
      v_retry := null;
    elsif v_out = 'denylisted' then
      v_status := 'rejected';
      v_reason := 'denylisted';
      v_retry := null;
      v_lock := true;
    end if;
    if v_status = 'rejected' and v_c.status <> 'rejected' then
      v_c.ok_days := 0;
      v_c.last_ok_on := null;
    end if;

    update public.source_candidates
       set status = v_status, reason = v_reason, retry_after = v_retry, locked = locked or v_lock,
           status_at = case when v_status is distinct from status then now() else status_at end,
           ok_runs = v_c.ok_runs, empty_runs = v_c.empty_runs, error_runs = v_c.error_runs, error_since = v_c.error_since,
           ok_days = v_c.ok_days, last_ok_on = v_c.last_ok_on, empty_since = v_c.empty_since,
           feed_kind = v_c.feed_kind, feed_url = v_c.feed_url, platform = v_c.platform,
           last_probe_at = now()
     where id = v_id;

    -- The feed_sources row: created at probation (off), on only while enabled.
    v_slug := public.source_candidate_slug(v_id);
    if v_status in ('probation', 'enabled') and not exists (select 1 from public.feed_sources f where f.candidate_id = v_id) then
      v_name := coalesce(v_c.name, left(v_c.host, 80));
      v_attr := left(case when v_name = v_c.host then 'Events from ' || v_c.host
                          else 'Events from ' || v_name || ' (' || v_c.host || ')' end, 300);
      v_rpoint := null; v_rradius := null; v_rlabel := null; v_rtz := null;
      if v_c.region_id is not null then
        select g.point, g.radius_km, g.label, g.timezone into v_rpoint, v_rradius, v_rlabel, v_rtz
          from public.collector_regions g where g.id = v_c.region_id;
      end if;
      if not exists (select 1 from public.feed_sources f where f.slug = v_slug) then
        insert into public.feed_sources
          (slug, kind, url, name, attribution, homepage_url, enabled, collector, lane,
           region_point, region_radius_km, region_label, region_timezone, discovered_from,
           discovery_status, candidate_id)
        values
          (v_slug, case v_c.feed_kind when 'page' then 'jsonld' else v_c.feed_kind end, v_c.feed_url,
           case when char_length(v_name) < 2 then v_c.host else v_name end,
           case when char_length(v_attr) < 10 then 'Events from ' || v_c.host || ' (public calendar)' else v_attr end,
           'https://' || v_c.host || '/', false, true, case v_c.feed_kind when 'page' then 'page' else 'feed' end,
           v_rpoint, v_rradius, v_rlabel, v_rtz, v_c.url,
           v_status, v_id);
      end if;
    end if;
    update public.feed_sources
       set discovery_status = v_status,
           enabled = v_status = 'enabled' and not denylisted
     where candidate_id = v_id
       and (discovery_status is distinct from v_status or enabled is distinct from (v_status = 'enabled' and not denylisted));
    if v_lock then
      update public.feed_sources set enabled = false, denylisted = true where candidate_id = v_id;
    end if;

    v_counts := jsonb_set(v_counts, '{recorded}', to_jsonb((v_counts ->> 'recorded')::int + 1));
    if v_status in ('probation', 'enabled', 'paused', 'rejected') and v_status is distinct from v_c.status then
      v_counts := jsonb_set(v_counts, array[v_status], to_jsonb((v_counts ->> v_status)::int + 1));
    end if;
  end loop;
  return v_counts;
end $$;
comment on function public.source_candidates_record(jsonb) is
  'Service role (D-042 slice 7; POST /collector/sources/record): the discovery lifecycle (design 6.3) from probe or nightly-run results [{candidate_id, run_id, outcome ok|empty|no_feed|error|blocked|robots|noindex|needs_permission|denylisted, kind? ics|rss|page, url?, platform?, items?, in_region?, requests?, errors?, complete?}] (at most 500; all checked before any write). A good run (ok with at least 1 in-window item inside the region, complete, under 20% errors) counts its UTC day once: one day is probation (a feed_sources row disc-<id>, off), good runs on two separate days enable it (at most 40 enabled a region, else probation with reason region_cap). Empty or no feed: a not yet live candidate is rejected (retry in 30 days); a live one pauses after 3 empty runs (retry weekly) and is rejected after 30 empty days. Errors: a not yet live candidate is rejected after 3 (retry in 30 days); a live or paused one (migration 50) pauses after 3 error runs with no good run between (retry weekly) and is rejected after 30 days of errors (errors_30_days, retry in 30 days). 401/403/bot challenge: rejected at once, never retried; robots or noindex: rejected, retry in 30 days; Localist and the like: needs_permission; denylisted: rejected and locked. Rejection resets the good days. A second result for the same candidate and run_id is ignored (repeat). Each result is kept 90 days in source_probe_results. Returns counts. Error: results_invalid.';

-- ---------------------------------------------------------------------------
-- 2. Suggest a calendar: no link to the member
-- ---------------------------------------------------------------------------
alter table public.place_rate_log drop constraint if exists place_rate_log_kind;
alter table public.place_rate_log add constraint place_rate_log_kind check (kind in ('add', 'edit', 'calendar', 'file'));
comment on table public.place_rate_log is
  'Per-member rate limits (D-041 migration 36, D-042 migrations 46 and 50): one row per member place added (add), per place edit (edit), per calendar suggestion (calendar) and per place-files row request (file). Rows older than a day are deleted hourly (pg_cron prune-place-rate-log, migration 50), so a calendar suggestion cannot be traced to a member past a day. No client access; removed on account deletion.';

create or replace function public.place_rate_log_prune()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_n integer;
begin
  with gone as (
    delete from public.place_rate_log where created_at < now() - interval '1 day' returning 1
  )
  select count(*) into v_n from gone;
  return v_n;
end $$;
comment on function public.place_rate_log_prune() is
  'D-042 migration 50, pg_cron hourly (prune-place-rate-log): deletes place_rate_log rows older than a day (every window that reads it is a day or shorter). Returns the count. Internal.';
revoke all on function public.place_rate_log_prune() from public, anon, authenticated;
grant execute on function public.place_rate_log_prune() to service_role;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; prune-place-rate-log not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'prune-place-rate-log') then
    perform cron.unschedule('prune-place-rate-log');
  end if;
  perform cron.schedule('prune-place-rate-log', '29 * * * *', 'select public.place_rate_log_prune()');
end $$;

-- Member candidates keep their times to the hour. Runs after source_candidates_set_updated_at
-- (BEFORE triggers fire in name order).
create or replace function public.source_candidates_member_hour()
returns trigger language plpgsql set search_path = '' as $$
begin
  if new.origin = 'member' then
    new.updated_at := date_trunc('hour', new.updated_at);
    new.status_at := date_trunc('hour', new.status_at);
    if tg_op = 'INSERT' then
      new.created_at := date_trunc('hour', new.created_at);
    end if;
  end if;
  return new;
end $$;
comment on function public.source_candidates_member_hour() is
  'Trigger on source_candidates (migration 50): a member suggestion''s created_at, updated_at and status_at are stored to the hour, so the candidate cannot be matched to the suggesting member''s place_rate_log row by its time. Internal.';
revoke all on function public.source_candidates_member_hour() from public, anon, authenticated;

drop trigger if exists source_candidates_zz_member_hour on public.source_candidates;
create trigger source_candidates_zz_member_hour before insert or update on public.source_candidates
  for each row execute function public.source_candidates_member_hour();

-- Existing member rows, once (the trigger rounds updated_at and status_at; a re-run changes nothing).
update public.source_candidates
   set created_at = date_trunc('hour', created_at)
 where origin = 'member'
   and (created_at <> date_trunc('hour', created_at) or updated_at <> date_trunc('hour', updated_at)
        or status_at <> date_trunc('hour', status_at));

-- ---------------------------------------------------------------------------
-- 3 and 4. The Atlanta gate: a floor for required, 2 runs in 24 hours
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('discovery_gate_min_required', '6')
  on conflict (key) do nothing;

create or replace function public.source_discovery_gate_min_required()
returns integer language sql stable security definer set search_path = '' as $$
  select greatest(6, coalesce((select case when m.value ~ '^[0-9]{1,3}$' then m.value::integer end
                                 from public.meta m where m.key = 'discovery_gate_min_required'), 6));
$$;
comment on function public.source_discovery_gate_min_required() is
  'D-042 migration 50: the least `required` a gate run may be recorded with (meta discovery_gate_min_required, never below 6). Internal.';
revoke all on function public.source_discovery_gate_min_required() from public, anon, authenticated;
grant execute on function public.source_discovery_gate_min_required() to service_role;

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
  v_min      integer := public.source_discovery_gate_min_required();
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
  -- Migration 50: the pass threshold has a floor the caller cannot lower (meta
  -- discovery_gate_min_required, 6), and expected must cover it.
  if v_required < v_min or v_expected < v_required then
    raise exception 'gate_invalid' using errcode = 'check_violation', hint = 'required_below_floor';
  end if;
  select coalesce(array_agg(distinct lower(s.value #>> '{}')), '{}') into v_sites
    from jsonb_array_elements(coalesce(p_gate -> 'found_sites', '[]'::jsonb)) s;
  if cardinality(v_sites) > v_expected
     or exists (select 1 from unnest(v_sites) h
                 where h !~ '^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$' or char_length(h) > 253) then
    raise exception 'gate_invalid' using errcode = 'check_violation';
  end if;

  delete from public.source_discovery_gates where created_at < now() - interval '180 days';
  -- Migration 50: at most 2 gate runs in 24 hours (each one reads about 150 Atlanta hosts). One at
  -- a time, so two runs finishing together cannot both pass the count. A repeated run_id still
  -- answers as a repeat.
  perform pg_advisory_xact_lock(hashtextextended('source_discovery_gate_record', 0));
  if not exists (select 1 from public.source_discovery_gates g where g.run_id = v_run)
     and (select count(*) from public.source_discovery_gates g where g.created_at > now() - interval '24 hours') >= 2 then
    raise exception 'gate_rate_limited' using errcode = 'check_violation';
  end if;
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
  'Service role (D-042 slice 8; POST /collector/discovery/gate): records one run of the Atlanta discovery gate {run_id, probe_hash (16 to 64 hex), region, expected, required, found, found_sites?, counts?}. passed is computed here (found >= required). A repeated run_id is ignored. Migration 50: required must be at least meta discovery_gate_min_required (6), and at most 2 gate runs are recorded in 24 hours (gate_rate_limited). Returns {recorded, repeat, passed}. Errors: gate_invalid, gate_rate_limited.';

-- ---------------------------------------------------------------------------
-- 3. source_discovery_gate_status
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_gate_open(p_probe_hash text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.source_discovery_gates g
                  where g.probe_hash = lower(coalesce(p_probe_hash, ''))
                    and g.passed and g.created_at > now() - interval '30 days'
                    and g.required >= public.source_discovery_gate_min_required());  -- Migration 50
$$;
comment on function public.source_discovery_gate_open(text) is
  'D-042 slice 8: true when a gate run of this probe code passed within 30 days, with required at least meta discovery_gate_min_required (migration 50). Internal.';

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
                     limit 1),
           -- Migration 50: gate runs recorded in the last 24 hours (at most 2 are taken), so the
           -- CLI can stop before probing anything.
           'runs_24h', (select count(*) from public.source_discovery_gates g
                         where g.created_at > now() - interval '24 hours'),
           'max_runs_24h', 2);
$$;
comment on function public.source_discovery_gate_status(text) is
  'Service role (D-042 slice 8; GET /collector/discovery/gate?hash=): {open, last}: whether the probe code with this hash passed the Atlanta gate within 30 days, and its best recent run (a passing one first); runs_24h and max_runs_24h (migration 50): gate runs recorded in the last 24 hours and the most allowed.';

-- ---------------------------------------------------------------------------
-- 5. EU gate: a candidate's own country in a European region
-- ---------------------------------------------------------------------------
create or replace function public.source_discovery_zone_needs_country(p_tz text)
returns boolean language sql immutable set search_path = '' as $$
  select p_tz is null
      or p_tz like 'Europe/%' or p_tz like 'Atlantic/%' or p_tz like 'Arctic/%'
      or p_tz in ('Asia/Nicosia', 'Asia/Famagusta', 'Africa/Ceuta', 'America/Cayenne', 'America/Guadeloupe',
                  'America/Martinique', 'America/Marigot', 'Indian/Reunion', 'Indian/Mayotte');
$$;
comment on function public.source_discovery_zone_needs_country(text) is
  'D-042 migration 50: true for a region zone where a circle can hold places of a gated country (European, Atlantic and Arctic zones, the gated countries'' zones elsewhere) or when the zone is unknown; automatic candidates there need their own country. Internal.';
revoke all on function public.source_discovery_zone_needs_country(text) from public, anon, authenticated;
grant execute on function public.source_discovery_zone_needs_country(text) to service_role;

create or replace function public.source_discovery_allowed(p_origin text, p_country text, p_region uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select public.source_discovery_allowed(p_origin, p_country)
     and (p_origin = 'member'
          or coalesce((select m.value from public.meta m where m.key = 'eu_discovery'), 'off') = 'on'
          or p_country is not null
          or (p_region is not null
              and not public.source_discovery_zone_needs_country(
                    (select r.timezone from public.collector_regions r where r.id = p_region))));
$$;
comment on function public.source_discovery_allowed(text, text, uuid) is
  'D-042 EU gate with the region (migration 50): source_discovery_allowed(origin, country), and an osm or wikidata candidate without a country of its own is refused while meta.eu_discovery is off when its region''s zone needs one (source_discovery_zone_needs_country) or it has no region, so a Swiss region''s circle cannot let German or French places through. Internal.';
revoke all on function public.source_discovery_allowed(text, text, uuid) from public, anon, authenticated;
grant execute on function public.source_discovery_allowed(text, text, uuid) to service_role;

-- source_candidates_due: latest body (migration 46).
create or replace function public.source_candidates_due(p_limit integer default 150, p_regions uuid[] default null)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'url', q.url, 'host', q.host, 'origin', q.origin, 'region_id', q.region_id,
           'name', q.name, 'place_kind', q.place_kind, 'wikidata_id', q.wikidata_id, 'country', q.country,
           'score', q.score, 'status', q.status) order by q.ord), '[]'::jsonb)
    from (select c.*, row_number() over (order by c.score desc, c.created_at, c.id) as ord
            from public.source_candidates c
           where not c.locked
             and c.review_status in ('none', 'approved')
             and (c.status = 'discovered' or (c.status = 'rejected' and c.retry_after is not null))
             and (c.retry_after is null or c.retry_after <= now())
             and (p_regions is null or c.region_id = any (p_regions))
             and public.source_discovery_allowed(c.origin, c.country, c.region_id)  -- Migration 50: the region's zone too
             and public.collector_host_denied(c.host) is null
           order by c.score desc, c.created_at, c.id
           limit least(500, greatest(1, coalesce(p_limit, 150)))) q;
$$;
comment on function public.source_candidates_due(integer, uuid[]) is
  'Service role (D-042 slice 7; GET /collector/candidates): candidates to probe, by score: discovered ones and rejected ones whose retry_after has passed, not locked, member suggestions only once approved, not denylisted, and not osm or wikidata candidates in the EU, EEA or UK while meta.eu_discovery is off (migration 50: nor osm or wikidata candidates without a country of their own in a region whose zone is European, unknown or another gated country zone). Optional region filter; at most 500. No user ids.';


-- source_discovery_probe_queue: latest body (migration 47).
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
       and public.source_discovery_allowed(c.origin, c.country, c.region_id)  -- Migration 50: the region's zone too
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
  'Service role (D-042 slice 8; GET /collector/discovery/queue): candidates the probe may read now. discovery_gate_closed unless the probe code (p_probe_hash) passed the Atlanta gate within 30 days. Same rules as source_candidates_due (not locked, member suggestions only once approved, not denylisted, not osm or wikidata candidates in the EU, EEA or UK while meta.eu_discovery is off (migration 50: nor osm or wikidata candidates without a country of their own in a region whose zone is European, unknown or another gated country zone)), only candidates with a collector region, at most p_per_region (default 150) a region a UTC day less the probes recorded today (run ids probe-...), round-robin over regions by score; at most p_limit (default 500, up to 2,000). No user ids.';

-- ---------------------------------------------------------------------------
-- 6. Ticketing-only events keep no text past 7 days (latest body: migration 48)
-- ---------------------------------------------------------------------------
create or replace function public.collector_api_shows_sweep()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_cancelled integer := 0;
  v_cleared   integer := 0;
  v_purged    integer := 0;
  v_blanked   integer := 0;
  v_old       uuid[];
  v_free      uuid[];
begin
  with stale as (
    select e.id from public.events e
     where e.kind = 'imported' and e.status = 'published' and e.ends_at > now()
       and exists (select 1 from public.event_imports ei
                     join public.feed_sources fs on fs.id = ei.source_id
                    where ei.event_id = e.id and ei.removed_at is null
                      and fs.kind in ('ticketmaster', 'seatgeek'))
       and not exists (select 1 from public.event_imports ei
                         join public.feed_sources fs on fs.id = ei.source_id
                        where ei.event_id = e.id and ei.removed_at is null
                          and (fs.kind not in ('ticketmaster', 'seatgeek')
                               or ei.last_seen_at >= now() - interval '3 days'))
     for update of e skip locked
  ), done as (
    update public.events e
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'No longer listed by the source.'
      from stale where e.id = stale.id
    returning e.id
  )
  select count(*) into v_cancelled from done;

  with cleared as (
    update public.event_imports ei set raw = '{}'::jsonb
      from public.feed_sources fs
     where fs.id = ei.source_id and fs.kind in ('ticketmaster', 'seatgeek')
       and ei.raw <> '{}'::jsonb
       and ((ei.event_id is null and ei.last_seen_at < now() - interval '7 days')
            or exists (select 1 from public.events e
                        where e.id = ei.event_id and e.ends_at < now() - interval '7 days'))
    returning ei.id
  )
  select count(*) into v_cleared from cleared;

  -- Migration 50: events built from ticketing data alone keep no text past 7 days after they
  -- ended, or after they were cancelled as no longer listed. Deleted (with their ticketing
  -- import rows) when nothing refers to them; when a member RSVP'd, was notified or messaged,
  -- the row stays for that member's history with its description and image blanked.
  v_old := array(
    select e.id from public.events e
     where e.kind = 'imported'
       and (e.ends_at < now() - interval '7 days'
            or (e.status = 'cancelled' and e.cancel_reason = 'No longer listed by the source.'
                and e.cancelled_at < now() - interval '7 days'))
       and exists (select 1 from public.event_imports ei
                     join public.feed_sources fs on fs.id = ei.source_id
                    where ei.event_id = e.id and fs.kind in ('ticketmaster', 'seatgeek'))
       and not exists (select 1 from public.event_imports ei
                         join public.feed_sources fs on fs.id = ei.source_id
                        where ei.event_id = e.id and fs.kind not in ('ticketmaster', 'seatgeek'))
     order by e.ends_at
     limit 5000);
  v_free := array(
    select e.id from public.events e
     where e.id = any (v_old)
       and not exists (select 1 from public.rsvps x where x.event_id = e.id)
       and not exists (select 1 from public.notifications x where x.event_id = e.id)
       and not exists (select 1 from public.event_broadcasts x where x.event_id = e.id)
       and not exists (select 1 from public.event_meets x where x.event_id = e.id));
  -- Their ticketing import rows go first (event_id would only be set null).
  delete from public.event_imports ei where ei.event_id = any (v_free);
  with gone as (
    delete from public.events e where e.id = any (v_free) returning e.id
  )
  select count(*) into v_purged from gone;

  with blanked as (
    update public.events e
       set description = '', cover_url = null, price_text = null
     where e.id = any (v_old) and not (e.id = any (v_free))
       and (e.description <> '' or e.cover_url is not null or e.price_text is not null)
    returning e.id
  )
  select count(*) into v_blanked from blanked;

  return jsonb_build_object('cancelled', v_cancelled, 'raw_cleared', v_cleared,
                            'events_deleted', v_purged, 'events_blanked', v_blanked);
end $$;

comment on function public.collector_api_shows_sweep() is
  'D-042 slice 10, pg_cron daily (api-shows-sweep): the ticketing APIs'' caching limit (Ticketmaster: cache only for reasonable periods). Cancels upcoming published imported events whose only live copies are Ticketmaster or SeatGeek rows not seen for 3 days, as "No longer listed by the source." (the importer re-publishes them when listed again), and clears the stored raw item of ticketing rows 7 days after their event ended or, without an event, 7 days after last seen. Migration 50: events built from ticketing rows alone are removed 7 days after they ended or were cancelled as no longer listed (deleted with their import rows when no RSVP, notification, broadcast or meet refers to them, else description, image and price text blanked), at most 5,000 a day. Returns counts. No user data.';

-- ---------------------------------------------------------------------------
-- 7. place-files POST /place: active onboarded members, 60 an hour
-- ---------------------------------------------------------------------------
create or replace function public.place_file_request_take(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
begin
  if p_user_id is null or not exists (
       select 1 from public.profiles
        where id = p_user_id and status = 'active' and deleted_at is null
          and onboarding_completed_at is not null) then
    return jsonb_build_object('ok', false, 'error', 'onboarding_required');
  end if;
  perform pg_advisory_xact_lock(hashtextextended('place_file_request:' || p_user_id::text, 0));
  if (select count(*) from public.place_rate_log
       where user_id = p_user_id and kind = 'file' and created_at > now() - interval '1 hour') >= 60 then
    return jsonb_build_object('ok', false, 'error', 'rate_limited');
  end if;
  insert into public.place_rate_log (user_id, kind) values (p_user_id, 'file');
  return jsonb_build_object('ok', true);
end $$;
comment on function public.place_file_request_take(uuid) is
  'Service role (D-042 migration 50; the place-files Edge Function before POST /place): {ok: true} and one place_rate_log row (kind file) for an active, onboarded member under 60 calls in the last hour; else {ok: false, error: onboarding_required | rate_limited}. Returns no user data.';
revoke all on function public.place_file_request_take(uuid) from public, anon, authenticated;
grant execute on function public.place_file_request_take(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Grants of the rebuilt functions (unchanged)
-- ---------------------------------------------------------------------------
revoke all on function public.source_candidates_record(jsonb) from public, anon, authenticated;
grant execute on function public.source_candidates_record(jsonb) to service_role;
revoke all on function public.source_candidates_due(integer, uuid[]) from public, anon, authenticated;
grant execute on function public.source_candidates_due(integer, uuid[]) to service_role;
revoke all on function public.source_discovery_probe_queue(text, uuid[], integer, integer) from public, anon, authenticated;
grant execute on function public.source_discovery_probe_queue(text, uuid[], integer, integer) to service_role;
revoke all on function public.source_discovery_gate_record(jsonb) from public, anon, authenticated;
grant execute on function public.source_discovery_gate_record(jsonb) to service_role;
revoke all on function public.source_discovery_gate_open(text) from public, anon, authenticated;
grant execute on function public.source_discovery_gate_open(text) to service_role;
revoke all on function public.source_discovery_gate_status(text) from public, anon, authenticated;
grant execute on function public.source_discovery_gate_status(text) to service_role;
revoke all on function public.collector_api_shows_sweep() from public, anon, authenticated;
grant execute on function public.collector_api_shows_sweep() to service_role;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.46')
  on conflict (key) do update set value = excluded.value, updated_at = now();
