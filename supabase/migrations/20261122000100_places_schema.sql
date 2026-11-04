-- ============================================================================
-- Activity Planet schema v2 — migration 27: hub map places schema (D-041,
--   docs/design/hub-map/HUB_MAP_DESIGN.md sections 4, 6 and 7; build slice 3).
--   Fixes forward; the one rebuilt function (request_account_deletion) starts
--   from its latest body (migration 20, 20261115000100_attendance.sql) and
--   only gains the places lines. Checks: supabase/tests/places_schema.sql.
--   The rules seed is supabase/seed/place_rules.sql (generated, slice 2),
--   run after supabase/seed/hubs.sql by config.toml and migrate.yml.
--
--   What this file does
--     1. Vocabulary: place_source (osm, geoapify, user, venue), place_status
--        (active, pending, hidden, closed, removed), place_tile_status
--        (wanted, filling, active, idle, retired). Tile helpers
--        place_tile_id(lat, lng), place_tile_id_of(geography) and
--        place_tile_bbox(id): a fixed 0.5-degree grid, 720 columns.
--     2. hubs.place_mode ('specific' | 'generic' | 'none', default
--        'specific') and hubs.geoapify_categories (text[]). hunting,
--        knife-collecting, cliff-diving and spearfishing are 'none' (founder,
--        2026-11-03); the seed sets every other hub's mode.
--     3. Rule tables: place_kinds (display kind: label, lucide icon),
--        place_rules (one base OSM tag plus extra conditions, stable smallint
--        id, rules_version), hub_place_rules (hub to rule). Everyone reads;
--        moderators write; the seed is the normal writer.
--     4. places: one table for every source with a source column, so the
--        ODbL-imported rows (osm, geoapify) stay separable from the rows
--        people contribute (user) and the meeting spots (venue):
--          * osm and geoapify rows need a source_id and never carry a user
--            id; venue rows never carry one either; user rows have no
--            source_id or osm_ref. Every row is ODbL-1.0 (Terms, design 8).
--          * Only user rows can be private, and a private row always has
--            its creator. tags is a fixed allowlist (design 4.3).
--          * created_by is never readable by anon or authenticated (column
--            grants): nobody can see who added a place (D-041 privacy).
--        rule_ids smallint[] holds the rules a place matched at ingest
--        (GIN), tile_id is generated from the point.
--     5. places_guard (before insert or update), the design 7 rules that
--        hold for any writer:
--          * a public request within 150 m of the creator's saved home
--            (home_point or location) is refused with near_your_home, and
--            within 50 m of one of the creator's private venues with
--            near_private_venue;
--          * a public member place written by anyone but a moderator starts
--            (or goes back to) 'pending'; only a moderator makes it active;
--          * a venue row needs a public venue (venue_not_public);
--          * a member place needs an onboarded active creator
--            (not_onboarded), the signed-in caller as its creator
--            (place_creator_mismatch) and at most 10 new places a day
--            (rate_limited); moderators are exempt from the last two;
--          * source never changes; created_by can only be cleared.
--     6. place_hubs (explicit links only: member, moderator, events; OSM
--        links live in rule_ids). place_hubs_guard: a sensitive hub's place
--        links come from moderators only (no member links, no plan counts).
--        Visible when its place is visible.
--     7. place_tiles (0.5-degree demand and run state; no user id) and
--        collector_budget (credits used per day and source). Moderators
--        read; service_role writes. Atlanta's three tiles are seeded
--        'active' (design 3.5) from the atlanta area row when it exists.
--     8. venues.place_ref (a public venue only), events.listing_kind and
--        feed_sources.listing_kind ('plan' | 'show'), a geometry GiST index
--        on published events' approx_point.
--     9. RLS: places for anon when active and public; for authenticated
--        also their own rows, moderators everything, and member-made or
--        venue-derived public places only for adults (viewer_is_adult);
--        imported OSM and Geoapify rows for every signed-in user.
--    10. request_account_deletion: the caller's private and still-pending
--        places go; reviewed public places stay as unattributed ODbL facts.
--     * meta.schema_version 2.23.
--
--   Not here (later slices): the read RPCs (map_in_view, places_in_view,
--   place_detail, slice 6), ingest_places (slice 4), add_place and reports
--   (slice 11; rule 4 of design 7 lands with place_reports), the demand
--   trigger (slice 13) and the duplicate-hub merge (bocce, tv-shows), which
--   touches the hub catalog generator and gets its own migration.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Vocabulary and tile helpers
-- ---------------------------------------------------------------------------
do $$ begin
  create type public.place_source as enum ('osm', 'geoapify', 'user', 'venue');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.place_status as enum ('active', 'pending', 'hidden', 'closed', 'removed');
