# Hub map: buildable design

Status: accepted as D-041 on 2026-11-03, with the founder's answers to section 12 folded into `docs/DECISIONS.md`. Written as a proposal on 2026-11-03 and moved into the repo on 2026-11-04 (hub map slices 1 and 2); the sections below are the proposal as written, except for the notes marked "Slice 2". The inputs are three research passes:
- `scripts/places/hub_place_rules.json`: the mapping from each of the 612 hubs to place types, built from `scripts/places/rules/rules.txt` by `scripts/places/build_rules_json.py`.
- `docs/design/hub-map/places_map_draft.sql` (this folder): draft SQL, written but never run. Slice 3 writes the real migration.
- The sources and licensing research, summarised in sections 3 and 8.

**Slice 2 notes (2026-11-04).** `scripts/places/gen_place_rules.py` turns the JSON into `supabase/seed/place_rules.sql` and `scripts/places/filters.txt`; CI (`place-rules` in `ci.yml`) rebuilds both and fails on a difference. Measured counts and the taginfo result are in `scripts/places/rules_stats.json` and D-041. Three changes from the proposal:
- A rule is one base tag plus its extra conditions, so "leisure=pitch|sports_centre&sport=basketball" is two rules shared by every hub that uses them. Rule ids are kept stable in `scripts/places/rule_ids.json` (append-only), and `rules_version` goes up whenever the generated set changes.
- Specificity is a property of the hub, not the rule: the same tag (`amenity=library`) is specific for one hub and generic for another. The seed sets `hubs.place_mode` and keeps no `specificity` column on `place_rules`; `map_in_view` reads the rule set from the hubs' `place_mode`.
- Geoapify categories are per hub in the research, so the seed writes them to `hubs.geoapify_categories` rather than to `place_rules.geoapify`. Display kinds (47, label and lucide icon) and the base-tag-to-kind map are in `scripts/places/place_kinds.json`.

External facts come from search-result excerpts, because the container blocks wiki.openstreetmap.org, overpass-api.de, osmfoundation.org, geoapify.com and download.geofabrik.de. Every one of them is marked "re-check" in section 11.

The goal, in the founder's words: anyone downloads the app, sets a location, joins hubs, and sees a Google-Maps-like map of nearby places for **their** hubs. Someone in the anime and basketball hubs sees courts, anime and comic stores, and club meeting spots, plus the events happening at them, with the information collected automatically from free sources.

---

## 1. Decision text (ready to paste as D-041)

> ## D-041 — Hub map: places for your hubs, from OpenStreetMap plus members; "Shows and games" row (Sai's decision, 2026-11-03)
> Sai, Nov 3: the map comes before messaging. Each person sees places to take part in the hubs they joined (courts for basketball, anime and comic stores and club meeting spots for anime), plus plans and events, anywhere in the world.
>
> **Places sources.** (1) OpenStreetMap, from Geofabrik regional extracts filtered with osmium in a scheduled GitHub Action, never from Overpass or Nominatim in production or from clients (D-038). (2) Places members add or correct, reviewed by a moderator before anyone else sees them. (3) Geoapify Places on its free tier, server-side only, to fill a new region before the weekly extract has run there, and only when the key exists. (4) Public venues where public plans were hosted, which become "meeting spots" for that hub. No Google Places and no paid APIs (D-024).
>
> **Hub matching.** A versioned rule table maps each hub to OSM tag rules (529 rules over 81 base tags). Rules marked *specific* (a basketball court, an anime shop) show under "All my hubs". Rules marked *generic* (a park, a library, a café) show only when that one hub's chip is selected, and are labelled "General spot". 42 hubs have no places (events or online only), and their chip says so.
>
> **Shows and games.** Ticketed events (Ticketmaster, SeatGeek and similar) get `listing_kind = 'show'` and appear in their own "Shows and games" row and map layer, separate from plans. This replaces D-039's 2026-11-03 note that put them inside the imported shelf.
>
> **Navigation.** Map takes the Chats slot in the five-tab bar until messaging ships. Chats then moves to a top-bar icon beside the inbox bell.
>
> **Privacy.** D-038 stands: private addresses are never pinned, and approved-only events appear only as their 0.1-degree cell. A member-added place is private by default. A public request within 150 m of the member's saved home point, or within 50 m of one of their private venues, is refused. Places for sensitive hubs (faith, LGBTQ+, wellness) come only from public institutions, and the app never shows or stores who saved or viewed a place. The demand signal that triggers a new region is a counter per 0.5-degree tile with no user id.
>
> **Licence.** The places table is an ODbL derivative database. The map shows "© OpenStreetMap contributors" without a tap. Place facts members contribute are published under ODbL (stated in the Terms). A monthly ODbL dump of public place facts, with no user ids, is attached to a GitHub release.
>
> **Budget.** Places are capped at 150 MB of the 500 MB Supabase Free database. Regions with no active member for 90 days are retired. If the cap is reached, the fallback is per-region static files (section 9).
>
> Considered: Google Places (paid, and its terms forbid storing results); Overpass at runtime (the public server asks regular users for under 100 queries and 10 MB a day, and one metro query is 5 to 15 MB); self-hosted Overpass (needs a server that runs all the time); OpenTripMap (non-commercial free plan, and it is OSM plus Wikidata anyway); member places shown before review (doxxing and spam risk); a separate places table per source (the ODbL guidance treats gap-filling non-OSM items as part of the derivative anyway, so separation buys nothing legally, and one table with a `source` column keeps the data separable). Amends D-038 (places layer scope) and D-039's 2026-11-03 note.

