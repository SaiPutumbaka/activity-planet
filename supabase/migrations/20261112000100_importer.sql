-- ============================================================================
-- Activity Planet schema v2 — migration 12: minimal importer (D-037, D-004,
--   D-014, PLAN 4.4)
--
--   What this file does
--     * Enables pg_cron and pg_net.
--     * public.feed_sources: the allowlist of feeds (kind localist | engage_rss,
--       later ics and others), attribution, an optional per-item chip, a campus
--       label, a default hub, and run status (last_run_at, last_ok_at,
--       last_error, item_count, last_sample). enabled defaults to false; both
--       seeded sources (GSU Localist, PIN Engage RSS) ship disabled and are
--       switched on per environment by a data file, never by this migration.
--     * public.event_imports: one row per (source, external id) with the event
--       it produced, a content hash, the trimmed raw item, first/last seen,
--       missed_runs, removal stamps, the labels the app shows (host org, open
--       to the public) and where the point came from.
--     * public.import_hub_rules: keyword rules (case-insensitive regex on the
--       title, categories, host or all of them) mapping an item to a hub; they
--       stand in for Claude tagging until week 7. Starter rules map obvious
--       keywords to existing 18+ general hubs.
--     * Hub "Happening nearby" (slug happening-nearby, general, 18+): the
--       neutral catch-all for items no rule matches (events.hub_id is NOT NULL).
--     * RPC import_upsert_batch(p_source_slug, p_items): SECURITY DEFINER,
--       service_role only. Takes the complete current item set of one source,
--       maps hubs, upserts kind = 'imported' public events within the events
--       constraints (title 3 to 120, excerpt, location_hint 120, https only,
--       end defaults to start + 2 h, items over 3 days skipped, campus label
--       always 18+), bumps last_seen, counts missed runs for upcoming items not
--       in the set and cancels them after two in a row, links an exact
--       (lower(title), starts_at) match from another source to the existing
--       event instead of duplicating it, and records the run on feed_sources.
--     * RPC import_record_error(p_source_slug, p_error, p_sample): service_role.
--     * Shared secret: vault secret import_feed_secret is generated in the
--       database (gen_random_bytes) when absent; it never appears in a file.
--       import_verify_secret(p_secret) (service_role) lets the Edge Function
--       check the caller. The function URL lives in vault secret
--       import_feed_url, written by import_set_function_url(p_url), which only
--       the migration owner can call (migrate.yml sets it per project ref).
--     * Scheduling: import_dispatch(p_slug) posts to the function with pg_net;
--       import_schedule() unschedules every import-feed-* job and schedules one
--       hourly job per enabled source; a trigger on feed_sources re-runs it
--       when enabled changes. import_dispatch_all() fires every enabled source
--       once (manual runs).
--     * RPC imported_event_labels(p_event_ids): for events the caller can
--       read, the attribution, chip, open-to-public flag, host org, whether the
--       point is an approximation and the organization the source belongs to
--       (for the D-022 not-affiliated line).
--     * Clients get no grants on the new tables except SELECT for
--       authenticated behind moderator-only policies.
--     * meta.schema_version 2.11.
--
--   Idempotent: safe to re-run.
-- ============================================================================

-- ---------------------------------------------------------------------------
-- 1. Extensions
-- ---------------------------------------------------------------------------
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

-- ---------------------------------------------------------------------------
-- 2. Catch-all hub (neutral, not campus-branded)
-- ---------------------------------------------------------------------------
-- The category comes from the hub seed; on a fresh database the migrations run
-- before the seed, so make sure it exists (the seed then updates it in place).
insert into public.hub_categories (slug, name, color_key, sort_order, is_sensitive, scope, min_age)
values ('social-lifestyle-and-community', 'Social, Lifestyle & Community', 'social', 70, false, 'general', 18)
on conflict (slug) do nothing;

insert into public.hubs (slug, name, category_slug, emoji, description, aliases, scope, min_age)
values ('happening-nearby', 'Happening nearby', 'social-lifestyle-and-community', '📍',
        'Things going on around town, listed from public calendars.',
        array['events', 'things to do', 'around town'], 'general', 18)
on conflict (slug) do update
   set name = excluded.name, category_slug = excluded.category_slug, emoji = excluded.emoji,
       description = excluded.description, scope = 'general', min_age = 18, is_active = true;

-- ---------------------------------------------------------------------------
-- 3. Tables
-- ---------------------------------------------------------------------------
create table if not exists public.feed_sources (
  id             uuid primary key default gen_random_uuid(),
  slug           text not null unique,
  kind           text not null,
  url            text not null,
  name           text not null,                 -- copied to events.source_name
  attribution    text not null default '',      -- the longer credit line on the event page
  homepage_url   text,
  item_label     text,                          -- chip on every item, e.g. "Georgia State student org event"
  enabled        boolean not null default false,
  campus_id      uuid references public.org_campuses (id) on delete set null,  -- a label, never a gate
  default_hub_id uuid references public.hubs (id) on delete set null,
  cron_minute    smallint not null default 17,
  last_run_at    timestamptz,
  last_ok_at     timestamptz,
  last_error     text,
  item_count     integer,
  last_stats     jsonb,
  last_sample    jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  constraint feed_sources_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint feed_sources_kind check (kind in ('localist', 'engage_rss', 'ics', 'rss')),
  constraint feed_sources_url_https check (url ~ '^https://' and char_length(url) <= 500),
  constraint feed_sources_homepage_https check (homepage_url is null or homepage_url ~ '^https://'),
  constraint feed_sources_name_length check (char_length(name) between 2 and 80),
  constraint feed_sources_attribution_length check (char_length(attribution) <= 300),
  constraint feed_sources_item_label_length check (item_label is null or char_length(item_label) between 2 and 60),
  constraint feed_sources_cron_minute check (cron_minute between 0 and 59),
  constraint feed_sources_error_length check (last_error is null or char_length(last_error) <= 2000)
);
comment on table public.feed_sources is
  'Importer allowlist (D-037). One row per feed; enabled defaults to false and production sources stay off until the GSU courtesy notice is answered and the legal pages are live. Written by migrations, data files and the import RPCs; moderators can read it.';