exception when duplicate_object then null; end $$;
do $$ begin
  create type public.place_tile_status as enum ('wanted', 'filling', 'active', 'idle', 'retired');
exception when duplicate_object then null; end $$;

-- Tile id = row * 720 + column, row = floor((lat + 90) / 0.5) (0..359),
-- column = floor((lng + 180) / 0.5) (0..719). 0.5 degrees is about
-- 55 x 45 km at Atlanta's latitude (design 3.5).
create or replace function public.place_tile_id(p_lat double precision, p_lng double precision)
returns integer language sql immutable strict parallel safe set search_path = '' as $$
  select (least(359, greatest(0, floor((p_lat + 90) / 0.5)::integer)) * 720
        + least(719, greatest(0, floor((p_lng + 180) / 0.5)::integer)));
$$;

create or replace function public.place_tile_id_of(p_point extensions.geography)
returns integer language sql immutable strict parallel safe set search_path = '' as $$
  select public.place_tile_id(extensions.ST_Y(p_point::extensions.geometry),
                              extensions.ST_X(p_point::extensions.geometry));
$$;

create or replace function public.place_tile_bbox(p_id integer)
returns extensions.geometry language sql immutable strict parallel safe set search_path = '' as $$
  select extensions.ST_MakeEnvelope(
    ((p_id % 720) * 0.5 - 180)::double precision, ((p_id / 720) * 0.5 - 90)::double precision,
    ((p_id % 720) * 0.5 - 179.5)::double precision, ((p_id / 720) * 0.5 - 89.5)::double precision, 4326);
$$;

comment on function public.place_tile_id(double precision, double precision) is
  'Hub map tile (D-041): the 0.5-degree cell holding a point, as row * 720 + column. Pure arithmetic.';
comment on function public.place_tile_id_of(extensions.geography) is
  'place_tile_id for a geography point.';
comment on function public.place_tile_bbox(integer) is
  'The bounding box of a place tile, as a polygon in EPSG:4326.';

