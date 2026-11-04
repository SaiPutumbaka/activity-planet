-- DRAFT ONLY (not a migration in the repo; not applied anywhere).
-- Activity Planet: places layer + map RPCs. Follows the house style of
-- supabase/migrations/20261025000100_v2_events.sql (extensions schema for
-- PostGIS, search_path = '', writes through security definer RPCs).

-- 1. Vocabulary ---------------------------------------------------------------
do $$ begin create type public.place_source as enum ('osm', 'geoapify', 'user', 'venue'); exception when duplicate_object then null; end $$;
do $$ begin create type public.place_status as enum ('active', 'pending', 'hidden', 'closed', 'removed'); exception when duplicate_object then null; end $$;

create table if not exists public.place_kinds (
  slug          text primary key,                 -- 'basketball_court', 'anime_store', 'comic_store', 'meetup_spot'
  label         text not null,
  icon          text not null,                    -- lucide icon name drawn into the map sprite at runtime
  osm_match     jsonb not null default '[]',      -- [{"leisure":"pitch","sport":"basketball"}, ...] read by the extract job
  geoapify_categories text[] not null default '{}',
  user_addable  boolean not null default true,
  sort          smallint not null default 100,
  constraint place_kinds_slug_format check (slug ~ '^[a-z0-9]+(_[a-z0-9]+)*$')
);

-- kind -> hubs default mapping (moderator-curated; place_hubs is the per-place truth)
create table if not exists public.kind_hubs (
  kind_slug text not null references public.place_kinds (slug) on update cascade on delete cascade,
  hub_id    uuid not null references public.hubs (id) on delete cascade,
  primary key (kind_slug, hub_id)
);
create index if not exists kind_hubs_hub_idx on public.kind_hubs (hub_id);

-- 2. Places --------------------------------------------------------------------
create table if not exists public.places (
  id             uuid primary key default gen_random_uuid(),
  source         public.place_source not null,
  source_id      text,                                   -- 'n123'/'w456'/'r789' (osm), place_id (geoapify), venue id (venue), null (user)
  osm_ref        text,                                   -- OSM element id when known (also from Geoapify datasource) for dedupe
  name           text not null,
  kind           text not null references public.place_kinds (slug) on update cascade,
  location       extensions.geography(Point, 4326) not null,
  geom           extensions.geometry(Point, 4326) generated always as (location::extensions.geometry) stored,
  lat            double precision generated always as (extensions.ST_Y(location::extensions.geometry)) stored,
  lng            double precision generated always as (extensions.ST_X(location::extensions.geometry)) stored,
  address_text   text not null default '',               -- one display line; never shown for non-public rows
  locality       text not null default '',
  country        text,                                   -- ISO 3166-1 alpha-2
  opening_hours  text,                                   -- OSM opening_hours syntax, shown as text
  website        text,
  tags           jsonb not null default '{}',            -- small allowlist: sport, hoops, indoor, surface, fee, lit, access
  is_public      boolean not null default false,
  status         public.place_status not null default 'pending',
  locked_fields  text[] not null default '{}',           -- approved corrections the importer must not overwrite
  created_by     uuid references public.profiles (id) on delete set null,
  attribution    text not null,                          -- '© OpenStreetMap contributors' | 'Powered by Geoapify · © OpenStreetMap contributors' | 'Added by Activity Planet members'
  license        text not null,                          -- 'ODbL-1.0' | 'AP-member-content'
  last_seen_at   timestamptz not null default now(),     -- last import that still contained it (user rows: last confirmation)
  merged_into    uuid references public.places (id) on delete set null,
  search_text    text generated always as (lower(name || ' ' || locality)) stored,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint places_name_length    check (char_length(name) between 2 and 120),
  constraint places_address_length check (char_length(address_text) <= 200),
  constraint places_hours_length   check (opening_hours is null or char_length(opening_hours) <= 255),
  constraint places_website_https  check (website is null or (website ~ '^https?://' and char_length(website) <= 500)),
  constraint places_country_format check (country is null or country ~ '^[A-Z]{2}$'),
  constraint places_source_shape   check (
       (source = 'user'  and created_by is not null and source_id is null and license = 'AP-member-content')
    or (source in ('osm', 'geoapify') and source_id is not null and license = 'ODbL-1.0' and created_by is null)
    or (source = 'venue' and source_id is not null)),
  -- a private row is a personal pin: never active-public, never imported
  constraint places_private_is_user check (is_public or source = 'user'),
  constraint places_tags_size check (pg_column_size(tags) <= 1024)
);
create unique index if not exists places_source_key on public.places (source, source_id) where source_id is not null;
create unique index if not exists places_osm_ref_key on public.places (osm_ref) where osm_ref is not null and status <> 'removed';
create index if not exists places_geom_gix on public.places using gist (geom) where status = 'active' and is_public;
create index if not exists places_geom_all_gix on public.places using gist (geom);   -- own pins, moderators, dedupe
create index if not exists places_kind_idx on public.places (kind);
create index if not exists places_created_by_idx on public.places (created_by) where created_by is not null;
create index if not exists places_status_idx on public.places (status, created_at) where status in ('pending', 'hidden');
create index if not exists places_search_trgm_idx on public.places using gin (search_text extensions.gin_trgm_ops);
create index if not exists places_seen_idx on public.places (source, last_seen_at) where source in ('osm', 'geoapify');

