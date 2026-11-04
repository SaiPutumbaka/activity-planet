-- ============================================================================
-- Activity Planet schema v2 — migration 49: place matching and lookups that
--   work from the static place files (D-042 slice 11,
--   docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 4.5 "Moves off
--   Postgres"). Until now a public OpenStreetMap place could be matched to a
--   venue, reported, corrected, linked to a hub or used for "Start a plan
--   here" only while Postgres held its row. This migration lets the database
--   take a row from the tile's published file when it needs one, verified
--   against the file's sha256, so an OSM place can live only in its file and
--   still be matched and acted on. Member places, meeting spots, hub links,
--   corrections and moderation stay in Postgres as before.
--   New functions, one new table and one pg_cron job; no existing function is
--   rebuilt and nothing is deleted. Checks: supabase/tests/places_off_postgres.sql.
--
--   What this file does
--     1. meta places_base_url: where the published files are served (GitHub
--        Pages, D-042); the place-files Edge Function reads files from here
--        (its PLACES_BASE_URL secret wins when set).
--     2. place_file_of_tile(tile), service_role: the tile's current published
--        file {tile, path, sha256, count, built_from, base}, or null. The
--        same conditions as place_files_in_view (switch on, rules file
--        published, tile active or idle, file published, current rules).
--     3. place_file_at(lat, lng), anon and authenticated: {tile, path} of the
--        published file holding a point, or null. Public file names only, the
--        same as map_in_view already offers for a view. The app reads it for
--        a moderation card's "nearby on the map" (design: "three public
--        places within 150 m" from the files).
--     4. place_from_file(tile, sha256, row), service_role: the database row
--        of one file place. Refused unless sha256 is the tile's current
--        published file (the Edge Function fetched and hashed it); the row is
--        normalised exactly like ingest_places (kind, rule ids, address,
--        hours, website, tag allowlist) and must lie in the tile. An existing
--        row with that OSM ref answers instead (null when a moderator hid,
--        removed or merged it, so the database decision stands). New rows are
--        source osm, active, public, no user id.
--     5. place_venue_file_checks (venue id, files key, checked day): which
--        published files a public venue was last checked against, so each
--        venue is checked once per file version. No user id; the venue
--        foreign key cascades.
--     6. place_match_queue(limit), service_role: public venues with a point
--        that have no matched place (no place_ref, or only their own meeting
--        spot row), in tiles with a published file, not yet checked against
--        the current files: [{venue_id, name, lng, lat, key, files}]. files
--        lists the venue's tile and any neighbour within about 66 m, so a
--        venue on a tile edge is matched like the database matcher would.
--     7. place_match_record(results), service_role: for each venue, the file
--        place the Edge Function matched (60 m, same or close name, trigram
--        0.45, the meeting_spot_refresh rule) becomes a row through
--        place_from_file, the check is stored, and meeting_spot_refresh runs,
--        so the database's own matcher makes the link (and drops the venue's
--        own meeting spot row) exactly as when Postgres held every place.
--     8. place_match_dispatch(force) and pg_cron job place-match (minutes 11
--        and 41): POSTs to the place-files Edge Function with the collector
--        secret through pg_net when a venue is queued.
--     * meta.schema_version 2.45.
--
--   Account deletion: place_venue_file_checks holds no user id and cascades
--   with its venue (private venues go with their member; public venues stay
--   without a creator); rows made by place_from_file are ODbL imports with no
--   user id. request_account_deletion is unchanged.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. meta places_base_url
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('places_base_url', 'https://saiputumbaka.github.io/activity-planet/')
  on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- 2. place_file_of_tile
-- ---------------------------------------------------------------------------
create or replace function public.place_file_of_tile(p_tile integer)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_rules jsonb;
  t       public.place_tiles%rowtype;