-- ---------------------------------------------------------------------------
-- 2. hubs.place_mode and hubs.geoapify_categories
-- ---------------------------------------------------------------------------
alter table public.hubs add column if not exists place_mode text not null default 'specific';
alter table public.hubs add column if not exists geoapify_categories text[] not null default '{}';
do $$ begin
  alter table public.hubs add constraint hubs_place_mode check (place_mode in ('specific', 'generic', 'none'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.hubs add constraint hubs_geoapify_categories_size check (cardinality(geoapify_categories) <= 32);
exception when duplicate_object then null; end $$;

comment on column public.hubs.place_mode is
  'Hub map (D-041): specific = its places show under "All my hubs"; generic = only when this one hub''s chip is selected ("General spot"); none = events only. Set by supabase/seed/place_rules.sql.';
comment on column public.hubs.geoapify_categories is
  'Geoapify Places categories for the gap fill (design 3.2), from the research table. Set by the seed.';

-- Founder, 2026-11-03 (question 3): these stay events-only.
update public.hubs set place_mode = 'none'
 where slug in ('hunting', 'knife-collecting', 'cliff-diving', 'spearfishing') and place_mode <> 'none';

-- ---------------------------------------------------------------------------
-- 3. Rule tables
-- ---------------------------------------------------------------------------
create table if not exists public.place_kinds (
  slug  text primary key,
  label text not null,
  icon  text not null,                  -- lucide icon name
  sort  smallint not null default 100,
  constraint place_kinds_slug_format check (slug ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and char_length(slug) <= 40),
  constraint place_kinds_label_length check (char_length(label) between 2 and 60),
  constraint place_kinds_icon_format check (icon ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and char_length(icon) <= 40)
);
comment on table public.place_kinds is
  'Hub map display kinds (D-041): label and lucide icon. Seeded from scripts/places/place_kinds.json.';

create table if not exists public.place_rules (
  id            smallint primary key,
  osm_key       text not null,
  osm_value     text,                              -- null = the key is present with any value
  extra         jsonb not null default '{}',       -- {"sport":["basketball"]}: any of the listed values
  osm_type      text not null default 'nwr',
  kind          text not null references public.place_kinds (slug) on update cascade,
  verified      boolean not null default false,    -- every tag reached 50 uses on taginfo
  rules_version integer not null,
  constraint place_rules_id_positive check (id > 0),
  constraint place_rules_osm_type check (osm_type in ('nwr', 'relation')),
  constraint place_rules_key_format check (osm_key ~ '^[a-z0-9_:]+$' and char_length(osm_key) <= 64),
  constraint place_rules_value_length check (osm_value is null or char_length(osm_value) between 1 and 128),
  constraint place_rules_extra_shape check (jsonb_typeof(extra) = 'object' and pg_column_size(extra) <= 1024),
  constraint place_rules_version_positive check (rules_version >= 1)
);
create index if not exists place_rules_kind_idx on public.place_rules (kind);
comment on table public.place_rules is
  'Hub map OSM tag rules (D-041): one base tag plus extra conditions. Ids are stable (scripts/places/rule_ids.json, append-only); places.rule_ids holds the ones a place matched at ingest. Generated by scripts/places/gen_place_rules.py.';

create table if not exists public.hub_place_rules (
  hub_id  uuid not null references public.hubs (id) on delete cascade,
  rule_id smallint not null references public.place_rules (id) on delete cascade,
  primary key (hub_id, rule_id)
);
create index if not exists hub_place_rules_rule_idx on public.hub_place_rules (rule_id);
comment on table public.hub_place_rules is
  'Which place rules each hub shows (D-041). Whether they show under "All my hubs" is the hub''s place_mode.';

-- ---------------------------------------------------------------------------
-- 4. places
-- ---------------------------------------------------------------------------
create table if not exists public.places (
  id            uuid primary key default gen_random_uuid(),
  source        public.place_source not null,
  source_id     text,                                   -- osm: 'n123'/'w456'/'r789'; geoapify: its place id; venue: the venue id; user: null
  osm_ref       text,                                   -- OSM element when known (also from Geoapify), for the merge
  name          text not null,
  kind          text not null references public.place_kinds (slug) on update cascade,
  rule_ids      smallint[] not null default '{}',
  location      extensions.geography(Point, 4326) not null,
  geom          extensions.geometry(Point, 4326) generated always as (location::extensions.geometry) stored,
  lat           double precision generated always as (extensions.ST_Y(location::extensions.geometry)) stored,
  lng           double precision generated always as (extensions.ST_X(location::extensions.geometry)) stored,
  tile_id       integer generated always as (public.place_tile_id_of(location)) stored,
  address_text  text not null default '',
  locality      text not null default '',
  country       text,                                   -- ISO 3166-1 alpha-2 when known
  opening_hours text,                                   -- OSM opening_hours syntax, shown as text
  website       text,
  tags          jsonb not null default '{}',            -- allowlist (design 4.3)
  is_public     boolean not null default false,
  status        public.place_status not null default 'pending',
  locked_fields text[] not null default '{}',           -- approved corrections the importer must not overwrite
  created_by    uuid references public.profiles (id) on delete set null,   -- user rows only; never client-readable
  attribution   text not null,
  license       text not null default 'ODbL-1.0',
  last_seen_at  timestamptz not null default now(),
  merged_into   uuid references public.places (id) on delete set null,
  search_text   text generated always as (lower(name || ' ' || locality)) stored,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint places_source_key unique (source, source_id),
  constraint places_name_length check (char_length(name) between 1 and 120),
  constraint places_source_id_length check (source_id is null or char_length(source_id) between 1 and 200),
  constraint places_osm_ref_format check (osm_ref is null or osm_ref ~ '^[nwr][0-9]{1,15}$'),
  constraint places_address_length check (char_length(address_text) <= 200),
  constraint places_locality_length check (char_length(locality) <= 120),
  constraint places_country_format check (country is null or country ~ '^[A-Z]{2}$'),
  constraint places_hours_length check (opening_hours is null or char_length(opening_hours) <= 255),
  constraint places_website_format check (website is null or (website ~ '^https?://' and char_length(website) <= 500)),
  constraint places_attribution_length check (char_length(attribution) between 1 and 200),
  constraint places_license check (license = 'ODbL-1.0'),
  constraint places_rule_ids_size check (cardinality(rule_ids) <= 64),
  constraint places_tags_shape check (jsonb_typeof(tags) = 'object' and pg_column_size(tags) <= 1024),
  constraint places_tags_allowlist check ((tags - array['sport', 'religion', 'denomination', 'lgbtq', 'access', 'fee', 'lit',
      'indoor', 'surface', 'hoops', 'wheelchair', 'wikidata', 'phone', 'brand']::text[]) = '{}'::jsonb),
  constraint places_locked_fields_allowlist check (locked_fields <@ array['name', 'kind', 'location', 'address_text', 'locality',
      'country', 'opening_hours', 'website', 'tags', 'closed']::text[]),
  constraint places_not_merged_into_self check (merged_into is null or merged_into <> id),
  -- ODbL imports and meeting spots carry no user id; member rows have no import keys.
  constraint places_source_shape check (
       (source in ('osm', 'geoapify') and source_id is not null and created_by is null)
    or (source = 'venue' and source_id is not null and osm_ref is null and created_by is null)
    or (source = 'user' and source_id is null and osm_ref is null)),
  -- A private row is a member's own pin, and it always has its member.
  constraint places_private_is_user check (is_public or (source = 'user' and created_by is not null))
);
create unique index if not exists places_osm_ref_key on public.places (osm_ref)
  where osm_ref is not null and status <> 'removed';
create index if not exists places_geom_public_gix on public.places using gist (geom)
  where status = 'active' and is_public;
create index if not exists places_geom_gix on public.places using gist (geom);          -- own pins, moderators, dedupe
create index if not exists places_rule_ids_gin on public.places using gin (rule_ids);
create index if not exists places_search_trgm_idx on public.places using gin (search_text extensions.gin_trgm_ops);
create index if not exists places_queue_idx on public.places (status, created_at) where status in ('pending', 'hidden');
create index if not exists places_tile_seen_idx on public.places (tile_id, source, last_seen_at);
create index if not exists places_created_by_idx on public.places (created_by) where created_by is not null;
create index if not exists places_kind_idx on public.places (kind);
create or replace trigger places_set_updated_at before update on public.places
  for each row execute function public.set_updated_at();

comment on table public.places is
  'Hub map places (D-041), an ODbL derivative database. source keeps the imported rows (osm, geoapify) separable from member rows (user) and meeting spots (venue). Only user rows can be private (their creator''s pin). Written by migrations, the service-role ingest and definer RPCs; places_guard enforces the design 7 rules for every writer. created_by is never readable by clients.';
comment on column public.places.rule_ids is
  'place_rules ids this place matched at ingest (D-041); a hub shows it when rule_ids overlaps that hub''s rules.';
comment on column public.places.tile_id is
  'The 0.5-degree place tile (place_tile_id_of(location)); retirement and refresh work per tile.';

-- ---------------------------------------------------------------------------
-- 5. places_guard: the design 7 rules for every writer
-- ---------------------------------------------------------------------------
create or replace function public.places_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := (select auth.uid());
  v_mod boolean := false;
  v_n   integer;
begin
  if new.source = 'user' then
    v_mod := coalesce(public.is_moderator(), false);
  end if;
  if tg_op = 'UPDATE' then
    if new.source is distinct from old.source then
      raise exception 'place_source_immutable' using errcode = 'check_violation';
    end if;
    if new.created_by is distinct from old.created_by and new.created_by is not null then
      raise exception 'place_creator_immutable' using errcode = 'check_violation';
    end if;
  end if;

  if new.source = 'user' and tg_op = 'INSERT' and new.created_by is not null then
    if not exists (select 1 from public.profiles p
                    where p.id = new.created_by and p.status = 'active' and p.deleted_at is null
                      and p.onboarding_completed_at is not null) then
      raise exception 'not_onboarded' using errcode = 'check_violation';
    end if;
    if v_uid is not null and not v_mod then
      if new.created_by <> v_uid then
        raise exception 'place_creator_mismatch' using errcode = 'check_violation';
      end if;
      perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('places_new:' || new.created_by::text));
      select count(*) into v_n from public.places x
       where x.created_by = new.created_by and x.source = 'user' and x.created_at > now() - interval '1 day';
      if v_n >= 10 then
        raise exception 'rate_limited' using errcode = 'check_violation', hint = 'Up to ten new places a day.';
      end if;
    end if;
  end if;

  -- Rules 1 and 3: a member's public place waits for a moderator.
  if new.source = 'user' and new.is_public and new.status = 'active' and v_uid is not null and not v_mod
     and (tg_op = 'INSERT' or not old.is_public or old.status <> 'active') then
    if tg_op = 'UPDATE' and old.is_public and old.status in ('pending', 'hidden', 'removed') then
      raise exception 'moderator_required' using errcode = 'insufficient_privilege';
    end if;
    new.status := 'pending';
  end if;

  -- Rule 2: never a public pin at or beside the member's home.
  if new.source = 'user' and new.is_public and new.created_by is not null
     and new.status in ('pending', 'active')
     and (tg_op = 'INSERT' or new.location is distinct from old.location
          or not old.is_public or old.status is distinct from new.status) then
    if exists (select 1 from public.profile_private pp
                where pp.user_id = new.created_by
                  and ((pp.home_point is not null and extensions.ST_DWithin(pp.home_point, new.location, 150))
                    or (pp.location is not null and extensions.ST_DWithin(pp.location, new.location, 150)))) then
      raise exception 'near_your_home' using errcode = 'check_violation',
        hint = 'A public place cannot be within 150 m of your saved home. Keep it as a private pin instead.';
    end if;
    if exists (select 1 from public.venues v
                where v.created_by = new.created_by and not v.is_public and v.location is not null
                  and extensions.ST_DWithin(v.location, new.location, 50)) then
      raise exception 'near_private_venue' using errcode = 'check_violation',
        hint = 'A public place cannot be within 50 m of one of your private addresses.';
    end if;
  end if;

  -- Rule 5: only public venues become meeting spots.
  if new.source = 'venue' and new.status = 'active'
     and (tg_op = 'INSERT' or new.source_id is distinct from old.source_id or old.status <> 'active') then
    if not exists (select 1 from public.venues v where v.id::text = new.source_id and v.is_public) then
      raise exception 'venue_not_public' using errcode = 'check_violation';
    end if;
  end if;

  return new;
end $$;

comment on function public.places_guard() is
  'Trigger on places (design 7, every writer): near_your_home (150 m of home_point or location), near_private_venue (50 m of the creator''s private venues), member public places pending until a moderator approves (moderator_required), venue rows need a public venue (venue_not_public), member rows need an onboarded creator (not_onboarded) who is the caller (place_creator_mismatch) and at most 10 a day (rate_limited, moderators exempt), source immutable, created_by only cleared.';

drop trigger if exists places_guard on public.places;
create trigger places_guard before insert or update on public.places
  for each row execute function public.places_guard();

-- ---------------------------------------------------------------------------
-- 6. place_hubs (explicit links only)
-- ---------------------------------------------------------------------------
create table if not exists public.place_hubs (
  place_id   uuid not null references public.places (id) on delete cascade,
  hub_id     uuid not null references public.hubs (id) on delete cascade,
  via        text not null,
  weight     integer not null default 1,              -- events: public plans here in the last 180 days
  created_at timestamptz not null default now(),
  primary key (place_id, hub_id),
  constraint place_hubs_via check (via in ('member', 'moderator', 'events')),
  constraint place_hubs_weight_range check (weight between 0 and 100000)
);
create index if not exists place_hubs_hub_idx on public.place_hubs (hub_id, place_id);
comment on table public.place_hubs is
  'Explicit place-to-hub links (D-041): member, moderator or events (meeting spots). OSM links live in places.rule_ids. A sensitive hub only gets moderator links. No user id.';

create or replace function public.place_hubs_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.via <> 'moderator' and exists (
       select 1 from public.hubs h join public.hub_categories c on c.slug = h.category_slug
        where h.id = new.hub_id and c.is_sensitive) then
    raise exception 'sensitive_hub_link' using errcode = 'check_violation',
      hint = 'Places for sensitive hubs come only from public institutions and moderators.';
  end if;
  return new;
end $$;

comment on function public.place_hubs_guard() is
  'Trigger on place_hubs (design 7 rule 6): a hub in a sensitive category takes moderator links only, never member links or plan counts.';

drop trigger if exists place_hubs_guard on public.place_hubs;
create trigger place_hubs_guard before insert or update on public.place_hubs
  for each row execute function public.place_hubs_guard();

-- ---------------------------------------------------------------------------
-- 7. place_tiles and collector_budget (no user ids)
-- ---------------------------------------------------------------------------
create table if not exists public.place_tiles (
  id              integer primary key,
  bbox            extensions.geometry(Polygon, 4326) generated always as (public.place_tile_bbox(id)) stored,
  status          public.place_tile_status not null default 'wanted',
  demand          integer not null default 0,         -- a count, never who asked
  osm_run_at      timestamptz,
  geoapify_run_at timestamptz,
  last_member_at  timestamptz,
  row_count       integer not null default 0,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint place_tiles_id_range check (id between 0 and 259199),
  constraint place_tiles_demand_nonneg check (demand >= 0),
  constraint place_tiles_row_count_nonneg check (row_count >= 0)
);
create index if not exists place_tiles_queue_idx on public.place_tiles (status, demand desc);
create or replace trigger place_tiles_set_updated_at before update on public.place_tiles
  for each row execute function public.set_updated_at();
comment on table public.place_tiles is
  'Hub map regions (D-041, design 3.5): one 0.5-degree tile per row with its lifecycle status, a demand counter and run stamps. No user id. Service role writes; moderators read.';

create table if not exists public.collector_budget (
  day        date not null,
  source     text not null,
  used       integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (day, source),
  constraint collector_budget_source_format check (source ~ '^[a-z0-9]+(_[a-z0-9]+)*$' and char_length(source) <= 40),
  constraint collector_budget_used_nonneg check (used >= 0)
);
create or replace trigger collector_budget_set_updated_at before update on public.collector_budget
  for each row execute function public.set_updated_at();
comment on table public.collector_budget is
  'Free-tier credits used per UTC day and source (for example geoapify_places, capped at 500 a day; design 3.2). Service role writes; moderators read.';

-- Atlanta's tiles (the founder's outreach city, design 3.5): the area centre's
-- tile and its west and north neighbours.
insert into public.place_tiles (id, status)
select t.id, 'active'::public.place_tile_status
  from public.areas a
 cross join lateral (values
         (public.place_tile_id_of(a.center)),
         (public.place_tile_id_of(a.center) - 1),
         (public.place_tile_id_of(a.center) + 720)) as t(id)
 where a.slug = 'atlanta' and a.center is not null