create table if not exists public.place_hubs (
  place_id uuid not null references public.places (id) on delete cascade,
  hub_id   uuid not null references public.hubs (id) on delete cascade,
  via      text not null default 'kind',           -- kind | tag | member | moderator | events
  weight   smallint not null default 1,            -- events: number of public plans here in 180 days
  primary key (place_id, hub_id),
  constraint place_hubs_via check (via in ('kind', 'tag', 'member', 'moderator', 'events'))
);
create index if not exists place_hubs_hub_idx on public.place_hubs (hub_id, place_id);

-- link a public event venue to the place it is (for "Plans here")
alter table public.venues add column if not exists place_ref uuid references public.places (id) on delete set null;
create index if not exists venues_place_ref_idx on public.venues (place_ref) where place_ref is not null;

-- events: separate "Shows and games" row (founder decision); set by the importer per source
alter table public.feed_sources add column if not exists listing_kind text not null default 'plan'
  constraint feed_sources_listing_kind check (listing_kind in ('plan', 'show'));
alter table public.events add column if not exists listing_kind text not null default 'plan'
  constraint events_listing_kind check (listing_kind in ('plan', 'show'));
create index if not exists events_approx_geom_gix on public.events using gist ((approx_point::extensions.geometry))
  where status = 'published';

-- 3. Moderation ---------------------------------------------------------------
create table if not exists public.place_edits (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null references public.places (id) on delete cascade,
  proposed_by uuid references public.profiles (id) on delete set null,
  changes     jsonb not null,                -- allowlisted keys: name, kind, address_text, opening_hours, website, location{lat,lng}, hubs_add[], hubs_remove[], closed
  note        text not null default '',
  status      text not null default 'pending',
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint place_edits_status check (status in ('pending', 'approved', 'rejected', 'superseded')),
  constraint place_edits_note_length check (char_length(note) <= 500),
  constraint place_edits_changes_size check (pg_column_size(changes) <= 2048)
);
create index if not exists place_edits_queue_idx on public.place_edits (status, created_at) where status = 'pending';
create index if not exists place_edits_place_idx on public.place_edits (place_id);

create table if not exists public.place_reports (
  id          uuid primary key default gen_random_uuid(),
  place_id    uuid not null references public.places (id) on delete cascade,
  reporter_id uuid references public.profiles (id) on delete set null,
  reason      text not null,
  note        text not null default '',
  status      text not null default 'open',
  resolved_by uuid references public.profiles (id) on delete set null,
  resolved_at timestamptz,
  created_at  timestamptz not null default now(),
  constraint place_reports_reason check (reason in ('closed', 'wrong_location', 'wrong_info', 'not_public', 'private_residence', 'unsafe', 'spam', 'other')),
  constraint place_reports_status check (status in ('open', 'actioned', 'dismissed')),
  constraint place_reports_note_length check (char_length(note) <= 500)
);
create unique index if not exists place_reports_one_open on public.place_reports (place_id, reporter_id) where status = 'open';
create index if not exists place_reports_queue_idx on public.place_reports (status, created_at) where status = 'open';

-- Coverage cells: what has been filled, never who asked (D-040 queue rule)
create table if not exists public.place_coverage (
  cell_key          text primary key,          -- 0.1-degree cell 'lat10:lng10' (the same grid as the D-038 fuzz)
  osm_region        text,                      -- Geofabrik extract that covers it, if loaded
  osm_loaded_at     timestamptz,
  geoapify_filled_at timestamptz,
  place_count       integer not null default 0,
  demand            integer not null default 0, -- viewport requests since the last fill (a count, no user id)
  last_demand_at    timestamptz
);