create or replace trigger feed_sources_set_updated_at before update on public.feed_sources
  for each row execute function public.set_updated_at();

create table if not exists public.event_imports (
  id             uuid primary key default gen_random_uuid(),
  source_id      uuid not null references public.feed_sources (id) on delete cascade,
  external_id    text not null,
  event_id       uuid references public.events (id) on delete set null,
  is_primary     boolean not null default true,   -- false: linked to another source's identical event
  content_hash   text not null,
  raw            jsonb not null default '{}'::jsonb,
  host_org       text,
  open_to_public boolean,
  point_source   text not null default 'none',
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  missed_runs    smallint not null default 0,
  removed_at     timestamptz,
  removed_reason text,
  constraint event_imports_source_external_key unique (source_id, external_id),
  constraint event_imports_external_id_length check (char_length(external_id) between 1 and 200),
  constraint event_imports_host_org_length check (host_org is null or char_length(host_org) <= 120),
  constraint event_imports_point_source check (point_source in ('source', 'campus_centroid', 'area_centroid', 'none')),
  constraint event_imports_removed_reason_length check (removed_reason is null or char_length(removed_reason) <= 500)
);
create index if not exists event_imports_event_idx on public.event_imports (event_id);
create index if not exists event_imports_source_seen_idx on public.event_imports (source_id, last_seen_at);
comment on table public.event_imports is
  'One row per imported item (source, external id): the event it produced, a content hash so unchanged items are skipped, the trimmed raw item, seen stamps and missed_runs (two missed runs cancel the event). removed_at is a moderator takedown: the item is never re-published.';

create table if not exists public.import_hub_rules (
  id         uuid primary key default gen_random_uuid(),
  source_id  uuid references public.feed_sources (id) on delete cascade,   -- null = every source
  match_on   text not null default 'any',
  pattern    text not null,                    -- case-insensitive POSIX regex
  hub_id     uuid not null references public.hubs (id) on delete cascade,
  priority   smallint not null default 100,    -- lower wins
  created_at timestamptz not null default now(),
  constraint import_hub_rules_match_on check (match_on in ('title', 'category', 'host', 'any')),
  constraint import_hub_rules_pattern_length check (char_length(pattern) between 2 and 200)
);
create unique index if not exists import_hub_rules_key
  on public.import_hub_rules (coalesce(source_id, '00000000-0000-0000-0000-000000000000'::uuid), match_on, pattern);
comment on table public.import_hub_rules is
  'Keyword rules mapping imported items to hubs (stand-in for Claude tagging, D-037). Lowest priority wins; rules pointing at an inactive or 21+ hub are ignored; no match falls back to the source default hub, then happening-nearby.';

-- ---------------------------------------------------------------------------
-- 4. Row level security and grants: moderators read, nobody else
-- ---------------------------------------------------------------------------
alter table public.feed_sources     enable row level security;
alter table public.event_imports    enable row level security;
alter table public.import_hub_rules enable row level security;

revoke all on public.feed_sources, public.event_imports, public.import_hub_rules from public, anon, authenticated;
grant select on public.feed_sources, public.event_imports, public.import_hub_rules to authenticated;
grant all on public.feed_sources, public.event_imports, public.import_hub_rules to service_role;

drop policy if exists "feed_sources_select_mod" on public.feed_sources;
create policy "feed_sources_select_mod" on public.feed_sources for select to authenticated
  using ((select public.is_moderator()));
drop policy if exists "event_imports_select_mod" on public.event_imports;
create policy "event_imports_select_mod" on public.event_imports for select to authenticated
  using ((select public.is_moderator()));
drop policy if exists "import_hub_rules_select_mod" on public.import_hub_rules;
create policy "import_hub_rules_select_mod" on public.import_hub_rules for select to authenticated
  using ((select public.is_moderator()));

-- ---------------------------------------------------------------------------
-- 5. Seed sources (disabled) and starter hub rules
-- ---------------------------------------------------------------------------
insert into public.feed_sources (slug, kind, url, name, attribution, homepage_url, item_label, campus_id, cron_minute)
values
  ('gsu-localist', 'localist', 'https://calendar.gsu.edu/api/2/events',
   'Georgia State University Calendar',
   'Listed from the Georgia State University public calendar (calendar.gsu.edu).',
   'https://calendar.gsu.edu', null,
   (select c.id from public.org_campuses c join public.organizations o on o.id = c.org_id
     where o.slug = 'georgia-state' and c.slug = 'atlanta'),
   17),
  ('gsu-pin', 'engage_rss', 'https://gsu.campuslabs.com/engage/events.rss',
   'PIN, Georgia State student organizations',
   'Listed from PIN, the Georgia State student organization calendar (gsu.campuslabs.com).',
   'https://gsu.campuslabs.com/engage/events', 'Georgia State student org event',
   (select c.id from public.org_campuses c join public.organizations o on o.id = c.org_id
     where o.slug = 'georgia-state' and c.slug = 'atlanta'),
   43)
