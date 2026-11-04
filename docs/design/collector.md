# Event collector (D-040)

`packages/collector` (`@ap/collector`) collects nearby public events so people can use the app the day they sign up, anywhere. It is TypeScript on Node 22, has no database access, and is meant to run as a scheduled GitHub Actions job. Today it ends in a dry run that prints counts. The real ingest step (one `import_upsert_batch(p_source_slug, p_items)` call per source) gets wired once the collector's source rows and schema land.

```sh
pnpm --filter collector collect --region atl --list      # seeds and API lanes that would run; no network
pnpm --filter collector collect --region atl --dry-run   # fetch, parse, normalize, print counts
pnpm --filter collector collect --regions-file regions.json --dry-run --json
```

Without `--dry-run` the CLI stops with exit code 2. It never writes to a database.

## Pipeline

```
regions ─┬─ city seed files that overlap them ─┬─ PoliteFetcher (https, denylist, login check,
         │                                     │   robots.txt, 2 s per host, conditional GET,
         └─ API adapters that have a key ──────┘   timeout, size cap)
                       │
                lane parsers ── RawEvent ── normalize() ── ImportItem
                       │
     radius filter ── run window ── dedupe ── one SourceBatch per source ── Ingest (dry run)
```

- **Input** is a list of regions (`{id, label, lat, lng, radiusKm, timezone?}`). `--region atl` uses the region in `data/cities/atl.json`. `--regions-file` takes the areas people actually use the app in, so coverage follows users. Every city file whose circle overlaps a requested region contributes its seeds. API adapters run once per requested region.
- **Output** is one `SourceBatch` per source: the item set `import_upsert_batch` takes (`external_id, title, description, starts_at, ends_at, all_day, location, lat, lng, url, cover_url, is_free, price_text, categories, host_org, open_to_public, cancelled, raw`, the shape of `supabase/functions/import-feed/adapters.ts`), plus two fields the RPC ignores, `attribution` (the source line to show) and `lane`. Skip counts are kept per reason.

## Lanes

| Lane                       | What                                                                                                                                                                                                                                                                                                                                                                                                          | Code                                                                                                                                 |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| 1. Free official APIs      | Ticketmaster Discovery (`TICKETMASTER_API_KEY`), SeatGeek Platform (`SEATGEEK_CLIENT_ID`), city open-data portals (Socrata SODA, ArcGIS feature layers, with a per-seed field map)                                                                                                                                                                                                                            | `src/adapters/api.ts`, `src/adapters/opendata.ts`                                                                                    |
| 2. Public ICS and RSS/Atom | Seeded feeds, Localist calendars through their documented read-only JSON API (`kind: "localist"`, `/api/2/events`, no key), plus feeds found on seed pages: `<link rel="alternate">` with a calendar or feed type, `.ics` and `webcal:` anchors, `?ical=1` (The Events Calendar), CivicPlus `iCalendar.aspx?catID=`, `/rss` and `.rss` links, and Google Calendar links turned into the calendar's public ICS | `src/parse/ics.ts`, `src/parse/rrule.ts`, `src/parse/feed.ts`, `src/parse/html.ts`, `src/parse/links.ts`, `src/adapters/localist.ts` |
| 3. schema.org Event markup | JSON-LD (`@graph`, top-level arrays, `@id` references, `ItemList`, Event subtypes) and microdata on seed pages and on same-site event pages linked from them, one level deep                                                                                                                                                                                                                                  | `src/parse/html.ts`, `src/parse/schema.ts`                                                                                           |

API adapters with no key are skipped and the run carries on. The API lane can reach `app.ticketmaster.com/discovery/v2/` and `api.seatgeek.com/2/` and nothing else on those sites (`apiAllow` in the denylist). Keys never appear in logs: URLs are redacted before anything is printed. Attribution lines say where the data came from ("Event data from the Ticketmaster Discovery API (ticketmaster.com)."), and every item links out to the source's own event page. D-039 sent Ticketmaster to its own decision and rejected SeatGeek. D-040 brings both into lane 1, so their caching and removal terms need a check before the keys go in.

### Discovery: what a page link may lead to

`src/parse/links.ts` classifies every link before anything fetches it.