---

## 2. End-to-end flow

```
member sets home point (owner-only, about 1 km)  ──► bump place_tiles.demand (0.5° tile, no user id)
                                                          │
                     nightly GitHub Action ◄──────────────┘ (tiles where status = 'wanted')
          Geofabrik extract ► osmium tags-filter ► osmium extract -b tile+margin ► export points
                                    │  NDJSON batches (≤ 2,000 rows)
                                    ▼
                 collector ingest path (D-040, collector secret only) ► ingest_places(batch)
                                    │
     Geoapify fill (Edge Function, pg_cron, ≤ 500 credits a day) ─┘ for tiles still 'wanted'
                                    ▼
   places (+ rule_ids) ── place_rules ── hub_place_rules ── hubs      place_hubs (member/event links)
                                    ▼
             map_in_view(bbox, hubs, layers, window)  ◄── app /map (MapLibre + list panel)
```

---

## 3. Data pipeline

### 3.1 OSM extract job (`.github/workflows/places-extract.yml`)
- **Schedule:** nightly at 03:17 UTC for tiles with status `wanted`, and weekly on Sunday to refresh `active` tiles. It can also be started by hand with `workflow_dispatch`. A stale-source check covers GitHub's 60-day pause on scheduled workflows (D-040).
- **Runner:** ubuntu-latest, which for a public repo gives 4 vCPU, 16 GB RAM and 14 GB disk with unlimited free minutes (GitHub docs, per search excerpt). The job first frees disk with a free-disk-space step.
- **Steps for each tile:**
  1. Fetch the tiles queue with `GET /collector/tiles?status=wanted,refresh` on the collector path. It returns tile ids and bounding boxes, never user data.
  2. Pick the smallest Geofabrik extract whose polygon contains the tile centre, using `index-v1.json`. Skip continent and whole-US files: the planet is about 87 GB and the whole-US file about 11 GB. If a tile straddles two extracts, take both.
  3. Download into `actions/cache`, keyed by `<extract>-<ISO week>`, so each extract is fetched at most once a week (Geofabrik's 2025 "download responsibly" request). Set a User-Agent of `ActivityPlanet-places/1 (+repo URL)`.
  4. Run `osmium tags-filter extract.pbf --expressions=filters.txt -o f.pbf`. `filters.txt` is generated from `place_rules` (section 4) and only base `key=value` pairs go in it; the finer conditions are applied in step 6.
  5. Run `osmium extract -b <tile bbox + 2 km> f.pbf -o t.pbf`, then `osmium export t.pbf -f geojsonseq --geometry-types=point,polygon`.
  6. A Python script, run with `-I`, does the rest:
     - Reduces each polygon to an interior point (`shapely` `representative_point`).
     - Drops `access=private|no`, unnamed pitches inside `landuse=residential`, anything tagged `building=house|residential|apartments`, and nodes that have `addr:*` but no POI tag.
     - Evaluates every rule, including the `extra_tags` conditions and the semicolon-separated `sport` lists ("contains", not "equals"), and gives each place its `rule_ids`.
     - Keeps the allowlisted tags only (§4.3).
  7. POST the result to `/collector/ingest/places` in batches of 2,000 or fewer, with an `X-Collector-Secret` header. The Edge Function calls `ingest_places(tile_id, run_id, batch)` as service_role. The workflow never holds the service-role key (D-040).
  8. Finish with `POST /collector/tiles/{id}/done {run_id, count}`. The RPC marks rows from this tile that are missing from 2 consecutive runs as `closed`.
- **Checks:** fail the run when a refresh tile's row count drops by more than 30% from the previous run. This guards against osmium filtering problems (the 2019 dev-list report) and broken extracts.
- **Cost:** about 2 to 10 minutes a tile (an estimate). 20 tiles fit well inside the 6-hour job limit.
- **As built (slice 5, `scripts/places/extract_places.py`):** the whole Atlanta run takes about 2.5 minutes with the extract cached (download 3 minutes when it is not). Differences from the steps above: lines are kept too (a named path becomes its midpoint, one row per name in a 2 km cell); every row goes to its own tile only and rows in the 2 km margin are dropped, so each element is posted once; unnamed courts, pools, tracks, playgrounds and similar facilities are kept with a made-up name ("Tennis court at Grant Park") unless they sit inside `landuse=residential`; the same name and kind within 150 m collapse into one row. Route relations (`route=hiking|mtb|…`) are not exported by `osmium export` and so add no rows yet. The job reads the collector secret from the target project's vault through the Management API (the token `migrate.yml` already uses) and masks it, so no new GitHub secret is needed. Named tiles that are not `wanted` or due a refresh are skipped unless `force` is set. Staging gets a dispatch from any branch but main (or a push of `scripts/places/extract_request.json`, since dispatch only works once the file is on main); production needs a dispatch from main with `production` typed in; the weekly schedule (Sunday 03:17 UTC) does nothing unless the variable `PLACES_EXTRACT_SCHEDULE` is `production`.

### 3.2 Geoapify gap fill (Edge Function `places-fill`, pg_cron every 15 min)
- Runs only when `GEOAPIFY_SERVER_KEY` is set. This is a separate server-side key; `VITE_GEOAPIFY_KEY` stays a browser geocoding key.
- Takes tiles that are `wanted` and have no OSM run yet, highest demand first. For each tile it calls `GET /v2/places?categories=<specific categories from rules>&filter=rect:...&limit=...`, paging until done or the tile's cap of 20 requests is used up.
- Geoapify categories don't carry the sport, so it post-filters on `datasource.raw.sport` / `raw.*` tags (taxonomy note). It stores rows with `source='geoapify'`, plus `osm_ref` when `datasource.raw.osm_id` is present, so the OSM run later merges into the same row instead of duplicating it.
- Daily cap: 500 credits for places (a counter in `collector_budget`). That leaves about 2,500 of the free 3,000 a day for geocoding (D-040). Pricing and the "Limited Commercial Use" wording need re-checking.
- The free plan requires "Powered by Geoapify". The app shows it while any `source='geoapify'` place is on screen.

### 3.3 Meeting spots from plans
An `after insert or update` trigger on `events` runs when a published, public-visibility event sits at a venue with `is_public = true`:
- It upserts `places(source='venue', source_id=venue_id)` and links `place_hubs(via='events', weight = count of public plans in the last 180 days)`.
- Private venues and approved-only events never create places.

### 3.4 Other sources (later, quarterly)
- Wikidata (CC0): website and Wikipedia links for museums, libraries and universities, matched by the OSM `wikidata` tag. Respect its limits (5 parallel queries, a real User-Agent).
- City open data (courts, parks): only datasets that are public domain, CC0 or ODbL-compatible. Skip anything with an unstated licence. Atlanta has no courts layer found yet.
- Never: Overpass in production, OpenTripMap, Google Places, or any login-walled or terms-forbidden site (D-040 never list).

### 3.5 Region lifecycle (`place_tiles`)
| status | meaning | moved by |
|---|---|---|
| `wanted` | demand ≥ 1 and no data yet | home point set, or `map_in_view` on an empty tile (rate-limited) |
| `filling` | Geoapify rows only | `places-fill` |
| `active` | an OSM run is done | extract job |
| `idle` | no active member's home in the tile for 90 days | nightly `retire_place_tiles()` |
| `retired` | OSM and Geoapify rows deleted; member, venue and corrected rows kept | same job, 7 days after `idle` |

The tile is 0.5° × 0.5°, about 55 × 45 km at Atlanta's latitude. The draft SQL's 0.1° `place_coverage` is too fine for extract jobs, so it becomes `place_tiles` (§4). Atlanta's two or three tiles are seeded `active` by hand so the founder's outreach city is never empty.

---

## 4. Schema (changes from `places_map_draft.sql`)

### 4.1 Rule tables (replace the draft's `place_kinds` + `kind_hubs`)
```sql
create table public.place_kinds (           -- about 40 display kinds: icon and label only
  slug text primary key, label text not null, icon text not null, sort smallint not null default 100
);
create table public.place_rules (           -- 529 rules, generated from hub_place_rules.json
  id smallint primary key,
  osm_key text not null, osm_value text,    -- null value = key present
  extra jsonb not null default '{}',        -- {"sport":["basketball"]}: any of the listed values
  osm_type text check (osm_type in ('nwr','relation')) default 'nwr',
  kind text not null references public.place_kinds,
  specificity text not null check (specificity in ('specific','generic')),
  geoapify text[] not null default '{}',
  verified boolean not null default false,
  rules_version int not null
);
create table public.hub_place_rules (
  hub_id uuid references public.hubs on delete cascade,
  rule_id smallint references public.place_rules on delete cascade,
  primary key (hub_id, rule_id)
);
create index on public.hub_place_rules (rule_id);
alter table public.hubs add column place_mode text not null default 'specific'
  check (place_mode in ('specific','generic','none'));   -- from place_specificity
```
The rules are evaluated **at ingest**, and each place stores `rule_ids smallint[]`. This means:
- One basketball court row serves basketball, streetball and pickup hubs without fanning out into `place_hubs` rows.
- A park, which matches about 50 generic hubs, costs about 4 bytes per rule instead of 50 link rows.
- When the rules change, `rules_version` goes up and the extract job re-evaluates `rule_ids`, because it holds the raw allowlisted tags.

### 4.2 `places` (the draft as written, plus `rule_ids` and `tile_id`)
Columns:
- `id uuid`, `source` (`osm|geoapify|user|venue`), `source_id`, `osm_ref` (e.g. `n123`/`w456`).
- `name`, `kind`, `rule_ids smallint[] not null default '{}'`.
- `location geography(Point)` and `geom geometry(Point,4326)` (stored, generated).
- `tile_id int`, `address_text`, `locality`, `country`, `opening_hours`, `website`, `tags jsonb` (allowlist).
- `is_public`, `status` (`active|pending|hidden|closed|removed`), `locked_fields text[]`.
- `created_by`, `attribution`, `license` (`ODbL-1.0`), `last_seen_at`, `merged_into`, `search_text` (generated).

Constraints:
- `unique (source, source_id)`.
- Partial unique index on `osm_ref` where it is not null.
- `check (is_public or source = 'user')`.
- `check (license = 'ODbL-1.0')`. All public place facts are ODbL, members' included (Terms, §8).

Indexes:
- GiST on `geom` where `status='active' and is_public`, and a full GiST for own pins, moderators and dedupe.
- **GIN on `rule_ids`** (`gin__int_ops` is not needed for smallint[]; the default `array_ops` works).
- Trigram index on `search_text`, the queue index, and `(tile_id, source, last_seen_at)` for retirement.

### 4.3 Tag allowlist kept in `tags`
`sport`, `religion`, `denomination`, `lgbtq`, `access`, `fee`, `lit`, `indoor`, `surface`, `hoops`, `wheelchair`, `wikidata`, `phone` (public businesses only), `brand`. Everything else is dropped. That keeps rows small, and no contributor data from OSM is stored.

### 4.4 Other tables (kept from the draft)
- `place_hubs (place_id, hub_id, via text check in ('member','moderator','events'), weight int)`, used only for explicit links. The OSM links live in `rule_ids`.
- `venues.place_ref uuid references places`.
- `events.listing_kind text not null default 'plan' check in ('plan','show')`, plus the same column on `feed_sources`. The importer copies it from the source.
- A GiST index on `(approx_point::geometry)` where the event is published.
- `place_edits`, `place_reports` and the moderation RPCs, as in the draft.
- `place_tiles (id int primary key, bbox box2d, status, demand int, osm_run_at, geoapify_run_at, last_member_at, row_count int)`. It has **no user id column**.
- `collector_budget (day date, source text, used int)`.

### 4.5 Size (measured on staging, 2026-11-04)
First Atlanta run: `places-extract.yml` runs 41832976451 (first ingest) and 41834781651 (forced refresh), Geofabrik `us/georgia` of 2026-11-04, rules_version 1, Atlanta's three tiles 178030, 178031 and 178751 (lat 33.5 to 34.5, lng -85 to -84).

| Measure | Value |
|---|---|
| Georgia extract | 358 MB `.osm.pbf`; 62.6 MB after `osmium tags-filter`; 17.5 MB for the tiles' box plus 2 km |
| Features exported | 370,933 points, lines and polygons (most match no rule or are dropped below) |
| Rows kept | **16,693** one per OSM element: 3,322 / 9,119 / 4,252 per tile |
| Biggest kinds | restaurant 3,027, court_field 2,331, worship 1,848, park 1,682, historic 1,426, shop 1,363, cafe 737, beach 704 (named `natural=water`), trail 415 |
| Unnamed facilities given a name ("Tennis court at …") | about 2,100 |
| Dropped | 29,565 unnamed lines, 20,041 unnamed non-facilities, 18,293 outside the tiles (the 2 km margin), 9,221 same name and kind within 150 m, 5,336 `access=private|no`, 4,021 unnamed facilities inside `landuse=residential`, 1,436 merged path segments, 626 unnamed non-public pools, 190 homes |
| Payload | 3.9 MB of JSON, 17 batches of up to 1,000 rows; ingest took about 70 s the first time and 30 s on a refresh |
| Table after the first ingest | 17.0 MB `pg_total_relation_size('places')`: heap 7.3 MB, indexes 9.7 MB, so **about 1.0 KB a row** |
| Table after one refresh | 26.5 MB: heap 13.3 MB (every row is re-stamped, so the heap holds a second version until vacuum reuses the space), indexes 13.1 MB, so **about 1.6 KB a row at steady state** |
| Largest index | trigram on `search_text`, 6.2 MB; the two GiST indexes 1.3 MB each, GIN on `rule_ids` 0.5 MB |
| Staging database | 39.3 MB before, 56.1 MB after the first run, 65.6 MB after the refresh |

What this means:
- **A large metro is about 17k rows and 17 to 27 MB**, at the low end of the estimate above (25k to 35k rows), because unnamed POIs, private access, homes and near duplicates are dropped before ingest.
- **The 150 MB cap holds about four metros of Atlanta's size** at the steady-state 1.6 KB a row, with the rest of the database at about 40 MB. That is fewer than the "5 large metros plus 10 to 15 cities" estimated earlier.
- **Levers, in order:** (1) stamp `last_seen_at` without rewriting unchanged rows (a separate `place_seen` table or a per-tile run stamp), which removes the second heap version and brings the steady state back to about 1.0 KB a row; (2) drop or shrink the trigram index (6.2 MB, the largest) in favour of a prefix search; (3) skip generic `amenity=restaurant|fast_food|cafe|bar|pub` (about 4,000 of Atlanta's rows) and fetch them from Geoapify on demand; (4) the static-file fallback in §9.
- The job's size check refuses to post when the database plus 1.6 KB per row it is about to send would pass 150 MB. Slice 15's size alarm at 120 MB still applies.

---

## 5. RPCs

| RPC | security | who | purpose |
|---|---|---|---|
| `map_in_view(west,south,east,north, hub_ids uuid[] default null, layers text[] default '{places,plans,shows}', from timestamptz default now(), to timestamptz default now()+7d, generic boolean default false)` | invoker | anon, authenticated | Returns one compact jsonb with `places`, `plans`, `shows`, `cells` and `truncated`/`zoom_in` flags |
| `places_in_view(...)` | invoker | same | Places only (used by the list at high zoom and by search) |
| `place_detail(id)` | invoker | same | Card data, `plans_here` (through `venues.place_ref`) and source line |
| `add_place(name, kind, lat, lng, hub_ids, public boolean, website, hours)` | definer | onboarded users | Applies the §7 rules and returns `{id,status}` or an error (`near_your_home`, `near_private_venue`, `duplicate_candidates`, `rate_limited`) |
| `suggest_place_edit(place_id, changes jsonb)` / `report_place(place_id, reason, note)` | definer | onboarded users | Allowlisted fields; one open report per person per place |
| `mod_place_queue()` / `mod_resolve_place(item, action)` | definer | moderators | Approving an edit to an imported row adds those fields to `locked_fields` |
| `ingest_places(tile_id, run_id, batch jsonb)` / `finish_place_tile(...)` | definer | **service_role only** | Upserts by `(source,source_id)`, merges on `osm_ref`, skips locked fields, never touches `source='user'` rows |
| `bump_place_tile(lat,lng)` | definer | trigger on `profile_private` home update + `map_in_view` | Increments demand. No user id. At most once per tile per minute per call path |
| `retire_place_tiles()` | definer | pg_cron | Runs the lifecycle in §3.5 |

`map_in_view` rules:
- **Size limits:** a bbox larger than 1.0° lat × 1.5° lng returns `zoom_in` for places, while plans and shows still come back up to 300.
- **Antimeridian:** a bbox that crosses 180° is split into two.
- **Places:** at most 800 by default and 1,500 at most. With more than 50 hubs, or more than 800 places, `truncated` is set.
- **Hub filter:**
  - `hub_ids` null means the viewer's joined hubs, or none for anon. Anon must pass hubs explicitly.
  - Rule set = `hub_place_rules` for those hubs where `place_rules.specificity='specific'`, or all rules when `generic` is set and exactly one hub is selected.
  - A place matches if `rule_ids && rule_set`, or it has a `place_hubs` row for one of those hubs.
- **Plans:** exact point only when the venue is public. Approved-only events come back as `cells: [{cell, n, ids}]` and never as points (D-038).
- **Window:** capped at 31 days.
- **Response:** each feature is `[id, lng, lat, kind_or_type, hub_id_primary, flags]`, an array and not an object, so 1,000 features fit in about 60 KB gzip or less.

**Slice 6 notes (2026-11-04, as built).** Migrations 29 (`20261124000100_places_read.sql`) and 30 (`20261124000200_places_read_fixes.sql`); tests `supabase/tests/places_read.sql`; timings `supabase/tests/places_read_perf.sql`; decoder `@ap/core/map`. Changes from the table above:
- **Encoding.** A place is `[id, lng, lat, kind, hub_idx, flags, name, hub_idxs]` and a plan or show is `[id, lng, lat, kind, hub_idx, flags, title, starts_at]` (unix seconds). The name and title are there so the list panel needs no second request. `hub_idx` points into the response's `hubs` list (`[id, slug, name, emoji, place_mode]`: the selected hubs first, then the other hubs the events are in), and `hub_idxs` lists every selected hub a place matches, so chip filtering stays on the client (§7 rule 6). Place flags: 1 general spot, 2 pending, 4 private, 8 member-added, 16 meeting spot, 32 Geoapify, 64 mine. Event flags: 1 imported, 2 in a selected hub, 4 free, 8 21+. Cells are `[lng, lat, n, ids, hub_idxs]`. Coordinates are rounded to 5 decimals (about 1 m).
- **Flags.** `truncated` is a boolean, and `more` says which part was cut: places, hubs, plans, shows or cells. `no_hubs` means a signed-in person with no joined hubs; `generic` means one generic hub's general spots are shown.
- **Signed out.** No hubs passed means every specific hub (D-041). Generic spots still need one hub plus `generic`.
- **Order.** Own pins come first, then the places nearest the bbox centre in planar degrees, read in that order from the GiST index (KNN). Across the antimeridian, each half is measured from its own copy of the centre.
- **place_detail** returns hubs as objects (`general`, `joined`; up to 12, joined first) and `plans_here` (up to 20, public addresses at a public venue only). It never returns who added a place.
- **Measured on staging** (run 41842887246, the 16,694 Atlanta places and 207 events in the next 7 days; database time, 30 warm runs; PostgREST and the network add to this):

| Scenario | p95 | Returned |
|---|---|---|
| Signed out, downtown 0.2 x 0.15 degrees | 46.7 ms | 800 places (cut), 173 plans |
| Signed out, 1.0 x 1.5 degrees | 35.3 ms | 800 places, 215 plans |
| Signed out, 1.0 x 1.5 degrees, cap 1,500 | 57.2 ms | 1,500 places |
| 5 joined hubs, downtown / 1.0 x 1.5 | 45.0 / 71.7 ms | 800 places |
| 50 hubs passed, 1.0 x 1.5 | 77.3 ms | 800 places, 73 hubs |
| One generic hub with generic set, downtown | 40.2 ms | 800 places |
| Name search "park", 1.0 x 1.5 | 43.0 ms | 800 places |
| 3 x 3 degrees (zoom_in, events only) | 8.8 ms | 215 plans |
| place_detail | 3.0 ms | 1 card |

  Payload: about 115 to 120 KB raw for 800 places plus about 200 plans, and 68 to 72 KB per 1,000 features compressed with lz4 inside the database. gzip on the same encoding (measured locally on synthetic Atlanta-like rows) is about 0.62 of the lz4 size, so about 42 to 45 KB per 1,000 features, under the 60 KB budget.
- **Fixed on the way:** migration 29 probed `place_hubs` once per (picked place, hub) pair. For a signed-out view (437 specific hubs) that cost about 150 microseconds per place, giving p95 135 ms downtown and 246 ms at 1,500 (run 41841317042). Migration 30 looks the links up by place id only.

---

## 6. RLS (from the draft, unchanged in substance)
- `places`: select when `(status='active' and is_public)`, or `created_by = auth.uid()`, or `is_moderator()`. No insert, update or delete policies; every write goes through the definer RPCs.
- `place_hubs`: visible when its place is visible. Rows with `via='member'` for **sensitive hubs** are never created (§7).
- `place_rules`, `hub_place_rules`, `place_kinds`: read for anon and authenticated, write for moderators only.
- `place_edits`, `place_reports`: author or moderator.
- `place_tiles`, `collector_budget`: moderators read; writes by service_role and definer RPCs only.
- Tests: pgTAP cases for each item above, plus "anon can't see pending", "creator sees own private pin", "member can't flip `is_public` without the RPC", "approved-only event never returns a point from any RPC".

---

## 7. Privacy rules (all enforced server-side)
1. New member places are **private** (only their creator sees them). "Everyone" sends them to `pending` behind a confirmation checkbox: "This is a public place, not a home or private residence."
2. A public request within **150 m of the member's saved home point**, or **50 m of any of their private venues**, is refused with `near_your_home` and a clear explanation.
3. A pending place is visible only to its creator, as a dashed pin, until a moderator approves it.
4. A report with reason `private_residence` or `unsafe` hides a member-added or venue place immediately. Three open reports from different accounts hide any place.
5. Private venues and approved-only events never become places or points. The extract drops `access=private` and residential-use objects.
6. **Sensitive hubs** (21: faith, LGBTQ+, wellness and similar):
   - Their places come only from rules on public institutions (`amenity=place_of_worship` plus `religion`, `lgbtq=primary`, community centres).
   - No member-added links, no "N members go here", and no saved-place lists that others can see.
   - Their chip filters run on the client from the already-fetched `rule_ids` where possible, so the server does not see which sensitive hub chip was tapped. A request from "All my hubs" sends every joined hub together.
7. **No viewing logs:**
   - `map_in_view` stores no bbox or user id. Only `bump_place_tile` increments a counter.
   - API logs at Supabase keep the standard retention, which goes in the Privacy Policy.
8. **Flagged no-pin hubs** (hunting, knife-collecting, cliff-diving, spearfishing) are set to `place_mode='none'`: the founder confirmed on 2026-11-03 that they stay events-only (question 3). Alcohol and gambling hubs show places with a "21+ at venue" note.
9. **Rate limits:** 10 new places, 30 edits and 20 reports per person a day. Finished onboarding is required.
10. **Directions** hand off to the device's own maps app through a URL, so no location is sent to us.

---

## 8. ODbL and attribution checklist
- The map corner shows "© OpenStreetMap contributors" (a link to openstreetmap.org/copyright), "OpenMapTiles" and "OpenFreeMap". It is visible without a tap (OSMF attribution guideline, 2021). "Powered by Geoapify" appears while Geoapify rows are on screen.
- The place sheet shows a source line: "From OpenStreetMap · checked 3 days ago", "Added by a member · reviewed", or "From Geoapify (OpenStreetMap data)". OSM places link "Improve it on OpenStreetMap".
- **Terms:** facts members contribute about places (name, point, kind, hours, website) are licensed under ODbL 1.0 and may be republished.
- **Monthly release:** `places-YYYY-MM.ndjson.gz` (public, active rows: `source, osm_ref, name, kind, lat, lng, tags, opening_hours, website`, with no ids or user data) is attached to a GitHub release under ODbL with a README. It is produced by a GitHub Action from a service_role-free export view through the collector path.
- No automatic uploads to OSM: the import guidelines and user consent both stand in the way.
- Attorney review list (FOUNDER-TODO): ODbL share-alike scope, and Geoapify's "Limited Commercial Use" wording.

---

## 9. Map UI

**Route.** `apps/app/src/routes/_app/map.tsx`. Search params are validated with zod: `hubs`, `layers`, `when`, `lat`, `lng`, `z`, `place`, `event`, `view=list`.
- Components go in `components/map/`: `map-canvas`, `hub-chips`, `layer-chips`, `list-panel`, `place-sheet`, `add-place`, `attribution`.
- Logic goes in `lib/map.ts` (query, bbox snapping, feature decoding) and `lib/map-style.ts`.

**Tab bar.** Home, Hubs, Post, **Map**, You. Chats moves to a top-bar icon.

**Load order.**
1. The route renders the chips and the list panel straight from `map_in_view`, centred on the device point if given, else the home point, else Atlanta.
2. After first paint, `map-canvas` does `import('maplibre-gl')` plus its CSS. One map instance is kept for the session.

**Chips.**
- "All my hubs" plus one chip per joined hub, with its emoji and `categoryTone`.
- `place_mode='none'` hubs show "Events only".
- One selected hub turns on its generic spots, labelled "General spots".
- "+ Explore" previews any hub without joining it.
- Layers: Places, Plans, Shows and games. When: Today, This week, 30 days.
- Filtering by chip is local (`setFilter` on features using `rule_ids` mapped to hubs) and does not refetch.

**Pins.**
- Two clustered GeoJSON sources: places (radius 48, max zoom 15) and happenings.
- Each type has its own shape:
  - Places: a rounded square with the kind icon.
  - Plans: an orange teardrop, grey-blue when imported.
  - Shows: a violet ticket shape.
  - Approved-only events: a hatched dashed cell, "N events in this area · exact spot shared after host approval".
- Icons are about 12 lucide SVGs drawn into the map with `addImage`, so there is no sprite to host.
- Below zoom 10, places are replaced by a "Zoom in to see places" pill.

**List panel.** A non-modal bottom panel (not the `<dialog>` Sheet) with peek, half and full heights.
- Sorted by distance. Every pin is in the list. A List/Map toggle switches the whole screen.
- An `aria-live` count line. The canvas has an `aria-label` and keyboard controls.
- With `prefers-reduced-motion` the map jumps instead of flying. With Save-Data on, the list opens by default.

**Place sheet** (the existing Sheet):
- Name, kind, hub chips, address (public places only), hours as text, website and source line.
- Directions, "Start a plan here" (`/post?place=`), "Plans here", "Suggest a correction", "Report", and "Improve on OSM".

**Add place.**
1. A crosshair over the map.
2. Name and kind; hubs pre-filled from the kind's rules (up to 3).
3. Visibility: "Only me" (default) or "Everyone (reviewed first)".
4. A duplicate check against the same kind within 60 m.
5. A pending pin for the creator.

**Empty and edge states.**
- A tile that is still `wanted`: "We're mapping this area. Courts and stores usually appear within a day. Add a spot you know." Public plans still show.
- No joined hubs: a join-hubs prompt plus public plans nearby.

**Dark mode.** `VITE_MAP_STYLE_URL` and `VITE_MAP_STYLE_URL_DARK`, following `lib/theme.ts`. On a theme change: `setStyle`, then re-add sources and icons on `style.load`. Check which dark style OpenFreeMap offers (likely "dark"; re-check).

**Performance budget.**

| Item | Budget |
|---|---|
| Route JS, excluding MapLibre | ≤ 35 KB gzip |
| List visible | ≤ 1.5 s on a mid-range Android over slow 4G |
| First map frame | ≤ 3.5 s |
| Requests per settled view | 1, debounced 300 ms, bbox snapped outward to a 0.05° grid |
| Response | ≤ 60 KB gzip per 1,000 features |
| Query cache | 2 min, keeping previous data while loading |
| Chip tap (INP) | ≤ 200 ms |
| Rendering | no 3D buildings or terrain; pixel ratio capped at 2 |

**Scale-out fallback** (only when the places table passes 120 MB): the extract job also writes per-tile FlatGeobuf files to GitHub Pages, which is free for a public repo. The client reads them with bbox HTTP range requests for OSM places. The database then keeps only member, venue and corrected rows, plus `osm_ref` overlays. The `map_in_view` contract stays the same apart from a `places_url` hint.

---

## 10. Cost and quota summary ($0 a month)

| Resource | Use | Limit |
|---|---|---|
| Supabase Free DB | places ≤ 150 MB; events and the rest about 100 MB | 500 MB |
| Supabase Edge Functions | ingest (about 15 calls per tile run), fill (≤ 100 a day), map RPCs go direct through PostgREST | 500k invocations a month, 2 s CPU each |
| GitHub Actions (public repo) | nightly and weekly extract, monthly dump | unlimited minutes, 6 h a job, 14 GB disk |
| Geofabrik | ≤ 1 download per extract per week, cached | "download responsibly" |
| Geoapify Free | ≤ 500 credits a day for places | 3,000 a day, 5 req/s |
| OpenFreeMap tiles | client tiles | no key, donations, no SLA |
| Vercel Hobby | app hosting | unchanged |

---

## 11. Build slices (in order, 1 to 3 days each, about 29 days in all)

| # | Slice | Days | Done when |
|---|---|---|---|
| 1 | **D-041 and taxonomy sign-off.** Paste D-041; founder answers §12; merge duplicate hubs (bocce, tv-shows); set `place_mode` for the flagged hubs | 1 | DECISIONS.md updated, rules frozen as v1 |
| 2 | **Rules generator.** `hub_place_rules.json` → `supabase/seed/place_rules.sql` + `filters.txt`; check the 430 unverified tags on taginfo once the host is allowed; drop any tag with fewer than 50 uses worldwide | 1 | Seed and filter generated in CI; verified count reported |
| 3 | **Schema migration.** `place_kinds`, `place_rules`, `hub_place_rules`, `places`, `place_hubs`, `place_tiles`, `collector_budget`, `listing_kind`, `venues.place_ref`, indexes, RLS, pgTAP | 2 | `supabase db reset` passes; RLS tests green |
| 4 | **Ingest RPCs.** `ingest_places`, `finish_place_tile`, close after 2 missed runs, `osm_ref` merge, locked fields; collector Edge Function route `/ingest/places` | 2 | Fixture batch round-trips; re-ingest is idempotent |
| 5 | **Extract Action.** Geofabrik index pick, cache, osmium, Python point reduction and rule evaluation, batch post, row-count guard; first manual Atlanta run on staging | 3 | Atlanta tiles `active`; size measured and §4.5 updated |
| 6 | **`map_in_view` / `places_in_view` / `place_detail`.** bbox split, caps, compact encoding, cells for approved-only; EXPLAIN on Atlanta data | 2 | p95 < 150 ms on staging; payload under budget |
| 7 | **Map route shell.** Tab bar swap (Chats to top bar), chips, layer and time chips, list panel, `lib/map.ts`, empty states | 2 | Usable list-only "Near me" on staging |
| 8 | **MapLibre canvas.** Lazy load, OpenFreeMap light and dark, clustering, shapes and icons, approved-only cells, attribution control | 3 | Lighthouse mobile budget met; a11y review passes |
| 9 | **Place sheet and meeting spots.** Detail, directions, "Plans here", "Start a plan here", venue→place trigger | 2 | A public plan at a public venue shows up as a hub spot |
| 10 | **Shows and games.** `listing_kind` from `feed_sources`; Ticketmaster and SeatGeek flagged `show`; feed row; map layer | 2 | Shows in their own row and layer, deduplicated |
| 11 | **Add place, corrections, reports.** `add_place` with the home and venue distance checks, duplicate check, rate limits, UI | 3 | §7 rules covered by pgTAP; UI flow works |
| 12 | **Moderation queue.** `mod_place_queue` and `mod_resolve_place`, admin UI tab, locked fields on approval | 2 | A moderator can clear pending places, edits and reports |
| 13 | **Demand and Geoapify fill.** `bump_place_tile` trigger, nightly `wanted` pickup in the Action, `places-fill` Edge Function with budget, "Powered by Geoapify" | 2 | A new city goes from `wanted` to `active` within 24 h |
| 14 | **ODbL and legal.** Monthly dump Action and release, Terms and Privacy text, place-sheet source lines, "Improve on OSM" | 1 | First release published from staging |
| 15 | **Retirement and health.** `retire_place_tiles`, size guard alarm at 120 MB, admin health panel (tiles, rows, last run, budget) | 1 | Lifecycle test passes; panel live |

Slices 1 to 6 are backend work and can start right away. Slices 7 and 8 need slice 6 deployed to staging. Slices 9 to 15 can run in any order after slice 8, but 11 must finish before 12.

---

## 12. Open questions for the founder
1. **Tab bar.** Map takes the Chats slot until messaging ships (the default here). Yes or no?
2. **Generic spots.** Show cafés, parks and libraries only when one hub chip is selected (the default), never, or always?
3. **No-pin hubs.** Should hunting, knife-collecting, cliff-diving and spearfishing show places (ranges, beaches) or stay events-only?
4. **Logged-out map.** Public plans only, or also places for hubs picked on the spot?
5. **"Open now".** Add an opening-hours parser later (about 30 KB), or keep hours as text?
6. **Atlanta seeding.** Should outreach add the founder's known spots (club meeting places, courts that are missing from OSM) as moderator-approved places before launch?

**Answers (founder, 2026-11-03):** 1 yes, Map takes the Chats slot until messaging ships. 2 generic spots only when one hub chip is selected. 3 hunting, knife-collecting, cliff-diving and spearfishing stay events-only (`place_mode='none'`). 4 the signed-out map shows public places and public plans. 5 "Open now" later; hours as text now. 6 yes, Atlanta outreach adds known spots as moderator-approved places before launch (FOUNDER-TODO). Places sources are OpenStreetMap, member-added and corrected places with moderation, Geoapify's free tier when a key exists, and the venues of public plans; no Google Places. Ticketed shows get their own row once the Ticketmaster and SeatGeek keys exist.

---

## 13. Risks and mitigations

| Risk | Likelihood / impact | Mitigation |
|---|---|---|
| OSM is thin for niche hubs (anime clubs, board-game cafés, comedy clubs, maid cafés) | High / medium | Meeting spots from plans; member add; Atlanta seeding (question 6); show "Add a spot" in sparse areas |
| Tags or Geoapify ids are wrong (430 tags and 80 ids unverified) | Medium / medium | Slice 2 checks taginfo; rules are versioned and re-evaluated without re-downloading; drop rules under 50 uses |
| A home address gets doxxed through a member-added place | Low / high | Private by default, moderation, home and venue distance checks, instant hide on a `private_residence` report |
| The places table outgrows the database | Medium / high | 150 MB cap, tile retirement, generic-category lever, static FlatGeobuf fallback (§9) |
| OpenFreeMap outage (no SLA) | Low / high | `VITE_MAP_STYLE_URL` swap; Protomaps PMTiles fallback (D-038); the list view works without tiles |
| GitHub pauses schedules after 60 days, or Geofabrik blocks us | Medium / medium | Stale-source check (D-040); weekly cache; descriptive User-Agent; manual dispatch |
| ODbL share-alike is misread, or Geoapify terms change | Low / medium | Everything published as ODbL; monthly dump; attorney review; Geoapify is optional |
| A view of a dense city returns too many points (mobile jank) | Medium / medium | Caps, `zoom_in`, clustering, compact encoding, pixel ratio capped at 2 |
| Map queries reveal sensitive-hub interest | Low / high | No bbox or user logging; sensitive chips filtered on the client; no per-user place stats |
| Facts in this doc came from search excerpts | Certain / low | Re-check list: OSM wiki and taginfo, Overpass policy, OSMF attribution and collective-database guidelines, Geofabrik index and terms, Geoapify pricing, caching terms and `limit`, OpenFreeMap dark style and FAQ, GitHub runner specs |

Sources: see the source lists in the three research passes (`hub_place_rules.json` notes and the sources and schema reports). The key links are https://wiki.openstreetmap.org/wiki/Overpass_API, https://blog.geofabrik.de/index.php/2025/09/10/download-responsibly/, https://osmfoundation.org/wiki/Attribution, https://osmfoundation.org/wiki/Community_Guidelines/Horizontal_Map_Layers_-_Guideline, https://geoapify.com/pricing, https://openplacesapi.com/blog/can-you-store-places-api-results, https://docs.github.com/en/enterprise-cloud@latest/actions/reference/runners/github-hosted-runners, https://openfreemap.org and https://wiki.openstreetmap.org/wiki/Tag:sport%3Dbasketball. All were read as search excerpts only.