-- 4. RLS -----------------------------------------------------------------------
alter table public.place_kinds    enable row level security;
alter table public.kind_hubs      enable row level security;
alter table public.places         enable row level security;
alter table public.place_hubs     enable row level security;
alter table public.place_edits    enable row level security;
alter table public.place_reports  enable row level security;
alter table public.place_coverage enable row level security;

create policy "place_kinds_read" on public.place_kinds for select to anon, authenticated using (true);
create policy "kind_hubs_read"   on public.kind_hubs   for select to anon, authenticated using (true);
create policy "place_kinds_mod"  on public.place_kinds for all to authenticated using (public.is_moderator()) with check (public.is_moderator());
create policy "kind_hubs_mod"    on public.kind_hubs   for all to authenticated using (public.is_moderator()) with check (public.is_moderator());

create policy "places_select" on public.places for select to anon, authenticated using (
  (status = 'active' and is_public)
  or created_by = (select auth.uid())
  or public.is_moderator());
-- no insert/update/delete policies: add_place, propose_place_edit, report_place, mod_* RPCs and the ingest path only

create policy "place_hubs_select" on public.place_hubs for select to anon, authenticated using (
  exists (select 1 from public.places p where p.id = place_id));   -- inherits places_select

create policy "place_edits_select"   on public.place_edits   for select to authenticated using (proposed_by = (select auth.uid()) or public.is_moderator());
create policy "place_reports_select" on public.place_reports for select to authenticated using (reporter_id = (select auth.uid()) or public.is_moderator());
create policy "place_coverage_mod"   on public.place_coverage for select to authenticated using (public.is_moderator());

-- 5. places_in_view -------------------------------------------------------------
-- security invoker: places_select decides visibility. bbox in degrees; west > east = antimeridian.
create or replace function public.places_in_view(
  p_west double precision, p_south double precision, p_east double precision, p_north double precision,
  p_hub_ids uuid[] default null,     -- null = the viewer's joined hubs (anon: required)
  p_kinds   text[] default null,
  p_limit   integer default 800)
returns table (id uuid, name text, kind text, lat double precision, lng double precision,
               hub_ids uuid[], source public.place_source, mine boolean, pending boolean, truncated boolean)
language plpgsql stable set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  v_hubs  uuid[];
  v_env   extensions.geometry;
  v_env2  extensions.geometry;
  v_limit integer := greatest(1, least(coalesce(p_limit, 800), 1500));
begin
  if p_south not between -90 and 90 or p_north not between -90 and 90 or p_north <= p_south
     or p_west not between -180 and 180 or p_east not between -180 and 180 then
    raise exception 'invalid_bbox' using errcode = 'check_violation';
  end if;
  if (p_north - p_south) > 1.0 or (case when p_west <= p_east then p_east - p_west else 360 - p_west + p_east end) > 1.5 then
    raise exception 'bbox_too_large' using errcode = 'check_violation', hint = 'Zoom in (about z10 or closer).';
  end if;
  v_hubs := coalesce(p_hub_ids, (select array_agg(hm.hub_id) from public.hub_members hm where hm.user_id = uid));
  if v_hubs is null or cardinality(v_hubs) = 0 then return; end if;
  if cardinality(v_hubs) > 50 then raise exception 'too_many_hubs' using errcode = 'check_violation'; end if;
  if p_west <= p_east then
    v_env := extensions.ST_MakeEnvelope(p_west, p_south, p_east, p_north, 4326);
  else
    v_env  := extensions.ST_MakeEnvelope(p_west, p_south, 180, p_north, 4326);
    v_env2 := extensions.ST_MakeEnvelope(-180, p_south, p_east, p_north, 4326);
  end if;

  return query
  with hit as (
    select p.id, p.name, p.kind, p.lat, p.lng, p.source, p.created_by, p.status, p.is_public,
           array_agg(ph.hub_id) filter (where ph.hub_id = any (v_hubs)) as hubs
      from public.places p
      join public.place_hubs ph on ph.place_id = p.id and ph.hub_id = any (v_hubs)
     where (p.geom && v_env or (v_env2 is not null and p.geom && v_env2))
       and p.status in ('active', 'pending') and p.merged_into is null
       and (p_kinds is null or p.kind = any (p_kinds))
     group by p.id
     limit v_limit + 1
  )
  select h.id, h.name, h.kind, h.lat, h.lng, h.hubs, h.source,
         (h.created_by = uid), (h.status = 'pending'),
         (count(*) over () > v_limit)
    from hit h
   limit v_limit;