on conflict (id) do nothing;

-- ---------------------------------------------------------------------------
-- 8. venues.place_ref, listing_kind, events geometry index
-- ---------------------------------------------------------------------------
alter table public.venues add column if not exists place_ref uuid references public.places (id) on delete set null;
do $$ begin
  alter table public.venues add constraint venues_place_ref_public check (place_ref is null or is_public);
exception when duplicate_object then null; end $$;
create index if not exists venues_place_ref_idx on public.venues (place_ref) where place_ref is not null;
comment on column public.venues.place_ref is
  'The hub map place this public venue is (for "Plans here"). Never set on a private venue.';

alter table public.feed_sources add column if not exists listing_kind text not null default 'plan';
do $$ begin
  alter table public.feed_sources add constraint feed_sources_listing_kind check (listing_kind in ('plan', 'show'));
exception when duplicate_object then null; end $$;
alter table public.events add column if not exists listing_kind text not null default 'plan';
do $$ begin
  alter table public.events add constraint events_listing_kind check (listing_kind in ('plan', 'show'));
exception when duplicate_object then null; end $$;
comment on column public.events.listing_kind is
  'plan (people meeting up) or show (a ticketed show or game: its own "Shows and games" row and map layer, D-041). The importer copies it from feed_sources.listing_kind.';