on conflict (slug) do update
   set kind = excluded.kind, url = excluded.url, name = excluded.name,
       attribution = excluded.attribution, homepage_url = excluded.homepage_url,
       item_label = excluded.item_label, campus_id = excluded.campus_id,
       cron_minute = excluded.cron_minute;
-- enabled is never set here: production sources stay off (D-037).

-- Starter rules (global). Word boundaries are \m and \M. Lower priority wins,
-- so specific phrases (table tennis, paint and sip) sit above single words.
with r (pattern, hub_slug, priority, match_on) as (values
  ('\m(table tennis|ping[- ]?pong)\M',                      'table-tennis', 10, 'any'),
  ('\mpaint (and|&|n) sip\M',                               'paint-and-sip', 10, 'any'),
  ('\mflag football\M',                                     'flag-football', 10, 'any'),
  ('\mbeach volleyball\M',                                  'beach-volleyball', 10, 'any'),
  ('\mbook club\M',                                         'book-club', 10, 'any'),
  ('\m(board games?|game night)\M',                         'board-game-night', 10, 'any'),
  ('\mopen mic\M',                                          'open-mic-night', 10, 'any'),
  ('\m(language exchange|conversation table)\M',            'language-exchange', 10, 'any'),
  ('\m(trading card|tcg|pok[eé]mon|magic: the gathering|yu-gi-oh)\M', 'trading-card-games', 10, 'any'),
  ('\m(d&d|dungeons (and|&) dragons|tabletop rpg)\M',       'tabletop-rpg', 10, 'any'),
  ('\m(career fair|career expo|career|employer|recruit\w*)\M', 'career-events', 20, 'any'),
  ('\m(resume|résumé|interview prep|mock interview)\M',    'resume-and-interview-prep', 15, 'any'),
  ('\m(internships?|job fair)\M',                           'internships-and-jobs', 15, 'any'),
  ('\mnetworking\M',                                        'networking-nights', 20, 'any'),
  ('\m(entrepreneur\w*|startups?|pitch competition)\M',     'entrepreneurship', 20, 'any'),
  ('\m(hackathon|coding|programming|developers?)\M',        'coding-and-programming', 20, 'any'),
  ('\mrobotics\M',                                          'robotics', 20, 'any'),
  ('\mbasketball\M',                                        'basketball', 30, 'any'),
  ('\mvolleyball\M',                                        'volleyball', 30, 'any'),
  ('\m(soccer|futsal)\M',                                   'soccer', 30, 'any'),
  ('\mpickleball\M',                                        'pickleball', 30, 'any'),
  ('\mtennis\M',                                            'tennis', 35, 'any'),
  ('\mbadminton\M',                                         'badminton', 30, 'any'),
  ('\mbaseball\M',                                          'baseball', 30, 'any'),
  ('\msoftball\M',                                          'softball', 30, 'any'),
  ('\multimate( frisbee)?\M',                               'ultimate-frisbee', 30, 'any'),
  ('\m(swim\w*|aquatics?)\M',                               'swimming', 30, 'any'),
  ('\m(5k|10k|fun run|run club|running)\M',                 'running', 30, 'any'),
  ('\m(cycling|bike ride|bicycle)\M',                       'cycling', 30, 'any'),
  ('\m(climbing|bouldering)\M',                             'rock-climbing', 30, 'any'),
  ('\m(hike|hiking)\M',                                     'hiking', 30, 'any'),
  ('\m(yoga)\M',                                            'yoga', 30, 'any'),
  ('\m(pilates)\M',                                         'pilates', 30, 'any'),
  ('\m(zumba)\M',                                           'zumba', 30, 'any'),
  ('\m(hiit|boot ?camp|workout|fitness class)\M',           'functional-training', 40, 'any'),
  ('\m(meditation|mindfulness)\M',                          'meditation', 30, 'any'),
  ('\m(boxing)\M',                                          'boxing', 30, 'any'),
  ('\m(karate)\M',                                          'karate', 30, 'any'),
  ('\m(taekwondo)\M',                                       'taekwondo', 30, 'any'),
  ('\m(jiu[- ]?jitsu|bjj)\M',                               'brazilian-jiu-jitsu', 30, 'any'),
  ('\mchess\M',                                             'chess', 30, 'any'),
  ('\m(esports|e-sports|smash bros|valorant|league of legends)\M', 'esports', 30, 'any'),
  ('\m(video games?|gaming)\M',                             'console-gaming', 45, 'any'),
  ('\manime\M',                                             'anime', 30, 'any'),
  ('\mcosplay\M',                                           'cosplay', 30, 'any'),
  ('\m(film|movie|screening|cinema)\M',                     'movies', 40, 'any'),
  ('\mtrivia\M',                                            'trivia', 30, 'any'),
  ('\mkaraoke\M',                                           'karaoke', 30, 'any'),
  ('\m(salsa|bachata)\M',                                   'salsa-dancing', 30, 'any'),
  ('\mballroom\M',                                          'ballroom-dancing', 30, 'any'),
  ('\m(hip[- ]?hop dance|breakdanc\w*|step show)\M',        'hip-hop-dance', 30, 'any'),
  ('\m(orchestra|symphony|recital|philharmonic)\M',         'orchestra', 35, 'any'),
  ('\m(choir|chorus|chorale|a cappella)\M',                 'choir-singing', 35, 'any'),
  ('\m(theatre|theater|musical|play reading)\M',            'musical-theater', 40, 'any'),
  ('\m(improv|stand-?up comedy|comedy show)\M',             'improv-comedy', 35, 'any'),
  ('\m(dj|djing)\M',                                        'djing', 40, 'any'),
  ('\mpoetry\M',                                            'poetry', 35, 'any'),
  ('\m(creative writing|writing workshop)\M',               'creative-writing', 35, 'any'),
  ('\mpodcast\w*\M',                                        'podcasting', 35, 'any'),
  ('\mdebate\M',                                            'debate', 35, 'any'),
  ('\mphotography\M',                                       'photography', 35, 'any'),
  ('\m(painting|watercolor)\M',                             'painting', 40, 'any'),
  ('\m(knitting|crochet\w*)\M',                             'knitting', 40, 'any'),
  ('\m(cooking|cook-?off)\M',                               'cooking', 40, 'any'),
  ('\mbaking\M',                                            'baking', 40, 'any'),
  ('\m(gardening|community garden)\M',                      'gardening', 40, 'any'),
  ('\m(volunteer\w*|service day|day of service)\M',         'volunteering', 40, 'any'),
  ('\m(fundraiser|benefit concert|charity)\M',              'fundraisers', 45, 'any'),
  ('\m(voter|voting|civic)\M',                              'civic-engagement-and-voting', 40, 'any'),
  ('\m(sustainab\w*|climate|recycling|earth day)\M',        'sustainability-and-climate', 40, 'any'),
  ('\m(mental health|wellness|counseling|stress)\M',        'mental-health-and-peer-support', 50, 'any'),
  ('\m(tutoring|tutor)\M',                                  'tutoring', 45, 'any'),
  ('\m(study session|study hall|study group)\M',            'study-sessions', 45, 'any'),
  ('\m(research|symposium|colloquium|poster session)\M',    'research-and-labs', 50, 'any'),
  ('\m(lecture|talk|speaker|seminar|panel|forum|conversation with)\M', 'lectures-and-talks', 60, 'any'),
  ('\m(workshop|training|webinar|info session|information session)\M', 'workshops-and-skill-builders', 70, 'any'),
  ('\m(pride|lgbtq\w*|queer)\M',                            'lgbtq-plus-community', 35, 'any'),
  ('\m(international students?|global|study abroad)\M',     'international-students', 50, 'any'),
  ('\m(first[- ]gen\w*)\M',                                 'first-generation-students', 35, 'any'),
  ('\m(veterans?|military)\M',                              'veterans-and-military', 35, 'any'),
  ('\m(latin[oaxe]?|hispanic)\M',                           'latinx-student-life', 40, 'any'),
  ('\m(aapi|asian|lunar new year)\M',                       'asian-and-pacific-islander-life', 40, 'any'),
  ('\m(black history|nsbe|naacp)\M',                        'black-student-life', 40, 'any'),
  ('\m(diwali|holi|cultural night|heritage)\M',             'cultural-celebrations', 45, 'any'),
  ('\m(bible|worship|christian|fellowship|ministry)\M',     'christian-fellowship', 40, 'any'),
  ('\m(muslim|islamic|ramadan|jummah|iftar)\M',             'muslim-student-life', 40, 'any'),
  ('\m(jewish|shabbat|hillel)\M',                           'jewish-student-life', 40, 'any'),
  ('\m(hindu)\M',                                           'hindu-community', 40, 'any'),
  ('\m(buddhis\w*)\M',                                      'buddhist-community', 40, 'any'),
  ('\minterfaith\M',                                        'interfaith-dialogue', 40, 'any'),
  ('\m(women in|women''s leadership)\M',                    'women-in-leadership', 45, 'any')
), resolved as (
  select r.pattern, h.id as hub_id, r.priority::smallint as priority, r.match_on
    from r join public.hubs h on h.slug = r.hub_slug
   where h.is_active and h.min_age = 18
)
insert into public.import_hub_rules (source_id, match_on, pattern, hub_id, priority)
select null, x.match_on, x.pattern, x.hub_id, x.priority
  from resolved x
 where not exists (
   select 1 from public.import_hub_rules ir
    where ir.source_id is null and ir.match_on = x.match_on and ir.pattern = x.pattern
 );

