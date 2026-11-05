# Automatic worldwide coverage: design (draft for D-042)

Date: 2026-11-04. Status: recorded as D-042 (`docs/DECISIONS.md`) on Nov 4 with four changes that win over this text where they differ: tile files are served from **GitHub Pages first** and move to Cloudflare R2 only when traffic needs it (section 4.3's choice is reversed for launch; same file layout); EU automatic event discovery stays off until the attorney read while places work in the EU from day one; the Geoapify, Ticketmaster and SeatGeek adapters no-op cleanly until `GEOAPIFY_SERVER_KEY`, `TICKETMASTER_API_KEY` and `SEATGEEK_CLIENT_ID` exist; the nightly places schedule acts on production only when `PLACES_EXTRACT_SCHEDULE` is `production`. Slice 1 is migration 40 (`supabase/migrations/20261204000100_place_tile_demand.sql`). Builds on D-040 (everyone, anywhere; free sources), D-041 (hub map), `docs/design/hub-map/HUB_MAP_DESIGN.md` and `docs/design/collector.md`.

Sai's question (Nov 4): "If somebody in Germany downloaded the app, would they be able to see stuff near them? Could we work out an algorithm that generates maps for people based on their location and hubs?"

**Short answer.** Yes, and most of the parts already exist. Today a German member can sign up, set a home and see the feed, but their map stays empty and their feed has no imported events. That is because nothing turns "a member lives here" into "map this area and find its event sources". This design adds that step, moves the bulk OpenStreetMap places out of the database into static files so the 500 MB free database is not the limit, and replaces hand-written city seed files with automatic source discovery. About 12 build slices of 1 to 3 days each.

---

## 1. Decision text (ready to become D-042)

> ## D-042 — Automatic worldwide coverage: maps and event sources build themselves where members are (Sai's decision, 2026-11-xx)
> Sai, Nov 4: anyone anywhere who sets a home and picks hubs should get a map and a feed for their area without anyone setting up a city by hand. Chose:
> **Demand.** Saving a home point or home area (onboarding, settings) marks its 0.5-degree place tile `wanted` and adds 1 to the tile's demand counter; a home within 10 km of a tile edge also marks the neighbouring tile wanted with demand 0. The same call already queues the 25 km event-discovery region (`collector_regions`). Neither table stores a user id, and times are rounded to the day. At most 50 new tiles and 10 new event regions a day worldwide. Panning the map never creates demand.
> **Places pipeline.** A nightly GitHub Action builds every `wanted` tile from Geofabrik regional extracts (smallest extract that holds the tile, never a whole-country file when subregions exist, never a file over 3 GB), within a per-night budget. Active tiles refresh weekly. Geoapify's free tier fills a brand-new tile within about 15 minutes when a server key exists; without it the tile is ready by the next night.
> **Storage and serving.** OpenStreetMap places are served as one gzipped JSON file per tile from Cloudflare R2 (free tier: 10 GB storage, free egress), not from Postgres. Postgres keeps everything members create or moderators change (member places, meeting spots, hidden or corrected rows, hub links), tile status and events. The app merges the two. This replaces the 150 MB places cap in D-041 as the binding limit and is the "per-region static files" fallback D-041 already named.
> **Event sources.** No more hand-written city files. For each event region, the collector finds candidate calendar sites from OpenStreetMap `website` tags of event-likely places (libraries, museums, theatres, community and sports centres, universities, parks) and from Wikidata official-website entries, probes each politely for feeds and schema.org events, and turns a source on only after it yields valid events on two separate days. Members can suggest a calendar URL, which goes through the same check. Ticketmaster and SeatGeek run by coordinates and radius once their keys exist. All D-040 rules stand (robots.txt, noindex, denylist, 1 request per 2 s per host, removal link).
> **EU.** Automatic discovery in the EU starts only after the attorney read (FOUNDER-TODO item 12) covers the EU database right; until then EU regions use lane 1 APIs, publisher-offered feeds (ICS, RSS) and member suggestions.
> **Honesty in the UI.** The map says "We're mapping this area" while a tile is wanted or filling, and says why if it is queued (budget or size). The feed widens its radius and then shows the "post the first plan" empty state; it never pretends a city is covered.
> **Budget.** Everything stays on free tiers: GitHub Actions (public repo), Supabase Free, Cloudflare R2 free tier, Geoapify free plan, Ticketmaster and SeatGeek free keys, Wikidata. Regions and tiles with no active member for 90 days stop refreshing; tile files idle 180 days are deleted.

---

## 2. End to end: a new member in Germany

Example: Lena in Leipzig, hubs basketball, board games, climbing.

| Time | What happens | Where |
|---|---|---|
| T+0 | Onboarding: she types "Leipzig" (Geoapify geocoder, or the starter city list without a key) or taps device location. `set_home_location` saves an owner-only point rounded to about 1 km. | `profile_private` (existing) |
| T+0 | `collector_note_home_point` (existing) upserts the 0.1-degree event region (25 km, no user id). **New:** it also calls `place_tile_note_home`, which upserts tile `wanted`, demand +1, plus edge neighbours. Rate limit: once per person per 24 h (existing `home_count_noted_at`). | migration (slice 1) |
| T+0 | Feed: public plans within a widening radius (D-040), then the honest empty state. Map: plans, meeting spots and "Add a spot" show; banner "We're mapping this area. Courts and stores usually appear within a day." | existing UI |
| T+1 min | If `GEOAPIFY_SERVER_KEY` exists: pg_net pings `places-fill`, which fetches specific-hub categories for the tile (max 20 requests) and ingests rows with `source='geoapify'`, status `filling`. "Powered by Geoapify" shows. | Edge Function (slice 9) |
| Night 1, 03:17 UTC | Nightly places job picks wanted tiles by demand. Leipzig tile resolves to Geofabrik `europe/germany/sachsen` (a few hundred MB; HEAD check under 3 GB). osmium filters with `filters.txt`, builds the tile file, uploads to R2, calls `finish_place_tile(tile, hash, bytes, count)`. Tile `active`. Geoapify rows with the same `osm_ref` are superseded. | Action (slices 2, 4) |
| Night 1 | Event region for Leipzig enters the discovery queue (priority by home_count). Wikidata pass and OSM-website pass build `source_candidates`. | Action (slices 7, 8) |
| Nights 2 to 4 | Probes about 150 hosts a night. Candidates that yield events become `discovered`, then `active` after a second good day. Ticketmaster `latlong` + `countryCode=DE` runs if the key exists (likely thin in Germany: Eventim dominates). | collector (slices 8, 10) |
| Day 3 onward | Lena's feed has imported events from Leipzig libraries, theatres and venues; her map shows courts, game stores and climbing gyms, filtered by her hub chips. | |

Nobody set up "Leipzig". The second Leipzig member only bumps the counters.

---

## 3. What blocks this today (checked in repo and on staging `gzrscndzzggxmcwnvvcq`, read-only)

- **No tile demand.** `bump_place_tile` is in the design (HUB_MAP_DESIGN section 5) but in no migration. The only insert into `place_tiles` is the Atlanta seed (`supabase/migrations/20261122000100_places_schema.sql:429`). `retire_place_tiles()` (`20261130000100_places_review_fixes.sql:717`) only updates existing rows. Staging: 3 tiles (178030, 178031, 178751), all Atlanta, active, keep, demand 0.
- **Extract job is weekly and off.** `.github/workflows/places-extract.yml` runs `17 3 * * 0` and only when `PLACES_EXTRACT_SCHEDULE=production`. `scripts/places/regions.json` names only Atlanta, though `queue` mode accepts any tile and `pick_extracts` (`scripts/places/extract_places.py:193`) already picks the smallest Geofabrik extract per point.
- **No Geoapify fill.** No `places-fill` function, no server key. The ingest path already accepts `source: "geoapify"`.
- **Collector is Atlanta-only and dry-run.** `packages/collector` reads only `data/cities/atl.json`; `collector-dry-run.yml` is dispatched by hand; ingest (`import_upsert_batch` via the collector secret) is not wired; nothing reads `collector_regions`, which has no timezone column.
- **Banner is wrong for new areas.** It shows only for an existing wanted or filling row, so a Berlin member gets the plain empty state; "within a day" is not true with a weekly gated job.

---

## 4. Storage and serving: static tile files on Cloudflare R2

### 4.1 Measurements (staging, Nov 4)

| | Rows | Size |
|---|---|---|
| Postgres `places`, Atlanta 3 tiles | 16,694 | 25 MB, about 1.0 KB a row fresh, 1.6 KB after a refresh |
| Map fields only, raw JSON | 16,694 | 77 B a row |
| Map fields + address, hours, website, tags, raw JSON | 16,694 | 149 B a row |
| Monthly ODbL dump, gzip (run 41864207256) | 16,694 | 587,845 B, about 35 B a row |

Per Atlanta tile: 3,323 / 9,119 / 4,252 rows, about 120 / 330 / 155 KB gzipped.

### 4.2 Germany and the world (estimates, not counts; taginfo and Geofabrik are blocked from this container)

- A 0.5-degree tile at 51 N is about 56 x 35 km. Germany is about 185 land tiles (about 220 with border tiles).
- Scaling from the Georgia extract (62.6 MB filtered, Atlanta box 17.5 MB = 16.7k rows) and Germany being 10 to 12x Georgia's raw size: roughly 300k to 800k matching places, middle about 600k.
- In Postgres at 1.0 to 1.6 KB a row: 0.6 to 1.0 GB. **Germany alone exceeds the whole 500 MB free database.**
- As static gzip at about 37 B a row: about 22 MB (11 to 30 MB).
- 1,000 active metro tiles worldwide: about 0.2 to 0.5 GB gzipped.

### 4.3 Egress at 10k monthly active users

Assumptions: 6 map sessions per user a month, about 2 tiles in view, 300 KB per tile, 40 KB `map_in_view` reply x 5 views a session.

| Option | Monthly egress | Fits free tier? |
|---|---|---|
| 1. Places via Postgres API (today) | about 12 GB plus events | No: Supabase Free is 5 GB uncached + 5 GB cached, shared with Storage |
| 2. Static files in Supabase Storage, device cache, weekly rebuild | about 26 GB | No (same shared egress) |
| 3. **Static files on Cloudflare R2** | about 26 to 36 GB | **Yes: R2 egress is free; about 120k reads/month vs 10M free Class B; about 9k writes/month vs 1M Class A** |
| GitHub Pages (fallback) | same | Up to about 30 to 40k MAU (100 GB/month soft limit); terms discourage commercial use |

**Choice: option 3.** R2 free tier: 10 GB-month storage, 1M Class A and 10M Class B operations a month, free egress. The `r2.dev` URL is rate-limited and "not intended for production", so the bucket is served either through a custom domain (needs `activityplanet.app` DNS on Cloudflare) or through a small Cloudflare Worker bound to the bucket (workers.dev URL, no DNS move; Workers free plan is about 100k requests a day, from memory, verify). Keep the same file layout buildable for GitHub Pages as a no-card fallback.

### 4.4 File format

- `places/v{rules_version}/{tile_id}.{hash}.json.gz`, compact JSON arrays: `[osm_ref, lng, lat, kind, name, rule_ids, addr, hours, website, extra_tags]`.
- `places/manifest.json`: tile id, hash, bytes, count, built_at. Also recorded in `place_tiles` so the database is the source of truth.
- `rules/v{n}.json`: the 1,332 hub-rule links and place modes (about 20 KB), so the client can filter by hub chip.
- Served with `Content-Encoding: gzip`, `Cache-Control: public, max-age=31536000, immutable` (hashed names), CORS for the app origins.
- Not PMTiles or FlatGeobuf now: the client clusters a few thousand points and filters by `rule_ids`; a 0.2 to 1 MB tile is cheaper fetched whole. Revisit if a tile passes about 3 MB (split into 0.25-degree subtiles first).

### 4.5 How `map_in_view` changes

- **Stays in Postgres:** tile status and the mapping banner reason; events, shows, approved-only cells; member places; meeting spots; Geoapify fill rows (until the tile is active); an overlay keyed by `osm_ref` (hidden, removed, closed, `locked_fields` corrections, member and moderator hub links).
- **RPC returns** the overlay plus `place_tiles: [[tile_id, hash, count, status]]` for tiles in view.
- **Client** fetches tile files in parallel with the RPC, caches them in Cache Storage by hash, filters by hub using `rules/v{n}.json`, applies the overlay (database row with the same `osm_ref` wins; hidden rows dropped), feeds one clustered MapLibre source, and shows OSM place details from the file (no `place_detail` call).
- **Build step** reads hidden and removed ids from the database and leaves them out of the file.
- **Moves off Postgres:** venue matching (nearest OSM place within 60 m) becomes an Edge Function reading the tile file, or is done at build time; name search runs on loaded tiles in the client; "three public places within 150 m" on moderation cards uses the Edge Function.
- Atlanta stays in both stores until the client merge passes tests; then OSM rows are deleted from Postgres (frees about 25 MB).
- As built (slice 11, migration 49, `supabase/functions/place-files`): venue matching runs in the `place-files` Edge Function against the published files (pg_cron `place-match`, minutes 11 and 41; the nearest row within 60 m with the same or a close name, pg_trgm 0.45), and a match becomes a database row through `place_from_file` (refused unless the file's sha256 is the tile's current one) before `meeting_spot_refresh` links it, so the rule stays the database's. A member acting on a file-only place (report, correction, "Start a plan here") gets its row from `POST place-files/place`. Name search, the add-a-place duplicate check and the moderation card's nearby places run in the client on the files read (`place_file_at` gives a point's file). The OSM rows are not deleted yet: the files are still built from them, so the delete needs the extract to write files directly first (a later step).

---

## 5. Nightly pipeline

### 5.1 Places (`places-extract.yml`)

- Cron `17 3 * * *` daily, `region=queue`. Wanted tiles every night; active tiles refresh on Sundays only (weekday check in "Decide target").
- `PLACES_EXTRACT_SCHEDULE=production` stays Sai's on switch.
- Queue: `wanted` by demand desc, then id; grouped by chosen extract so one download serves every tile in it.
- Per-night budget (workflow inputs with defaults):

| Limit | Default | Why |
|---|---|---|
| Wanted tiles per night | 12 | Atlanta's 3 tiles took about 2.5 min with the extract cached |
| New Geofabrik downloads | 6 files, 6 GB total | Geofabrik asks for responsible downloads; runner disk is 14 GB |
| Largest single extract | 3 GB (HEAD `Content-Length`; else log `extract_too_big`, tile stays wanted with reason) | Disk and time; `index-v1.json` has no sizes |
| `timeout-minutes` | 300 (from 120) | Job limit is 6 h |
| R2 writes per night | 500 | Far under 1M Class A a month |

- Germany resolves to state or Regierungsbezirk files (Berlin, Oberbayern, Köln about 202 MB, Düsseldorf about 194 MB per Geofabrik's NRW page, search excerpt). The whole Germany file is never needed.
- Actions cache: 10 GB per repo, 7-day eviction; cache key `<extract>-<ISO week>`. With many regions the cache will churn, another reason for the download cap.
- `keepalive.yml` plus the admin "not seen within a day" check cover GitHub's 60-day pause of scheduled workflows.

### 5.2 Geoapify fill (`places-fill` Edge Function)

- pg_cron every 15 min, plus an immediate pg_net call when a tile first becomes wanted.
- Wanted tiles with no OSM run, by demand. `/v2/places` with `categories` from `hubs.geoapify_categories` (specific hubs only), `filter=rect:<tile>`, at most 20 requests a tile.
- Budget 500 credits a day for places in `collector_budget` (free plan is 3,000 credits a day; leaves about 2,500 for geocoding). About 25 new tiles a day.
- Rows carry `osm_ref` from `datasource.raw.osm_id`, so the nightly OSM build supersedes them cleanly.
- As built (slice 9, migration 43, `supabase/functions/places-fill`): only tiles with demand of at least 1 (members' own tiles; demand-0 neighbours wait for the night). Requests take 100 places (5 credits, at Geoapify's 1 credit per 20 places; re-check when the key exists), at most 8 a tile (40 credits), round-robin over category groups (sport, activity, outdoors, learning, shops, food) with the broad parents (`sport`, `commercial`, `catering`, `entertainment`, `natural`, `heritage`, `building`) left out. The result's OSM tags go through the same rules as the extract, so kind and rule ids match. Once the tile has an OSM run, Geoapify rows the merge did not take are deleted every 15 minutes (`places_fill_supersede`), keeping only rows with a correction, venue, member or moderator link, pending edit or open report, and rows a moderator hid or removed (migration 44).

### 5.3 Events (`collector.yml`, new nightly)

- `GET /collector/regions?due=1` (collector secret only) returns due regions: point, radius, priority, `last_discovery_at`, timezone. No user ids.
- Matrix of up to 20 regions a night: lane 1 APIs by `latlong`/radius; lane 2/3 runs of active discovered sources; discovery probes (section 6) within caps.
- Ingest through `import_upsert_batch` via the collector secret (slice 6 wires it).
- Timezone resolved offline in the job from coordinates (e.g. `tz-lookup` npm package) and stored on the region.
- As built (slice 6, migration 45): `collector-ingest.yml` nightly at 05:41 UTC, `region=due` by default. The due regions (not collected this UTC day, by priority, never-collected first, then home count; 20 a night) come from the project whose members they are (production only behind `COLLECTOR_PRODUCTION`). One job, not a matrix: every region is collected in one pass with one fetcher, so per-host spacing and caps hold across regions, with a 30-minute run deadline. Seeds: the city files overlapping each region (a city file whose area contains a region also runs as a seeds-only region, so Atlanta keeps its 60 km) plus `GET /collector/sources?regions=` (slice 7, migration 46: probation and enabled discovered sources, whose results go back through `POST /collector/sources/record`). Zones from `tz-lookup` 6.1.25 and the per-region source and item counts are stored with `POST /collector/regions/record`. Lane 1 APIs run once per collector region, never for seeds-only city areas.

---

## 6. Source discovery algorithm

### 6.1 Candidate sites (all free)

1. **OSM `website` tags** in the region's tiles (already in `places.website` from `website` or `contact:website`, `extract_places.py:515`). Event-likely kinds first: library, museum, arts_venue (theatre, arts centre, concert hall, music venue, events venue), community centre, sports centre, university/college, townhall, park, maker/hackerspace, cinema, dance. Second tier: bars and breweries. Excluded: restaurants, shops, cafés (low yield) and worship (D-041: sensitive hubs only from public institutions). Atlanta staging: 438 distinct hosts on event-likely kinds out of 2,731; 17 of the 19 hand-seed hosts checked are present.
   - With static tiles, the build step emits a small `candidates/{tile}.json` (host, kind, name, country, wikidata id) so discovery does not need OSM rows in Postgres.
2. **Wikidata P856 (official website).** First, for places with an OSM `wikidata` tag (288 in Atlanta, 181 event-likely), `wbgetentities` 50 ids a call (about 4 calls a region). Then one SPARQL `wikibase:around` query per region (25 km) over museum, library, theatre, university, concert hall, botanical garden and city (city sites lead to parks and city calendars), one `P279` hop only. Identifying User-Agent with our bot URL, one query at a time, honour `Retry-After`.
3. **Member suggestions.** A "Suggest a calendar" form (URL only), rate-limited per member, stored with no user id on the candidate row. Needed because about a third of Atlanta's working seeds (Park Pride, ArtsATL, the contra dance society) are organisations without a venue.
4. **Lane 1:** Ticketmaster, SeatGeek, and a short curated list of national open-data event APIs (Germany: the German Tourism Knowledge Graph, schema.org events from all 16 states with per-entry licences, typically CC BY-SA; API terms not yet checked).

Dedup by host globally, so a library system or a chain is probed once.

### 6.2 Probe (max 8 requests per host, existing `PoliteFetcher`)

1. robots.txt: disallow or 5xx means `rejected`, retry after 30 days.
2. Homepage: `<link rel=alternate>` calendar/RSS links, JSON-LD. Find event pages by link path or link text against the keyword table, never by reading body text.
3. Up to 3 matching pages. Guess `/events`, `/veranstaltungen` etc. only when no link matched.
4. Platform recognition: plain ICS/webcal and RSS with event times; The Events Calendar (`tribe-events`, REST only when robots allows and no noindex); Trumba (`$Trumba.addSpud` to `trumba.com/calendars/x.ics`); LibCal, CivicPlus `iCalendar.aspx`, Communico RSS, Google Calendar embeds; schema.org Event JSON-LD or microdata. **Localist is never auto-enabled** (vendor says API use is licensed): status `needs_permission`.
5. Result: best URL, kind (`ics`, `rss`, `jsonld`), count of upcoming in-window items, share of items inside the region.

Keywords (lower-cased, accents stripped; ordered by `places.country`, English always included):

| Lang | Keywords |
|---|---|
| en | events, calendar, whats-on, programme, program, shows, concerts, schedule |
| de | veranstaltungen, veranstaltungskalender, termine, kalender, programm, spielplan, aktuelles |
| fr | evenements, agenda, programmation, calendrier |
| es/pt | eventos, agenda, actividades, programacion |
| it | eventi, calendario, agenda |
| nl | evenementen, agenda, activiteiten |
| pl/sv/da | wydarzenia, kalendarz; evenemang, kalender; arrangementer, begivenheder |

### 6.3 Score and lifecycle

- Score 0 to 100: feed yielding events +50; recognised platform +30; 3+ JSON-LD events +40; kind prior x 20 (library 0.8, university 0.7, arts_venue 0.6, community 0.5, park 0.3, bar 0.2); confirmed by Wikidata +10; items mostly outside region -30; duplicates an existing source -20. Probe order within a region is by score of the cheap signals (kind, Wikidata) first.
- Tables: new `source_candidates` (host, url, region, origin osm/wikidata/member, score, status, reason, retry_after, ok_runs, empty_runs; no user ids). `feed_sources` gains `discovery_status ('discovered','trial','active','paused','rejected')` and `discovered_from`; new rows `collector = true`, `enabled = false`, attribution "Events from <name> (<host>)".
- `discovered` to `active` after two runs on separate days each with at least 1 valid in-window, in-region item, no noindex, error rate under 20%, not Localist or partner.
- 3 empty runs: `paused`, weekly retry; 30 days empty: `rejected`. 401/403/bot challenge: `rejected` at once. Removal request or denylist: `rejected` and locked.
- As built (slice 7, migration 46): statuses are `discovered` (not yet probed), `probation` (the design's `trial`: one good UTC day), `enabled` (the design's `active`: good runs on two separate UTC days, enforced by the lifecycle and by a check constraint), `paused`, `rejected` and `needs_permission`. A good run is `ok` with at least 1 kept in-window item inside the region, a complete read and under 20% errors when the request count is known. The `feed_sources` row (`disc-<12 hex>`, `collector`, `discovery_status`, `candidate_id`) is created at probation, off, and switched only by `source_candidates_record`; the 40-per-region cap holds a third source at probation with reason `region_cap`. Rejection resets the good days. Member suggestions go to `review_status` pending and are never fetched before a moderator approves them; the rate limit is 5 a day (`place_rate_log` kind `calendar`, already covered by account deletion) and 500 pending in all. Service routes: `GET /collector/sources?regions=` (seeds for probation, enabled and retry-due paused sources), `POST /collector/sources/record` (the nightly run's per-source results), `GET /collector/candidates` and `POST /collector/candidates` (for the slice 8 probe). EU gate: `meta.eu_discovery` (off) keeps osm and wikidata candidates in the EU, EEA and UK out of the probe queue.

### 6.4 Quality gate

Before any region gets discovery: an Atlanta dry run must rediscover at least 6 of the 9 seeds that work today (6 are reachable via OSM: History Center, Kennesaw State via homepage link to `calendar.kennesaw.edu`, Marietta, Piedmont Park, Alliance Theatre, Botanical Garden). Then one German region as a dry run, with counts reported before any claim about Germany.

Expected yield (estimate, not measured): 10 to 20% of event-likely hosts produce events (many small venues post only on denylisted Facebook, Instagram, Eventbrite). Atlanta: about 45 to 90 sources vs 9 today.

As built (slice 8, migration 47, `packages/collector/src/discovery/`, `.github/workflows/discovery.yml`):

- **Candidates** from the tile rows the place files are built from (`GET /collector/tiles/{id}/rows`, no new `candidates/{tile}.json`), event-likely kinds only, one per host; Wikidata P856 of the OSM items (SPARQL `VALUES`, 50 ids a query, at most 5) and one `wikibase:around` query (25 km), through the collector's fetcher with the bot User-Agent. Hosts of hand-written seeds are left out of real runs (not of the gate). Cheap score: kind prior x 20, +10 Wikidata, +2 per extra place naming the host (up to 10), +10 when a place's website link is itself an events page.
- **Probe**: at most 8 requests a host, counting robots.txt and redirect hops (the shared fetcher's per-host allowance). The Events Calendar's root (from its `text/calendar` head link) and CivicPlus's `/iCalendar.aspx` are read instead of keyword pages; for The Events Calendar two of its single event pages are read first (exports and list views there often say noindex), and the source recorded is the calendar page. LibCal, Communico, Trumba and Google Calendar embeds are recognised; Localist is `needs_permission`. Results go to `source_candidates_record` with run id `probe-<run>`; the nightly collector run gives the second day.
- **Score** after the probe adds +50 feed with events, +30 platform, +40 for 3 or more JSON-LD events, -30 mostly outside the region; it is logged, the queue orders by the stored cheap score. Duplicates of hand-written seeds are left out rather than scored -20.
- **Gate**: enforced by the database for the probe code's hash (`source_discovery_gates`, `source_discovery_probe_queue` raises `discovery_gate_closed`), passing runs valid 30 days; run as a CI check on branch pushes and pull requests that change the collector. Kennesaw State counts as rediscovered as Localist (`needs_permission`): found, never read automatically.
- **Measured**, Atlanta from scratch, Nov 4, run 41927278244 (strict 8 requests): 16,694 tile rows in 3 of 12 tiles, 500 candidates, 150 probed in 630 s, 899 requests to 218 hosts; outcomes ok 23, needs_permission 3, empty 58, blocked 21, robots 16, noindex 13, error 9, no_feed 7. 26 calendars in 150 probed hosts (17%, inside the 10 to 20% estimate). Rediscovered 6 of 9: Botanical Garden, Marietta, Piedmont Park, History Center, Alliance Theatre, Kennesaw State (Localist). Not reachable from OSM or Wikidata: ArtsATL, Park Pride, the contra dance society (as predicted above). Earlier runs on the way: 4 of 9 (41915852882), 5 (41917834199), 6 with up to 14 requests a host (41919702551, not kept), 5 with the strict cap (41921780269, 41923667870, 41925467695).
- **Nightly on staging** (run 41928904496, Atlanta's collector region, 50 km): gate already open for the code, 500 candidates added (536 OSM hosts, 96 places on hand-written seed sites left out), 150 probed: 18 to probation (11 page, 7 ics; their `feed_sources` rows off until a second good day), 120 rejected (empty, no feed, noindex and robots retry in 30 days; 401/403 never), 2 needs_permission, 10 errors left discovered; 360 wait for the next nights at 150 a day.
- **EU**: the country list is in `data/discovery.json`; a region's country comes from its time zone (an unlisted `Europe/` zone or a missing zone counts as gated), and the database keeps its own list behind `meta.eu_discovery`. The German dry run stays slice 12.

---

## 7. Budgets and politeness

| Resource | Cap | Free limit |
|---|---|---|
| New place tiles | 50/day worldwide | |
| New event regions | 10/day | |
| Wanted tiles built | 12/night | |
| Geofabrik downloads | 6 files, 6 GB/night; 3 GB max file | "download responsibly" |
| Geoapify places | 500 credits/day, 20 requests/tile | 3,000 credits/day, 5 req/s |
| Ticketmaster | 1,000 calls/day | 5,000/day, 5 req/s (FAQ says 2 req/s; use 2) |
| Wikidata | 1 SPARQL + about 5 entity calls per region per day, serial | about 60 s query time per minute per agent (secondary source) |
| Discovery probes | 150 hosts/region/day, 8 requests/host/probe | |
| Collector run | 9-min deadline, 4 workers, 60 requests/host, 1 request per 2 s per host | D-040 |
| Events per region | 40 active discovered sources, 1,000 stored items in a 30-day window | |
| Database | 450 MB alarm; events about 6.7 KB a row incl. indexes, so about 6.5 MB a capped region | 500 MB |
| R2 | storage alarm at 5 GB | 10 GB, 1M writes, 10M reads/month |

Database arithmetic after the move to R2: 64 MB base + member data + events. At about 6.5 MB per capped region, about 60 active event regions fit before the 450 MB alarm; regions retire after 90 days without an active member, and the per-region item cap is enforced from day one. That, not places, becomes the binding database limit; the lever after that is shorter event windows or Supabase Pro.

Politeness carried from D-040: identifying User-Agent with contact URL, robots.txt, noindex, nofollow, conditional requests, denylist, "Request removal" on every item.

---

## 8. Privacy

- `place_tiles` and `collector_regions` hold a tile or a 0.1-degree point, a counter and day-rounded timestamps. No user id, no exact point, no join back to a profile.
- The per-person 24 h limit uses an owner-only timestamp on `profile_private`, not a log.
- A tile with demand 1 reveals that someone lives in a 56 x 35 km area. Tile and region rows are readable only by `service_role` and the collector secret; the client learns only "mapping in view: yes, reason" for tiles in view, never demand counts.
- Map panning never writes demand (abuse vector and interest leak).
- R2 / Cloudflare sees viewers' IPs and which tiles they fetch; add Cloudflare to the Privacy Policy processor list (same exposure OpenFreeMap already has). No cookies or auth on tile requests.
- Member calendar suggestions store the URL only.
- Public Actions logs print counts and pass/fail only; tile ids are not personal but are still not printed with demand counts.
- Sensitive hubs: candidate sources only from public institutions (D-041); worship places are excluded from discovery.

---

## 9. Founder accounts and settings needed

| # | What | Why | Without it |
|---|---|---|---|
| A | Set repo variable `PLACES_EXTRACT_SCHEDULE=production` (FOUNDER-TODO item 7) | Turns on the nightly places job | No new areas ever get places in production |
| B | **Cloudflare account** (free; probably asks for a card for R2), one R2 bucket `activity-planet-places`, a bucket-scoped API token. Either move `activityplanet.app` DNS to Cloudflare (needs the domain from item 1) for `places.activityplanet.app`, or let Claude deploy a tiny Worker on workers.dev | Static place tiles with free egress | Fall back to GitHub Pages (no card; fine to about 30k MAU; commercial-use terms caveat) |
| C | **Geoapify server key** `GEOAPIFY_SERVER_KEY` (item 5, same free account) | Places within minutes instead of next night | New areas wait up to one night |
| D | **Ticketmaster Discovery key** (item 20b) and **SeatGeek client id** | "Shows and games" row in any city | Row empty; feed relies on discovered sources |
| E | Allow hosts in the Claude cloud environment (item 14), adding `query.wikidata.org`, `www.wikidata.org`, `download.geofabrik.de`, `api.cloudflare.com` | Lets Claude verify sizes, terms and payloads instead of relying on search excerpts | Numbers stay estimates |
| F | Attorney question added to item 12: EU database right (Directive 96/9/EC Art. 7; CJEU Innoweb C-202/12, CV-Online C-762/19) for automatic discovery in the EU, and Ticketmaster's no-revenue clause | Gate for EU discovery and for monetisation | EU regions get lane 1, publisher feeds and member suggestions only |

The R2 token can live in the Supabase vault and be read by the Action through the Management API, like the collector secret, so no new GitHub secret is required (or store it as a GitHub secret if Sai prefers).

---

## 10. Build slices (in order, 1 to 3 days each)

| # | Slice | Days | Depends on |
|---|---|---|---|
| 1 | **Tile demand migration.** `place_tile_note_home` called from `collector_note_home_point`; upsert wanted/demand+1, retired to wanted, idle to active; edge neighbours; 50/day cap; backfill from existing homes; `place_tiles_mapping_in_view` returns a reason; banner copy for queued states. pgTAP tests. | 1 to 1.5 | none |
| 2 | **Nightly places schedule.** Daily cron, Sunday-only active refresh, per-night budget inputs, HEAD size guard, `timeout-minutes: 300`, queue grouped by extract; stamp `last_seen_at` without rewriting unchanged rows (back to about 1.0 KB a row while still in Postgres). | 1.5 | 1; Sai: A |
| 3 | **Tile file builder.** Extract script emits `{tile}.{hash}.json.gz`, manifest, `rules/v{n}.json`, `candidates/{tile}.json`; excludes hidden/removed ids; `finish_place_tile` stores hash, bytes, count. Uploads as an Actions artifact only (no R2 yet). | 2 | 2 |
| 4 | **Publish to R2 (or Pages fallback).** Upload step with bucket-scoped token, cache headers, CORS, `VITE_PLACES_BASE_URL`; delete files idle 180 days. | 1 | 3; Sai: B |
| 5 | **Client merge.** `map_in_view` returns overlay + tile list; client fetch/cache by hash, hub filter from rules file, overlay merge, place details from file; Atlanta served from both stores behind a flag; e2e tests. | 3 | 4 |
| 6 | **Collector ingest + regions endpoint.** Wire `import_upsert_batch` via collector secret; `GET /collector/regions?due=1`; timezone column filled by the job; nightly `collector.yml` running lane 2/3 for Atlanta seeds (ends dry-run-only). As built: migration 45, nightly `collector-ingest.yml` over due regions (5.3). | 2 | none (parallel to 3 to 5) |
| 7 | **Discovery data model.** `source_candidates`, `feed_sources.discovery_status` + `discovered_from`, `GET /collector/sources?regions=`, member "Suggest a calendar" form + RPC. | 1.5 | 6 |
| 8 | **Discovery probe.** Candidate builders (OSM website from `candidates/*.json`, Wikidata entity + SPARQL), probe, platform recognisers (TEC, Trumba, LibCal, CivicPlus, Communico, GCal), multilingual keywords, scoring, lifecycle. **Gate: Atlanta dry run rediscovers at least 6 of 9 seeds.** | 3 | 7; Sai: E helps |
| 9 | **Geoapify fill.** `places-fill` Edge Function, pg_cron + pg_net ping, budget in `collector_budget`, `osm_ref` merge. | 1.5 | 1; Sai: C |
| 10 | **Lane 1 by region.** Ticketmaster and SeatGeek by `latlong`/radius per due region, quota in `collector_budget`, `listing_kind='show'`. Test `countryCode=DE`. | 1.5 | 6; Sai: D |
| 11 | **Move venue matching, search and moderation lookups off Postgres**, then delete OSM rows from Postgres. | 2 | 5 |
| 12 | **German dry run and EU gate.** One German region end to end (places + discovery dry run), report counts; EU discovery flag stays off until F is answered. Update Privacy Policy processor list (Cloudflare). | 1 | 8, 5; Sai: F |

As built (slice 10, migration 48): Ticketmaster (`geoPoint` + `radius`, `locale=*`, no `countryCode`) and SeatGeek (`lat`/`lon`/`range`) run once per collector region a night inside `collector-ingest.yml`, as `listing_kind='show'` sources. Keys come from the repository secrets or, failing those, the Edge Function secrets of the project the regions come from (`GET /collector/api-keys`); with neither the lane asks nothing. Calls are taken per run from `collector_budget` (`ticketmaster_calls`, `seatgeek_calls`, 1,000 a UTC day each; `POST /collector/api-budget`, unsent calls back through `/api-budget/return`); regions past the budget wait a night with no batch. Shows link out as "Tickets on <seller>" with the seller's credit linking to its homepage, never store images, and are cancelled as no longer listed when not refreshed for 3 days (`collector_api_shows_sweep`, pg_cron daily; raw items cleared a week after the show). `countryCode=DE` was not tested: there is no key yet, and the query is by point and radius, so a German region needs nothing else; the first keyed run reports the German counts.

As built (slice 12, no migration; `region-trial.yml`, `scripts/places/region_trial.py`): Leipzig end to end on staging, Nov 5. A home save at 51.34 N, 12.37 E through `collector_note_home_point` (no user id) added the 25 km event region and tiles 203424 (wanted, demand 1) and 203425 (the edge neighbour within 10 km, demand 0); the region's other neighbours are more than 10 km away. The places run (41940393179, 4 min 40 s) took Geofabrik Sachsen, Sachsen-Anhalt and Thüringen (606,767,185 bytes in all, every one under the 3 GB cap) and posted 10,192 and 4,748 rows (192,883 and 74,012 features read); the places table grew from 29.6 MB to 38.9 MB (about 620 bytes a row with indexes) and the database from 71.9 MB to 81.2 MB. The files run (41941162245) wrote 414,562 bytes (10,191 rows, 40.7 bytes a row) and 156,456 bytes (4,748 rows, 33.0 bytes a row), so Germany's estimate in 4.2 (about 37 bytes a row) holds. Signed out, map_in_view gives the same places from Postgres and from the files in every view and hub chip tried (800 of 800 in the city centre and across the city; basketball 25 and 92, board game night 36 and 72, bouldering 4 and 8, rock climbing 4 and 7), read through the app's own `loadMapView` from the built files (region-trial run 41941382473). The collector run (41940463950) gave the region the zone Europe/Berlin with 0 sources and 0 items: no city file covers it, discovery is gated, and Shows ran nothing because no Ticketmaster or SeatGeek key exists. The discovery run (41941337782) counted the region as `eu_gated` and added no candidates. So a member in Leipzig sees a full map and an empty feed (no plans yet, no imported events, no shows row) until the attorney answers F, a key exists, or members suggest calendars.

Total about 21 to 23 build days. A German member gets a working map after slices 1, 2 and 9 (or 1 and 2 with a one-night wait), still from Postgres, within about 4 days of work; slices 3 to 5 are what keep it free once many cities exist. Events in Germany need 6 to 8 plus 12.

---

## 11. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| Postgres places cap hit before R2 move (about 4 Atlanta-size metros at 1.6 KB a row) | High if many cities sign up early | Slice 2 row-stamping fix; 50 tiles/day cap; slices 3 to 5 next |
| Cloudflare needs a card or DNS move Sai does not want | Medium | workers.dev Worker (no DNS move) or GitHub Pages fallback, same layout |
| Germany or other dense tiles over 3 MB | Low to medium | Split to 0.25-degree subtiles; PMTiles later |
| Geofabrik extract too big (countries without subregions) or blocked/slow | Medium | HEAD guard, `extract_too_big` reason shown in UI, per-night download cap |
| Low discovery yield (Facebook-only venues) | High in small towns | Member suggestions, lane 1, "post the first plan" empty state; never fake coverage |
| EU database right exposure | Medium | EU auto-discovery gated on attorney read; prefer publisher-offered feeds; short excerpts; removal path |
| Ticketmaster thin in Germany; terms forbid revenue from API | Medium | Treat as bonus; attorney item; Eventim has no free API (not checked) |
| Event rows fill the database (about 6.5 MB per region) | Medium after about 60 regions | Per-region item cap, 90-day retirement, shorter window; Pro plan is the paid lever |
| GitHub pauses scheduled workflows after 60 days of no repo activity | Medium | keepalive workflow, admin health panel |
| Demand counters revealing a lone member's rough area | Low | No user ids, service-role only, client sees only a boolean + reason |
| Abuse: fake homes to trigger crawling of chosen areas | Low | 24 h per person limit, 50 tiles/day global cap, demand-ordered queue |
| Wikidata or Geoapify terms/limits differ from search excerpts | Medium | Re-read live terms when hosts are allowed (item E) and when keys are created |
| Timezone wrong near borders | Low | Offline tz boundary lookup per region point |

## Sources

All external facts come from search excerpts because the container blocks most hosts; re-verify once FOUNDER-TODO item 14 hosts are allowed.

- Supabase pricing https://supabase.com/pricing.md ; Smart CDN https://supabase.com/docs/guides/storage/cdn/smart-cdn.md
- Cloudflare R2 pricing https://developers.cloudflare.com/r2/pricing ; limits https://developers.cloudflare.com/r2/platform/limits
- GitHub Pages limits https://docs.github.com/en/pages/getting-started-with-github-pages/github-pages-limits
- GitHub-hosted runners https://docs.github.com/en/actions/reference/runners/github-hosted-runners ; cache size https://github.blog/changelog/2025-11-20-github-actions-cache-size-can-now-exceed-10-gb-per-repository/
- Geofabrik NRW page https://download.geofabrik.de/europe/germany/nordrhein-westfalen.html
- Geoapify pricing https://geoapify.com/pricing ; storage terms (third party) https://openplacesapi.com/blog/can-you-store-places-api-results
- Ticketmaster getting started https://developer.ticketmaster.com/products-and-docs/apis/getting-started/ ; terms https://developer.ticketmaster.com/support/terms-of-use/
- Wikidata User-Agent policy https://phabricator.wikimedia.org/T402959
- German Tourism Knowledge Graph https://arxiv.org/html/2404.09587v1
- Database Directive Art. 7 https://www.legislation.gov.uk/eudr/1996/9/article/7/data.htm ; Innoweb C-202/12 https://eulawradar.com/case-c-20212-innoweb-search-engines-copying-insubstantial-parts-of-a-website/ ; CV-Online C-762/19 https://www.ippt.eu/sites/ippt/files/2021/IPPT20210603_CJEU_CV-Online_Latvia_v_Melons.pdf

Repo files: `supabase/migrations/20261120000100_location_region_limits.sql`, `20261122000100_places_schema.sql`, `20261124000100_places_read.sql`, `20261129000100_places_lifecycle_odbl.sql`, `20261130000100_places_review_fixes.sql`, `20261201000100_collector_events_ingest.sql`; `.github/workflows/places-extract.yml`; `scripts/places/extract_places.py`, `regions.json`, `filters.txt`; `packages/collector/data/cities/atl.json`; `apps/app/src/routes/map.tsx`; `docs/design/hub-map/HUB_MAP_DESIGN.md`; `docs/design/collector.md`.