comment on column public.feed_sources.listing_kind is
  'What this source''s items are: plan or show (D-041). Copied to events.listing_kind.';

create index if not exists events_approx_geom_gix on public.events
  using gist ((approx_point::extensions.geometry)) where status = 'published';

-- ---------------------------------------------------------------------------
-- 9. RLS and grants
-- ---------------------------------------------------------------------------
alter table public.place_kinds      enable row level security;
alter table public.place_rules      enable row level security;
alter table public.hub_place_rules  enable row level security;
alter table public.places           enable row level security;
alter table public.place_hubs       enable row level security;
alter table public.place_tiles      enable row level security;
alter table public.collector_budget enable row level security;

revoke all on public.place_kinds, public.place_rules, public.hub_place_rules, public.places,
  public.place_hubs, public.place_tiles, public.collector_budget from public, anon, authenticated;
grant all on public.place_kinds, public.place_rules, public.hub_place_rules, public.places,
  public.place_hubs, public.place_tiles, public.collector_budget to service_role;

-- Rule tables: everyone reads; moderators write.
grant select on public.place_kinds, public.place_rules, public.hub_place_rules to anon, authenticated;
grant insert, update, delete on public.place_kinds, public.place_rules, public.hub_place_rules to authenticated;

drop policy if exists "place_kinds_read" on public.place_kinds;
create policy "place_kinds_read" on public.place_kinds for select to anon, authenticated using (true);
drop policy if exists "place_kinds_insert_mod" on public.place_kinds;
create policy "place_kinds_insert_mod" on public.place_kinds for insert to authenticated
  with check ((select public.is_moderator()));