-- ---------------------------------------------------------------------------
-- 6. Helpers
-- ---------------------------------------------------------------------------
-- Clip to n characters with an ellipsis, verbatim otherwise.
create or replace function public.import_clip(p_text text, p_max integer)
returns text language sql immutable set search_path = '' as $$
  select case
    when p_text is null then null
    when char_length(p_text) <= p_max then p_text
    else rtrim(left(p_text, p_max - 1)) || '…'
  end
$$;

-- The hub for one item: the lowest-priority matching rule whose hub is active
-- and 18+, else the source's default hub, else happening-nearby.
create or replace function public.import_pick_hub(
  p_source_id uuid, p_title text, p_categories text, p_host text
) returns uuid language sql stable set search_path = '' as $$
  select coalesce(
    (select ir.hub_id
       from public.import_hub_rules ir
       join public.hubs h on h.id = ir.hub_id and h.is_active and h.min_age = 18
      where (ir.source_id is null or ir.source_id = p_source_id)
        and case ir.match_on
              when 'title'    then coalesce(p_title, '') ~* ir.pattern
              when 'category' then coalesce(p_categories, '') ~* ir.pattern
              when 'host'     then coalesce(p_host, '') ~* ir.pattern
              else concat_ws(' ', p_title, p_categories, p_host) ~* ir.pattern
            end
      order by ir.priority, (ir.source_id is null), ir.pattern
      limit 1),
    (select fs.default_hub_id from public.feed_sources fs
       join public.hubs h on h.id = fs.default_hub_id and h.is_active and h.min_age = 18
      where fs.id = p_source_id),
    (select h.id from public.hubs h where h.slug = 'happening-nearby')
  )