- **Google Calendar** pages are never followed. A subscribe or embed link that names a public calendar (`cid=` or `src=`, as a calendar id or base64 of one) becomes Google's documented public address, `calendar.google.com/calendar/ical/<id>/public/basic.ics`. A `cid=` that wraps a feed on another site (`webcal://…`, `https://…`, or base64 of either) becomes that feed. `action=TEMPLATE` "add to calendar" buttons, private addresses and every other Google Calendar page are skipped. Outlook and Yahoo add-to-calendar links are skipped too. The resulting URL still goes through robots.txt, the denylist and the other fetcher checks.
- **Action pages** are skipped: Localist `/event/<slug>/confirm`, `/register`, `/rsvp`, `/edit` and the like, `/event/create`, `/events/new`, `/submit`, and sign-in or sign-up paths. They never list events, and sites usually disallow them in robots.txt, so following them only cost requests.
- **The source's own feed comes first.** Feeds are ranked: the page's `<link rel="alternate">` feeds, then calendar-wide export links, then single-event exports (`/event/<slug>/?ical=1`). When a calendar-wide feed yields events, single-event exports and the discovered event pages are not fetched. A seed can set `"crawlPages": true` to crawl the pages anyway. A seed of kind `ics`, `rss` or `localist` is never crawled at all.
- Skipped links are counted by reason in the run's `linksSkipped`.

A `localist` seed reads `https://<calendar>/api/2/events?days=<window>&pp=100&page=N` (filters such as `type=` in the seed URL are kept), through the normal web politeness: robots.txt and 2 s spacing, not the API lane. Private events and academic-calendar deadlines are dropped. If robots.txt disallows the API, the seed falls back to reading the calendar's home page like a page seed.

### What a lane reads

- **Facts only**: title, start and end, place (name, address, point), status, price or free, organizer, categories, and the link. The description is kept as a verbatim excerpt of at most 280 characters, cut at a word boundary.
- **No images** unless the seed says `"imagesLicensed": true`. Otherwise `cover_url` is always null, including from the APIs.
- **No LLM reads page text**, and nothing outside schema.org markup, feed fields or API fields is read.
- **ICS**: TZID (IANA names, mozilla-style prefixes, VTIMEZONE `X-LIC-LOCATION`, common Windows names), floating times in `X-WR-TIMEZONE` or the region's zone, all-day dates with an inclusive end, `DURATION`, `RRULE` (DAILY, WEEKLY, MONTHLY, YEARLY with INTERVAL, COUNT, UNTIL, BYDAY with ordinals, BYMONTHDAY, BYMONTH, BYSETPOS, WKST) expanded in wall-clock time within the run window (default 60 days, at most 200 emitted instances per event; rules without COUNT skip straight to the window however old DTSTART is, past RDATEs never count toward the cap, and each file gets a fixed expansion budget of 50,000 steps), `EXDATE`, `RDATE`, `RECURRENCE-ID` overrides including cancelled ones. `CLASS:PRIVATE` and `CONFIDENTIAL` events are dropped. BYHOUR, BYMINUTE, BYWEEKNO and BYYEARDAY rules give only DTSTART.
- **RSS/Atom**: an entry counts only when it carries event times (`ev:startdate`, `<start>`, `xcal:dtstart`, or hCalendar `dt-start` in the description). `pubDate` is never treated as an event time, so a news feed yields nothing.
- **Status**: cancelled events are sent with `cancelled: true`, so the RPC marks them cancelled. `EventPostponed` and date-TBD API events are dropped.

## Politeness

All of it lives in `src/net/fetcher.ts`, and nothing else in the collector touches the network.

