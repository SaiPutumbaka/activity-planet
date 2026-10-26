-- ============================================================================
-- Activity Planet schema v2 — migration 6: events, venues, RSVPs, weekly
--   recurrence, campus email verification RPCs, hub stats refresh
--   (PLAN.md 4.2 to 4.5; D-018, D-021, D-022, D-023, D-027, D-031).
--   Revision 2, after the security / data-model / product review.
--
--   What this file adds
--     * venues: normalized addresses with a PostGIS point (plus generated
--       lat/lng so clients never parse EWKB), trigram search, de-duplication
--       through upsert_venue;
--     * events: one table for the three kinds on one card (member, chapter,
--       imported) with status, visibility, the 18+/21+ flag, capacity,
--       waitlist, minimum headcount, free/paid, counters, trigram search and
--       the feed indexes;
--     * event_addresses: the exact address of an event, split off so RLS can
--       hide it per viewer (see "Private addresses");
--     * event_series: weekly recurrence materialized into ordinary events rows
--       (see "Occurrences");
--     * rsvps: going / interested / waitlisted / cancelled per occurrence,
--       written only through set_rsvp / approve_rsvp / remove_rsvp / check_in;
--     * profiles.guidelines_accepted_at + accept_guidelines() (Community
--       Guidelines at first RSVP, PLAN 4.11);
--     * RPCs: create_event, update_event, cancel_event, create_event_series,
--       update_event_series, cancel_event_series, materialize_event_series,
--       materialize_all_event_series, set_rsvp, check_in, approve_rsvp,
--       remove_rsvp, event_attendees, event_share_card, feed_events,
--       upsert_venue, request_hub, accept_guidelines, create_verification_code,
--       confirm_email_verification, refresh_hub_stats;
--     * request_account_deletion and complete_onboarding re-created so they
--       know about events, series, RSVPs, private venues and 21+ hubs.
--
--   Design choices
--     Occurrences. A weekly series is a template (weekday, local start time,
--     duration, timezone, starts_on, ends_on or a cap). materialize_event_series
--     turns it into ordinary events rows N weeks ahead (8 at creation), each
--     carrying series_id and occurrence_date, so RSVPs, check-ins, share links
--     and later chat hang off the occurrence and nothing downstream knows about
--     recurrence. Each start is computed from local wall-clock time in the
--     series timezone ((date + time) at time zone tz), so a 7 pm practice stays
--     at 7 pm across the DST change; "today" is the local date in the series
--     timezone, never the server's UTC date. Editing a series updates future,
--     published, non-detached occurrences in place (title, cover, capacity,
--     address and so on reach every occurrence, attendees included, and the
--     occurrence ids survive, so share links keep working). A schedule change
--     (weekday, start time, duration, timezone, dates) deletes and regenerates
--     the occurrences nobody but the host has RSVP'd to and shifts the ones
--     with attendees to the new wall-clock time in the same week. Cancelling a
--     series cancels its future occurrences. The materializer is idempotent
--     (unique (series_id, occurrence_date)); materialize_all_event_series is
--     the cron entry point once pg_cron is enabled.
--
--     Private addresses (D-027). RLS hides rows, not columns, so the exact
--     address lives in event_addresses (venue_id, free-text location, "buzz
--     4B" note) and the events row carries only a coarse location_hint ("Near
--     Downtown Atlanta") plus approx_point: the exact venue point for public
--     addresses, the campus centroid (or a 0.1 degree snap, about 10 km) for
--     approved-only ones. event_addresses is readable when the event is
--     readable and its address is public, or when the viewer is the host, a
--     captain of the event's chapter, a moderator, or a going RSVP the host
--     approved (rsvps.approved_by_host, read through viewer_is_approved).
--     The database, not the client, keeps a home address private: a venue marked is_public = false cannot be used
--     with a public address (private_venue_requires_approval), a hand-typed
--     venue (no geocoder place_id) is private by default, and a public venue
--     its creator uses for an approved-only event is flipped to private when
--     no other public-address event references it. A non-public venue is
--     readable only by its creator, moderators, or through a readable
--     event_addresses row, so the venues table is not a side channel.
--     Anonymous visitors get public addresses of public events and nothing
--     else; event_share_card gives the logged-out share page the host and hub.
--
--     RSVP atomicity. set_rsvp locks the events row (select ... for update),
--     counts going rows under that lock and decides going vs waitlisted in the
--     same transaction; leaving a going RSVP promotes the lowest waitlist
--     position while the lock is held. Leaving is always allowed (it runs
--     before every eligibility check); joining needs an active, onboarded
--     profile with a photo and accepted guidelines (PLAN 4.1, 4.11). Counters
--     on events are recomputed by a trigger from the rsvps rows, never
--     incremented by hand, and events.updated_at ignores the counters so it
--     still means "edited". The host is auto-RSVP'd going by trigger on every
--     events insert, so on every occurrence, and takes one seat.
--
--     Attendee lists and sensitive hubs. Clients hold SELECT on rsvps for
--     (event_id, user_id, status, created_at, updated_at) only; approved_by_host,
--     checked_in_at, waitlist_position and the removal columns come back only
--     from the RPCs for the caller's own row and from event_attendees() for the
--     host, chapter captains and moderators. For events in a sensitive hub
--     category (faith, culture and identity, wellness and support) other
--     people's rows are visible only to the host, captains, moderators and
--     people who are themselves attending, matching hub_members_read.
--
--     Verification codes. create_verification_code runs only with the service
--     role (the send-verification-code Edge Function): it throttles first (one
--     send a minute and three an hour per user, three an hour per address,
--     counted from rows that are written on every request, so an "already
--     verified" answer is throttled too and the API response is the same
--     either way), checks the domain against org_email_domains, draws a
--     6-digit code from pgcrypto and stores sha256(code || row id). The row id
--     is a salt, not a secret: a reader of the table can brute-force a live
--     6-digit code in milliseconds; the hash only keeps stale rows in logs and
--     dumps from being usable. The table has no client policies, which is the
--     real protection. confirm_email_verification runs as the user and
--     returns a status instead of raising for a wrong, expired or exhausted
--     code, because a raised exception would roll back the attempts counter
--     (PostgREST runs the RPC in one transaction) and the five-strike limit
--     would never persist. Five wrong attempts kill the row.
--
--     Age (D-018, D-027). Accounts are 18+. Events carry min_age 18 or 21; an
--     event tagged to a campus (campus_id, and so the campus space feed) or
--     posted in a campus-scope hub cannot be 21+, and an event cannot be
--     younger than its hub (nightlife hubs are 21+). viewer_age() reads the
--     signed-in viewer's birth date (null when logged out) and the events read
--     policy refuses rows above the viewer's age; anonymous and not-yet-
--     onboarded viewers are treated as 18. hub_members and complete_onboarding
--     get the same guard. When an edit raises min_age, narrows visibility to
--     a campus or turns on members_only, attendees who no longer qualify are
--     cancelled in the same transaction and the waitlist is promoted.
--
--     Campus tag. events.campus_id means "in this campus's space" whatever the
--     visibility, so it needs a verified org membership (or a moderator) and
--     18+; the space feed and refresh_hub_stats filter on campus_id.
--
--     Writes. Every content write goes through a SECURITY DEFINER RPC scoped
--     to auth.uid(); clients hold SELECT only on the new tables. Joining and
--     leaving a hub stays a direct insert/delete on hub_members (policies
--     hub_members_insert_own / hub_members_delete_own and the grants from
--     migration 1), now with the age guard. request_hub replaces the direct
--     insert on hub_requests so the three-open-requests limit, the duplicate
--     checks and the length rules are enforced by the database. Posting is
--     rate-limited per user (10 events an hour / 30 a day, 3 series a day,
--     20 venues a day; moderators exempt). Every client-facing RPC maps a
--     table check constraint to its name as the error message, so the app's
--     error map can key on constraint names as well as the snake_case codes.
--
--   Left for the importer migration: feed_sources, event_imports (source,
--   external id, raw payload, content hash, last_seen_at), event_hub_tags
--   (an imported event in several hubs), organizer claim and takedown, the
--   tagging queue and the service-role insert path for kind = 'imported'. The
--   card-facing columns exist now (kind, external_url, source_name, cover_url,
--   is_free, price_text) so the UI is built against one shape; imported rows
--   have no host, no series and no client insert path (create_event refuses
--   the kind and clients have no INSERT grant on events). The morning-after
--   prompt (attended, people met) is migration 7.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Enums
-- ---------------------------------------------------------------------------
do $$ begin create type public.event_kind as enum ('member', 'chapter', 'imported'); exception when duplicate_object then null; end $$;
do $$ begin create type public.event_status as enum ('published', 'cancelled'); exception when duplicate_object then null; end $$;
do $$ begin create type public.event_visibility as enum ('public', 'campus'); exception when duplicate_object then null; end $$;
do $$ begin create type public.address_visibility as enum ('public', 'approved_only'); exception when duplicate_object then null; end $$;
do $$ begin create type public.rsvp_status as enum ('going', 'interested', 'waitlisted', 'cancelled'); exception when duplicate_object then null; end $$;

-- ---------------------------------------------------------------------------
-- 2. Venues
-- ---------------------------------------------------------------------------
create table if not exists public.venues (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  address_line1 text not null default '',
  address_line2 text not null default '',
  city          text not null default '',
  state         text not null default '',
  postal_code   text not null default '',
  country       text not null default 'US',
  location      extensions.geography(Point, 4326),
  lat           double precision generated always as (extensions.ST_Y(location::extensions.geometry)) stored,
  lng           double precision generated always as (extensions.ST_X(location::extensions.geometry)) stored,
  place_id      text,                                  -- geocoder id (Geoapify), optional
  campus_id     uuid references public.org_campuses (id) on delete set null,
  created_by    uuid references public.profiles (id) on delete set null,
  is_public     boolean not null default true,         -- false = someone's home; see venues_select
  search_text   text generated always as (lower(name || ' ' || city)) stored,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint venues_name_length          check (char_length(name) between 1 and 120),
  constraint venues_address_line1_length check (char_length(address_line1) <= 200),
  constraint venues_address_line2_length check (char_length(address_line2) <= 200),
  constraint venues_city_length          check (char_length(city) <= 80),
  constraint venues_state_length         check (char_length(state) <= 40),
  constraint venues_postal_code_length   check (char_length(postal_code) <= 20),
  constraint venues_country_format       check (country ~ '^[A-Z]{2}$'),
  constraint venues_place_id_length      check (place_id is null or char_length(place_id) between 1 and 200)
);
-- One public row per geocoder place; private rows keep their place_id (so a
-- private venue never reveals itself by forcing place_id to null on others).
create unique index if not exists venues_public_place_id_key on public.venues (place_id) where place_id is not null and is_public;
create index if not exists venues_place_id_idx on public.venues (place_id) where place_id is not null;
create index if not exists venues_name_postal_idx on public.venues (lower(name), postal_code);
create index if not exists venues_location_gix on public.venues using gist (location);
create index if not exists venues_search_trgm_idx on public.venues using gin (search_text extensions.gin_trgm_ops);
create index if not exists venues_campus_idx on public.venues (campus_id);
create index if not exists venues_created_by_idx on public.venues (created_by);
comment on table public.venues is
  'Geocoded places (Geoapify results may be stored). lat/lng are generated from location. is_public = false marks a private address (default for hand-typed venues without a place_id): readable by its creator, moderators and through a readable event_addresses row only. Written through upsert_venue.';
create or replace trigger venues_set_updated_at before update on public.venues
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 3. Event series (weekly recurrence template; occurrences are events rows)
-- ---------------------------------------------------------------------------
create table if not exists public.event_series (
  id                 uuid primary key default gen_random_uuid(),
  kind               public.event_kind not null default 'member',
  hub_id             uuid not null references public.hubs (id) on delete cascade,
  chapter_id         uuid references public.hub_chapters (id) on delete set null,
  campus_id          uuid references public.org_campuses (id) on delete restrict,
  host_id            uuid references public.profiles (id) on delete set null,
  title              text not null,
  description        text not null default '',
  cover_url          text,
  weekday            smallint not null,                 -- 0 = Sunday .. 6 = Saturday (extract(dow))
  start_time         time not null,                     -- local wall-clock time in `timezone`
  duration_minutes   integer not null,
  timezone           text not null default 'America/New_York',
  starts_on          date not null,
  ends_on            date,
  max_occurrences    integer,
  min_age            smallint not null default 18,
  capacity           integer,
  waitlist_enabled   boolean not null default true,
  min_headcount      integer,
  members_only       boolean not null default false,
  is_free            boolean not null default true,
  price_text         text,
  visibility         public.event_visibility not null default 'public',
  address_visibility public.address_visibility not null default 'public',
  venue_id           uuid references public.venues (id) on delete set null,
  location_text      text not null default '',
  address_note       text not null default '',
  location_hint      text not null default '',
  status             public.event_status not null default 'published',
  cancelled_at       timestamptz,
  cancel_reason      text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint event_series_kind                  check (kind in ('member', 'chapter')),
  constraint event_series_title_length          check (char_length(title) between 3 and 120),
  constraint event_series_description_length    check (char_length(description) <= 2000),
  constraint event_series_cover_url_format      check (cover_url is null or (char_length(cover_url) <= 500 and cover_url ~ '^https://')),
  constraint event_series_weekday_range         check (weekday between 0 and 6),
  constraint event_series_duration_range        check (duration_minutes between 15 and 1440),
  constraint event_series_timezone_length       check (char_length(timezone) between 1 and 64),
  constraint event_series_date_order            check (ends_on is null or ends_on >= starts_on),
  constraint event_series_max_occurrences_range check (max_occurrences is null or max_occurrences between 1 and 104),
  constraint event_series_min_age               check (min_age in (18, 21)),
  constraint event_series_capacity_range        check (capacity is null or capacity between 1 and 5000),
  constraint event_series_min_headcount_range   check (min_headcount is null or min_headcount between 2 and 5000),
  constraint event_series_min_headcount_within_capacity check (capacity is null or min_headcount is null or min_headcount <= capacity),
  constraint event_series_price_text_length     check (price_text is null or char_length(price_text) <= 40),
  constraint event_series_chapter_only_for_chapter_kind check (kind = 'chapter' or chapter_id is null),
  constraint event_series_campus_requires_campus check (visibility <> 'campus' or campus_id is not null),
  constraint event_series_campus_tag_not_21     check (campus_id is null or min_age = 18),   -- D-027
  constraint event_series_cancelled_stamp       check ((status = 'cancelled') = (cancelled_at is not null)),
  constraint event_series_cancel_reason_length  check (cancel_reason is null or char_length(cancel_reason) <= 500),
  constraint event_series_location_text_length  check (char_length(location_text) <= 200),
  constraint event_series_address_note_length   check (char_length(address_note) <= 200),
  constraint event_series_location_hint_length  check (char_length(location_hint) <= 120)
);
create index if not exists event_series_hub_idx     on public.event_series (hub_id);
create index if not exists event_series_chapter_idx on public.event_series (chapter_id);
create index if not exists event_series_campus_idx  on public.event_series (campus_id);
create index if not exists event_series_host_idx    on public.event_series (host_id);
create index if not exists event_series_venue_idx   on public.event_series (venue_id);
create index if not exists event_series_live_idx    on public.event_series (status) where status = 'published';
comment on table public.event_series is
  'Weekly recurrence template. Readable by the host, moderators and captains of its chapter (it carries the address). Occurrences are rows in events with series_id set; see materialize_event_series.';
create or replace trigger event_series_set_updated_at before update on public.event_series
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 4. Events (the social object; one row per occurrence)
-- ---------------------------------------------------------------------------
create table if not exists public.events (
  id                 uuid primary key default gen_random_uuid(),
  kind               public.event_kind not null default 'member',
  hub_id             uuid not null references public.hubs (id) on delete cascade,
  chapter_id         uuid references public.hub_chapters (id) on delete set null,
  campus_id          uuid references public.org_campuses (id) on delete restrict,
  host_id            uuid references public.profiles (id) on delete set null,   -- null for imported rows
  series_id          uuid references public.event_series (id) on delete set null,
  occurrence_date    date,                              -- local date of the occurrence in the series timezone
  detached_at        timestamptz,                       -- edited on its own; series edits leave it alone
  title              text not null,
  description        text not null default '',
  cover_url          text,
  starts_at          timestamptz not null,
  ends_at            timestamptz not null,
  timezone           text not null default 'America/New_York',
  min_age            smallint not null default 18,
  capacity           integer,                           -- null = unlimited
  waitlist_enabled   boolean not null default true,
  min_headcount      integer,                           -- "happens if N join"; informational, shown by the client
  members_only       boolean not null default false,    -- RSVP limited to hub (or chapter) members
  is_free            boolean not null default true,     -- feed filter free/paid
  price_text         text,                              -- "$5 cover", "Free for members"
  status             public.event_status not null default 'published',
  cancelled_at       timestamptz,
  cancel_reason      text,
  visibility         public.event_visibility not null default 'public',
  address_visibility public.address_visibility not null default 'public',
  location_hint      text not null default '',          -- always readable; coarse when the address is approved-only
  approx_point       extensions.geography(Point, 4326), -- exact venue point for public addresses; campus centroid or ~10 km snap otherwise
  approx_lat         double precision generated always as (extensions.ST_Y(approx_point::extensions.geometry)) stored,
  approx_lng         double precision generated always as (extensions.ST_X(approx_point::extensions.geometry)) stored,
  going_count        integer not null default 0,
  waitlist_count     integer not null default 0,
  interested_count   integer not null default 0,
  external_url       text,                              -- imported: source registration page; others: optional https link
  source_name        text,                              -- imported: feed attribution (importer migration fills it)
  search_text        text generated always as (lower(title || ' ' || description)) stored,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  constraint events_title_length            check (char_length(title) between 3 and 120),
  constraint events_description_length      check (char_length(description) <= 2000),
  constraint events_cover_url_format        check (cover_url is null or (char_length(cover_url) <= 500 and cover_url ~ '^https://')),
  constraint events_time_order              check (ends_at > starts_at),
  constraint events_duration_max            check (ends_at <= starts_at + interval '3 days'),
  constraint events_timezone_length         check (char_length(timezone) between 1 and 64),
  constraint events_min_age                 check (min_age in (18, 21)),
  constraint events_capacity_range          check (capacity is null or capacity between 1 and 5000),
  constraint events_min_headcount_range     check (min_headcount is null or min_headcount between 2 and 5000),
  constraint events_min_headcount_within_capacity check (capacity is null or min_headcount is null or min_headcount <= capacity),
  constraint events_going_within_capacity   check (capacity is null or going_count <= capacity),
  constraint events_price_text_length       check (price_text is null or char_length(price_text) <= 40),
  constraint events_cancelled_stamp         check ((status = 'cancelled') = (cancelled_at is not null)),
  constraint events_cancel_reason_length    check (cancel_reason is null or char_length(cancel_reason) <= 500),
  constraint events_campus_requires_campus  check (visibility <> 'campus' or campus_id is not null),
  constraint events_campus_tag_not_21       check (campus_id is null or min_age = 18),   -- D-027
  constraint events_chapter_only_for_chapter_kind check (kind = 'chapter' or chapter_id is null),
  constraint events_imported_shape          check (kind <> 'imported' or (host_id is null and series_id is null and external_url is not null)),
  constraint events_external_url_format     check (external_url is null or (char_length(external_url) <= 2000 and external_url ~ '^https://')),
  constraint events_source_name_length      check (source_name is null or char_length(source_name) <= 80),
  constraint events_location_hint_length    check (char_length(location_hint) <= 120),
  constraint events_occurrence_has_date     check (series_id is null or occurrence_date is not null),
  constraint events_counts_nonnegative      check (going_count >= 0 and waitlist_count >= 0 and interested_count >= 0)
);
create index if not exists events_published_starts_idx on public.events (starts_at) where status = 'published';
create index if not exists events_hub_starts_idx    on public.events (hub_id, starts_at);
create index if not exists events_campus_starts_idx on public.events (campus_id, starts_at);
create index if not exists events_host_idx          on public.events (host_id);
create index if not exists events_chapter_idx       on public.events (chapter_id);
-- (series_id, occurrence_date) also covers the series_id foreign key.
create unique index if not exists events_series_occurrence_key on public.events (series_id, occurrence_date) where series_id is not null;
create index if not exists events_approx_point_gix  on public.events using gist (approx_point);
create index if not exists events_search_trgm_idx   on public.events using gin (search_text extensions.gin_trgm_ops);
comment on table public.events is
  'One row per occurrence. kind: member (any hub member), chapter (captains/organizers), imported (service role; importer migration). The exact address is in event_addresses; location_hint and approx_point (approx_lat/approx_lng) are the coarse, always-readable version. campus_id = in that campus space (needs a verified membership, never 21+). Written through create_event / update_event / cancel_event / materialize_event_series.';
-- updated_at ignores the RSVP counters so it still means "edited".
drop trigger if exists events_set_updated_at on public.events;
create trigger events_set_updated_at before update of
    kind, hub_id, chapter_id, campus_id, host_id, series_id, occurrence_date, detached_at, title, description,
    cover_url, starts_at, ends_at, timezone, min_age, capacity, waitlist_enabled, min_headcount, members_only,
    is_free, price_text, status, cancelled_at, cancel_reason, visibility, address_visibility, location_hint,
    approx_point, external_url, source_name
  on public.events for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 5. Event addresses (the exact address; RLS decides who sees the row)
-- ---------------------------------------------------------------------------
create table if not exists public.event_addresses (
  event_id      uuid primary key references public.events (id) on delete cascade,
  venue_id      uuid references public.venues (id) on delete set null,
  location_text text not null default '',               -- free text when there is no venue, or extra detail
  address_note  text not null default '',               -- "buzz 4B", "meet at the north gate"
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint event_addresses_location_text_length check (char_length(location_text) <= 200),
  constraint event_addresses_address_note_length  check (char_length(address_note) <= 200)
);
create index if not exists event_addresses_venue_idx on public.event_addresses (venue_id);
comment on table public.event_addresses is
  'Exact address of an event. Readable with the event when address_visibility = public; otherwise only by the host, chapter captains, moderators and going RSVPs with approved_by_host. Written by event_set_location (RPC-internal).';
create or replace trigger event_addresses_set_updated_at before update on public.event_addresses
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 6. RSVPs (per occurrence; RPC-only writes)
-- ---------------------------------------------------------------------------
create table if not exists public.rsvps (
  event_id          uuid not null references public.events (id) on delete cascade,
  user_id           uuid not null references public.profiles (id) on delete cascade,
  status            public.rsvp_status not null,
  waitlist_position integer,
  approved_by_host  boolean not null default false,     -- unlocks event_addresses for approved-only addresses
  checked_in_at     timestamptz,
  removed_by        uuid references public.profiles (id) on delete set null,  -- host/captain/moderator who removed the attendee
  removed_at        timestamptz,
  removed_reason    text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  primary key (event_id, user_id),
  constraint rsvps_waitlist_position          check ((status = 'waitlisted') = (waitlist_position is not null)),
  constraint rsvps_waitlist_position_positive check (waitlist_position is null or waitlist_position > 0),
  constraint rsvps_removed_is_cancelled       check (removed_at is null or status = 'cancelled'),
  constraint rsvps_removed_reason_length      check (removed_reason is null or char_length(removed_reason) <= 200)
);
create index if not exists rsvps_user_idx         on public.rsvps (user_id);
create index if not exists rsvps_event_status_idx on public.rsvps (event_id, status);
create index if not exists rsvps_removed_by_idx   on public.rsvps (removed_by);
create index if not exists rsvps_waitlist_idx     on public.rsvps (event_id, waitlist_position) where status = 'waitlisted';
comment on table public.rsvps is
  'One row per (event, user). Written only by set_rsvp, approve_rsvp, remove_rsvp, check_in and the host auto-RSVP trigger. Clients may select event_id, user_id, status, created_at, updated_at (own rows always; others except cancelled when the event is readable, and for sensitive hub categories only for the host, captains, moderators and fellow attendees). The other columns come back from the RPCs and event_attendees().';
create or replace trigger rsvps_set_updated_at before update on public.rsvps
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------------
-- 7. Community Guidelines acceptance (first RSVP; PLAN 4.11)
-- ---------------------------------------------------------------------------
alter table public.profiles add column if not exists guidelines_accepted_at timestamptz;
comment on column public.profiles.guidelines_accepted_at is
  'When the user accepted the Community Guidelines (accept_guidelines()). Required by set_rsvp. Not client-writable.';

-- ---------------------------------------------------------------------------
-- 8. Policy helpers (STABLE, SECURITY DEFINER so policies never need table
--    grants the caller lacks and so events <-> rsvps never recurse). All of
--    them are caller-scoped: they judge auth.uid(), never a passed-in user.
-- ---------------------------------------------------------------------------
-- The signed-in viewer's age in whole years; null when logged out or before
-- the birth date is recorded.
create or replace function public.viewer_age()
returns integer language sql stable security definer set search_path = '' as $$
  select extract(year from age(current_date::timestamp, birth_date::timestamp))::integer
    from public.profile_private
   where user_id = (select auth.uid()) and birth_date is not null;
$$;

-- Verified (org_memberships) member of the organization that owns the campus.
-- Note the scope: the organization, not the single campus (a Dunwoody-verified
-- student is a member of Georgia State and so of its Atlanta space).
create or replace function public.is_campus_org_member(p_campus uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_campus is not null and exists (
    select 1
      from public.org_memberships m
      join public.org_campuses c on c.org_id = m.org_id
     where c.id = p_campus and m.user_id = (select auth.uid())
       and (m.expires_at is null or m.expires_at > now())
  );
$$;

-- Captain or organizer of the chapter (chapter_members.role).
create or replace function public.is_chapter_captain(p_chapter uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select p_chapter is not null and exists (
    select 1 from public.chapter_members
     where chapter_id = p_chapter and user_id = (select auth.uid())
       and role in ('captain', 'organizer')
  );
$$;

-- Any RSVP row of the viewer on the event (lets attendees keep seeing a
-- cancelled event). Definer so the events policy does not read rsvps under
-- RLS, which would recurse into the events policy.
create or replace function public.viewer_has_rsvp(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.rsvps
     where event_id = p_event and user_id = (select auth.uid())
  );
$$;

-- A live (not cancelled) RSVP of the viewer: the attendee-list gate for
-- events in sensitive hub categories.
create or replace function public.viewer_is_attending(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.rsvps
     where event_id = p_event and user_id = (select auth.uid()) and status <> 'cancelled'
  );
$$;

-- A going RSVP of the viewer that the host approved: unlocks an approved-only
-- address. Definer because clients hold no SELECT on rsvps.approved_by_host,
-- and a policy subquery runs as the caller.
create or replace function public.viewer_is_approved(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.rsvps
     where event_id = p_event and user_id = (select auth.uid())
       and status = 'going' and approved_by_host
  );
$$;

-- The events read rule for a signed-in viewer, as one predicate, for definer
-- RPCs that bypass RLS (event_attendees). Keep in step with
-- events_select_authenticated.
create or replace function public.can_read_event(p_event uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.events e
     where e.id = p_event
       and (
         e.host_id = (select auth.uid())
         or public.is_moderator()
         or (
           (e.status = 'published' or public.viewer_has_rsvp(e.id))
           and e.min_age <= coalesce(public.viewer_age(), 18)
           and (e.visibility = 'public' or public.is_campus_org_member(e.campus_id))
         )
       )
  );
$$;

-- Caller is the service role, the migration owner or a direct admin session.
create or replace function public.is_service_role()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce(auth.role(), current_user::text) in ('service_role', 'postgres', 'supabase_admin');
$$;

-- IANA zone names only ('America/New_York'); abbreviations such as 'EST'
-- resolve but never observe DST, so they are refused.
create or replace function public.is_valid_timezone(p_tz text)
returns boolean language sql stable set search_path = '' as $$
  select p_tz is not null
     and char_length(p_tz) <= 64
     and p_tz like '%/%'
     and exists (select 1 from pg_catalog.pg_timezone_names where name = p_tz);
$$;

-- Default address visibility for a venue: a private venue is approved-only
-- unless the caller says otherwise (and "public" on a private venue is refused).
create or replace function public.default_address_visibility(p_venue_id uuid)
returns public.address_visibility language sql stable security definer set search_path = '' as $$
  select case when exists (select 1 from public.venues where id = p_venue_id and not is_public)
              then 'approved_only'::public.address_visibility
              else 'public'::public.address_visibility end;
$$;

-- ---------------------------------------------------------------------------
-- 9. Triggers: host auto-RSVP, RSVP counters
-- ---------------------------------------------------------------------------
create or replace function public.events_host_auto_rsvp()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.host_id is not null then
    insert into public.rsvps (event_id, user_id, status, approved_by_host)
    values (new.id, new.host_id, 'going', true)
    on conflict (event_id, user_id) do nothing;
  end if;
  return null;
end $$;
create or replace trigger events_host_auto_rsvp after insert on public.events
  for each row execute function public.events_host_auto_rsvp();

create or replace function public.rsvps_refresh_counts()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  v_event uuid;
begin
  if tg_op = 'DELETE' then v_event := old.event_id; else v_event := new.event_id; end if;
  update public.events e
     set going_count      = c.going,
         waitlist_count   = c.waitlisted,
         interested_count = c.interested
    from (select count(*) filter (where status = 'going')      as going,
                 count(*) filter (where status = 'waitlisted') as waitlisted,
                 count(*) filter (where status = 'interested') as interested
            from public.rsvps
           where event_id = v_event) c
   where e.id = v_event;
  return null;
end $$;
create or replace trigger rsvps_refresh_counts after insert or delete or update of status on public.rsvps
  for each row execute function public.rsvps_refresh_counts();

-- ---------------------------------------------------------------------------
-- 10. RPC internals: shared validation, address writer, waitlist promotion,
--     eligibility sweep, series materialization, constraint-name mapping
-- ---------------------------------------------------------------------------
-- The product rules shared by create_event, update_event and the series RPCs.
-- Caller-scoped (auth.uid()). Raises on the first violation; returns the
-- resolved campus_id (a chapter event in the campus space inherits the
-- chapter's campus when none is given).
create or replace function public.event_rules_check(
  p_kind               public.event_kind,
  p_hub_id             uuid,
  p_chapter_id         uuid,
  p_visibility         public.event_visibility,
  p_campus_id          uuid,
  p_min_age            smallint,
  p_venue_id           uuid,
  p_location_text      text,
  p_address_visibility public.address_visibility
)
returns uuid language plpgsql stable security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  v_hub     public.hubs%rowtype;
  v_chapter public.hub_chapters%rowtype;
  v_venue   public.venues%rowtype;
  v_campus  uuid := p_campus_id;
  v_mod     boolean := public.is_moderator();
  v_age     integer := public.viewer_age();
begin
  if p_kind is null or p_kind = 'imported' then
    raise exception 'kind_not_allowed' using errcode = 'check_violation',
      hint = 'Imported events are written by the importer with the service role.';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;

  select * into v_hub from public.hubs where id = p_hub_id;
  if not found then
    raise exception 'hub_not_found' using errcode = 'P0002';
  end if;
  if not v_hub.is_active then
    raise exception 'hub_inactive' using errcode = 'check_violation';
  end if;

  if p_min_age is null or p_min_age not in (18, 21) then
    raise exception 'min_age_invalid' using errcode = 'check_violation';
  end if;
  if p_min_age < v_hub.min_age then
    raise exception 'hub_min_age' using errcode = 'check_violation',
      hint = 'Events in this hub are ' || v_hub.min_age || '+.';
  end if;
  if v_hub.scope = 'campus' and p_min_age <> 18 then
    raise exception 'campus_min_age' using errcode = 'check_violation',
      hint = '21+ events belong to non-campus hubs (D-027).';
  end if;
  if v_age is null or v_age < p_min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;

  if p_kind = 'member' then
    if p_chapter_id is not null then
      raise exception 'invalid_chapter' using errcode = 'check_violation',
        hint = 'Member events do not belong to a chapter.';
    end if;
    if not v_mod and not exists (select 1 from public.hub_members where hub_id = p_hub_id and user_id = uid) then
      raise exception 'not_hub_member' using errcode = '42501', hint = 'Join the hub to post an event in it.';
    end if;
  else
    if p_chapter_id is null then
      raise exception 'invalid_chapter' using errcode = 'check_violation', hint = 'Chapter events need a chapter.';
    end if;
    select * into v_chapter from public.hub_chapters where id = p_chapter_id;
    if not found or not v_chapter.is_active then
      raise exception 'chapter_not_found' using errcode = 'P0002';
    end if;
    if v_chapter.hub_id <> p_hub_id then
      raise exception 'chapter_mismatch' using errcode = 'check_violation', hint = 'The chapter belongs to another hub.';
    end if;
    if not v_mod and not public.is_chapter_captain(p_chapter_id) then
      raise exception 'not_chapter_captain' using errcode = '42501',
        hint = 'Only captains and organizers post as the chapter.';
    end if;
    if p_visibility = 'campus' then
      v_campus := coalesce(v_campus, v_chapter.campus_id);
    end if;
  end if;

  if p_visibility = 'campus' and v_campus is null then
    raise exception 'campus_required' using errcode = 'check_violation';
  end if;
  -- A campus tag puts the event in that campus's space whatever the visibility:
  -- verified members only, never 21+.
  if v_campus is not null then
    if not exists (select 1 from public.org_campuses where id = v_campus) then
      raise exception 'campus_not_found' using errcode = 'P0002';
    end if;
    if p_min_age <> 18 then
      raise exception 'campus_min_age' using errcode = 'check_violation',
        hint = '21+ events live outside the campus space (D-027).';
    end if;
    if v_chapter.id is not null and v_chapter.campus_id is not null and v_chapter.campus_id <> v_campus then
      raise exception 'chapter_mismatch' using errcode = 'check_violation', hint = 'The chapter belongs to another campus.';
    end if;
    if not v_mod and not public.is_campus_org_member(v_campus) then
      raise exception 'not_campus_member' using errcode = '42501',
        hint = 'Verify a campus email to post in the campus space.';
    end if;
  end if;

  if p_venue_id is not null then
    select * into v_venue from public.venues v
     where v.id = p_venue_id and (v.is_public or v.created_by = uid or v_mod);
    if not found then
      raise exception 'venue_not_found' using errcode = 'P0002';
    end if;
    if not v_venue.is_public and coalesce(p_address_visibility, 'public') = 'public' then
      raise exception 'private_venue_requires_approval' using errcode = 'check_violation',
        hint = 'This venue is a private address; share it after approval.';
    end if;
  elsif nullif(btrim(coalesce(p_location_text, '')), '') is null then
    raise exception 'location_required' using errcode = 'check_violation',
      hint = 'Pick a venue or describe where to meet.';
  end if;

  return v_campus;
end $$;

-- Writes the exact address to event_addresses and the coarse version
-- (location_hint, approx_point) to the events row. For approved-only
-- addresses the hint is the host's own wording, else "Near <campus>" or
-- "Near <city>", and the point is the campus centroid when the event has a
-- campus, else the venue point snapped to a 0.1 degree grid (about 10 km):
-- never a venue-derived coordinate that could be matched back to a home.
-- A public venue its creator uses for an approved-only event becomes private
-- unless another public-address event already references it.
create or replace function public.event_set_location(
  p_event_id           uuid,
  p_venue_id           uuid,
  p_location_text      text,
  p_address_note       text,
  p_address_visibility public.address_visibility,
  p_location_hint      text,
  p_campus_id          uuid
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_venue  public.venues%rowtype;
  v_host   uuid;
  v_campus public.org_campuses%rowtype;
  v_hint   text;
  v_point  extensions.geography;
  v_text   text := btrim(coalesce(p_location_text, ''));
begin
  select host_id into v_host from public.events where id = p_event_id;
  if p_venue_id is not null then
    select * into v_venue from public.venues where id = p_venue_id;
    if not found then
      raise exception 'venue_not_found' using errcode = 'P0002';
    end if;
  end if;
  if p_campus_id is not null then
    select * into v_campus from public.org_campuses where id = p_campus_id;
  end if;

  if p_address_visibility = 'public' then
    if v_venue.id is not null and not v_venue.is_public then
      raise exception 'private_venue_requires_approval' using errcode = 'check_violation';
    end if;
    v_hint  := coalesce(nullif(btrim(coalesce(p_location_hint, '')), ''), v_venue.name, nullif(v_text, ''), '');
    v_point := v_venue.location;
  else
    if v_venue.id is not null and v_venue.is_public and v_venue.created_by is not null and v_venue.created_by = v_host
       and not exists (
         select 1 from public.event_addresses ea
           join public.events e2 on e2.id = ea.event_id
          where ea.venue_id = v_venue.id and ea.event_id <> p_event_id and e2.address_visibility = 'public') then
      update public.venues set is_public = false where id = v_venue.id;
      v_venue.is_public := false;
    end if;
    v_hint := coalesce(
      nullif(btrim(coalesce(p_location_hint, '')), ''),
      case when v_campus.id is not null then 'Near ' || v_campus.name end,
      case when nullif(v_venue.city, '') is not null then 'Near ' || v_venue.city end,
      'Address shared after approval');
    if v_campus.location is not null then
      v_point := v_campus.location;
    elsif v_venue.location is not null then
      v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(
                   round(extensions.ST_X(v_venue.location::extensions.geometry)::numeric, 1)::double precision,
                   round(extensions.ST_Y(v_venue.location::extensions.geometry)::numeric, 1)::double precision
                 ), 4326)::extensions.geography;
    end if;
  end if;

  insert into public.event_addresses (event_id, venue_id, location_text, address_note)
  values (p_event_id, p_venue_id, v_text, btrim(coalesce(p_address_note, '')))
  on conflict (event_id) do update
     set venue_id      = excluded.venue_id,
         location_text = excluded.location_text,
         address_note  = excluded.address_note;

  update public.events
     set location_hint = left(v_hint, 120),
         approx_point  = v_point
   where id = p_event_id
     and (location_hint is distinct from left(v_hint, 120) or approx_point::text is distinct from v_point::text);
end $$;

-- Moves waitlisted people to going while seats are free, lowest position
-- first. Callers hold the events row lock; the re-lock here is a no-op.
create or replace function public.rsvp_promote_waitlist(p_event_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  e          public.events%rowtype;
  v_going    integer;
  v_user     uuid;
  v_promoted integer := 0;
begin
  select * into e from public.events where id = p_event_id for update;
  if not found or e.status = 'cancelled' then
    return 0;
  end if;
  loop
    select count(*) into v_going from public.rsvps where event_id = p_event_id and status = 'going';
    exit when e.capacity is not null and v_going >= e.capacity;
    select user_id into v_user
      from public.rsvps
     where event_id = p_event_id and status = 'waitlisted'
     order by waitlist_position
     limit 1;
    exit when v_user is null;
    update public.rsvps
       set status = 'going', waitlist_position = null
     where event_id = p_event_id and user_id = v_user;
    v_promoted := v_promoted + 1;
  end loop;
  return v_promoted;
end $$;

-- After an edit narrows who may attend (min_age up, campus visibility,
-- members_only): cancels the RSVPs of people who no longer qualify, then
-- promotes the waitlist. The host's own row is never touched. Returns the
-- number of RSVPs cancelled.
create or replace function public.event_drop_ineligible_rsvps(p_event_id uuid)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  n integer;
begin
  update public.rsvps r
     set status = 'cancelled', waitlist_position = null
    from public.events e
   where e.id = p_event_id and r.event_id = e.id
     and r.status <> 'cancelled'
     and r.user_id is distinct from e.host_id
     and (
       coalesce((select extract(year from age(current_date::timestamp, pp.birth_date::timestamp))::integer
                   from public.profile_private pp where pp.user_id = r.user_id), 0) < e.min_age
       or (e.visibility = 'campus' and not exists (
             select 1 from public.org_memberships m
               join public.org_campuses c on c.org_id = m.org_id
              where c.id = e.campus_id and m.user_id = r.user_id
                and (m.expires_at is null or m.expires_at > now())))
       or (e.members_only and e.kind = 'chapter' and not exists (
             select 1 from public.chapter_members cm where cm.chapter_id = e.chapter_id and cm.user_id = r.user_id))
       or (e.members_only and e.kind <> 'chapter' and not exists (
             select 1 from public.hub_members hm where hm.hub_id = e.hub_id and hm.user_id = r.user_id))
     );
  get diagnostics n = row_count;
  if n > 0 then
    perform public.rsvp_promote_waitlist(p_event_id);
  end if;
  return n;
end $$;

-- Creates the missing occurrences of a series up to p_weeks ahead (1 to 26)
-- from the first occurrence (or today, whichever is later), so a spring
-- schedule entered in November gets its full horizon. DST-correct: each start
-- is the local wall-clock time on that date in the series timezone; "today"
-- is the local date in that timezone. Idempotent through (series_id,
-- occurrence_date); honours ends_on and max_occurrences (which counts every
-- existing occurrence, cancelled ones included). Does nothing for a cancelled
-- series or a host whose account is no longer active. Returns the number of
-- rows inserted.
create or replace function public.materialize_event_series(p_series_id uuid, p_weeks integer default 8)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  s          public.event_series%rowtype;
  v_today    date;
  v_horizon  date;
  v_date     date;
  v_count    integer;
  v_inserted integer := 0;
  v_starts   timestamptz;
  v_ends     timestamptz;
  v_id       uuid;
begin
  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'P0002';
  end if;
  if s.status = 'cancelled' then
    return 0;
  end if;
  if s.host_id is null or not exists (select 1 from public.profiles where id = s.host_id and status = 'active') then
    return 0;
  end if;

  v_today   := (now() at time zone s.timezone)::date;
  v_date    := greatest(s.starts_on, v_today);
  v_horizon := v_date + greatest(1, least(coalesce(p_weeks, 8), 26)) * 7;
  v_date    := v_date + ((s.weekday - extract(dow from v_date)::integer + 7) % 7);
  select count(*) into v_count from public.events where series_id = s.id;

  while v_date < v_horizon and (s.ends_on is null or v_date <= s.ends_on) loop
    exit when s.max_occurrences is not null and v_count >= s.max_occurrences;
    v_starts := (v_date + s.start_time) at time zone s.timezone;
    v_ends   := v_starts + make_interval(mins => s.duration_minutes);
    if v_starts > now() then
      insert into public.events (kind, hub_id, chapter_id, campus_id, host_id, series_id, occurrence_date,
                                 title, description, cover_url, starts_at, ends_at, timezone, min_age,
                                 capacity, waitlist_enabled, min_headcount, members_only, is_free, price_text,
                                 visibility, address_visibility, status)
      values (s.kind, s.hub_id, s.chapter_id, s.campus_id, s.host_id, s.id, v_date,
              s.title, s.description, s.cover_url, v_starts, v_ends, s.timezone, s.min_age,
              s.capacity, s.waitlist_enabled, s.min_headcount, s.members_only, s.is_free, s.price_text,
              s.visibility, s.address_visibility, 'published')
      on conflict (series_id, occurrence_date) where series_id is not null do nothing
      returning id into v_id;
      if v_id is not null then
        perform public.event_set_location(v_id, s.venue_id, s.location_text, s.address_note,
                                          s.address_visibility, s.location_hint, s.campus_id);
        v_inserted := v_inserted + 1;
        v_count    := v_count + 1;
        v_id       := null;
      end if;
    end if;
    v_date := v_date + 7;
  end loop;
  return v_inserted;
end $$;

comment on function public.materialize_event_series(uuid, integer) is
  'Creates missing occurrences of a weekly series up to N weeks ahead (default 8) from its first occurrence. Internal: called by the series RPCs now and by materialize_all_event_series later. Service role only.';

-- Cron entry point (pg_cron, weekly, once enabled): tops up every published
-- series. Returns the number of occurrences created.
create or replace function public.materialize_all_event_series(p_weeks integer default 8)
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_series uuid;
  n        integer := 0;
begin
  if not public.is_service_role() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for v_series in select id from public.event_series where status = 'published' order by created_at loop
    n := n + public.materialize_event_series(v_series, p_weeks);
  end loop;
  return n;
end $$;

comment on function public.materialize_all_event_series(integer) is
  'Materializes every published weekly series N weeks ahead (default 8). Service role / cron only; not scheduled by this migration.';

-- Rate limit shared by create_event / create_event_series. Serialized per
-- host with an advisory lock so two concurrent posts cannot both pass.
create or replace function public.event_post_rate_check(p_series boolean)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
begin
  if public.is_moderator() then
    return;
  end if;
  perform pg_advisory_xact_lock(hashtext('events:' || uid::text));
  if p_series then
    if (select count(*) from public.event_series where host_id = uid and created_at > now() - interval '24 hours') >= 3 then
      raise exception 'too_many_series' using errcode = 'check_violation',
        hint = 'Up to three weekly series a day.';
    end if;
  else
    if (select count(*) from public.events where host_id = uid and series_id is null and created_at > now() - interval '1 hour') >= 10
       or (select count(*) from public.events where host_id = uid and series_id is null and created_at > now() - interval '24 hours') >= 30 then
      raise exception 'too_many_events' using errcode = 'check_violation',
        hint = 'Up to ten events an hour and thirty a day.';
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 11. Event RPCs: create_event, update_event, cancel_event
--     All take a jsonb of named fields (the client has Zod schemas for them;
--     a bad enum or timestamp text fails the cast with 22P02). Keys:
--       hub_id*, title*, starts_at*, ends_at*, description, kind (member |
--       chapter), chapter_id, visibility (public | campus), campus_id,
--       min_age (18 | 21), capacity, waitlist_enabled, min_headcount,
--       members_only, is_free, price_text, venue_id, location_text,
--       address_note, address_visibility (public | approved_only; defaults to
--       approved_only for a private venue), location_hint, cover_url,
--       timezone, external_url.
--     A table check constraint that slips past the explicit checks comes back
--     with its name as the message (events_duration_max, ...).
-- ---------------------------------------------------------------------------
create or replace function public.create_event(p_args jsonb)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  uid         uuid := (select auth.uid());
  a           jsonb := coalesce(p_args, '{}'::jsonb);
  v_kind      public.event_kind := coalesce((a ->> 'kind')::public.event_kind, 'member');
  v_vis       public.event_visibility := coalesce((a ->> 'visibility')::public.event_visibility, 'public');
  v_venue     uuid := (a ->> 'venue_id')::uuid;
  v_addr      public.address_visibility;
  v_min_age   smallint := coalesce((a ->> 'min_age')::smallint, 18);
  v_tz        text := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), 'America/New_York');
  v_title     text := btrim(coalesce(a ->> 'title', ''));
  v_desc      text := btrim(coalesce(a ->> 'description', ''));
  v_starts    timestamptz := (a ->> 'starts_at')::timestamptz;
  v_ends      timestamptz := (a ->> 'ends_at')::timestamptz;
  v_capacity  integer := (a ->> 'capacity')::integer;
  v_headcount integer := (a ->> 'min_headcount')::integer;
  v_campus    uuid;
  v_c         text;
  result      public.events;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_title = '' then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(v_title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(v_desc) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if v_starts is null or v_ends is null or v_ends <= v_starts then
    raise exception 'invalid_time_range' using errcode = 'check_violation';
  end if;
  if v_ends > v_starts + interval '3 days' then
    raise exception 'duration_too_long' using errcode = 'check_violation', hint = 'Events last up to three days.';
  end if;
  if v_starts < now() - interval '1 hour' then
    raise exception 'starts_in_past' using errcode = 'check_violation', hint = 'Events start in the future.';
  end if;
  if not public.is_valid_timezone(v_tz) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if v_capacity is not null and v_headcount is not null and v_headcount > v_capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  v_addr := coalesce((a ->> 'address_visibility')::public.address_visibility, public.default_address_visibility(v_venue));

  v_campus := public.event_rules_check(
    v_kind, (a ->> 'hub_id')::uuid, (a ->> 'chapter_id')::uuid, v_vis,
    (a ->> 'campus_id')::uuid, v_min_age, v_venue, a ->> 'location_text', v_addr);
  perform public.event_post_rate_check(false);

  insert into public.events (kind, hub_id, chapter_id, campus_id, host_id, title, description, cover_url,
                             starts_at, ends_at, timezone, min_age, capacity, waitlist_enabled, min_headcount,
                             members_only, is_free, price_text, visibility, address_visibility, external_url)
  values (v_kind, (a ->> 'hub_id')::uuid, (a ->> 'chapter_id')::uuid, v_campus, uid,
          v_title, v_desc,
          nullif(btrim(coalesce(a ->> 'cover_url', '')), ''),
          v_starts, v_ends, v_tz, v_min_age, v_capacity, coalesce((a ->> 'waitlist_enabled')::boolean, true),
          v_headcount, coalesce((a ->> 'members_only')::boolean, false),
          coalesce((a ->> 'is_free')::boolean, true), nullif(btrim(coalesce(a ->> 'price_text', '')), ''),
          v_vis, v_addr,
          nullif(btrim(coalesce(a ->> 'external_url', '')), ''))
  returning * into result;

  perform public.event_set_location(result.id, v_venue, a ->> 'location_text',
                                    a ->> 'address_note', v_addr, a ->> 'location_hint', v_campus);
  select * into result from public.events where id = result.id;
  return result;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.create_event(jsonb) is
  'Posts an event as the caller. kind member needs hub membership, kind chapter needs a captain/organizer role; a campus tag needs a verified org membership and 18+. Errors: not_authenticated, title_required, title_length, description_too_long, invalid_time_range, duration_too_long, starts_in_past, timezone_invalid, min_headcount_above_capacity, kind_not_allowed, onboarding_required, hub_not_found, hub_inactive, min_age_invalid, hub_min_age, campus_min_age, age_restricted, invalid_chapter, not_hub_member, chapter_not_found, chapter_mismatch, not_chapter_captain, campus_required, campus_not_found, not_campus_member, venue_not_found, private_venue_requires_approval, location_required, too_many_events, or a table constraint name.';

-- Patch semantics: only keys present in p_args change; kind, hub_id and
-- chapter_id are fixed after creation. Address keys (venue_id, location_text,
-- address_note, address_visibility) are the host's (and moderators'); chapter
-- captains edit everything else. Editing an occurrence detaches it from its
-- series so a later series edit leaves it alone. Narrowing eligibility
-- cancels the attendees who no longer qualify.
create or replace function public.update_event(p_event_id uuid, p_args jsonb)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  uid       uuid := (select auth.uid());
  a         jsonb := coalesce(p_args, '{}'::jsonb);
  e         public.events%rowtype;
  l         public.event_addresses%rowtype;
  v_key     text;
  v_allowed text[] := array['title', 'description', 'cover_url', 'starts_at', 'ends_at', 'timezone', 'min_age',
                            'capacity', 'waitlist_enabled', 'min_headcount', 'members_only', 'is_free', 'price_text',
                            'visibility', 'campus_id', 'address_visibility', 'venue_id', 'location_text',
                            'address_note', 'location_hint', 'external_url'];
  v_address text[] := array['address_visibility', 'venue_id', 'location_text', 'address_note'];
  v_going   integer;
  v_campus  uuid;
  v_hint    text;
  v_narrow  boolean := false;
  v_c       text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  for v_key in select jsonb_object_keys(a) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'immutable_field' using errcode = 'check_violation',
        hint = v_key || ' cannot be changed after creation.';
    end if;
  end loop;

  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if e.kind = 'imported' then
    raise exception 'kind_not_allowed' using errcode = 'check_violation';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if a ?| v_address and not (coalesce(e.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can change the address.';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if e.ends_at < now() then
    raise exception 'event_over' using errcode = 'check_violation';
  end if;
  select * into l from public.event_addresses where event_id = e.id;

  if a ? 'title'              then e.title              := btrim(coalesce(a ->> 'title', '')); end if;
  if a ? 'description'        then e.description        := btrim(coalesce(a ->> 'description', '')); end if;
  if a ? 'cover_url'          then e.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), ''); end if;
  if a ? 'starts_at'          then e.starts_at          := (a ->> 'starts_at')::timestamptz; end if;
  if a ? 'ends_at'            then e.ends_at            := (a ->> 'ends_at')::timestamptz; end if;
  if a ? 'timezone'           then e.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), e.timezone); end if;
  if a ? 'min_age'            then e.min_age            := (a ->> 'min_age')::smallint; end if;
  if a ? 'capacity'           then e.capacity           := (a ->> 'capacity')::integer; end if;
  if a ? 'waitlist_enabled'   then e.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, e.waitlist_enabled); end if;
  if a ? 'min_headcount'      then e.min_headcount      := (a ->> 'min_headcount')::integer; end if;
  if a ? 'members_only'       then e.members_only       := coalesce((a ->> 'members_only')::boolean, e.members_only); end if;
  if a ? 'is_free'            then e.is_free            := coalesce((a ->> 'is_free')::boolean, e.is_free); end if;
  if a ? 'price_text'         then e.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), ''); end if;
  if a ? 'visibility'         then e.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, e.visibility); end if;
  if a ? 'campus_id'          then e.campus_id          := (a ->> 'campus_id')::uuid; end if;
  if a ? 'venue_id'           then l.venue_id           := (a ->> 'venue_id')::uuid; end if;
  if a ? 'address_visibility' then e.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, e.address_visibility);
  elsif a ? 'venue_id'        then e.address_visibility := public.default_address_visibility(l.venue_id); end if;
  if a ? 'location_text'      then l.location_text      := btrim(coalesce(a ->> 'location_text', '')); end if;
  if a ? 'address_note'       then l.address_note       := btrim(coalesce(a ->> 'address_note', '')); end if;
  if a ? 'external_url'       then e.external_url       := nullif(btrim(coalesce(a ->> 'external_url', '')), ''); end if;
  -- location_hint: the caller's value when sent (empty asks for the default);
  -- recomputed when any address field changes; otherwise kept as stored.
  v_hint := case
              when a ? 'location_hint' then a ->> 'location_hint'
              when a ?| array['venue_id', 'location_text', 'address_visibility', 'campus_id', 'visibility'] then null
              else e.location_hint
            end;

  if nullif(e.title, '') is null then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(e.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(e.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if e.starts_at is null or e.ends_at is null or e.ends_at <= e.starts_at then
    raise exception 'invalid_time_range' using errcode = 'check_violation';
  end if;
  if e.ends_at > e.starts_at + interval '3 days' then
    raise exception 'duration_too_long' using errcode = 'check_violation', hint = 'Events last up to three days.';
  end if;
  if a ? 'starts_at' and e.starts_at < now() - interval '1 hour' then
    raise exception 'starts_in_past' using errcode = 'check_violation', hint = 'Events start in the future.';
  end if;
  if not public.is_valid_timezone(e.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if e.capacity is not null and e.min_headcount is not null and e.min_headcount > e.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  if e.capacity is not null then
    select count(*) into v_going from public.rsvps where event_id = e.id and status = 'going';
    if v_going > e.capacity then
      raise exception 'capacity_below_going' using errcode = 'check_violation',
        hint = v_going || ' people are already going.';
    end if;
  end if;

  v_campus := public.event_rules_check(
    e.kind, e.hub_id, e.chapter_id, e.visibility, e.campus_id, e.min_age, l.venue_id, l.location_text, e.address_visibility);

  v_narrow := (a ? 'min_age' and e.min_age = 21)
           or (a ? 'visibility' and e.visibility = 'campus')
           or (a ? 'campus_id')
           or (a ? 'members_only' and e.members_only);

  update public.events
     set title              = e.title,
         description        = e.description,
         cover_url          = e.cover_url,
         starts_at          = e.starts_at,
         ends_at            = e.ends_at,
         timezone           = e.timezone,
         min_age            = e.min_age,
         capacity           = e.capacity,
         waitlist_enabled   = e.waitlist_enabled,
         min_headcount      = e.min_headcount,
         members_only       = e.members_only,
         is_free            = e.is_free,
         price_text         = e.price_text,
         visibility         = e.visibility,
         campus_id          = v_campus,
         address_visibility = e.address_visibility,
         external_url       = e.external_url,
         detached_at        = case when e.series_id is not null then coalesce(e.detached_at, now()) else e.detached_at end
   where id = e.id;

  perform public.event_set_location(e.id, l.venue_id, l.location_text, l.address_note,
                                    e.address_visibility, v_hint, v_campus);
  if v_narrow then
    perform public.event_drop_ineligible_rsvps(e.id);
  end if;
  perform public.rsvp_promote_waitlist(e.id);

  select * into e from public.events where id = e.id;
  return e;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.update_event(uuid, jsonb) is
  'Patches an event (keys present in p_args). Host, chapter captains and moderators; address keys are host/moderator only. Narrowing eligibility cancels attendees who no longer qualify. Errors: not_authenticated, immutable_field, event_not_found, kind_not_allowed, forbidden, event_cancelled, event_over, capacity_below_going, plus the create_event validation codes.';

create or replace function public.cancel_event(p_event_id uuid, p_reason text default null)
returns public.events language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if e.status = 'cancelled' then
    return e;
  end if;
  update public.events
     set status        = 'cancelled',
         cancelled_at  = now(),
         cancel_reason = left(nullif(btrim(coalesce(p_reason, '')), ''), 500)
   where id = e.id
   returning * into e;
  -- Attendee notifications are a later migration (notifications table); the
  -- client reads status and cancel_reason for now.
  return e;
end $$;

comment on function public.cancel_event(uuid, text) is
  'Cancels an event (host, chapter captains, moderators). Idempotent. Errors: not_authenticated, event_not_found, forbidden.';

-- ---------------------------------------------------------------------------
-- 12. Series RPCs: create_event_series, update_event_series,
--     cancel_event_series. Keys as for create_event, plus weekday* (0 = Sunday),
--     start_time* ('19:00'), duration_minutes* (15..1440), starts_on (default
--     today in the series timezone), ends_on, max_occurrences; no starts_at /
--     ends_at.
-- ---------------------------------------------------------------------------
create or replace function public.create_event_series(p_args jsonb)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  a        jsonb := coalesce(p_args, '{}'::jsonb);
  s        public.event_series%rowtype;
  v_campus uuid;
  v_today  date;
  v_c      text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  s.kind               := coalesce((a ->> 'kind')::public.event_kind, 'member');
  s.hub_id             := (a ->> 'hub_id')::uuid;
  s.chapter_id         := (a ->> 'chapter_id')::uuid;
  s.campus_id          := (a ->> 'campus_id')::uuid;
  s.title              := btrim(coalesce(a ->> 'title', ''));
  s.description        := btrim(coalesce(a ->> 'description', ''));
  s.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), '');
  s.weekday            := (a ->> 'weekday')::smallint;
  s.start_time         := (a ->> 'start_time')::time;
  s.duration_minutes   := (a ->> 'duration_minutes')::integer;
  s.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), 'America/New_York');
  s.ends_on            := (a ->> 'ends_on')::date;
  s.max_occurrences    := (a ->> 'max_occurrences')::integer;
  s.min_age            := coalesce((a ->> 'min_age')::smallint, 18);
  s.capacity           := (a ->> 'capacity')::integer;
  s.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, true);
  s.min_headcount      := (a ->> 'min_headcount')::integer;
  s.members_only       := coalesce((a ->> 'members_only')::boolean, false);
  s.is_free            := coalesce((a ->> 'is_free')::boolean, true);
  s.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), '');
  s.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, 'public');
  s.venue_id           := (a ->> 'venue_id')::uuid;
  s.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, public.default_address_visibility(s.venue_id));
  s.location_text      := btrim(coalesce(a ->> 'location_text', ''));
  s.address_note       := btrim(coalesce(a ->> 'address_note', ''));
  s.location_hint      := btrim(coalesce(a ->> 'location_hint', ''));

  if s.title = '' then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(s.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(s.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if s.weekday is null or s.weekday not between 0 and 6 then
    raise exception 'weekday_invalid' using errcode = 'check_violation', hint = '0 = Sunday .. 6 = Saturday.';
  end if;
  if s.start_time is null then
    raise exception 'start_time_required' using errcode = 'check_violation';
  end if;
  if s.duration_minutes is null or s.duration_minutes not between 15 and 1440 then
    raise exception 'duration_invalid' using errcode = 'check_violation';
  end if;
  if not public.is_valid_timezone(s.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  v_today     := (now() at time zone s.timezone)::date;
  s.starts_on := coalesce((a ->> 'starts_on')::date, v_today);
  if s.ends_on is not null and s.ends_on < greatest(s.starts_on, v_today) then
    raise exception 'invalid_date_range' using errcode = 'check_violation';
  end if;
  if s.capacity is not null and s.min_headcount is not null and s.min_headcount > s.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;

  v_campus := public.event_rules_check(
    s.kind, s.hub_id, s.chapter_id, s.visibility, s.campus_id, s.min_age, s.venue_id, s.location_text, s.address_visibility);
  perform public.event_post_rate_check(true);

  insert into public.event_series (kind, hub_id, chapter_id, campus_id, host_id, title, description, cover_url,
                                   weekday, start_time, duration_minutes, timezone, starts_on, ends_on,
                                   max_occurrences, min_age, capacity, waitlist_enabled, min_headcount,
                                   members_only, is_free, price_text, visibility, address_visibility, venue_id,
                                   location_text, address_note, location_hint)
  values (s.kind, s.hub_id, s.chapter_id, v_campus, uid, s.title, s.description, s.cover_url,
          s.weekday, s.start_time, s.duration_minutes, s.timezone, s.starts_on, s.ends_on,
          s.max_occurrences, s.min_age, s.capacity, s.waitlist_enabled, s.min_headcount,
          s.members_only, s.is_free, s.price_text, s.visibility, s.address_visibility, s.venue_id,
          s.location_text, s.address_note, s.location_hint)
  returning * into s;

  perform public.materialize_event_series(s.id, 8);
  return s;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.create_event_series(jsonb) is
  'Creates a weekly series as the caller and materializes 8 weeks of occurrences (the first occurrence is events where series_id = id order by starts_at limit 1). Errors: not_authenticated, title_required, title_length, description_too_long, weekday_invalid, start_time_required, duration_invalid, timezone_invalid, invalid_date_range, min_headcount_above_capacity, too_many_series, plus the create_event validation codes.';

-- Patch semantics as update_event. Template fields (title, description,
-- cover, capacity, flags, address) are pushed to every future, published,
-- non-detached occurrence, attendees included, so ids and share links
-- survive. A schedule change (weekday, start_time, duration_minutes,
-- timezone, starts_on, ends_on, max_occurrences) regenerates the occurrences
-- nobody but the host has RSVP'd to and moves the ones with attendees to the
-- new wall-clock time in the same week (or cancels them when they fall
-- outside the new dates).
create or replace function public.update_event_series(p_series_id uuid, p_args jsonb)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  s          public.event_series%rowtype;
  v_old      public.event_series%rowtype;
  v_key      text;
  v_allowed  text[] := array['title', 'description', 'cover_url', 'weekday', 'start_time', 'duration_minutes',
                             'timezone', 'starts_on', 'ends_on', 'max_occurrences', 'min_age', 'capacity',
                             'waitlist_enabled', 'min_headcount', 'members_only', 'is_free', 'price_text',
                             'visibility', 'campus_id', 'address_visibility', 'venue_id', 'location_text',
                             'address_note', 'location_hint'];
  v_schedule text[] := array['weekday', 'start_time', 'duration_minutes', 'timezone', 'starts_on', 'ends_on', 'max_occurrences'];
  v_address  text[] := array['address_visibility', 'venue_id', 'location_text', 'address_note'];
  v_campus   uuid;
  v_narrow   boolean;
  v_max      integer;
  v_occ      record;
  v_date     date;
  v_starts   timestamptz;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  for v_key in select jsonb_object_keys(a) loop
    if not (v_key = any (v_allowed)) then
      raise exception 'immutable_field' using errcode = 'check_violation',
        hint = v_key || ' cannot be changed after creation.';
    end if;
  end loop;

  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'P0002';
  end if;
  v_old := s;
  if not (coalesce(s.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(s.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if a ?| v_address and not (coalesce(s.host_id = uid, false) or public.is_moderator()) then
    raise exception 'forbidden' using errcode = '42501', hint = 'Only the host can change the address.';
  end if;
  if s.status = 'cancelled' then
    raise exception 'series_cancelled' using errcode = 'check_violation';
  end if;

  if a ? 'title'              then s.title              := btrim(coalesce(a ->> 'title', '')); end if;
  if a ? 'description'        then s.description        := btrim(coalesce(a ->> 'description', '')); end if;
  if a ? 'cover_url'          then s.cover_url          := nullif(btrim(coalesce(a ->> 'cover_url', '')), ''); end if;
  if a ? 'weekday'            then s.weekday            := (a ->> 'weekday')::smallint; end if;
  if a ? 'start_time'         then s.start_time         := (a ->> 'start_time')::time; end if;
  if a ? 'duration_minutes'   then s.duration_minutes   := (a ->> 'duration_minutes')::integer; end if;
  if a ? 'timezone'           then s.timezone           := coalesce(nullif(btrim(coalesce(a ->> 'timezone', '')), ''), s.timezone); end if;
  if a ? 'starts_on'          then s.starts_on          := coalesce((a ->> 'starts_on')::date, s.starts_on); end if;
  if a ? 'ends_on'            then s.ends_on            := (a ->> 'ends_on')::date; end if;
  if a ? 'max_occurrences'    then s.max_occurrences    := (a ->> 'max_occurrences')::integer; end if;
  if a ? 'min_age'            then s.min_age            := (a ->> 'min_age')::smallint; end if;
  if a ? 'capacity'           then s.capacity           := (a ->> 'capacity')::integer; end if;
  if a ? 'waitlist_enabled'   then s.waitlist_enabled   := coalesce((a ->> 'waitlist_enabled')::boolean, s.waitlist_enabled); end if;
  if a ? 'min_headcount'      then s.min_headcount      := (a ->> 'min_headcount')::integer; end if;
  if a ? 'members_only'       then s.members_only       := coalesce((a ->> 'members_only')::boolean, s.members_only); end if;
  if a ? 'is_free'            then s.is_free            := coalesce((a ->> 'is_free')::boolean, s.is_free); end if;
  if a ? 'price_text'         then s.price_text         := nullif(btrim(coalesce(a ->> 'price_text', '')), ''); end if;
  if a ? 'visibility'         then s.visibility         := coalesce((a ->> 'visibility')::public.event_visibility, s.visibility); end if;
  if a ? 'campus_id'          then s.campus_id          := (a ->> 'campus_id')::uuid; end if;
  if a ? 'venue_id'           then s.venue_id           := (a ->> 'venue_id')::uuid; end if;
  if a ? 'address_visibility' then s.address_visibility := coalesce((a ->> 'address_visibility')::public.address_visibility, s.address_visibility);
  elsif a ? 'venue_id'        then s.address_visibility := public.default_address_visibility(s.venue_id); end if;
  if a ? 'location_text'      then s.location_text      := btrim(coalesce(a ->> 'location_text', '')); end if;
  if a ? 'address_note'       then s.address_note       := btrim(coalesce(a ->> 'address_note', '')); end if;
  if a ? 'location_hint'      then s.location_hint      := btrim(coalesce(a ->> 'location_hint', '')); end if;

  if s.title = '' then
    raise exception 'title_required' using errcode = 'check_violation';
  end if;
  if char_length(s.title) not between 3 and 120 then
    raise exception 'title_length' using errcode = 'check_violation', hint = '3 to 120 characters.';
  end if;
  if char_length(s.description) > 2000 then
    raise exception 'description_too_long' using errcode = 'check_violation', hint = 'Up to 2000 characters.';
  end if;
  if s.weekday is null or s.weekday not between 0 and 6 then
    raise exception 'weekday_invalid' using errcode = 'check_violation';
  end if;
  if s.start_time is null then
    raise exception 'start_time_required' using errcode = 'check_violation';
  end if;
  if s.duration_minutes is null or s.duration_minutes not between 15 and 1440 then
    raise exception 'duration_invalid' using errcode = 'check_violation';
  end if;
  if not public.is_valid_timezone(s.timezone) then
    raise exception 'timezone_invalid' using errcode = 'check_violation';
  end if;
  if s.ends_on is not null and s.ends_on < s.starts_on then
    raise exception 'invalid_date_range' using errcode = 'check_violation';
  end if;
  if s.capacity is not null and s.min_headcount is not null and s.min_headcount > s.capacity then
    raise exception 'min_headcount_above_capacity' using errcode = 'check_violation';
  end if;
  if a ? 'capacity' and s.capacity is not null then
    select max(going_count) into v_max from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;
    if coalesce(v_max, 0) > s.capacity then
      raise exception 'capacity_below_going' using errcode = 'check_violation',
        hint = v_max || ' people are already going to one occurrence.';
    end if;
  end if;

  v_campus := public.event_rules_check(
    s.kind, s.hub_id, s.chapter_id, s.visibility, s.campus_id, s.min_age, s.venue_id, s.location_text, s.address_visibility);

  update public.event_series
     set title = s.title, description = s.description, cover_url = s.cover_url, weekday = s.weekday,
         start_time = s.start_time, duration_minutes = s.duration_minutes, timezone = s.timezone,
         starts_on = s.starts_on, ends_on = s.ends_on, max_occurrences = s.max_occurrences,
         min_age = s.min_age, capacity = s.capacity, waitlist_enabled = s.waitlist_enabled,
         min_headcount = s.min_headcount, members_only = s.members_only, is_free = s.is_free,
         price_text = s.price_text, visibility = s.visibility, campus_id = v_campus,
         address_visibility = s.address_visibility, venue_id = s.venue_id,
         location_text = s.location_text, address_note = s.address_note, location_hint = s.location_hint
   where id = s.id
   returning * into s;

  -- Lock the future occurrences first so a set_rsvp that commits while we
  -- wait is seen by the statements below (they take fresh snapshots).
  perform 1 from public.events
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
   for update;

  if a ?| v_schedule then
    -- Nobody but the host has committed: regenerate from the template.
    delete from public.events e
     where e.series_id = s.id
       and e.status = 'published'
       and e.starts_at > now()
       and e.detached_at is null
       and not exists (
         select 1 from public.rsvps r
          where r.event_id = e.id
            and r.status <> 'cancelled'
            and r.user_id is distinct from e.host_id
       );
    -- Occurrences with attendees move to the new wall-clock slot in their
    -- week, or are cancelled when the new dates no longer cover them.
    for v_occ in
      select id, occurrence_date from public.events
       where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
       order by occurrence_date
    loop
      v_date   := v_occ.occurrence_date + (s.weekday - v_old.weekday);
      v_starts := (v_date + s.start_time) at time zone s.timezone;
      if v_starts <= now() or v_date < s.starts_on or (s.ends_on is not null and v_date > s.ends_on) then
        update public.events
           set status = 'cancelled', cancelled_at = now(), cancel_reason = 'The weekly schedule changed.'
         where id = v_occ.id;
      else
        update public.events
           set occurrence_date = v_date,
               starts_at       = v_starts,
               ends_at         = v_starts + make_interval(mins => s.duration_minutes),
               timezone        = s.timezone
         where id = v_occ.id;
      end if;
    end loop;
  end if;

  -- Template fields reach every remaining future occurrence.
  update public.events
     set title = s.title, description = s.description, cover_url = s.cover_url, min_age = s.min_age,
         capacity = s.capacity, waitlist_enabled = s.waitlist_enabled, min_headcount = s.min_headcount,
         members_only = s.members_only, is_free = s.is_free, price_text = s.price_text,
         visibility = s.visibility, campus_id = s.campus_id, address_visibility = s.address_visibility
   where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null;

  v_narrow := (a ? 'min_age' and s.min_age = 21)
           or (a ? 'visibility' and s.visibility = 'campus')
           or (a ? 'campus_id')
           or (a ? 'members_only' and s.members_only);
  for v_occ in
    select id from public.events
     where series_id = s.id and status = 'published' and starts_at > now() and detached_at is null
  loop
    perform public.event_set_location(v_occ.id, s.venue_id, s.location_text, s.address_note,
                                      s.address_visibility, s.location_hint, s.campus_id);
    if v_narrow then
      perform public.event_drop_ineligible_rsvps(v_occ.id);
    end if;
    perform public.rsvp_promote_waitlist(v_occ.id);
  end loop;

  perform public.materialize_event_series(s.id, 8);
  return s;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.update_event_series(uuid, jsonb) is
  'Patches a weekly series: template fields are pushed to every future non-detached occurrence; a schedule change regenerates occurrences without attendees and shifts the others in place. Errors: not_authenticated, immutable_field, series_not_found, forbidden, series_cancelled, capacity_below_going, plus the create_event_series validation codes.';

create or replace function public.cancel_event_series(p_series_id uuid, p_reason text default null)
returns public.event_series language plpgsql security definer set search_path = '' as $$
declare
  uid      uuid := (select auth.uid());
  s        public.event_series%rowtype;
  v_reason text := left(nullif(btrim(coalesce(p_reason, '')), ''), 500);
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into s from public.event_series where id = p_series_id for update;
  if not found then
    raise exception 'series_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(s.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(s.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.status = 'cancelled' then
    return s;
  end if;
  update public.event_series
     set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason
   where id = s.id
   returning * into s;
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancel_reason = v_reason
   where series_id = s.id and status = 'published' and starts_at > now();
  return s;
end $$;

comment on function public.cancel_event_series(uuid, text) is
  'Cancels a weekly series and every future published occurrence. Idempotent. Errors: not_authenticated, series_not_found, forbidden.';

-- ---------------------------------------------------------------------------
-- 13. RSVP RPCs: set_rsvp, check_in, approve_rsvp, remove_rsvp,
--     event_attendees, accept_guidelines
-- ---------------------------------------------------------------------------
-- Decides going vs waitlisted atomically under the events row lock. Asking
-- for 'waitlisted' is treated as asking for 'going' (the function decides).
-- Leaving ('cancelled') is handled before any eligibility check, so an
-- attendee can always withdraw, including from a cancelled, finished or
-- no-longer-visible event. Cancelling an RSVP that does not exist returns
-- null (the client treats the result as nullable).
create or replace function public.set_rsvp(p_event_id uuid, p_status public.rsvp_status)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid     uuid := (select auth.uid());
  e       public.events%rowtype;
  p       public.profiles%rowtype;
  r       public.rsvps%rowtype;
  v_want  public.rsvp_status;
  v_was   public.rsvp_status;
  v_going integer;
  v_age   integer;
  v_mod   boolean;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_status is null then
    raise exception 'invalid_status' using errcode = 'check_violation';
  end if;
  v_want := case when p_status = 'waitlisted' then 'going'::public.rsvp_status else p_status end;

  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  v_was := r.status;   -- null when there is no row yet

  -- Leaving needs nothing but the row.
  if v_want = 'cancelled' then
    if v_was is null then
      return null;
    end if;
    if v_was = 'cancelled' then
      return r;
    end if;
    update public.rsvps
       set status = 'cancelled', waitlist_position = null
     where event_id = p_event_id and user_id = uid
     returning * into r;
    if v_was = 'going' then
      perform public.rsvp_promote_waitlist(p_event_id);
    end if;
    return r;
  end if;

  -- This function bypasses RLS, so the read rules are repeated here.
  v_mod := public.is_moderator();
  select * into p from public.profiles where id = uid;
  if p.status is distinct from 'active' or p.onboarding_completed_at is null then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  if p.avatar_url is null then
    raise exception 'photo_required' using errcode = 'check_violation',
      hint = 'Add a profile photo to RSVP (PLAN 4.1).';
  end if;
  if p.guidelines_accepted_at is null then
    raise exception 'guidelines_required' using errcode = 'check_violation',
      hint = 'Accept the Community Guidelines first (accept_guidelines).';
  end if;
  if r.removed_at is not null and not v_mod then
    raise exception 'removed_by_host' using errcode = '42501',
      hint = 'The host removed you from this event.';
  end if;
  v_age := public.viewer_age();
  if v_age is null or v_age < e.min_age then
    raise exception 'age_restricted' using errcode = 'check_violation';
  end if;
  if e.visibility = 'campus' and not v_mod and not public.is_campus_org_member(e.campus_id) then
    raise exception 'not_campus_member' using errcode = '42501',
      hint = 'Campus events are for verified members of that campus.';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if e.ends_at < now() then
    raise exception 'event_over' using errcode = 'check_violation';
  end if;
  if e.members_only and uid is distinct from e.host_id and not v_mod then
    if e.kind = 'chapter' then
      if not exists (select 1 from public.chapter_members where chapter_id = e.chapter_id and user_id = uid) then
        raise exception 'not_chapter_member' using errcode = '42501', hint = 'This event is for chapter members.';
      end if;
    elsif not exists (select 1 from public.hub_members where hub_id = e.hub_id and user_id = uid) then
      raise exception 'not_hub_member' using errcode = '42501', hint = 'This event is for hub members.';
    end if;
  end if;

  if v_want = 'interested' then
    if v_was = 'interested' then
      return r;
    end if;
    insert into public.rsvps (event_id, user_id, status)
    values (p_event_id, uid, 'interested')
    on conflict (event_id, user_id) do update set status = 'interested', waitlist_position = null
    returning * into r;
  else
    if v_was in ('going', 'waitlisted') then
      return r;
    end if;
    select count(*) into v_going from public.rsvps where event_id = p_event_id and status = 'going';
    if e.capacity is null or v_going < e.capacity then
      insert into public.rsvps (event_id, user_id, status)
      values (p_event_id, uid, 'going')
      on conflict (event_id, user_id) do update set status = 'going', waitlist_position = null
      returning * into r;
    elsif e.waitlist_enabled then
      insert into public.rsvps (event_id, user_id, status, waitlist_position)
      values (p_event_id, uid, 'waitlisted',
              (select coalesce(max(waitlist_position), 0) + 1 from public.rsvps
                where event_id = p_event_id and status = 'waitlisted'))
      on conflict (event_id, user_id) do update set status = 'waitlisted', waitlist_position = excluded.waitlist_position
      returning * into r;
    else
      raise exception 'event_full' using errcode = 'check_violation';
    end if;
  end if;

  if v_was = 'going' and r.status <> 'going' then
    perform public.rsvp_promote_waitlist(p_event_id);
  end if;
  return r;
end $$;

comment on function public.set_rsvp(uuid, public.rsvp_status) is
  'Sets the caller''s RSVP on one occurrence: going (or waitlisted when full and the waitlist is on), interested, cancelled (always allowed; returns null when there was no row). Atomic against capacity; promotes the waitlist when a going seat frees up. Errors: not_authenticated, invalid_status, event_not_found, onboarding_required, photo_required, guidelines_required, removed_by_host, age_restricted, not_campus_member, event_cancelled, event_over, not_chapter_member, not_hub_member, event_full.';

-- Window: one hour before start to six hours after end. Going RSVPs only.
create or replace function public.check_in(p_event_id uuid)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if e.status = 'cancelled' then
    raise exception 'event_cancelled' using errcode = 'check_violation';
  end if;
  if now() < e.starts_at - interval '1 hour' or now() > e.ends_at + interval '6 hours' then
    raise exception 'check_in_window' using errcode = 'check_violation',
      hint = 'Check in from an hour before the start until six hours after the end.';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = uid for update;
  if not found or r.status <> 'going' then
    raise exception 'not_going' using errcode = 'check_violation', hint = 'Tap Going first.';
  end if;
  if r.checked_in_at is null then
    update public.rsvps set checked_in_at = now()
     where event_id = p_event_id and user_id = uid
     returning * into r;
  end if;
  return r;
end $$;

comment on function public.check_in(uuid) is
  'Stamps checked_in_at on the caller''s going RSVP, from 1 hour before start to 6 hours after end. Idempotent. Errors: not_authenticated, event_not_found, event_cancelled, check_in_window, not_going.';

-- Host approval unlocks the exact address of an approved-only event for that
-- going attendee (event_addresses policy). p_approved = false withdraws it.
create or replace function public.approve_rsvp(p_event_id uuid, p_user_id uuid, p_approved boolean default true)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'P0002';
  end if;
  if r.status <> 'going' then
    raise exception 'not_going' using errcode = 'check_violation', hint = 'Only going attendees can be approved.';
  end if;
  update public.rsvps
     set approved_by_host = coalesce(p_approved, true)
   where event_id = p_event_id and user_id = p_user_id
   returning * into r;
  return r;
end $$;

comment on function public.approve_rsvp(uuid, uuid, boolean) is
  'Host, chapter captain or moderator approves (or un-approves) a going attendee, which reveals an approved-only address to them. Errors: not_authenticated, event_not_found, forbidden, rsvp_not_found, not_going.';

-- Attendee management (PLAN 4.5): removes someone from the event. The row
-- becomes cancelled with removed_by / removed_at, so set_rsvp refuses a
-- re-RSVP (removed_by_host) until a moderator intervenes; the waitlist moves up.
create or replace function public.remove_rsvp(p_event_id uuid, p_user_id uuid, p_reason text default null)
returns public.rsvps language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  e   public.events%rowtype;
  r   public.rsvps%rowtype;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into e from public.events where id = p_event_id for update;
  if not found then
    raise exception 'event_not_found' using errcode = 'P0002';
  end if;
  if not (coalesce(e.host_id = uid, false) or public.is_moderator() or public.is_chapter_captain(e.chapter_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id = e.host_id then
    raise exception 'cannot_remove_host' using errcode = 'check_violation';
  end if;
  select * into r from public.rsvps where event_id = p_event_id and user_id = p_user_id for update;
  if not found then
    raise exception 'rsvp_not_found' using errcode = 'P0002';
  end if;
  update public.rsvps
     set status            = 'cancelled',
         waitlist_position = null,
         approved_by_host  = false,
         removed_by        = uid,
         removed_at        = now(),
         removed_reason    = left(nullif(btrim(coalesce(p_reason, '')), ''), 200)
   where event_id = p_event_id and user_id = p_user_id
   returning * into r;
  perform public.rsvp_promote_waitlist(p_event_id);
  return r;
end $$;

comment on function public.remove_rsvp(uuid, uuid, text) is
  'Host, chapter captain or moderator removes an attendee: the RSVP is cancelled and marked removed, so they cannot re-RSVP; the waitlist is promoted. Errors: not_authenticated, event_not_found, forbidden, cannot_remove_host, rsvp_not_found.';

-- The attendee list with the columns clients cannot select directly. Everyone
-- who can read the event gets their own row; the host, chapter captains and
-- moderators get every non-cancelled row (approved_by_host, checked_in_at,
-- waitlist_position and the removal columns included). Rows come back empty
-- when the caller cannot read the event.
create or replace function public.event_attendees(p_event_id uuid)
returns setof public.rsvps language sql stable security definer set search_path = '' as $$
  select r.*
    from public.rsvps r
    join public.events e on e.id = r.event_id
   where r.event_id = p_event_id
     and (select auth.uid()) is not null
     and public.can_read_event(p_event_id)
     and (
       r.user_id = (select auth.uid())
       or (
         r.status <> 'cancelled'
         and (e.host_id = (select auth.uid()) or public.is_moderator() or public.is_chapter_captain(e.chapter_id))
       )
     )
   order by r.status, r.waitlist_position nulls first, r.created_at;
$$;

comment on function public.event_attendees(uuid) is
  'Own RSVP row for any viewer of the event; the full non-cancelled attendee list (approval, check-in, waitlist position, removals) for the host, chapter captains and moderators.';

-- Community Guidelines (PLAN 4.11): accepted once, before the first RSVP.
create or replace function public.accept_guidelines()
returns timestamptz language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := (select auth.uid());
  t   timestamptz;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  update public.profiles
     set guidelines_accepted_at = coalesce(guidelines_accepted_at, now())
   where id = uid
   returning guidelines_accepted_at into t;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;
  return t;
end $$;

comment on function public.accept_guidelines() is
  'Records the caller''s acceptance of the Community Guidelines (once; returns the timestamp). Required by set_rsvp.';

-- ---------------------------------------------------------------------------
-- 14. Readers: event_share_card (logged-out share page / OG image),
--     feed_events (home list in one round trip)
-- ---------------------------------------------------------------------------
-- The share page renders logged out, and profiles is authenticated-only, so
-- the host card comes from here. Only what the anon policy already allows:
-- published, public, 18+ events; never the attendee list, never the address.
create or replace function public.event_share_card(p_event_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
           'id', e.id,
           'kind', e.kind,
           'title', e.title,
           'description', e.description,
           'cover_url', e.cover_url,
           'starts_at', e.starts_at,
           'ends_at', e.ends_at,
           'timezone', e.timezone,
           'min_age', e.min_age,
           'capacity', e.capacity,
           'min_headcount', e.min_headcount,
           'is_free', e.is_free,
           'price_text', e.price_text,
           'location_hint', e.location_hint,
           'approx_lat', e.approx_lat,
           'approx_lng', e.approx_lng,
           'going_count', e.going_count,
           'interested_count', e.interested_count,
           'external_url', e.external_url,
           'source_name', e.source_name,
           'series_id', e.series_id,
           'hub', jsonb_build_object('id', h.id, 'slug', h.slug, 'name', h.name, 'emoji', h.emoji),
           'chapter', case when ch.id is not null then jsonb_build_object('id', ch.id, 'slug', ch.slug, 'name', ch.name) end,
           'host', case when p.id is not null and p.deleted_at is null
                        then jsonb_build_object('handle', p.handle, 'first_name', p.first_name, 'avatar_url', p.avatar_url) end
         )
    from public.events e
    join public.hubs h on h.id = e.hub_id
    left join public.hub_chapters ch on ch.id = e.chapter_id
    left join public.profiles p on p.id = e.host_id
   where e.id = p_event_id
     and e.status = 'published' and e.visibility = 'public' and e.min_age = 18;
$$;

comment on function public.event_share_card(uuid) is
  'Public card for the logged-out share page and OG image: the event fields anon may read plus host (handle, first name, avatar), hub and chapter. Null for anything not published, public and 18+.';

-- "This week in my hubs and my campus" without a client-side id list.
-- SECURITY INVOKER: the events policy still decides every row.
create or replace function public.feed_events(p_from timestamptz, p_to timestamptz, p_limit integer default 100)
returns setof public.events language sql stable set search_path = '' as $$
  select e.*
    from public.events e
   where e.status = 'published'
     and e.starts_at >= p_from and e.starts_at < p_to
     and (
       e.hub_id in (select hub_id from public.hub_members where user_id = (select auth.uid()))
       or e.campus_id in (select campus_id from public.org_memberships
                           where user_id = (select auth.uid()) and campus_id is not null
                             and (expires_at is null or expires_at > now()))
     )
   order by e.starts_at
   limit greatest(1, least(coalesce(p_limit, 100), 200));
$$;

comment on function public.feed_events(timestamptz, timestamptz, integer) is
  'Published events in the caller''s hubs or tagged to the caller''s verified campus, starting in [p_from, p_to), ordered by start. Runs as the caller, so RLS applies.';

-- ---------------------------------------------------------------------------
-- 15. upsert_venue: finds or creates a venue for the caller. Keys: name*,
--     address_line1, address_line2, city, state, postal_code, country, lat,
--     lng, place_id, campus_id, is_public (default: true when a geocoder
--     place_id is given, false for a hand-typed address).
--     Public requests de-duplicate on place_id among public venues and on
--     (name, postal code) among the caller's own rows only, so nobody is
--     merged onto a row somebody else created by name. Private requests
--     de-duplicate among the caller's own private rows. Blanks on an existing
--     row are filled only by its creator or a moderator. Coordinates and
--     place_id are still client-supplied until geocoding moves server-side.
-- ---------------------------------------------------------------------------
create or replace function public.upsert_venue(p_args jsonb)
returns public.venues language plpgsql security definer set search_path = '' as $$
declare
  uid        uuid := (select auth.uid());
  a          jsonb := coalesce(p_args, '{}'::jsonb);
  v          public.venues%rowtype;
  v_mod      boolean;
  v_name     text := btrim(coalesce(a ->> 'name', ''));
  v_addr1    text := btrim(coalesce(a ->> 'address_line1', ''));
  v_addr2    text := btrim(coalesce(a ->> 'address_line2', ''));
  v_city     text := btrim(coalesce(a ->> 'city', ''));
  v_state    text := btrim(coalesce(a ->> 'state', ''));
  v_postal   text := btrim(coalesce(a ->> 'postal_code', ''));
  v_country  text := upper(coalesce(nullif(btrim(coalesce(a ->> 'country', '')), ''), 'US'));
  v_place_id text := nullif(btrim(coalesce(a ->> 'place_id', '')), '');
  v_campus   uuid := (a ->> 'campus_id')::uuid;
  v_public   boolean;
  v_lat      double precision := (a ->> 'lat')::double precision;
  v_lng      double precision := (a ->> 'lng')::double precision;
  v_point    extensions.geography;
  v_c        text;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if not exists (select 1 from public.profiles
                  where id = uid and status = 'active' and onboarding_completed_at is not null) then
    raise exception 'onboarding_required' using errcode = 'check_violation';
  end if;
  v_mod    := public.is_moderator();
  v_public := coalesce((a ->> 'is_public')::boolean, v_place_id is not null);
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) > 120 then
    raise exception 'name_length' using errcode = 'check_violation', hint = 'Up to 120 characters.';
  end if;
  if v_country !~ '^[A-Z]{2}$' then
    raise exception 'country_invalid' using errcode = 'check_violation', hint = 'Two-letter country code.';
  end if;
  if (v_lat is null) <> (v_lng is null)
     or (v_lat is not null and (v_lat not between -90 and 90 or v_lng not between -180 and 180)) then
    raise exception 'invalid_coordinates' using errcode = 'check_violation';
  end if;
  if v_lat is not null then
    v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
  end if;
  if v_campus is not null and not exists (select 1 from public.org_campuses where id = v_campus) then
    raise exception 'campus_not_found' using errcode = 'P0002';
  end if;

  -- Serialize concurrent creates of the same place; hashtext is stable per key.
  perform pg_advisory_xact_lock(hashtext('venue:' || coalesce(v_place_id, lower(v_name) || '|' || v_postal)));

  if v_public then
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and is_public;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  else
    if v_place_id is not null then
      select * into v from public.venues where place_id = v_place_id and not is_public and created_by = uid
       order by created_at limit 1;
    end if;
    if v.id is null and v_postal <> '' then
      select * into v from public.venues
       where lower(name) = lower(v_name) and postal_code = v_postal and not is_public and created_by = uid
       order by created_at
       limit 1;
    end if;
  end if;

  if v.id is not null then
    if v.created_by = uid or v_mod then
      update public.venues
         set address_line1 = case when address_line1 = '' then v_addr1 else address_line1 end,
             address_line2 = case when address_line2 = '' then v_addr2 else address_line2 end,
             city          = case when city = ''          then v_city  else city end,
             state         = case when state = ''         then v_state else state end,
             postal_code   = case when postal_code = ''   then v_postal else postal_code end,
             location      = coalesce(location, v_point),
             campus_id     = coalesce(campus_id, v_campus),
             place_id      = case when place_id is null and v_place_id is not null
                                   and not exists (select 1 from public.venues x where x.place_id = v_place_id and x.is_public)
                                  then v_place_id else place_id end
       where id = v.id
       returning * into v;
    end if;
    return v;
  end if;

  if not v_mod then
    perform pg_advisory_xact_lock(hashtext('venues:' || uid::text));
    if (select count(*) from public.venues where created_by = uid and created_at > now() - interval '24 hours') >= 20 then
      raise exception 'too_many_venues' using errcode = 'check_violation', hint = 'Up to twenty new venues a day.';
    end if;
  end if;

  insert into public.venues (name, address_line1, address_line2, city, state, postal_code, country,
                             location, place_id, campus_id, created_by, is_public)
  values (v_name, v_addr1, v_addr2, v_city, v_state, v_postal, v_country,
          v_point, v_place_id, v_campus, uid, v_public)
  returning * into v;
  return v;
exception when check_violation then
  get stacked diagnostics v_c = constraint_name;
  if coalesce(v_c, '') <> '' then
    raise exception using message = v_c, errcode = 'check_violation';
  end if;
  raise;
end $$;

comment on function public.upsert_venue(jsonb) is
  'Finds or creates a venue for the caller: public requests match place_id among public venues or (name, postal code) among the caller''s own; private requests (default without a place_id) match the caller''s own private rows. Twenty new venues a day. Errors: not_authenticated, onboarding_required, name_required, name_length, country_invalid, invalid_coordinates, campus_not_found, too_many_venues, or a table constraint name.';

-- ---------------------------------------------------------------------------
-- 16. request_hub: replaces the direct insert on hub_requests (max 3 open,
--     no duplicates of an existing hub or of the caller's pending request)
-- ---------------------------------------------------------------------------
create or replace function public.request_hub(p_name text, p_note text default '')
returns public.hub_requests language plpgsql security definer set search_path = '' as $$
declare
  uid    uuid := (select auth.uid());
  v_name text := btrim(coalesce(p_name, ''));
  v_note text := btrim(coalesce(p_note, ''));
  v_slug text;
  result public.hub_requests;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'name_required' using errcode = 'check_violation';
  end if;
  if char_length(v_name) not between 2 and 60 then
    raise exception 'name_length' using errcode = 'check_violation', hint = '2 to 60 characters.';
  end if;
  if char_length(v_note) > 280 then
    raise exception 'note_too_long' using errcode = 'check_violation', hint = 'Up to 280 characters.';
  end if;
  select slug into v_slug from public.hubs h
   where h.is_active and (lower(h.name) = lower(v_name) or lower(v_name) = any (h.aliases))
   order by h.is_featured desc, h.created_at
   limit 1;
  if v_slug is not null then
    raise exception 'hub_exists' using errcode = 'unique_violation', hint = v_slug;
  end if;
  perform pg_advisory_xact_lock(hashtext('hub_request:' || uid::text));
  if exists (select 1 from public.hub_requests where user_id = uid and status = 'pending' and lower(name) = lower(v_name)) then
    raise exception 'duplicate_request' using errcode = 'unique_violation';
  end if;
  if (select count(*) from public.hub_requests where user_id = uid and status = 'pending') >= 3 then
    raise exception 'too_many_requests' using errcode = 'check_violation',
      hint = 'Up to three hub requests can be open at once.';
  end if;
  insert into public.hub_requests (user_id, name, note)
  values (uid, v_name, v_note)
  returning * into result;
  return result;
end $$;

comment on function public.request_hub(text, text) is
  'Asks for a new hub (name 2..60, note up to 280). At most three pending requests per user; refuses names that match an existing hub (hint = its slug) or a pending request of the caller. Errors: not_authenticated, name_required, name_length, note_too_long, hub_exists, duplicate_request, too_many_requests.';

-- ---------------------------------------------------------------------------
-- 17. Campus email verification
--     create_verification_code: service role only (send-verification-code
--     Edge Function). confirm_email_verification: the signed-in user. Both
--     return jsonb (one object, not a one-row table).
--     Hash = sha256(code || row id): the row id is a salt against reuse of a
--     dumped stale row, not a defence against a reader of live rows (a
--     6-digit space is brute-forced in milliseconds). The table has no client
--     policies; that is the protection.
--     Throttle: one send a minute and three an hour per user, three an hour
--     per address across users; counted from rows written on every request,
--     including "already verified" answers, so nothing can be probed faster
--     than a real send.
-- ---------------------------------------------------------------------------
create or replace function public.create_verification_code(p_user_id uuid, p_email text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_email  text := lower(btrim(coalesce(p_email, '')));
  v_domain text;
  v_org    public.organizations%rowtype;
  v_last   timestamptz;
  v_hour   integer;
  v_addr   integer;
  v_owner  uuid;
  v_code   text;
  v_id     uuid;
  v_row    public.email_verification_codes%rowtype;
begin
  if not public.is_service_role() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user_id is null or v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' or char_length(v_email) > 254 then
    raise exception 'invalid_email' using errcode = 'check_violation';
  end if;
  if not exists (select 1 from public.profiles where id = p_user_id and status = 'active') then
    raise exception 'user_not_found' using errcode = 'P0002';
  end if;

  -- Throttle before anything that could reveal state.
  perform pg_advisory_xact_lock(hashtext('verification:' || p_user_id::text));
  select max(last_sent_at),
         coalesce(sum(send_count) filter (where last_sent_at > now() - interval '1 hour'), 0)::integer
    into v_last, v_hour
    from public.email_verification_codes
   where user_id = p_user_id;
  select coalesce(sum(send_count), 0)::integer into v_addr
    from public.email_verification_codes
   where lower(email) = v_email and last_sent_at > now() - interval '1 hour';
  if v_last is not null and v_last > now() - interval '1 minute' then
    raise exception 'too_many_sends' using errcode = 'check_violation',
      hint = 'Wait a minute before asking for another code.';
  end if;
  if v_hour >= 3 or v_addr >= 3 then
    raise exception 'too_many_sends' using errcode = 'check_violation',
      hint = 'Three codes an hour. Try again later.';
  end if;

  v_domain := split_part(v_email, '@', 2);
  select o.* into v_org from public.organizations o
    join public.org_email_domains d on d.org_id = o.id
   where d.domain = v_domain;
  if v_org.id is null then
    raise exception 'domain_not_recognized' using errcode = 'check_violation',
      hint = 'Use the email address your school gave you.';
  end if;

  -- Already verified: write a dead, consumed row so the throttle still
  -- counts the request, and answer without a code. The Edge Function sends
  -- the same "check your inbox" response either way; the email itself says
  -- the address is already linked to an account.
  select user_id into v_owner from public.verified_emails where lower(email) = v_email;
  if v_owner is not null then
    insert into public.email_verification_codes
      (user_id, email, org_id, code_hmac, attempts, send_count, last_sent_at, expires_at, consumed_at)
    values
      (p_user_id, v_email, v_org.id, 'already-verified', 0, 1, now(), now(), now());
    return jsonb_build_object(
      'status', 'already_verified',
      'own', v_owner = p_user_id,
      'code', null,
      'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
      'expires_at', null);
  end if;

  -- Six digits from pgcrypto; the bias from % 1000000 on 32 random bits is negligible.
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');

  select * into v_row from public.email_verification_codes
   where user_id = p_user_id and lower(email) = v_email and consumed_at is null
   for update;
  if found then
    update public.email_verification_codes
       set code_hmac    = encode(extensions.digest(v_code || v_row.id::text, 'sha256'), 'hex'),
           org_id       = v_org.id,
           attempts     = 0,
           send_count   = case when last_sent_at > now() - interval '1 hour' then send_count + 1 else 1 end,
           last_sent_at = now(),
           expires_at   = now() + interval '15 minutes'
     where id = v_row.id
     returning * into v_row;
  else
    v_id := gen_random_uuid();
    insert into public.email_verification_codes
      (id, user_id, email, org_id, code_hmac, attempts, send_count, last_sent_at, expires_at)
    values
      (v_id, p_user_id, v_email, v_org.id, encode(extensions.digest(v_code || v_id::text, 'sha256'), 'hex'),
       0, 1, now(), now() + interval '15 minutes')
    returning * into v_row;
  end if;

  return jsonb_build_object(
    'status', 'sent',
    'code', v_code,
    'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
    'expires_at', v_row.expires_at);
end $$;

comment on function public.create_verification_code(uuid, text) is
  'Service role only. Issues a 6-digit code for a campus email (domain must be in org_email_domains), throttled to one send a minute and three an hour per user and per address, valid 15 minutes. Returns {status: sent, code, org_id, org_slug, org_name, expires_at} or {status: already_verified, own, org...} with no code. Errors: forbidden, invalid_email, user_not_found, too_many_sends, domain_not_recognized.';

-- Returns {status: ok, org_id, org_slug, org_name, campus_id, campus_name} on
-- success. A wrong, expired or exhausted code is reported in status
-- (code_invalid with attempts_left, code_expired, too_many_attempts,
-- code_not_found) rather than raised, so the attempts counter commits.
create or replace function public.confirm_email_verification(p_code text, p_email text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid         uuid := (select auth.uid());
  v_code      text := regexp_replace(coalesce(p_code, ''), '\s', '', 'g');
  v_email     text := nullif(lower(btrim(coalesce(p_email, ''))), '');
  v_row       public.email_verification_codes%rowtype;
  v_attempts  integer;
  v_org       public.organizations%rowtype;
  v_campus    public.org_campuses%rowtype;
  v_verified  uuid;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if v_code !~ '^[0-9]{6}$' then
    return jsonb_build_object('status', 'code_invalid');
  end if;

  select * into v_row from public.email_verification_codes
   where user_id = uid and consumed_at is null
     and (v_email is null or lower(email) = v_email)
   order by last_sent_at desc
   limit 1
   for update;
  if not found then
    return jsonb_build_object('status', 'code_not_found');
  end if;
  if v_row.attempts >= 5 then
    return jsonb_build_object('status', 'too_many_attempts');
  end if;
  if v_row.expires_at < now() then
    return jsonb_build_object('status', 'code_expired');
  end if;

  -- Count the attempt before comparing, so a failed compare is never free.
  update public.email_verification_codes
     set attempts = attempts + 1
   where id = v_row.id
   returning attempts into v_attempts;
  if encode(extensions.digest(v_code || v_row.id::text, 'sha256'), 'hex') <> v_row.code_hmac then
    if v_attempts >= 5 then
      return jsonb_build_object('status', 'too_many_attempts');
    end if;
    return jsonb_build_object('status', 'code_invalid', 'attempts_left', 5 - v_attempts);
  end if;

  -- The domain must still be recognized (an admin may have removed it).
  select o.* into v_org from public.organizations o
    join public.org_email_domains d on d.org_id = o.id
   where d.domain = lower(split_part(v_row.email, '@', 2));
  if v_org.id is null then
    raise exception 'domain_not_recognized' using errcode = 'check_violation';
  end if;

  -- One verified row per address across all users. The ON CONFLICT clause only
  -- updates the caller's own row, so a race with another user ends in
  -- email_already_verified instead of a takeover.
  if exists (select 1 from public.verified_emails
              where lower(email) = lower(v_row.email) and user_id <> uid) then
    raise exception 'email_already_verified' using errcode = 'unique_violation';
  end if;
  insert into public.verified_emails (user_id, email, org_id)
  values (uid, v_row.email, v_org.id)
  on conflict (lower(email)) do update
     set org_id = excluded.org_id, verified_at = now()
   where public.verified_emails.user_id = excluded.user_id
  returning id into v_verified;
  if v_verified is null then
    raise exception 'email_already_verified' using errcode = 'unique_violation';
  end if;

  -- Campus: the profile's declared campus, when it belongs to this organization.
  select c.* into v_campus
    from public.profiles p
    join public.org_campuses c on c.id = p.home_campus_id
   where p.id = uid and c.org_id = v_org.id;

  insert into public.org_memberships (user_id, org_id, campus_id, role, source, verified_email_id, verified_at, expires_at)
  values (uid, v_org.id, v_campus.id, 'member', 'edu_email', v_verified, now(), null)
  on conflict (user_id, org_id) do update
     set campus_id         = coalesce(excluded.campus_id, public.org_memberships.campus_id),
         role              = greatest(public.org_memberships.role, excluded.role),
         source            = case when public.org_memberships.source = 'manual' then 'manual' else excluded.source end,
         verified_email_id = excluded.verified_email_id,
         verified_at       = now(),
         expires_at        = null;

  update public.profiles set home_org_id = v_org.id where id = uid;
  update public.email_verification_codes set consumed_at = now() where id = v_row.id;

  return jsonb_build_object(
    'status', 'ok',
    'org_id', v_org.id, 'org_slug', v_org.slug, 'org_name', v_org.name,
    'campus_id', v_campus.id, 'campus_name', v_campus.name);
end $$;

comment on function public.confirm_email_verification(text, text) is
  'Checks the caller''s newest open code (for p_email when given), 5 attempts per code. On success records the verified email, grants the org membership (campus from the profile when it belongs to the org), sets home_org_id, consumes the code and returns {status: ok, org_id, org_slug, org_name, campus_id, campus_name}. Otherwise returns {status: code_invalid | code_expired | too_many_attempts | code_not_found, attempts_left?}. Errors: not_authenticated, domain_not_recognized, email_already_verified.';

-- ---------------------------------------------------------------------------
-- 18. refresh_hub_stats: recomputes the ranking rows for every active hub
--     (campus_id null) and for every (hub, campus) with any signal. Service
--     role / cron only; this migration runs it once at the end so the Hubs
--     tab has rows; re-run by hand (or pg_cron later). One transaction:
--     readers see the old rows until it commits.
--     activity_score = events_next_7d * 10 + active_members_30d * 2
--                    + chapter_count * 5 + ln(1 + member_count)
-- ---------------------------------------------------------------------------
create or replace function public.refresh_hub_stats()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_now timestamptz := clock_timestamp();
  n     integer;
begin
  if not public.is_service_role() then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  delete from public.hub_stats;

  insert into public.hub_stats (hub_id, campus_id, member_count, chapter_count, events_next_7d, active_members_30d, activity_score, computed_at)
  select h.id, null, m.cnt, c.cnt, e.cnt, a.cnt,
         (e.cnt * 10 + a.cnt * 2 + c.cnt * 5 + ln(1 + m.cnt))::numeric(10, 3), v_now
    from public.hubs h
    cross join lateral (select count(*)::integer as cnt from public.hub_members where hub_id = h.id) m
    cross join lateral (select count(*)::integer as cnt from public.hub_chapters where hub_id = h.id and is_active) c
    cross join lateral (select count(*)::integer as cnt from public.events
                         where hub_id = h.id and status = 'published'
                           and starts_at >= v_now and starts_at < v_now + interval '7 days') e
    cross join lateral (
      select count(*)::integer as cnt from (
        select r.user_id from public.rsvps r join public.events ev on ev.id = r.event_id
         where ev.hub_id = h.id and r.status in ('going', 'interested') and r.updated_at > v_now - interval '30 days'
        union
        select hm.user_id from public.hub_members hm
         where hm.hub_id = h.id and hm.joined_at > v_now - interval '30 days'
      ) x) a
   where h.is_active;

  insert into public.hub_stats (hub_id, campus_id, member_count, chapter_count, events_next_7d, active_members_30d, activity_score, computed_at)
  select h.id, oc.id, m.cnt, c.cnt, e.cnt, a.cnt,
         (e.cnt * 10 + a.cnt * 2 + c.cnt * 5 + ln(1 + m.cnt))::numeric(10, 3), v_now
    from public.hubs h
    cross join public.org_campuses oc
    cross join lateral (select count(*)::integer as cnt from public.hub_members hm
                          join public.profiles p on p.id = hm.user_id
                         where hm.hub_id = h.id and p.home_campus_id = oc.id) m
    cross join lateral (select count(*)::integer as cnt from public.hub_chapters
                         where hub_id = h.id and campus_id = oc.id and is_active) c
    cross join lateral (select count(*)::integer as cnt from public.events
                         where hub_id = h.id and campus_id = oc.id and status = 'published'
                           and starts_at >= v_now and starts_at < v_now + interval '7 days') e
    cross join lateral (
      select count(*)::integer as cnt from (
        select r.user_id from public.rsvps r join public.events ev on ev.id = r.event_id
         where ev.hub_id = h.id and ev.campus_id = oc.id
           and r.status in ('going', 'interested') and r.updated_at > v_now - interval '30 days'
        union
        select hm.user_id from public.hub_members hm join public.profiles p on p.id = hm.user_id
         where hm.hub_id = h.id and p.home_campus_id = oc.id and hm.joined_at > v_now - interval '30 days'
      ) x) a
   where h.is_active
     and (m.cnt + c.cnt + e.cnt + a.cnt) > 0;

  select count(*) into n from public.hub_stats where computed_at = v_now;
  return n;
end $$;

comment on function public.refresh_hub_stats() is
  'Recomputes hub_stats for every active hub and for each (hub, campus) with activity. Service role / cron only; run once by this migration, schedule later with pg_cron. Returns the number of rows written.';

-- ---------------------------------------------------------------------------
-- 19. request_account_deletion (D-031) now covers events: the deleted
--     person's series and future events are cancelled, their addresses
--     removed, their private venues deleted, their RSVPs removed (seats free
--     up and the waitlist moves), all inside the same transaction as before.
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
  update public.events
     set status = 'cancelled', cancelled_at = now(), cancel_reason = 'host_deleted'
   where host_id = uid and status = 'published' and starts_at > now();
  delete from public.event_addresses
   where event_id in (select id from public.events where host_id = uid)
      or venue_id in (select id from public.venues where created_by = uid and not is_public);
  delete from public.venues where created_by = uid and not is_public;
  update public.venues set created_by = null where created_by = uid;

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
  'Deletes the caller''s account immediately: ledger row, tombstone profile, handle released, private data and memberships removed, hosted series and future events cancelled with their addresses, private venues deleted, RSVPs removed (waitlists promoted), auth user banned. The delete-account Edge Function finishes (soft-deletes the auth user, removes avatars, stamps completed_at). Idempotent.';

-- ---------------------------------------------------------------------------
-- 20. complete_onboarding: the hub age guard applies here too (the function
--     is SECURITY DEFINER and inserts hub_members directly). A 21+ hub in
--     p_hub_ids for someone under 21 is refused with hub_min_age; the client
--     already hides those hubs, so this is a backstop, not a flow.
-- ---------------------------------------------------------------------------
create or replace function public.complete_onboarding(
  p_handle     text,
  p_first_name text,
  p_birth_date date,
  p_hub_ids    uuid[],
  p_campus_id  uuid default null,
  p_org_id     uuid default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
  uid    uuid := (select auth.uid());
  v_org  uuid;
  v_age  integer;
  result public.profiles;
begin
  if uid is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  if p_birth_date is null then
    raise exception 'birth_date_required' using errcode = 'check_violation';
  end if;
  if nullif(btrim(coalesce(p_first_name, '')), '') is null then
    raise exception 'first_name_required' using errcode = 'check_violation';
  end if;
  if p_hub_ids is null or array_length(p_hub_ids, 1) is null then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;
  if array_length(p_hub_ids, 1) > 25 then
    raise exception 'too_many_hubs' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.reserved_handles where handle = lower(p_handle)) then
    raise exception 'handle_reserved' using errcode = 'check_violation';
  end if;
  if exists (select 1 from public.profiles where lower(handle) = lower(p_handle) and id <> uid) then
    raise exception 'handle_taken' using errcode = 'unique_violation';
  end if;

  if p_campus_id is not null then
    select org_id into v_org from public.org_campuses where id = p_campus_id;
    if v_org is null then
      raise exception 'campus_not_found' using errcode = 'foreign_key_violation';
    end if;
  elsif p_org_id is not null then
    if not exists (select 1 from public.organizations where id = p_org_id) then
      raise exception 'org_not_found' using errcode = 'foreign_key_violation';
    end if;
    v_org := p_org_id;
  end if;

  -- Birth date first (write-once), so the age trigger aborts before anything else changes.
  update public.profile_private
     set birth_date = p_birth_date
   where user_id = uid
     and (birth_date is null or birth_date = p_birth_date);
  if not found then
    raise exception 'birth_date_locked' using errcode = 'check_violation',
      hint = 'The birth date is recorded once; contact support to correct it.';
  end if;
  v_age := extract(year from age(current_date::timestamp, p_birth_date::timestamp))::integer;
  if exists (select 1 from public.hubs h where h.id = any (p_hub_ids) and h.is_active and h.min_age > v_age) then
    raise exception 'hub_min_age' using errcode = 'check_violation',
      hint = 'One of the picked hubs is 21+.';
  end if;

  update public.profiles
     set handle = p_handle,
         first_name = btrim(p_first_name),
         home_org_id = coalesce(v_org, home_org_id),
         home_campus_id = coalesce(p_campus_id, home_campus_id),
         onboarding_completed_at = coalesce(onboarding_completed_at, now())
   where id = uid
   returning * into result;
  if not found then
    raise exception 'profile_missing' using errcode = 'P0002';
  end if;

  insert into public.hub_members (user_id, hub_id)
  select uid, h.id
    from public.hubs h
   where h.id = any (p_hub_ids) and h.is_active and h.min_age <= v_age
  on conflict do nothing;

  if not exists (select 1 from public.hub_members where user_id = uid) then
    raise exception 'pick_at_least_one_hub' using errcode = 'check_violation';
  end if;

  return result;
end $$;

-- ---------------------------------------------------------------------------
-- 21. Row Level Security
--     Policies are split by role where the anonymous branch must not touch
--     tables anon cannot read (a policy subquery is planned as the caller, so
--     a missing grant is an error, not a false). No write policies: every
--     write goes through the RPCs above.
-- ---------------------------------------------------------------------------
alter table public.venues          enable row level security;
alter table public.event_series    enable row level security;
alter table public.events          enable row level security;
alter table public.event_addresses enable row level security;
alter table public.rsvps           enable row level security;

-- events: logged out = published, public, 18+ only. Signed in = host and
-- moderators always; otherwise published (or own RSVP, so a cancelled event
-- stays visible to its attendees), not above the viewer's age, and public or
-- a campus the viewer is a verified member of. Mirrored by can_read_event().
drop policy if exists "events_select_anon" on public.events;
create policy "events_select_anon" on public.events for select to anon
  using (status = 'published' and visibility = 'public' and min_age = 18);
drop policy if exists "events_select_authenticated" on public.events;
create policy "events_select_authenticated" on public.events for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      (status = 'published' or public.viewer_has_rsvp(id))
      and min_age <= coalesce((select public.viewer_age()), 18)
      and (visibility = 'public' or public.is_campus_org_member(campus_id))
    )
  );

-- event_addresses: public addresses travel with a readable event; approved-
-- only addresses need host, chapter captain, moderator or an approved going
-- RSVP.
drop policy if exists "event_addresses_select_anon" on public.event_addresses;
create policy "event_addresses_select_anon" on public.event_addresses for select to anon
  using (exists (
    select 1 from public.events e
     where e.id = event_addresses.event_id and e.address_visibility = 'public'
  ));
drop policy if exists "event_addresses_select_authenticated" on public.event_addresses;
create policy "event_addresses_select_authenticated" on public.event_addresses for select to authenticated
  using (exists (
    select 1 from public.events e
     where e.id = event_addresses.event_id
       and (
         e.address_visibility = 'public'
         or e.host_id = (select auth.uid())
         or (select public.is_moderator())
         or public.is_chapter_captain(e.chapter_id)
         or public.viewer_is_approved(e.id)
       )
  ));

-- venues: public places for everyone; a private address only for its creator,
-- moderators, or through an event_addresses row the viewer can read.
drop policy if exists "venues_select" on public.venues;
create policy "venues_select" on public.venues for select to anon, authenticated
  using (
    is_public
    or created_by = (select auth.uid())
    or (select public.is_moderator())
    or exists (select 1 from public.event_addresses l where l.venue_id = venues.id)
  );

-- event_series carries the address, so only the people who may edit it read it.
drop policy if exists "event_series_select" on public.event_series;
create policy "event_series_select" on public.event_series for select to authenticated
  using (
    host_id = (select auth.uid())
    or (select public.is_moderator())
    or public.is_chapter_captain(chapter_id)
  );

-- rsvps: own rows always; the attendee list (minus cancelled rows) for anyone
-- who can read the event, except in a sensitive hub category where only the
-- host, chapter captains, moderators and fellow attendees see it (the rule
-- hub_members_read applies to membership). events is read under its own
-- policy here; the events policy reaches rsvps only through definer helpers,
-- so no cycle. Column grants limit what clients select (see 22).
drop policy if exists "rsvps_select" on public.rsvps;
create policy "rsvps_select" on public.rsvps for select to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_moderator())
    or (
      status <> 'cancelled'
      and exists (
        select 1 from public.events e
          join public.hubs h on h.id = e.hub_id
          join public.hub_categories c on c.slug = h.category_slug
         where e.id = rsvps.event_id
           and (
             not c.is_sensitive
             or e.host_id = (select auth.uid())
             or public.is_chapter_captain(e.chapter_id)
             or public.viewer_is_attending(e.id)
           )
      )
    )
  );

-- hub_members: joining stays a direct insert, now refused for hubs above the
-- viewer's age (nightlife hubs are 21+). Anonymous and pre-onboarding
-- accounts count as 18, as in the events policy. Leaving stays the direct
-- delete under hub_members_delete_own from migration 1.
drop policy if exists "hub_members_insert_own" on public.hub_members;
create policy "hub_members_insert_own" on public.hub_members for insert to authenticated
  with check (
    user_id = (select auth.uid())
    and exists (
      select 1 from public.hubs h
       where h.id = hub_id and h.is_active
         and h.min_age <= coalesce((select public.viewer_age()), 18)
    )
  );

-- hub_requests: inserts go through request_hub() so the caps hold.
drop policy if exists "hub_requests_insert_own" on public.hub_requests;

-- ---------------------------------------------------------------------------
-- 22. Privileges (explicit; RLS still decides rows)
-- ---------------------------------------------------------------------------
grant all on public.venues, public.event_series, public.events, public.event_addresses, public.rsvps
  to service_role;
grant select on public.venues, public.events, public.event_addresses to anon, authenticated;
grant select on public.event_series to authenticated;
-- rsvps: the card columns only; the rest comes from the RPCs and event_attendees().
revoke select on public.rsvps from anon, authenticated;
grant select (event_id, user_id, status, created_at, updated_at) on public.rsvps to authenticated;
revoke insert on public.hub_requests from authenticated;

-- Policy helpers: only policies and RPCs call them.
revoke all on function public.viewer_age() from public, anon;
grant execute on function public.viewer_age() to authenticated;
revoke all on function public.is_campus_org_member(uuid) from public, anon;
grant execute on function public.is_campus_org_member(uuid) to authenticated;
revoke all on function public.is_chapter_captain(uuid) from public, anon;
grant execute on function public.is_chapter_captain(uuid) to authenticated;
revoke all on function public.viewer_has_rsvp(uuid) from public, anon;
grant execute on function public.viewer_has_rsvp(uuid) to authenticated;
revoke all on function public.viewer_is_attending(uuid) from public, anon;
grant execute on function public.viewer_is_attending(uuid) to authenticated;
revoke all on function public.viewer_is_approved(uuid) from public, anon;
grant execute on function public.viewer_is_approved(uuid) to authenticated;
revoke all on function public.can_read_event(uuid) from public, anon;
grant execute on function public.can_read_event(uuid) to authenticated;

-- Internal helpers and trigger functions: no client execute at all.
revoke all on function public.is_service_role() from public, anon, authenticated;
revoke all on function public.is_valid_timezone(text) from public, anon, authenticated;
revoke all on function public.default_address_visibility(uuid) from public, anon, authenticated;
revoke all on function public.events_host_auto_rsvp() from public, anon, authenticated;
revoke all on function public.rsvps_refresh_counts() from public, anon, authenticated;
revoke all on function public.event_rules_check(public.event_kind, uuid, uuid, public.event_visibility, uuid, smallint, uuid, text, public.address_visibility)
  from public, anon, authenticated;
revoke all on function public.event_set_location(uuid, uuid, text, text, public.address_visibility, text, uuid)
  from public, anon, authenticated;
revoke all on function public.rsvp_promote_waitlist(uuid) from public, anon, authenticated;
revoke all on function public.event_drop_ineligible_rsvps(uuid) from public, anon, authenticated;
revoke all on function public.event_post_rate_check(boolean) from public, anon, authenticated;
revoke all on function public.materialize_event_series(uuid, integer) from public, anon, authenticated;
grant execute on function public.materialize_event_series(uuid, integer) to service_role;
revoke all on function public.materialize_all_event_series(integer) from public, anon, authenticated;
grant execute on function public.materialize_all_event_series(integer) to service_role;

-- RPCs the app calls.
revoke all on function public.create_event(jsonb) from public, anon;
grant execute on function public.create_event(jsonb) to authenticated;
revoke all on function public.update_event(uuid, jsonb) from public, anon;
grant execute on function public.update_event(uuid, jsonb) to authenticated;
revoke all on function public.cancel_event(uuid, text) from public, anon;
grant execute on function public.cancel_event(uuid, text) to authenticated;
revoke all on function public.create_event_series(jsonb) from public, anon;
grant execute on function public.create_event_series(jsonb) to authenticated;
revoke all on function public.update_event_series(uuid, jsonb) from public, anon;
grant execute on function public.update_event_series(uuid, jsonb) to authenticated;
revoke all on function public.cancel_event_series(uuid, text) from public, anon;
grant execute on function public.cancel_event_series(uuid, text) to authenticated;
revoke all on function public.set_rsvp(uuid, public.rsvp_status) from public, anon;
grant execute on function public.set_rsvp(uuid, public.rsvp_status) to authenticated;
revoke all on function public.check_in(uuid) from public, anon;
grant execute on function public.check_in(uuid) to authenticated;
revoke all on function public.approve_rsvp(uuid, uuid, boolean) from public, anon;
grant execute on function public.approve_rsvp(uuid, uuid, boolean) to authenticated;
revoke all on function public.remove_rsvp(uuid, uuid, text) from public, anon;
grant execute on function public.remove_rsvp(uuid, uuid, text) to authenticated;
revoke all on function public.event_attendees(uuid) from public, anon;
grant execute on function public.event_attendees(uuid) to authenticated;
revoke all on function public.accept_guidelines() from public, anon;
grant execute on function public.accept_guidelines() to authenticated;
revoke all on function public.feed_events(timestamptz, timestamptz, integer) from public, anon;
grant execute on function public.feed_events(timestamptz, timestamptz, integer) to authenticated;
revoke all on function public.event_share_card(uuid) from public;
grant execute on function public.event_share_card(uuid) to anon, authenticated;
revoke all on function public.upsert_venue(jsonb) from public, anon;
grant execute on function public.upsert_venue(jsonb) to authenticated;
revoke all on function public.request_hub(text, text) from public, anon;
grant execute on function public.request_hub(text, text) to authenticated;
revoke all on function public.confirm_email_verification(text, text) from public, anon;
grant execute on function public.confirm_email_verification(text, text) to authenticated;
revoke all on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid) from public, anon;
grant execute on function public.complete_onboarding(text, text, date, uuid[], uuid, uuid) to authenticated;
revoke all on function public.request_account_deletion(text) from public, anon;
grant execute on function public.request_account_deletion(text) to authenticated;

-- Service-role surface (Edge Functions, cron).
revoke all on function public.create_verification_code(uuid, text) from public, anon, authenticated;
grant execute on function public.create_verification_code(uuid, text) to service_role;
revoke all on function public.refresh_hub_stats() from public, anon, authenticated;
grant execute on function public.refresh_hub_stats() to service_role;

-- ---------------------------------------------------------------------------
-- 23. First hub_stats rows (the migration session counts as the service
--     role), then the version stamp (last, so /api/health only sees it when
--     everything landed)
-- ---------------------------------------------------------------------------
select public.refresh_hub_stats();

insert into public.meta (key, value) values ('schema_version', '2.6')
  on conflict (key) do update set value = excluded.value, updated_at = now();