end $$;

-- 6. map_in_view: places + events + shows + approximate areas in one round trip ----------
-- Returns compact jsonb so a 1000-feature viewport stays near 50-60 KB gzip.
-- events: published, starts in [p_from, p_to), readable by the caller (security invoker, events RLS),
-- in the selected hubs, or public and nearby (the Feed v2 public arm) when p_include_nearby.
-- address_visibility = 'approved_only' rows return no point: only their 0.1-degree cell (D-038).
create or replace function public.map_in_view(
  p_west double precision, p_south double precision, p_east double precision, p_north double precision,
  p_from timestamptz, p_to timestamptz,
  p_hub_ids uuid[] default null, p_kinds text[] default null,
  p_layers text[] default array['places', 'plans', 'shows'],
  p_include_nearby boolean default true)
returns jsonb
language plpgsql stable set search_path = '' as $$
-- body sketch:
--  places : select from places_in_view(...) when 'places' = any(p_layers) and the bbox is small enough;
--           otherwise {"places": null, "places_hint": "zoom_in"}
--  events : e.status = 'published' and e.starts_at >= p_from and e.starts_at < p_to (max 31 days)
--           and e.approx_point::geometry && envelope
--           and (e.hub_id = any(v_hubs) or (p_include_nearby and e.visibility = 'public'))
--           listing_kind = 'show' -> layer 'show' (only if 'shows' in p_layers), else 'plan'
--           address_visibility = 'public' -> [id, lat, lng, hub_id, layer, starts_at, title, imported, place_ref]
--           address_visibility = 'approved_only' -> grouped by round(lat,1), round(lng,1):
--             {"cell": [lat10, lng10], "n": count, "ids": [...]} ; the client draws the cell as
--             [lat10/10 - 0.05, lat10/10 + 0.05] x [lng10/10 - 0.05, lng10/10 + 0.05]
--  demand : when places came back empty and the cell is not covered, upsert place_coverage.demand
--           through a security definer helper (count only, no user id); the fill job drains it.
begin
  raise exception 'draft';
end $$;

-- 7. Write RPCs (signatures; bodies follow upsert_venue's patterns in migration 22) ------------
-- add_place(p jsonb) returns places
--   needs onboarding complete; 10 new places a day; name 2-120; kind user_addable; hubs 1-3 (default from kind_hubs)
--   is_public default false. If is_public:
--     * reject (force private, error 'near_your_home') when within 150 m of the caller's profile_private.location
--       or saved home point (D-040); the client explains why
--     * reject if a private venue of the caller is within 50 m (it is their home or a private host spot)
--     * status 'pending' (visible to the caller as a dashed pin, to nobody else) until a moderator approves;
--       address_text is stored but not exposed by any RPC until active
--     * duplicate check: same kind within 60 m and similar name -> 'possible_duplicate' with the ids, unless p.force
--   If not is_public: status 'active', is_public false, visible only to the caller, never in moderation.
-- propose_place_edit(p_place uuid, p_changes jsonb, p_note text)  -> place_edits row; 30 a day
--   the creator of a still-pending user place edits it directly; everything else is queued
-- report_place(p_place uuid, p_reason text, p_note text)          -> place_reports row; 20 a day
--   'private_residence' or 'unsafe' on a user/venue place hides it at once (status 'hidden') pending review;
--   3 open reports of any reason from distinct accounts hide any place
-- mod_place_queue(p_limit int) -> union of pending places, pending edits, open reports, oldest first, with
--   reporter counts, the nearest public venue/OSM place, and a 'near_residential' flag from OSM landuse
-- mod_resolve_place(p_kind text, p_id uuid, p_action text, p_note text)  approve|reject|hide|remove|merge
--   approving an edit on an osm/geoapify row adds the changed fields to locked_fields
-- ingest_places(p_batch jsonb)  service path only (the D-040 collector secret's single ingest function):
--   upserts by (source, source_id); skips locked_fields; sets last_seen_at; rows of a region not seen in two
--   consecutive loads become 'closed'; never touches source = 'user' rows.