- User-Agent `ActivityPlanetBot/0.1 (+https://activity-planet.vercel.app/bot)`, with no email. The `/bot` page still has to be written.
- **robots.txt** (RFC 9309) is fetched once per host per run, and conditional GET keeps it cheap across runs. The group for `ActivityPlanetBot` beats `*`. Within a group the longest match wins, and Allow wins a tie. `*` and `$` work. A 4xx means no rules. A 5xx or a network failure means nothing is fetched from that host (`robots_unavailable`). `Crawl-delay` is honoured when it is longer than 2 s. A delay over 60 s is waited out too, inside a per-host budget for the run (`--slow-host-minutes`, default 10): the host gets `floor(budget / delay) + 1` requests at that spacing, and later ones are skipped as `crawl_budget_spent`. A delay longer than the whole budget skips the host (`crawl_delay_too_long`). Keep `maxPages` small on such a seed. The API lane does not read robots.txt, because the API terms govern it.
- **At most one request per 2 seconds per host**, measured from request start to request start. Seeds run four at a time, and per-host spacing still holds across them.
- **Conditional GET**: ETag and Last-Modified are stored in `.cache/http.json` (gitignored; the Actions job can keep it with `actions/cache`), and a 304 is served from the cache. API-lane responses are never cached, because their URLs carry `apikey=` and `client_id=`.
- **Limits**: 20 s timeout, 3 MB body cap (bigger bodies are abandoned mid-stream), at most 5 redirects, and binary content types are refused. By default each page seed follows up to 10 discovered feeds and 25 discovered event pages (`--max-pages`, or `maxPages` per seed).
- **Every hop is checked**: https only (http links are upgraded, `webcal:` is read as https), port 443 only, public hosts only, denylist, and login-URL patterns. A redirect to a denied, private or login URL ends the fetch, so the target is never requested. Custom request headers never follow a redirect to another host, and an API-lane redirect must land on another `apiAllow` endpoint.
- **Public hosts only** (`src/net/address.ts`): IP literals in loopback, private, link-local (cloud metadata), CGNAT, unique-local, multicast, documentation and unspecified ranges (IPv4-mapped, NAT64 and 6to4 forms too) are refused, and so are `localhost`, `*.local`, `*.internal`, `*.home.arpa` and other private-use names and single-label hosts. The default transport is an undici `Agent` whose DNS lookup refuses a name if any address it resolves to is in those ranges, so the check also runs at connect time for every hop and defeats DNS rebinding.
- **Page permissions**: `<meta name="robots">` and `<meta name="activityplanetbot">`, plus `X-Robots-Tag` (unprefixed or prefixed with our bot name). `noindex` means no events are read from the page or feed. `nosnippet` (or `max-snippet:0`) means items carry no excerpt, and `max-snippet:N` clips the excerpt to N characters; the strictest value across the header and meta tags wins. `nofollow` means no links are discovered from the page, and `rel="nofollow"` anchors are never followed. Pages with a password field or a login form are skipped, and so are 401 and 403 responses.

## Denylist

`packages/collector/data/denylist.json` lists sites whose terms forbid automated collection or that sit behind logins. Today that is facebook.com, instagram.com, threads.net and threads.com, meetup.com, linkedin.com, joinhandshake.com, x.com, twitter.com, tiktok.com and their short-link domains (fb.me, m.me, lnkd.in, t.co, meetu.ps), evbuc.com, plus `eventbrite`, `ticketmaster`, `livenation`, `seatgeek` and `nextdoor` under any suffix. `domains` entries match the domain and every subdomain. `anyTld` entries match when the name is the site's own label: second to last, or third to last under a two-part suffix such as co.uk or com.au (so `eventbrite.events` and `nextdoor.com.au` match, `eventbrite.example.org` does not). `apiAllow` is the only way onto a listed site, and only for the API lane. A URL on the list is never requested, whether it comes from a seed, a discovered link or a redirect. Linking out to such a page from an item (a Ticketmaster event URL from the Discovery API) is fine, because nothing fetches it. Add entries as data. Removing one needs an entry in `docs/DECISIONS.md`.

## Normalization (the `import_upsert_batch` constraints)

`src/normalize.ts` applies the same rules as the RPC, so dry-run counts match what the database would accept:

- The title is whitespace-collapsed and entity-decoded. It must be at least 3 characters and is clipped to 120 with an ellipsis.
- The description is the excerpt above (at most 280; the database allows 2000).
- The URL must be https and at most 2000 characters. When the event has no link of its own, the page it is listed on is used, or the first https link in an ICS description. Otherwise the event is skipped (`no_https_url`).
- `starts_at` and `ends_at` are UTC ISO instants. Floating and date-only times are read in the source's zone (API venue zone), else the region's zone. A missing or non-positive end becomes start + 2 h, or the end of the day for all-day items. Spans over 3 days are skipped (`longer_than_3_days`).
- `location` is at most 120 characters ("Online" for online-only events), `price_text` at most 40, and `host_org` at most 120. Categories are de-duplicated, at most 10.
- `lat`/`lng` are kept only when they are valid and not 0,0.
- `external_id` is the source's UID, `@id` or API id. For a recurring instance it is `<uid>#<instance start>`. Ids from a discovered feed get a `f<hash>:` prefix and ids from page markup get `p:`, so feeds of one source cannot collide. An id longer than 200 characters becomes a hash.

After normalization:

- **Radius**: an item with a point is kept only inside one of the requested regions. An item without a point is kept only when its source's own area (the seeded city's centre, or the region an API was asked about) lies inside one of the requested regions, and the RPC places it on the fallback centroid. A small user region at the edge of a city therefore does not get the city's coordinate-less events.
- **Window**: an item is dropped when it has already ended or starts after the window.
- **Dedupe within a run**: the same external id within a source, the same title (letters and digits only) and start minute across sources, or the same URL and start minute. Official feeds win over APIs, APIs over page markup, and a copy with a point wins over one without. The RPC still links cross-source matches against what is already stored.

## Adding a city