begin
  if p_tile is null then
    return null;
  end if;
  if coalesce((select m.value from public.meta m where m.key = 'places_files'), 'off') <> 'on' then
    return null;
  end if;
  select m.value::jsonb into v_rules from public.meta m where m.key = 'places_rules_file';
  if v_rules is null or coalesce((v_rules ->> 'published')::boolean, false) is false then
    return null;
  end if;
  select * into t from public.place_tiles pt
   where pt.id = p_tile and pt.file_path is not null and pt.file_published_at is not null
     and pt.status in ('active', 'idle')
     and pt.file_rules_version = (v_rules ->> 'rules_version')::integer;
  if not found then
    return null;
  end if;
  return jsonb_build_object(
    'tile', t.id, 'path', t.file_path, 'sha256', t.file_sha256, 'count', t.file_count,
    'built_from', t.file_built_from,
    'base', nullif((select m.value from public.meta m where m.key = 'places_base_url'), ''));
end $$;

comment on function public.place_file_of_tile(integer) is
  'D-042 slice 11, service_role: the current published static file of a place tile {tile, path, sha256, count, built_from, base} or null (switch off, no published rules file, tile not active or idle, no published file, or an older rules version). The same conditions as place_files_in_view.';

revoke all on function public.place_file_of_tile(integer) from public, anon, authenticated;
grant execute on function public.place_file_of_tile(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 3. place_file_at
-- ---------------------------------------------------------------------------
create or replace function public.place_file_at(p_lat double precision, p_lng double precision)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v jsonb;
begin
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    return null;
  end if;
  v := public.place_file_of_tile(public.place_tile_id(p_lat, p_lng));
  if v is null then
    return null;
  end if;
  return jsonb_build_object('tile', v -> 'tile', 'path', v -> 'path');
end $$;

comment on function public.place_file_at(double precision, double precision) is
  'D-042 slice 11: {tile, path} of the published static place file holding a point, or null. Public file names only (map_in_view offers the same for a view). Stores nothing.';

revoke all on function public.place_file_at(double precision, double precision) from public;
grant execute on function public.place_file_at(double precision, double precision) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. place_from_file
-- ---------------------------------------------------------------------------
create or replace function public.place_from_file(p_tile integer, p_sha256 text, p_row jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_allow   constant text[] := array['sport', 'religion', 'denomination', 'lgbtq', 'access', 'fee', 'lit',
                                     'indoor', 'surface', 'hoops', 'wheelchair', 'wikidata', 'phone', 'brand'];
  v_file  jsonb;
  v_ref   text;
  v_name  text;
  v_kind  text;
  v_rules smallint[];
  v_lat   double precision;
  v_lng   double precision;
  v_addr  text;
  v_local text;
  v_hours text;
  v_web   text;
  v_tags  jsonb;
  v_id    uuid;
  v_st    public.place_status;
  v_pub   boolean;
  v_mrg   uuid;
begin
  v_file := public.place_file_of_tile(p_tile);
  if v_file is null or p_sha256 is null or v_file ->> 'sha256' is distinct from p_sha256 then
    raise exception 'file_not_current' using errcode = 'check_violation',
      hint = 'The tile has no published file with this sha256.';
  end if;
  if p_row is null or jsonb_typeof(p_row) <> 'object' then
    raise exception 'row_invalid' using errcode = 'check_violation';
  end if;

  v_ref := btrim(coalesce(p_row ->> 'osm_ref', ''));
  if v_ref !~ '^[nwr][0-9]{1,15}$' then
    raise exception 'osm_ref_invalid' using errcode = 'check_violation';
  end if;

  -- A row the database already has answers: the database decides (a hidden,
  -- removed or merged row is never brought back from a file).
  select p.id, p.status, p.is_public, p.merged_into into v_id, v_st, v_pub, v_mrg
    from public.places p
   where (p.source = 'osm' and p.source_id = v_ref)
      or (p.osm_ref = v_ref and p.status <> 'removed')
   order by (p.source = 'osm') desc, p.created_at
   limit 1;
  if v_id is not null then
    return case when v_st = 'active' and v_pub and v_mrg is null then v_id end;
  end if;

  v_name := left(regexp_replace(btrim(coalesce(p_row ->> 'name', '')), '\s+', ' ', 'g'), 120);
  v_kind := btrim(coalesce(p_row ->> 'kind', ''));
  if v_name = '' then
    raise exception 'name_missing' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.place_kinds k where k.slug = v_kind) then
    raise exception 'kind_unknown' using errcode = 'check_violation';
  end if;
  select coalesce(array_agg(x.id order by x.id), '{}') into v_rules
    from (select distinct r.id
            from jsonb_array_elements_text(case when jsonb_typeof(p_row -> 'rule_ids') = 'array'
                                                then p_row -> 'rule_ids' else '[]'::jsonb end) as e(t)
            join public.place_rules r on r.id::text = btrim(e.t)
           order by r.id limit 64) as x;
  if cardinality(v_rules) = 0 then
    raise exception 'no_rules' using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_row -> 'lat') <> 'number' or jsonb_typeof(p_row -> 'lng') <> 'number' then
    raise exception 'point_invalid' using errcode = 'check_violation';
  end if;
  v_lat := (p_row ->> 'lat')::double precision;
  v_lng := (p_row ->> 'lng')::double precision;
  if v_lat not between -90 and 90 or v_lng not between -180 and 180 then
    raise exception 'point_invalid' using errcode = 'check_violation';
  end if;
  if public.place_tile_id(v_lat, v_lng) <> p_tile then
    raise exception 'point_outside_tile' using errcode = 'check_violation';
  end if;

  -- ingest_places' normalisation (migration 28).
  v_addr  := left(btrim(coalesce(p_row ->> 'address_text', '')), 200);
  v_local := left(btrim(coalesce(p_row ->> 'locality', '')), 120);
  v_hours := nullif(btrim(coalesce(p_row ->> 'opening_hours', '')), '');
  if char_length(v_hours) > 255 then v_hours := null; end if;
  v_web   := nullif(btrim(coalesce(p_row ->> 'website', '')), '');
  if v_web !~ '^https?://' or char_length(v_web) > 500 then v_web := null; end if;
  select coalesce(jsonb_object_agg(t.key, to_jsonb(left(t.value #>> '{}', 255))), '{}'::jsonb) into v_tags
    from jsonb_each(case when jsonb_typeof(p_row -> 'tags') = 'object' then p_row -> 'tags' else '{}'::jsonb end) as t
   where t.key = any (c_allow) and jsonb_typeof(t.value) in ('string', 'number', 'boolean');
  if pg_column_size(v_tags) > 1024 then v_tags := '{}'::jsonb; end if;

  begin
    insert into public.places (source, source_id, osm_ref, name, kind, rule_ids, location, address_text,
                               locality, opening_hours, website, tags, is_public, status, attribution,
                               last_seen_at)
    values ('osm', v_ref, v_ref, v_name, v_kind, v_rules,
            extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography,
            v_addr, v_local, v_hours, v_web, v_tags, true, 'active', '© OpenStreetMap contributors',
            coalesce((v_file ->> 'built_from')::timestamptz, now()))
    returning id into v_id;
  exception when unique_violation then
    -- Another call made it first.
    select p.id into v_id from public.places p
     where p.source = 'osm' and p.source_id = v_ref and p.status = 'active' and p.is_public
       and p.merged_into is null;
  end;
  return v_id;
end $$;

comment on function public.place_from_file(integer, text, jsonb) is
  'D-042 slice 11, service_role (the place-files Edge Function): the database row of one place from a tile''s published static file, made when something needs a row (a venue match, a report, a correction, a hub link, "Start a plan here"). Refused (file_not_current) unless p_sha256 is the tile''s current published file; the row is normalised like ingest_places and must lie in the tile. An existing row with the OSM ref answers instead: its id when active and public, null when a moderator hid, removed or merged it. New rows: source osm, active, public, no user id.';

revoke all on function public.place_from_file(integer, text, jsonb) from public, anon, authenticated;
grant execute on function public.place_from_file(integer, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 5. place_venue_file_checks
-- ---------------------------------------------------------------------------
create table if not exists public.place_venue_file_checks (
  venue_id   uuid primary key references public.venues (id) on delete cascade,
  files_key  text not null,
  checked_on date not null default ((now() at time zone 'utc')::date),
  constraint place_venue_file_checks_key_format check (files_key ~ '^[0-9a-f]{32}$')
);

comment on table public.place_venue_file_checks is
  'D-042 slice 11: the published place files (an md5 of their sha256s) a public venue was last matched against, so each venue is checked once per file version. No user id; cascades with the venue. service_role only.';

alter table public.place_venue_file_checks enable row level security;
revoke all on table public.place_venue_file_checks from public, anon, authenticated;
grant select, insert, update, delete on table public.place_venue_file_checks to service_role;

-- ---------------------------------------------------------------------------
-- 6. place_match_queue
-- ---------------------------------------------------------------------------
create or replace function public.place_match_queue(p_limit integer default 50)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_out   jsonb := '[]'::jsonb;
  r       record;
  v_files jsonb;
  v_key   text;
  v_dlat  double precision := 0.0006;   -- about 66 m: the 60 m match radius and a margin
  v_dlng  double precision;
begin
  for r in
    select v.id, v.name, v.lat, v.lng
      from public.venues v
     where v.is_public and v.location is not null
       and (v.place_ref is null
            or exists (select 1 from public.places p where p.id = v.place_ref and p.source = 'venue'))
       and (exists (select 1 from public.places p where p.source = 'venue' and p.source_id = v.id::text
                       and p.status = 'active')
            or (v.place_ref is null and exists (
                  select 1 from public.event_addresses ea
                    join public.events e on e.id = ea.event_id
                    join public.hubs h on h.id = e.hub_id
                    left join public.hub_categories c on c.slug = h.category_slug
                   where ea.venue_id = v.id
                     and e.status = 'published' and e.visibility = 'public' and e.address_visibility = 'public'
                     and e.starts_at > now() - interval '180 days'
                     and h.is_active and h.place_mode <> 'none' and not coalesce(c.is_sensitive, false))))
     order by v.id
  loop
    v_dlng := v_dlat / greatest(cos(radians(r.lat)), 0.01);
    select jsonb_agg(f.file order by (f.file ->> 'tile')::integer), md5(string_agg(f.file ->> 'sha256', ',' order by (f.file ->> 'tile')::integer))
      into v_files, v_key
      from (select distinct public.place_file_of_tile(public.place_tile_id(
                     least(greatest(r.lat + dy, -89.999999), 89.999999),
                     case when r.lng + dx > 180 then r.lng + dx - 360
                          when r.lng + dx < -180 then r.lng + dx + 360 else r.lng + dx end)) as file
              from (values (-v_dlat), (0::double precision), (v_dlat)) as a(dy),
                   (values (-v_dlng), (0::double precision), (v_dlng)) as b(dx)) f
     where f.file is not null;
    if v_files is null then
      continue;
    end if;
    if exists (select 1 from public.place_venue_file_checks c where c.venue_id = r.id and c.files_key = v_key) then
      continue;
    end if;
    v_out := v_out || jsonb_build_array(jsonb_build_object(
      'venue_id', r.id, 'name', r.name, 'lng', r.lng, 'lat', r.lat, 'key', v_key,
      'files', (select jsonb_agg(jsonb_build_object('tile', x -> 'tile', 'path', x -> 'path', 'sha256', x -> 'sha256'))
                  from jsonb_array_elements(v_files) as e(x))));
    exit when jsonb_array_length(v_out) >= v_limit;
  end loop;
  return jsonb_build_object(
    'base', nullif((select m.value from public.meta m where m.key = 'places_base_url'), ''),
    'venues', v_out);
end $$;

comment on function public.place_match_queue(integer) is
  'D-042 slice 11, service_role (place-files Edge Function): public venues with a point that have no matched place (no place_ref, or only their own meeting spot row) and either a live meeting spot or a qualifying public plan (meeting_spot_refresh''s rule), whose tile or a neighbour within about 66 m has a published file, not yet checked against those files: {base, venues: [{venue_id, name, lng, lat, key, files: [{tile, path, sha256}]}]}. Public venue facts only.';

revoke all on function public.place_match_queue(integer) from public, anon, authenticated;
grant execute on function public.place_match_queue(integer) to service_role;

-- ---------------------------------------------------------------------------
-- 7. place_match_record
-- ---------------------------------------------------------------------------
create or replace function public.place_match_record(p_results jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item    jsonb;
  v_venue   uuid;
  v_key     text;
  v_place   uuid;
  v_checked integer := 0;
  v_rows    integer := 0;
  v_linked  integer := 0;
  v_refused integer := 0;
  v_skipped integer := 0;
begin
  if p_results is null or jsonb_typeof(p_results) <> 'array' then
    raise exception 'results_invalid' using errcode = 'check_violation';
  end if;
  if jsonb_array_length(p_results) > 200 then
    raise exception 'results_too_large' using errcode = 'check_violation';
  end if;
  for v_item in select e.value from jsonb_array_elements(p_results) as e(value) loop
    begin
      v_venue := (v_item ->> 'venue_id')::uuid;
    exception when others then
      v_venue := null;
    end;
    v_key := v_item ->> 'key';
    if v_venue is null or v_key is null or v_key !~ '^[0-9a-f]{32}$'
       or not exists (select 1 from public.venues v where v.id = v_venue and v.is_public) then
      v_skipped := v_skipped + 1;
      continue;
    end if;
    v_place := null;
    if jsonb_typeof(v_item -> 'match') = 'object' then
      begin
        v_place := public.place_from_file((v_item -> 'match' ->> 'tile')::integer,
                                          v_item -> 'match' ->> 'sha256', v_item -> 'match' -> 'row');
        if v_place is not null then v_rows := v_rows + 1; end if;
      exception when check_violation or invalid_text_representation then
        v_refused := v_refused + 1;
      end;
    end if;
    insert into public.place_venue_file_checks (venue_id, files_key, checked_on)
    values (v_venue, v_key, (now() at time zone 'utc')::date)
    on conflict (venue_id) do update set files_key = excluded.files_key, checked_on = excluded.checked_on;
    v_checked := v_checked + 1;
    if v_place is not null then
      perform public.meeting_spot_refresh(v_venue);
      if exists (select 1 from public.venues v join public.places p on p.id = v.place_ref
                  where v.id = v_venue and p.source <> 'venue') then
        v_linked := v_linked + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('checked', v_checked, 'rows', v_rows, 'linked', v_linked,
                            'refused', v_refused, 'skipped', v_skipped);
end $$;

comment on function public.place_match_record(jsonb) is
  'D-042 slice 11, service_role (place-files Edge Function): [{venue_id, key, match: {tile, sha256, row} | null}]. A match becomes a row through place_from_file (refused when the file is no longer current), the check is stored against key, and meeting_spot_refresh runs so the database''s own 60 m / trigram 0.45 matcher links the venue. Returns counts {checked, rows, linked, refused, skipped}.';

revoke all on function public.place_match_record(jsonb) from public, anon, authenticated;
grant execute on function public.place_match_record(jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- 8. place_match_dispatch and the job
-- ---------------------------------------------------------------------------
create or replace function public.place_match_dispatch(p_force boolean default false)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base   text := public.project_url();
  v_secret text;
begin
  if v_base is null then
    raise notice 'place-match: project_url not set; nothing sent';
    return null;
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    select ds.decrypted_secret into v_secret
      from vault.decrypted_secrets ds where ds.name = 'collector_secret' limit 1;
  end if;
  if v_secret is null then
    raise notice 'place-match: collector secret not configured; nothing sent';
    return null;
  end if;
  if not coalesce(p_force, false)
     and jsonb_array_length(public.place_match_queue(1) -> 'venues') = 0 then
    return null;
  end if;
  return net.http_post(
    url := v_base || '/functions/v1/place-files/match',
    body := '{}'::jsonb,
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-collector-secret', v_secret),
    timeout_milliseconds := 120000);
end $$;

comment on function public.place_match_dispatch(boolean) is
  'D-042 slice 11: asks the place-files Edge Function (pg_net, collector secret) to match queued venues against the static place files when one is queued (p_force skips the check). Returns the pg_net request id or null. Not client-callable.';

revoke all on function public.place_match_dispatch(boolean) from public, anon, authenticated;

do $$
begin
  if to_regclass('cron.job') is null then
    raise notice 'pg_cron is not installed; place-match not scheduled';
    return;
  end if;
  if exists (select 1 from cron.job where jobname = 'place-match') then
    perform cron.unschedule('place-match');
  end if;
  perform cron.schedule('place-match', '11,41 * * * *', 'select public.place_match_dispatch(false)');
end $$;

-- ---------------------------------------------------------------------------
-- Version stamp
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.45')
  on conflict (key) do update set value = excluded.value, updated_at = now();