drop policy if exists "place_kinds_update_mod" on public.place_kinds;
create policy "place_kinds_update_mod" on public.place_kinds for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
drop policy if exists "place_kinds_delete_mod" on public.place_kinds;
create policy "place_kinds_delete_mod" on public.place_kinds for delete to authenticated
  using ((select public.is_moderator()));

drop policy if exists "place_rules_read" on public.place_rules;
create policy "place_rules_read" on public.place_rules for select to anon, authenticated using (true);
drop policy if exists "place_rules_insert_mod" on public.place_rules;
create policy "place_rules_insert_mod" on public.place_rules for insert to authenticated
  with check ((select public.is_moderator()));
drop policy if exists "place_rules_update_mod" on public.place_rules;
create policy "place_rules_update_mod" on public.place_rules for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
drop policy if exists "place_rules_delete_mod" on public.place_rules;
create policy "place_rules_delete_mod" on public.place_rules for delete to authenticated
  using ((select public.is_moderator()));

drop policy if exists "hub_place_rules_read" on public.hub_place_rules;
create policy "hub_place_rules_read" on public.hub_place_rules for select to anon, authenticated using (true);
drop policy if exists "hub_place_rules_insert_mod" on public.hub_place_rules;
create policy "hub_place_rules_insert_mod" on public.hub_place_rules for insert to authenticated
  with check ((select public.is_moderator()));
drop policy if exists "hub_place_rules_update_mod" on public.hub_place_rules;
create policy "hub_place_rules_update_mod" on public.hub_place_rules for update to authenticated
  using ((select public.is_moderator())) with check ((select public.is_moderator()));