$$;

-- ---------------------------------------------------------------------------
-- 7. import_upsert_batch
-- ---------------------------------------------------------------------------
-- p_items: the complete current set for the source, an array of
--   { external_id, title, description, starts_at, ends_at, all_day, location,
--     lat, lng, url, cover_url, is_free, price_text, categories[], host_org,
--     open_to_public, cancelled, raw }
-- Unknown or missing fields are tolerated; an item that cannot satisfy the
-- events constraints is skipped and counted.
create or replace function public.import_upsert_batch(p_source_slug text, p_items jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_src        public.feed_sources%rowtype;
  v_run        timestamptz := clock_timestamp();
  v_origin     extensions.geography;
  v_item       jsonb;
  v_ext        text;
  v_title      text;
  v_desc       text;
  v_start      timestamptz;
  v_end        timestamptz;
  v_url        text;
  v_cover      text;
  v_loc        text;
  v_lat        double precision;
  v_lng        double precision;
  v_point      extensions.geography;
  v_point_src  text;
  v_cats       text;
  v_host       text;
  v_public     boolean;
  v_free       boolean;
  v_price      text;
  v_cancelled  boolean;
  v_hub        uuid;
  v_hash       text;
  v_imp        public.event_imports%rowtype;
  v_event      uuid;
  v_dup        uuid;
  v_seen       text[] := '{}';
  v_total      integer := 0;
  v_inserted   integer := 0;
  v_updated    integer := 0;
  v_unchanged  integer := 0;
  v_linked     integer := 0;
  v_skipped    jsonb := '{}'::jsonb;
  v_missed     integer := 0;
  v_cancel_cnt integer := 0;
  v_first_err  text;
  v_reason     text;
begin
  select * into v_src from public.feed_sources where slug = p_source_slug for update;
  if not found then
    raise exception 'source_not_found' using errcode = 'P0002';
  end if;
  if p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'items_must_be_array' using errcode = 'check_violation';
  end if;

  -- Fallback point: the source's campus centroid, else Atlanta.
  v_origin := coalesce(
    (select c.location from public.org_campuses c where c.id = v_src.campus_id),
    (select a.center from public.areas a where a.slug = 'atlanta'));

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    v_total := v_total + 1;
    v_reason := null;
    begin
      v_ext := nullif(btrim(coalesce(v_item->>'external_id', '')), '');
      if v_ext is null or char_length(v_ext) > 200 then v_reason := 'bad_external_id'; end if;
      if v_reason is null and v_ext = any (v_seen) then v_reason := 'duplicate_in_batch'; end if;

      v_title := regexp_replace(btrim(coalesce(v_item->>'title', '')), '\s+', ' ', 'g');
      if v_reason is null and char_length(v_title) < 3 then v_reason := 'title_too_short'; end if;
      v_title := public.import_clip(v_title, 120);

      v_start := nullif(v_item->>'starts_at', '')::timestamptz;
      v_end   := nullif(v_item->>'ends_at', '')::timestamptz;
      if v_reason is null and v_start is null then v_reason := 'no_start'; end if;
      if v_start is not null then
        if v_end is null or v_end <= v_start then
          v_end := case when coalesce((v_item->>'all_day')::boolean, false)
                        then v_start + interval '1 day' - interval '1 minute'
                        else v_start + interval '2 hours' end;
        end if;
        if v_reason is null and v_end > v_start + interval '3 days' then v_reason := 'longer_than_3_days'; end if;
      end if;

      v_url := btrim(coalesce(v_item->>'url', ''));
      if v_reason is null and (v_url !~ '^https://' or char_length(v_url) > 2000) then v_reason := 'no_https_url'; end if;

      if v_reason is not null then
        v_skipped := jsonb_set(v_skipped, array[v_reason], to_jsonb(coalesce((v_skipped->>v_reason)::integer, 0) + 1));
        -- A known item that is still listed but now invalid counts as seen, so it is not cancelled for it.
        if v_ext is not null and v_reason <> 'duplicate_in_batch' then
          update public.event_imports set last_seen_at = v_run, missed_runs = 0
           where source_id = v_src.id and external_id = v_ext;
          v_seen := v_seen || v_ext;
        end if;
        continue;
      end if;
      v_seen := v_seen || v_ext;

      v_desc  := public.import_clip(btrim(coalesce(v_item->>'description', '')), 2000);
      v_cover := nullif(btrim(coalesce(v_item->>'cover_url', '')), '');
      if v_cover is not null and (v_cover !~ '^https://' or char_length(v_cover) > 500) then v_cover := null; end if;
      v_loc   := coalesce(public.import_clip(regexp_replace(btrim(coalesce(v_item->>'location', '')), '\s+', ' ', 'g'), 120), '');
      v_cats  := coalesce((select string_agg(x, ' | ') from jsonb_array_elements_text(
                   case when jsonb_typeof(v_item->'categories') = 'array' then v_item->'categories' else '[]'::jsonb end) x), '');
      v_host  := public.import_clip(nullif(btrim(coalesce(v_item->>'host_org', '')), ''), 120);
      v_public := case when jsonb_typeof(v_item->'open_to_public') = 'boolean' then (v_item->>'open_to_public')::boolean end;
      v_free  := case when jsonb_typeof(v_item->'is_free') = 'boolean' then (v_item->>'is_free')::boolean else true end;
      v_price := public.import_clip(nullif(btrim(coalesce(v_item->>'price_text', '')), ''), 40);
      v_cancelled := coalesce(case when jsonb_typeof(v_item->'cancelled') = 'boolean' then (v_item->>'cancelled')::boolean end, false);

      -- Point: the source's coordinates when they are within 200 km of the
      -- fallback, else the campus (or Atlanta) centroid, labelled as such.
      v_lat := case when jsonb_typeof(v_item->'lat') = 'number' then (v_item->>'lat')::double precision end;
      v_lng := case when jsonb_typeof(v_item->'lng') = 'number' then (v_item->>'lng')::double precision end;
      v_point := null;
      if v_lat between -90 and 90 and v_lng between -180 and 180 and not (v_lat = 0 and v_lng = 0) then
        v_point := extensions.ST_SetSRID(extensions.ST_MakePoint(v_lng, v_lat), 4326)::extensions.geography;
        if v_origin is not null and not extensions.ST_DWithin(v_point, v_origin, 200000) then
          v_point := null;
        end if;
      end if;
      if v_point is not null then
        v_point_src := 'source';
      elsif v_src.campus_id is not null and v_origin is not null then
        v_point := v_origin; v_point_src := 'campus_centroid';
      elsif v_origin is not null then
        v_point := v_origin; v_point_src := 'area_centroid';
      else
        v_point_src := 'none';
      end if;

      v_hub := public.import_pick_hub(v_src.id, v_title, v_cats, v_host);
      if v_hub is null then
        raise exception 'catch_all_hub_missing';
      end if;

      v_hash := encode(extensions.digest(concat_ws(chr(31),
                  v_title, v_desc, v_start::text, v_end::text, v_url, v_cover, v_loc,
                  v_point_src, extensions.ST_AsText(v_point::extensions.geometry), v_free::text, v_price,
                  v_host, v_public::text, v_cancelled::text, v_hub::text), 'sha256'), 'hex');

      select * into v_imp from public.event_imports where source_id = v_src.id and external_id = v_ext for update;

      if found then
        update public.event_imports
           set last_seen_at = v_run, missed_runs = 0,
               raw = coalesce(v_item->'raw', '{}'::jsonb),
               host_org = v_host, open_to_public = v_public
         where id = v_imp.id;

        if v_imp.removed_at is not null or not v_imp.is_primary or v_imp.event_id is null then
          v_unchanged := v_unchanged + 1;
        elsif v_imp.content_hash = v_hash
              and not exists (select 1 from public.events e where e.id = v_imp.event_id
                               and e.status = 'cancelled' and e.cancel_reason = 'No longer listed by the source.') then
          v_unchanged := v_unchanged + 1;
        else
          update public.events
             set hub_id = v_hub, title = v_title, description = v_desc, cover_url = v_cover,
                 starts_at = v_start, ends_at = v_end, location_hint = v_loc, approx_point = v_point,
                 external_url = v_url, source_name = v_src.name, campus_id = v_src.campus_id,
                 min_age = 18, is_free = v_free, price_text = v_price,
                 status = case when v_cancelled then 'cancelled'::public.event_status else 'published'::public.event_status end,
                 cancelled_at = case when v_cancelled then coalesce(cancelled_at, now()) end,
                 cancel_reason = case when v_cancelled then 'Cancelled by the source.' end
           where id = v_imp.event_id and kind = 'imported';
          update public.event_imports
             set content_hash = v_hash, point_source = v_point_src
           where id = v_imp.id;
          v_updated := v_updated + 1;
        end if;
      else
        -- Cheap cross-source dedupe: an identical title and start from another source.
        select e.id into v_dup
          from public.events e
          join public.event_imports ei on ei.event_id = e.id and ei.is_primary and ei.source_id <> v_src.id
         where e.kind = 'imported' and e.status = 'published'
           and e.starts_at = v_start and lower(e.title) = lower(v_title)
         limit 1;

        if v_dup is not null then
          insert into public.event_imports
            (source_id, external_id, event_id, is_primary, content_hash, raw, host_org, open_to_public,
             point_source, first_seen_at, last_seen_at)
          values (v_src.id, v_ext, v_dup, false, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_linked := v_linked + 1;
        elsif v_cancelled or v_end <= now() then
          -- Nothing to show: remember the key, create no event.
          insert into public.event_imports
            (source_id, external_id, event_id, content_hash, raw, host_org, open_to_public, point_source,
             first_seen_at, last_seen_at)
          values (v_src.id, v_ext, null, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_unchanged := v_unchanged + 1;
        else
          insert into public.events
            (kind, hub_id, campus_id, host_id, series_id, title, description, cover_url, starts_at, ends_at,
             timezone, min_age, is_free, price_text, status, visibility, address_visibility, location_hint,
             approx_point, external_url, source_name)
          values
            ('imported', v_hub, v_src.campus_id, null, null, v_title, v_desc, v_cover, v_start, v_end,
             'America/New_York', 18, v_free, v_price, 'published', 'public', 'public', v_loc,
             v_point, v_url, v_src.name)
          returning id into v_event;
          insert into public.event_imports
            (source_id, external_id, event_id, content_hash, raw, host_org, open_to_public, point_source,
             first_seen_at, last_seen_at)
          values (v_src.id, v_ext, v_event, v_hash, coalesce(v_item->'raw', '{}'::jsonb), v_host, v_public,
                  v_point_src, v_run, v_run);
          v_inserted := v_inserted + 1;
        end if;
      end if;
    exception when others then
      v_skipped := jsonb_set(v_skipped, '{error}', to_jsonb(coalesce((v_skipped->>'error')::integer, 0) + 1));
      if v_first_err is null then
        v_first_err := left(coalesce(v_ext, '?') || ': ' || sqlerrm, 500);
      end if;
    end;
  end loop;

  -- Missed runs: only for upcoming events, and never when the source returned
  -- nothing at all (an empty feed is more likely an outage than a cancellation).
  if v_total > 0 then
    with missed as (
      update public.event_imports ei
         set missed_runs = least(ei.missed_runs + 1, 100)
        from public.events e
       where ei.source_id = v_src.id
         and ei.last_seen_at < v_run
         and ei.removed_at is null
         and e.id = ei.event_id
         and e.starts_at > now()
      returning ei.event_id, ei.missed_runs, ei.is_primary
    ), cancelled as (
      update public.events e
         set status = 'cancelled', cancelled_at = now(), cancel_reason = 'No longer listed by the source.'
        from missed m
       where e.id = m.event_id and m.is_primary and m.missed_runs >= 2
         and e.status = 'published' and e.kind = 'imported'
      returning e.id
    )
    select (select count(*) from missed), (select count(*) from cancelled) into v_missed, v_cancel_cnt;
  end if;

  update public.feed_sources
     set last_run_at = v_run,
         last_ok_at  = v_run,
         last_error  = v_first_err,
         item_count  = v_total,
         last_stats  = jsonb_build_object(
           'total', v_total, 'inserted', v_inserted, 'updated', v_updated, 'unchanged', v_unchanged,
           'linked_duplicates', v_linked, 'skipped', v_skipped, 'missed', v_missed, 'cancelled', v_cancel_cnt),
         last_sample = coalesce((select jsonb_agg(x) from (select value as x from jsonb_array_elements(p_items) limit 2) s),
                                last_sample)
   where id = v_src.id;

  return jsonb_build_object(
    'source', v_src.slug, 'total', v_total, 'inserted', v_inserted, 'updated', v_updated,
    'unchanged', v_unchanged, 'linked_duplicates', v_linked, 'skipped', v_skipped,
    'missed', v_missed, 'cancelled', v_cancel_cnt, 'first_error', v_first_err);
end $$;

comment on function public.import_upsert_batch(text, jsonb) is
  'Importer write path (D-037), service_role only. p_items is the complete current item set of one source. Upserts kind=imported public events (campus_id as a label, 18+), maps hubs by import_hub_rules, skips items that break the events constraints, links exact title+start matches from another source, counts missed runs for upcoming events and cancels after two, and records the run on feed_sources. Returns counts.';

create or replace function public.import_record_error(p_source_slug text, p_error text, p_sample jsonb default null)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.feed_sources
     set last_run_at = now(),
         last_error  = left(coalesce(p_error, 'unknown error'), 2000),
         last_sample = coalesce(p_sample, last_sample)
   where slug = p_source_slug;
end $$;

-- ---------------------------------------------------------------------------
-- 8. Shared secret, function URL, dispatch and schedule
-- ---------------------------------------------------------------------------
-- Generate the shared secret inside the database when absent. Its value never
-- leaves the database except in the pg_net header to the import-feed function.
do $$
begin
  if to_regclass('vault.secrets') is null then
    raise notice 'supabase_vault is not installed; import_feed_secret not created';
  elsif not exists (select 1 from vault.secrets where name = 'import_feed_secret') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'import_feed_secret',
                                'Shared secret between pg_cron and the import-feed Edge Function (D-037)');
  end if;
end $$;

create or replace function public.import_verify_secret(p_secret text)
returns boolean language plpgsql stable security definer set search_path = '' as $$
declare
  v_secret text;
begin
  if p_secret is null or char_length(p_secret) < 32 then
    return false;
  end if;
  select ds.decrypted_secret into v_secret
    from vault.decrypted_secrets ds where ds.name = 'import_feed_secret' limit 1;
  return v_secret is not null and v_secret = p_secret;
end $$;

-- Written by migrate.yml for each project (it knows the project ref). Only the
-- migration owner can call it.
create or replace function public.import_set_function_url(p_url text)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_id uuid;
begin
  if p_url !~ '^https://[a-z0-9]+\.supabase\.co/functions/v1/import-feed$' then
    raise exception 'invalid_function_url' using errcode = 'check_violation';
  end if;
  select id into v_id from vault.secrets where name = 'import_feed_url';
  if v_id is null then
    perform vault.create_secret(p_url, 'import_feed_url', 'URL of the import-feed Edge Function on this project');
  else
    perform vault.update_secret(v_id, p_url, 'import_feed_url', 'URL of the import-feed Edge Function on this project');
  end if;
end $$;

-- Posts one run request for a source. Returns the pg_net request id, or null
-- when the URL or secret is not configured yet.
create or replace function public.import_dispatch(p_slug text)
returns bigint language plpgsql security definer set search_path = '' as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url from vault.decrypted_secrets where name = 'import_feed_url' limit 1;
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'import_feed_secret' limit 1;
  if v_url is null or v_secret is null then
    raise notice 'import-feed URL or secret not configured; nothing sent for %', p_slug;
    return null;
  end if;
  if not exists (select 1 from public.feed_sources where slug = p_slug and enabled) then
    return null;
  end if;
  return net.http_post(
    url := v_url,
    body := jsonb_build_object('source', p_slug),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-import-secret', v_secret),
    timeout_milliseconds := 150000);
end $$;

create or replace function public.import_dispatch_all()
returns jsonb language sql security definer set search_path = '' as $$
  select coalesce(jsonb_object_agg(fs.slug, public.import_dispatch(fs.slug)), '{}'::jsonb)
    from public.feed_sources fs where fs.enabled
$$;

-- One hourly job per enabled source; every import-feed-* job is unscheduled first.
create or replace function public.import_schedule()
returns integer language plpgsql security definer set search_path = '' as $$
declare
  v_job record;
  v_src record;
  v_n   integer := 0;
begin
  if to_regclass('cron.job') is null then
    return 0;
  end if;
  for v_job in select jobname from cron.job where jobname like 'import-feed-%'
  loop
    perform cron.unschedule(v_job.jobname);
  end loop;
  for v_src in select slug, cron_minute from public.feed_sources where enabled order by slug
  loop
    perform cron.schedule(
      'import-feed-' || v_src.slug,
      v_src.cron_minute || ' * * * *',
      format('select public.import_dispatch(%L)', v_src.slug));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

create or replace function public.feed_sources_reschedule()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  perform public.import_schedule();
  return null;
end $$;
drop trigger if exists feed_sources_reschedule on public.feed_sources;
create trigger feed_sources_reschedule
  after insert or delete or update of enabled, cron_minute, slug on public.feed_sources
  for each statement execute function public.feed_sources_reschedule();

-- Bring the schedule in line with the current rows (no jobs while all are disabled).
select public.import_schedule();

-- ---------------------------------------------------------------------------
-- 9. Labels the app shows on imported cards and event pages
-- ---------------------------------------------------------------------------
create or replace function public.imported_event_labels(p_event_ids uuid[])
returns table (
  event_id             uuid,
  source_slug          text,
  source_kind          text,
  source_name          text,
  attribution          text,
  homepage_url         text,
  item_label           text,
  host_org             text,
  open_to_public       boolean,
  approximate_location boolean,
  affiliated_org_name  text
)
language sql stable security definer set search_path = '' as $$
  select e.id, fs.slug, fs.kind, fs.name, fs.attribution, fs.homepage_url, fs.item_label,
         ei.host_org, ei.open_to_public, (ei.point_source <> 'source'),
         o.name
    from public.events e
    join public.event_imports ei on ei.event_id = e.id and ei.is_primary
    join public.feed_sources fs on fs.id = ei.source_id
    left join public.org_campuses c on c.id = fs.campus_id
    left join public.organizations o on o.id = c.org_id
   where e.id = any ((coalesce(p_event_ids, '{}'::uuid[]))[1:200])
     and e.kind = 'imported'
     and public.can_read_event(e.id)
$$;
comment on function public.imported_event_labels(uuid[]) is
  'For up to 200 imported events the caller can read: source attribution, the per-source chip (PIN: "Georgia State student org event"), the hosting organization, whether the source says the event is open to the public, whether the point is a centroid approximation, and the organization the source belongs to (shown as the D-022 not-affiliated line).';

-- ---------------------------------------------------------------------------
-- 10. Privileges (explicit)
-- ---------------------------------------------------------------------------
revoke all on function public.import_clip(text, integer) from public, anon, authenticated;
grant execute on function public.import_clip(text, integer) to service_role;
revoke all on function public.import_pick_hub(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.import_pick_hub(uuid, text, text, text) to service_role;
revoke all on function public.import_upsert_batch(text, jsonb) from public, anon, authenticated;
grant execute on function public.import_upsert_batch(text, jsonb) to service_role;
revoke all on function public.import_record_error(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.import_record_error(text, text, jsonb) to service_role;
revoke all on function public.import_verify_secret(text) from public, anon, authenticated;
grant execute on function public.import_verify_secret(text) to service_role;
revoke all on function public.import_set_function_url(text) from public, anon, authenticated, service_role;
revoke all on function public.import_dispatch(text) from public, anon, authenticated, service_role;
revoke all on function public.import_dispatch_all() from public, anon, authenticated, service_role;
revoke all on function public.import_schedule() from public, anon, authenticated, service_role;
revoke all on function public.feed_sources_reschedule() from public, anon, authenticated, service_role;
revoke all on function public.imported_event_labels(uuid[]) from public, anon;
grant execute on function public.imported_event_labels(uuid[]) to authenticated;

-- ---------------------------------------------------------------------------
-- 11. Version stamp (last)
-- ---------------------------------------------------------------------------
insert into public.meta (key, value) values ('schema_version', '2.11')
  on conflict (key) do update set value = excluded.value, updated_at = now();
