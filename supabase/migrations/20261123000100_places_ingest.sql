-- ============================================================================
-- Activity Planet schema v2 — migration 28: hub map ingest RPCs (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md sections 3.1, 3.5 and 5; build
--   slice 4). New functions only; no existing function is rebuilt.
--   Checks: supabase/tests/places_ingest.sql (and collector_smoke.sql for
--   the collector Edge Function).
--
--   What this file does
--     1. places.last_run_id and places.missed_runs: the last run of the
--        row's own tile that saw it, and how many of that tile's finished
--        runs in a row missed it. Not client-readable (column grants).
--     2. place_tile_runs: one row per (tile, source, run). received is the
--        row count the collector sent (per batch number when given, so a
--        retried batch is not counted twice); finish_place_tile compares it
--        with the count the job reports. No user id. Service role writes;
--        moderators read.
--     3. ingest_places(tile_id, run_id, batch, source default 'osm',
--        batch_no default null), service_role only. Up to 2,000 rows of one
--        source (osm or geoapify). Each row is normalized (name, kind, known
--        rule ids, point, tag allowlist, https website, country code) or
--        skipped with a counted reason; nothing raises on a bad row.
--          * Upsert by (source, source_id). Only the imported sources are
--            ever written: source = 'user' and 'venue' rows are never read
--            for update, so member places and meeting spots stay untouched.
--          * Locked fields (an approved correction) keep their value; a
--            'closed' lock freezes the open/closed status.
--          * A closed row that shows up again reopens; hidden and removed
--            rows (moderation) are never reopened or rewritten.
--          * osm_ref merge: an OSM row whose element a Geoapify row already
--            carries takes that row's place: the new OSM row keeps the
--            Geoapify row's locked fields and values, its hub links and the
--            venues pointing at it; the Geoapify row becomes 'removed' with
--            merged_into set. A Geoapify row for an element that already
--            has an OSM row is skipped (osm_row_exists).
--          * Idempotent: a row whose content is unchanged is only stamped
--            (last_seen_at, run), so a re-ingest updates nothing.
--          * Rows whose point is outside the run's tile (the extract's
--            2 km margin) are upserted but not stamped with this run: miss
--            counting belongs to each row's own tile.
--     4. finish_place_tile(tile_id, run_id, count, source default 'osm'),
--        service_role only. Refuses a count that differs from what the run
--        received (count_mismatch) and an empty run on a tile that has rows
--        (empty_run), so a lost batch or a broken extract never closes
--        places. Every active row of that source in the tile that this run
--        did not see gets one more miss; at two misses in a row it is
--        'closed' (unless 'closed' is locked). Stamps the tile (osm_run_at
--        or geoapify_run_at, row_count, wanted/filling to active after an
--        OSM run, wanted to filling after a Geoapify run). Calling it again
--        for the same run returns the stored result and changes nothing.
--        Keeps the latest 10 finished runs per tile and source.
--     5. place_tiles_queue(kinds default {wanted,refresh}, limit default
--        20), service_role only: tile ids, status and bounding boxes for
--        the extract job (refresh = active and no OSM run for 6 days). No
--        user data.
--     6. Collector shared secret: vault secret collector_secret is
--        generated in the database (gen_random_bytes) when absent and is in
--        no file; collector_verify_secret(p_secret) (service_role) lets the
--        collector Edge Function check the caller. It is a separate secret
--        from import_feed_secret, so it can reach only the collector routes
--        (D-040: the workflow holds a collector secret, never the service
--        role key).
--     * meta.schema_version 2.24.
--
--   Account deletion: nothing here references a user (no new columns or
--   tables with a user id), so request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. places: run stamps for miss counting
-- ---------------------------------------------------------------------------
alter table public.places add column if not exists last_run_id text;
alter table public.places add column if not exists missed_runs smallint not null default 0;
do $$ begin
  alter table public.places add constraint places_last_run_id_format
    check (last_run_id is null or last_run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$');
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.places add constraint places_missed_runs_range check (missed_runs between 0 and 100);
exception when duplicate_object then null; end $$;

comment on column public.places.last_run_id is
  'The last finished-or-open collector run of this row''s own tile that saw it (ingest_places). Service role only.';
comment on column public.places.missed_runs is
  'Consecutive finished runs of the row''s tile that did not see it; finish_place_tile closes the row at 2.';

-- ---------------------------------------------------------------------------
-- 2. place_tile_runs (no user id)
-- ---------------------------------------------------------------------------
create table if not exists public.place_tile_runs (
  tile_id     integer not null references public.place_tiles (id) on delete cascade,
  source      public.place_source not null,
  run_id      text not null,
  received    integer not null default 0,              -- loose + the batch counts
  loose       integer not null default 0,              -- rows from calls without a batch number
  batches     jsonb not null default '{}',             -- {"<batch_no>": rows received}
  stats       jsonb not null default '{}',
  started_at  timestamptz not null default now(),
  finished_at timestamptz,
  primary key (tile_id, source, run_id),
  constraint place_tile_runs_source check (source in ('osm', 'geoapify')),
  constraint place_tile_runs_run_id_format check (run_id ~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$'),
  constraint place_tile_runs_received_nonneg check (received >= 0 and loose >= 0),
  constraint place_tile_runs_batches_shape check (jsonb_typeof(batches) = 'object'),
  constraint place_tile_runs_stats_shape check (jsonb_typeof(stats) = 'object')
);
create index if not exists place_tile_runs_recent_idx on public.place_tile_runs (tile_id, source, started_at desc);
comment on table public.place_tile_runs is
  'Collector runs per place tile and source (D-041 slice 4): rows received, per-batch counts and the finish result. No user id. Service role writes; moderators read.';

alter table public.place_tile_runs enable row level security;
revoke all on public.place_tile_runs from public, anon, authenticated;
grant all on public.place_tile_runs to service_role;
grant select on public.place_tile_runs to authenticated;   -- rows only through the moderator policy
drop policy if exists "place_tile_runs_select_mod" on public.place_tile_runs;
create policy "place_tile_runs_select_mod" on public.place_tile_runs for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 3. ingest_places
-- ---------------------------------------------------------------------------
create or replace function public.ingest_places(
  p_tile_id  integer,
  p_run_id   text,
  p_batch    jsonb,
  p_source   text default 'osm',
  p_batch_no integer default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_allow   constant text[] := array['sport', 'religion', 'denomination', 'lgbtq', 'access', 'fee', 'lit',
                                     'indoor', 'surface', 'hoops', 'wheelchair', 'wikidata', 'phone', 'brand'];
  v_src     public.place_source;
  v_tile    public.place_tiles%rowtype;
  v_run     public.place_tile_runs%rowtype;
  v_item    jsonb;
  v_ex      public.places%rowtype;
  v_mrg     public.places%rowtype;
  v_found   boolean;
  v_merge   boolean;
  v_reason  text;
  v_id      uuid;
  v_sid     text;
  v_ref     text;
  v_name    text;
  v_kind    text;
  v_rules   smallint[];
  v_lat     double precision;
  v_lng     double precision;
  v_addr    text;
  v_local   text;
  v_country text;
  v_hours   text;
  v_web     text;
  v_tags    jsonb;
  v_attr    text;
  v_own     boolean;
  v_lock    text[];
  v_status  public.place_status;
  n_name    text;
  n_kind    text;
  n_lat     double precision;
  n_lng     double precision;
  n_addr    text;
  n_local   text;
  n_country text;
  n_hours   text;
  n_web     text;
  n_tags    jsonb;
  v_n       integer := 0;
  v_in      integer := 0;
  v_up      integer := 0;
  v_same    integer := 0;
  v_merged  integer := 0;
  v_reopen  integer := 0;
  v_skip    jsonb := '{}';
  v_total   integer;
begin
  if p_source is null or p_source not in ('osm', 'geoapify') then
    raise exception 'source_invalid' using errcode = 'check_violation';
  end if;
  v_src := p_source::public.place_source;
  if p_run_id is null or p_run_id !~ '^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$' then
    raise exception 'run_id_invalid' using errcode = 'check_violation';
  end if;
  if p_batch is null or jsonb_typeof(p_batch) <> 'array' then
    raise exception 'batch_invalid' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_batch) > 2000 then
    raise exception 'batch_too_large' using errcode = 'check_violation', hint = 'At most 2,000 rows per call.';
  end if;
  if p_batch_no is not null and (p_batch_no < 0 or p_batch_no > 100000) then
    raise exception 'batch_no_invalid' using errcode = 'check_violation';
  end if;

  select * into v_tile from public.place_tiles where id = p_tile_id for update;
  if not found then
    raise exception 'tile_unknown' using errcode = 'P0002';
  end if;
  if v_tile.status = 'retired' then
    raise exception 'tile_retired' using errcode = 'check_violation';
  end if;

  insert into public.place_tile_runs (tile_id, source, run_id) values (p_tile_id, v_src, p_run_id)
  on conflict (tile_id, source, run_id) do nothing;
  select * into v_run from public.place_tile_runs
   where tile_id = p_tile_id and source = v_src and run_id = p_run_id for update;
  if v_run.finished_at is not null then
    raise exception 'run_finished' using errcode = 'check_violation';
  end if;

  v_attr := case v_src when 'osm' then '© OpenStreetMap contributors'
                       else 'Powered by Geoapify · © OpenStreetMap contributors' end;

  for v_item in select e.value from jsonb_array_elements(p_batch) as e(value) loop
    v_n := v_n + 1;
    v_reason := null;

    -- Normalize, or name the reason the row is skipped.
    if jsonb_typeof(v_item) <> 'object' then
      v_reason := 'not_object';
    elsif v_item ? 'source' and v_item ->> 'source' is distinct from p_source then
      v_reason := 'source_mismatch';
    end if;

    if v_reason is null then
      v_sid := btrim(coalesce(v_item ->> 'source_id', ''));
      v_ref := nullif(btrim(coalesce(v_item ->> 'osm_ref', '')), '');
      if v_src = 'osm' then
        v_ref := coalesce(v_ref, v_sid);
        if v_sid !~ '^[nwr][0-9]{1,15}$' or v_ref <> v_sid then
          v_reason := 'source_id_invalid';
        end if;
      else
        if char_length(v_sid) not between 1 and 200 then
          v_reason := 'source_id_invalid';
        elsif v_ref is not null and v_ref !~ '^[nwr][0-9]{1,15}$' then
          v_ref := null;
        end if;
      end if;
    end if;

    if v_reason is null then
      v_name := left(regexp_replace(btrim(coalesce(v_item ->> 'name', '')), '\s+', ' ', 'g'), 120);
      v_kind := btrim(coalesce(v_item ->> 'kind', ''));
      if v_name = '' then
        v_reason := 'name_missing';
      elsif not exists (select 1 from public.place_kinds k where k.slug = v_kind) then
        v_reason := 'kind_unknown';
      end if;
    end if;

    if v_reason is null then
      select coalesce(array_agg(x.id order by x.id), '{}') into v_rules
        from (select distinct r.id
                from jsonb_array_elements_text(case when jsonb_typeof(v_item -> 'rule_ids') = 'array'
                                                    then v_item -> 'rule_ids' else '[]'::jsonb end) as e(t)
                join public.place_rules r on r.id::text = btrim(e.t)
               order by r.id limit 64) as x;
      if cardinality(v_rules) = 0 then
        v_reason := 'no_rules';
      end if;
    end if;

    if v_reason is null then
      if jsonb_typeof(v_item -> 'lat') <> 'number' or jsonb_typeof(v_item -> 'lng') <> 'number' then
        v_reason := 'point_invalid';
      else
        v_lat := (v_item ->> 'lat')::double precision;
        v_lng := (v_item ->> 'lng')::double precision;
        if v_lat not between -90 and 90 or v_lng not between -180 and 180 then
          v_reason := 'point_invalid';
        end if;
      end if;
    end if;

    if v_reason is not null then
      v_skip := jsonb_set(v_skip, array[v_reason], to_jsonb(coalesce((v_skip ->> v_reason)::integer, 0) + 1));
      continue;
    end if;

    v_addr    := left(btrim(coalesce(v_item ->> 'address_text', '')), 200);
    v_local   := left(btrim(coalesce(v_item ->> 'locality', '')), 120);
    v_country := upper(btrim(coalesce(v_item ->> 'country', '')));
    if v_country !~ '^[A-Z]{2}$' then v_country := null; end if;
    v_hours   := nullif(btrim(coalesce(v_item ->> 'opening_hours', '')), '');
    if char_length(v_hours) > 255 then v_hours := null; end if;
    v_web     := nullif(btrim(coalesce(v_item ->> 'website', '')), '');
    if v_web !~ '^https?://' or char_length(v_web) > 500 then v_web := null; end if;
    select coalesce(jsonb_object_agg(t.key, to_jsonb(left(t.value #>> '{}', 255))), '{}'::jsonb) into v_tags
      from jsonb_each(case when jsonb_typeof(v_item -> 'tags') = 'object' then v_item -> 'tags' else '{}'::jsonb end) as t
     where t.key = any (c_allow) and jsonb_typeof(t.value) in ('string', 'number', 'boolean');
    if pg_column_size(v_tags) > 1024 then v_tags := '{}'::jsonb; end if;
    v_own := public.place_tile_id(v_lat, v_lng) = p_tile_id;

    -- Existing row of this imported source (never a user or venue row).
    select * into v_ex from public.places
     where source = v_src and source_id = v_sid for update;
    v_found := found;

    if v_found then
      if v_ex.merged_into is not null or v_ex.status in ('removed', 'hidden') then
        -- Moderation decided; the importer only notes that the element still exists.
        update public.places set last_seen_at = now() where id = v_ex.id;
        v_skip := jsonb_set(v_skip, array['moderated'], to_jsonb(coalesce((v_skip ->> 'moderated')::integer, 0) + 1));
        continue;
      end if;
      if v_src = 'geoapify' and v_ref is not null and v_ref is distinct from v_ex.osm_ref
         and exists (select 1 from public.places o where o.osm_ref = v_ref and o.status <> 'removed' and o.id <> v_ex.id) then
        v_ref := v_ex.osm_ref;   -- another row holds that element; keep this row's link
      end if;
      v_lock    := v_ex.locked_fields;
      n_name    := case when 'name' = any (v_lock) then v_ex.name else v_name end;
      n_kind    := case when 'kind' = any (v_lock) then v_ex.kind else v_kind end;
      n_lat     := case when 'location' = any (v_lock) then v_ex.lat else v_lat end;
      n_lng     := case when 'location' = any (v_lock) then v_ex.lng else v_lng end;
      n_addr    := case when 'address_text' = any (v_lock) then v_ex.address_text else v_addr end;
      n_local   := case when 'locality' = any (v_lock) then v_ex.locality else v_local end;
      n_country := case when 'country' = any (v_lock) then v_ex.country else v_country end;
      n_hours   := case when 'opening_hours' = any (v_lock) then v_ex.opening_hours else v_hours end;
      n_web     := case when 'website' = any (v_lock) then v_ex.website else v_web end;
      n_tags    := case when 'tags' = any (v_lock) then v_ex.tags else v_tags end;
      v_status  := case when v_ex.status = 'closed' and not ('closed' = any (v_lock)) then 'active'::public.place_status
                        else v_ex.status end;
      if v_status is distinct from v_ex.status then v_reopen := v_reopen + 1; end if;

      if (n_name, n_kind, v_rules, n_lat, n_lng, n_addr, n_local, n_country, n_hours, n_web, n_tags, v_ref,
          v_status, v_attr)
         is distinct from
         (v_ex.name, v_ex.kind, v_ex.rule_ids, v_ex.lat, v_ex.lng, v_ex.address_text, v_ex.locality,
          v_ex.country, v_ex.opening_hours, v_ex.website, v_ex.tags, v_ex.osm_ref, v_ex.status, v_ex.attribution) then
        update public.places
           set name          = n_name,
               kind          = n_kind,
               rule_ids      = v_rules,
               location      = case when 'location' = any (v_lock) then location
                                    else extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography end,
               address_text  = n_addr,
               locality      = n_local,
               country       = n_country,
               opening_hours = n_hours,
               website       = n_web,
               tags          = n_tags,
               osm_ref       = v_ref,
               status        = v_status,
               attribution   = v_attr,
               last_seen_at  = now(),
               last_run_id   = case when v_own then p_run_id else last_run_id end,
               missed_runs   = case when v_own then 0 else missed_runs end
         where id = v_ex.id;
        v_up := v_up + 1;
      else
        update public.places
           set last_seen_at = now(),
               last_run_id  = case when v_own then p_run_id else last_run_id end,
               missed_runs  = case when v_own then 0 else missed_runs end
         where id = v_ex.id;
        v_same := v_same + 1;
      end if;
      continue;
    end if;

    -- New row. A Geoapify row for an element that already has an OSM row adds nothing.
    if v_src = 'geoapify' and v_ref is not null
       and exists (select 1 from public.places o where o.osm_ref = v_ref and o.status <> 'removed') then
      v_skip := jsonb_set(v_skip, array['osm_row_exists'], to_jsonb(coalesce((v_skip ->> 'osm_row_exists')::integer, 0) + 1));
      continue;
    end if;

    v_merge := false;
    if v_src = 'osm' then
      select * into v_mrg from public.places
       where osm_ref = v_ref and status <> 'removed' and source = 'geoapify' for update;
      v_merge := found;
    end if;

    if v_merge then
      v_lock := v_mrg.locked_fields;
      v_status := case when v_mrg.status = 'hidden' then 'hidden'::public.place_status
                       when v_mrg.status = 'closed' and 'closed' = any (v_lock) then 'closed'::public.place_status
                       else 'active'::public.place_status end;
      -- Free the osm_ref slot (the unique index skips removed rows), then take its place.
      update public.places set status = 'removed' where id = v_mrg.id;
      insert into public.places (source, source_id, osm_ref, name, kind, rule_ids, location, address_text, locality,
                                 country, opening_hours, website, tags, is_public, status, locked_fields,
                                 attribution, last_seen_at, last_run_id, missed_runs)
      values (v_src, v_sid, v_ref,
              case when 'name' = any (v_lock) then v_mrg.name else v_name end,
              case when 'kind' = any (v_lock) then v_mrg.kind else v_kind end,
              v_rules,
              case when 'location' = any (v_lock) then v_mrg.location
                   else extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography end,
              case when 'address_text' = any (v_lock) then v_mrg.address_text else v_addr end,
              case when 'locality' = any (v_lock) then v_mrg.locality else v_local end,
              case when 'country' = any (v_lock) then v_mrg.country else v_country end,
              case when 'opening_hours' = any (v_lock) then v_mrg.opening_hours else v_hours end,
              case when 'website' = any (v_lock) then v_mrg.website else v_web end,
              case when 'tags' = any (v_lock) then v_mrg.tags else v_tags end,
              true, v_status, v_lock, v_attr, now(),
              case when v_own then p_run_id end, 0)
      returning id into v_id;
      update public.places set merged_into = v_id where id = v_mrg.id;
      insert into public.place_hubs (place_id, hub_id, via, weight, created_at)
      select v_id, ph.hub_id, ph.via, ph.weight, ph.created_at from public.place_hubs ph where ph.place_id = v_mrg.id
      on conflict (place_id, hub_id) do nothing;
      delete from public.place_hubs where place_id = v_mrg.id;
      update public.venues set place_ref = v_id where place_ref = v_mrg.id;
      v_merged := v_merged + 1;
    else
      insert into public.places (source, source_id, osm_ref, name, kind, rule_ids, location, address_text, locality,
                                 country, opening_hours, website, tags, is_public, status, attribution,
                                 last_seen_at, last_run_id, missed_runs)
      values (v_src, v_sid, v_ref, v_name, v_kind, v_rules,
              extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography,
              v_addr, v_local, v_country, v_hours, v_web, v_tags, true, 'active', v_attr,
              now(), case when v_own then p_run_id end, 0);
      v_in := v_in + 1;
    end if;
  end loop;

  -- Rows received by this run: per batch number when given (a retried batch replaces its own
  -- count), plus the unnumbered calls.
  if p_batch_no is null then
    update public.place_tile_runs set loose = loose + v_n
     where tile_id = p_tile_id and source = v_src and run_id = p_run_id;
  else
    update public.place_tile_runs set batches = jsonb_set(batches, array[p_batch_no::text], to_jsonb(v_n))
     where tile_id = p_tile_id and source = v_src and run_id = p_run_id;
  end if;
  update public.place_tile_runs r
     set received = r.loose + (select coalesce(sum(b.value::integer), 0) from jsonb_each_text(r.batches) as b)
   where tile_id = p_tile_id and source = v_src and run_id = p_run_id;
  update public.place_tile_runs
     set stats = jsonb_build_object(
           'inserted', coalesce((stats ->> 'inserted')::integer, 0) + v_in,
           'updated',  coalesce((stats ->> 'updated')::integer, 0) + v_up,
           'merged',   coalesce((stats ->> 'merged')::integer, 0) + v_merged)
   where tile_id = p_tile_id and source = v_src and run_id = p_run_id
  returning received into v_total;

  return jsonb_build_object(
    'tile_id', p_tile_id, 'run_id', p_run_id, 'source', p_source, 'received', v_n,
    'inserted', v_in, 'updated', v_up, 'unchanged', v_same, 'merged', v_merged, 'reopened', v_reopen,
    'skipped', v_skip, 'run_received', v_total);
end $$;

comment on function public.ingest_places(integer, text, jsonb, text, integer) is
  'Collector ingest (D-041 slice 4), service_role only: up to 2,000 rows of one imported source (osm or geoapify) for a place tile run. Upserts by (source, source_id), never touches user or venue rows, keeps locked fields, reopens closed rows unless closed is locked, leaves hidden and removed rows alone, merges an OSM row into the Geoapify row carrying its osm_ref (links, venues and locks move; the Geoapify row is removed with merged_into), skips bad rows with counted reasons. Unchanged rows are only stamped, so a re-ingest updates nothing. Returns counts.';

-- ---------------------------------------------------------------------------
-- 4. finish_place_tile
-- ---------------------------------------------------------------------------
create or replace function public.finish_place_tile(
  p_tile_id integer,
  p_run_id  text,
  p_count   integer,
  p_source  text default 'osm')
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

comment on function public.finish_place_tile(integer, text, integer, text) is
  'Collector run end (D-041 slice 4), service_role only: checks the reported count against the rows the run received (count_mismatch), refuses an empty run on a tile with places (empty_run), adds a miss to every active row of that source and tile the run did not see and closes rows at two misses in a row (not when closed is locked), stamps the tile (run time, row_count, status) and returns the counts (previous_seen, the last run''s count, for the 30% drop check). Repeat calls for a finished run return the stored result.';

-- ---------------------------------------------------------------------------
-- 5. place_tiles_queue
-- ---------------------------------------------------------------------------
create or replace function public.place_tiles_queue(
  p_kinds text[] default array['wanted', 'refresh'],
  p_limit integer default 20)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id', q.id, 'status', q.status, 'demand', q.demand, 'row_count', q.row_count,
           'osm_run_at', q.osm_run_at,
           'west', extensions.ST_XMin(q.bbox), 'south', extensions.ST_YMin(q.bbox),
           'east', extensions.ST_XMax(q.bbox), 'north', extensions.ST_YMax(q.bbox))
           order by q.demand desc, q.osm_run_at nulls first, q.id), '[]'::jsonb)
    from (select t.* from public.place_tiles t
           where ('wanted' = any (p_kinds) and t.status = 'wanted')
              or ('refresh' = any (p_kinds) and t.status = 'active'
                  and (t.osm_run_at is null or t.osm_run_at < now() - interval '6 days'))
           order by t.demand desc, t.osm_run_at nulls first, t.id
           limit greatest(1, least(coalesce(p_limit, 20), 100))) as q;
$$;

comment on function public.place_tiles_queue(text[], integer) is
  'Collector tiles queue (design 3.1 step 1), service_role only: wanted tiles and active tiles due a weekly refresh (no OSM run for 6 days), with bounding boxes. No user data.';

-- ---------------------------------------------------------------------------
-- 6. Collector shared secret
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; collector_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'collector_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'collector_secret',
                                'Shared secret between the collector jobs and the collector Edge Function (D-040, D-041)');
  end if;
end $$;

create or replace function public.collector_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if p_secret is null or char_length(p_secret) < 32 then
    return false;
  end if;
  select ds.decrypted_secret into v_secret
    from vault.decrypted_secrets ds where ds.name = 'collector_secret' limit 1;
  return v_secret is not null and v_secret = p_secret;
end $$;

comment on function public.collector_verify_secret(text) is
  'True when p_secret is the vault secret collector_secret (generated in the database). Service role only; used by the collector Edge Function.';

-- ---------------------------------------------------------------------------
-- 7. Function grants (explicit): service_role only
-- ---------------------------------------------------------------------------
revoke all on function public.ingest_places(integer, text, jsonb, text, integer) from public, anon, authenticated;
revoke all on function public.finish_place_tile(integer, text, integer, text) from public, anon, authenticated;
revoke all on function public.place_tiles_queue(text[], integer) from public, anon, authenticated;
revoke all on function public.collector_verify_secret(text) from public, anon, authenticated;
grant execute on function public.ingest_places(integer, text, jsonb, text, integer) to service_role;
grant execute on function public.finish_place_tile(integer, text, integer, text) to service_role;
grant execute on function public.place_tiles_queue(text[], integer) to service_role;
grant execute on function public.collector_verify_secret(text) to service_role;

-- ---------------------------------------------------------------------------
-- 8. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.24')
  on conflict (key) do update set value = excluded.value, updated_at = now();