drop policy if exists "hub_place_rules_delete_mod" on public.hub_place_rules;
create policy "hub_place_rules_delete_mod" on public.hub_place_rules for delete to authenticated
  using ((select public.is_moderator()));

-- places: read only, every column but created_by; no client writes at all
-- (definer RPCs and the service-role ingest only).
grant select (id, source, source_id, osm_ref, name, kind, rule_ids, location, geom, lat, lng, tile_id,
              address_text, locality, country, opening_hours, website, tags, is_public, status,
              locked_fields, attribution, license, last_seen_at, merged_into, search_text,
              created_at, updated_at)
  on public.places to anon, authenticated;

drop policy if exists "places_select_anon" on public.places;
create policy "places_select_anon" on public.places for select to anon
  using (status = 'active' and is_public);
drop policy if exists "places_select_authenticated" on public.places;
create policy "places_select_authenticated" on public.places for select to authenticated
  using (
    created_by = (select auth.uid())
    or (select public.is_moderator())
    or (status = 'active' and is_public
        and (source in ('osm', 'geoapify') or (select public.viewer_is_adult())))
  );

-- place_hubs: visible when its place is visible (the subquery runs under
-- places RLS).
grant select on public.place_hubs to anon, authenticated;
drop policy if exists "place_hubs_select" on public.place_hubs;
create policy "place_hubs_select" on public.place_hubs for select to anon, authenticated
  using (exists (select 1 from public.places p where p.id = place_hubs.place_id));

-- place_tiles, collector_budget: moderators read; service_role writes.
grant select on public.place_tiles, public.collector_budget to authenticated;
drop policy if exists "place_tiles_select_mod" on public.place_tiles;
create policy "place_tiles_select_mod" on public.place_tiles for select to authenticated
  using ((select public.is_moderator()));