1. Copy `packages/collector/data/cities/atl.json` to `data/cities/<id>.json`. Set `region` (`id` of 2 to 40 characters from a-z, 0-9 and `-`; centre; `radiusKm` up to 300; IANA `timezone`).
2. Add seeds. Each needs a unique `id`, a `kind` (`page`, `ics`, `rss`, `localist`, `socrata`, `arcgis`), an https `url`, a `name` (2 to 80 characters), and an `attribution` line (10 to 300 characters, naming the source and its host). Optional: `host_org`, `categories`, `discover: false`, `maxPages`, `crawlPages`, `imagesLicensed`, `enabled: false`, `verified`, `note`. Set `verified: true` only once a live run has read the endpoint or a person has opened it; say why in `note`, and say why a seed is off.
   - Good page seeds are the events pages of the library system, parks department, museums, university public calendars and city or county sites. Discovery finds their feed exports and event pages.
   - Prefer a feed seed (`ics` or `rss`) when the source publishes one. It is one request, and the data is the source's own. Platforms with documented public feeds: Localist (`kind: "localist"` with the calendar's `/api/2/events`), The Events Calendar for WordPress (`<calendar>/?ical=1`), Trumba (`trumba.com/calendars/<web name>.ics`), CivicPlus (`/common/modules/iCalendar/iCalendar.aspx?catID=<n>&feed=calendar`), LibCal (`ical_subscribe.php`), and Communico's RSS export where the library has turned it on.
   - A site that answers the bot with 401 or 403 stays off (`enabled: false`) until its owner offers a feed or allows the bot.
   - Open-data seeds need `fields` (`title`, `start`, plus `end`, `location`, `url`, `id`, `lat`, `lng`, `category` as available; dotted paths work), and `geoColumn` for Socrata circle filtering.
   - Never add a page that needs a login, a denylisted site, or a paid API.
3. Run `pnpm --filter collector collect --region <id> --list`, then `--dry-run`. Every blocked or unreadable seed shows up as a `skip … <reason>` line on stderr.
4. Run `pnpm --filter collector test`. The seed-file test validates every city file and checks that no seed is denylisted.

The Atlanta seeds were written without network access from the authoring environment. The first live dry run (Actions run 41849155715) read Kennesaw State, Marietta and the Atlanta History Center; those are `verified: true`. The other endpoints were inferred from each site's platform and public search results and stay `verified: false` until a run reads them. Sites that answered 403 (City of Atlanta, Decatur) and sites with no machine-readable feed found (High Museum, Fernbank, the Center for Civil and Human Rights, Georgia Tech's RSS index, Emory's Trumba page until its web name is known) are off, with the reason in `note`. Georgia State is left out because the D-037 importer already reads it.

## Running it in GitHub Actions (later)

```yaml
- uses: actions/cache@v4
  with: { path: packages/collector/.cache, key: collector-http-${{ github.run_id }}, restore-keys: collector-http- }
- run: pnpm --filter collector collect --regions-file regions.json --dry-run --json
  env:
    TICKETMASTER_API_KEY: ${{ secrets.TICKETMASTER_API_KEY }}
    SEATGEEK_CLIENT_ID: ${{ secrets.SEATGEEK_CLIENT_ID }}
```

## Tests

`pnpm --filter collector test` runs on fixtures only, with a fake transport and a fake clock, and never touches the network. It covers:

- ICS lexing, zones (DST, floating, Windows names), RRULE expansion and the window, EXDATE, overrides and cancelled instances
- RSS, Atom and hCalendar
- JSON-LD variants (`@graph`, arrays, `@id`, Place and PostalAddress, offers, cancelled, postponed, online) and microdata
- robots.txt rules and statuses, the denylist, noindex and nofollow, login detection
- fetcher politeness (spacing, Crawl-delay, redirects, 304, size caps, timeouts)
- normalizer clipping, the radius and window filters, dedupe
- the API and open-data adapters
- an end-to-end run over a fixture site, and seed-file validation
- discovery (`test/discovery.test.ts`): Google Calendar cid/src conversion and skipped render pages, action pages, feed ranking and the feed-first rule, the Localist API seed and its robots fallback, and a long Crawl-delay honoured within the budget
- hardening (`test/hardening.test.ts`): private and loopback hosts, ports and the connect-time lookup, markup revealed by decoding, API keys kept out of the cache, API redirects and cross-host headers, linear-time scans of hostile feeds and HTML (with a time budget), old RRULEs and past RDATEs, denylist gaps, nosnippet and max-snippet, and the region filter for items without a point. The connect-time lookup test resolves `localhost`, which reads the local hosts file and sends nothing.