drop policy if exists "collector_budget_select_mod" on public.collector_budget;
create policy "collector_budget_select_mod" on public.collector_budget for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 10. request_account_deletion (migration 20 body, 20261115000100_attendance.sql)
-- ---------------------------------------------------------------------------
create or replace function public.request_account_deletion(p_reason text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid       uuid := (select auth.uid());
  v_profile public.profiles%rowtype;
  v_email   text;
  v_handle  text;
  v_reason  text := nullif(left(btrim(coalesce(p_reason, '')), 500), '');
  v_event   uuid;
  v_ids     uuid[];
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into v_profile from public.profiles where id = uid for update;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  -- Idempotent: a retry after a lost response must not fail.
  if v_profile.status = 'deleted' then
    return;
  end if;

  select lower(email) into v_email from auth.users where id = uid;

  -- Evidence ledger first; it has no foreign key and outlives everything below.
  insert into public.account_deletions (user_id, email_hash, requested_at, retain_evidence_until, reason)
  values (
    uid,
    encode(extensions.digest(coalesce(v_email, uid::text), 'sha256'), 'hex'),
    now(),
    now() + interval '30 days',
    v_reason
  )
  on conflict (user_id) do update
     set requested_at          = excluded.requested_at,
         retain_evidence_until = excluded.retain_evidence_until,
         reason                = coalesce(excluded.reason, public.account_deletions.reason),
         completed_at          = null;

  -- Release the handle (30-day hold, same as a rename) and pick a tombstone handle that
  -- cannot collide: 'deleted' itself is reserved and the suffix is random.
  insert into public.handle_history (user_id, handle) values (uid, v_profile.handle);
  loop
    v_handle := 'deleted_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10);
    exit when not exists (select 1 from public.profiles where lower(handle) = v_handle);
  end loop;

  perform set_config('ap.account_deletion', 'on', true);
  update public.profiles
     set handle                 = v_handle,
         first_name             = 'Deleted user',
         bio                    = '',
         avatar_url             = null,
         home_org_id            = null,
         home_campus_id         = null,
         guidelines_accepted_at = null,
         status                 = 'deleted',
         deletion_requested_at  = now(),
         deleted_at             = now()
   where id = uid;
  perform set_config('ap.account_deletion', 'off', true);

  -- Events: hosted series and future events are cancelled (past ones stay as
  -- history under "Deleted user"), their addresses go, private venues go,
  -- public venues lose the creator link.
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted',
         location_text = '', address_note = ''
   where host_id = uid and status = 'published';
  update public.event_series
     set location_text = '', address_note = ''
   where host_id = uid and (location_text <> '' or address_note <> '');
  with u as (
    update public.events
       set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
     where host_id = uid and status = 'published' and starts_at > now()
    returning id
  )
  select coalesce(array_agg(id), '{}') into v_ids from u;
  -- Their attendees hear about it (migration 18); the caller's own profile is
  -- already a tombstone, so nothing is queued for the caller.
  foreach v_event in array v_ids loop
    perform public.notify_event_audience(
      v_event, 'event_cancelled', array['going', 'waitlisted', 'interested']::public.rsvp_status[],
      v_event::text, null, jsonb_build_object('reason', 'host_deleted'));
  end loop;
  v_event := null;
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

  -- Places (migration 27): the caller's private pins and still-pending
  -- requests go; places a moderator reviewed stay as ODbL place facts with
  -- no creator link (D-041).
  delete from public.places
   where created_by = uid and source = 'user' and (not is_public or status = 'pending');
  update public.places set created_by = null where created_by = uid;

  -- Attendance (migration 20): the caller's reports and every meet that
  -- names the caller, in either direction. (Reports would also go with the
  -- RSVP rows below; deleted here so the order does not matter.)
  delete from public.event_meets              where user_id = uid or met_user_id = uid;
  delete from public.event_attendance_reports where user_id = uid;

  -- RSVPs: every row goes (the counters trigger fixes the counts); seats on
  -- future events are handed to the waitlist.
  for v_event in
    select event_id from public.rsvps r
      join public.events e on e.id = r.event_id
     where r.user_id = uid and r.status = 'going' and e.status = 'published' and e.ends_at > now()
  loop
    delete from public.rsvps where event_id = v_event and user_id = uid;
    perform public.rsvp_promote_waitlist(v_event);
  end loop;
  delete from public.rsvps where user_id = uid;
  update public.rsvps set removed_by = null where removed_by = uid;
  update public.rsvps set checked_in_by = null where checked_in_by = uid;

  -- Chapters: the caller's claims (reference contacts included) go; stamps
  -- that point at the caller are cleared. The chapter_members row goes below
  -- (the last-organizer guard lets a deleted profile leave).
  delete from public.chapter_claims where user_id = uid;
  update public.chapter_claims set reviewed_by = null where reviewed_by = uid;
  update public.hub_chapters set claimed_by = null where claimed_by = uid;

  -- Notifications (migration 18): the caller's inbox goes; rows that name the
  -- caller as the actor keep their text and lose the link; broadcasts the
  -- caller sent stay with the event, unattributed.
  delete from public.notifications where user_id = uid;
  update public.notifications set actor_id = null where actor_id = uid;
  update public.event_broadcasts set sender_id = null where sender_id = uid;

  -- Personal data and memberships go now. Avatar files are removed by the Edge Function
  -- through the Storage API (deleting storage.objects rows here would orphan the files).
  delete from public.profile_private          where user_id = uid;
  delete from public.notification_prefs       where user_id = uid;
  delete from public.push_devices             where user_id = uid;
  delete from public.hub_members              where user_id = uid;
  delete from public.chapter_members          where user_id = uid;
  delete from public.org_memberships          where user_id = uid;
  delete from public.verified_emails          where user_id = uid;
  delete from public.email_verification_codes where user_id = uid;
  delete from public.user_roles               where user_id = uid;
  delete from public.area_waitlist            where user_id = uid;
  -- auth_provider_secrets stays until the Edge Function has revoked the Apple token.
  -- hub_requests keep pointing at the tombstone (they read as "Deleted user").

  -- Stop sign-in at once: password, OAuth, magic-link and refresh grants all check
  -- banned_until. Sessions are ended by the Edge Function's soft delete; an access token
  -- issued before this call lasts at most jwt_expiry (one hour), and the app drops it on
  -- its next route load (profiles.deleted_at).
  update auth.users
     set banned_until       = now() + interval '100 years',
         raw_user_meta_data = '{}'::jsonb
   where id = uid;
end $$;

comment on function public.request_account_deletion(text) is
  'Deletes the caller''s account immediately: ledger row, tombstone profile, profile_private (home area and radius) deleted, handle released, private data, memberships, chapter claims, notifications, attendance reports, meets naming the caller (either direction) and the city waitlist row removed, claimed_by / reviewed_by / checked_in_by / notification actor / broadcast sender references cleared, hosted series and future events cancelled with their addresses (attendees notified), private venues deleted, private and pending places deleted and reviewed places unattributed, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';


-- ---------------------------------------------------------------------------
-- 11. Function grants (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.place_tile_id(double precision, double precision) from public;
revoke all on function public.place_tile_id_of(extensions.geography) from public;
revoke all on function public.place_tile_bbox(integer) from public;
grant execute on function public.place_tile_id(double precision, double precision) to anon, authenticated, service_role;
grant execute on function public.place_tile_id_of(extensions.geography) to anon, authenticated, service_role;
grant execute on function public.place_tile_bbox(integer) to anon, authenticated, service_role;
revoke all on function public.places_guard() from public, anon, authenticated, service_role;
revoke all on function public.place_hubs_guard() from public, anon, authenticated, service_role;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 12. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.23')
  on conflict (key) do update set value = excluded.value, updated_at = now();
