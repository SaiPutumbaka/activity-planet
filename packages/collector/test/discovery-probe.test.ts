import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  cheapScore as score2,
  KIND_PRIOR,
  learnedPrior,
  LEARNED_MIN_PROBES,
  parseYield,
  WIKIDATA_BONUS,
} from "../src/discovery/candidates.ts";
import { loadCities } from "../src/config.ts";
import {
  aroundQuery,
  cheapScore,
  entitiesQuery,
  mergeCandidates,
  osmCandidates,
  parseAround,
  parseEntities,
  siteUrl,
  type TileRow,
  tilesForRegion,
} from "../src/discovery/candidates.ts";
import { loadDiscoveryConfig, parseDiscoveryConfig } from "../src/discovery/config.ts";
import { foundCalendar, gateReport, probeAll } from "../src/discovery/discover.ts";
import { candidateGate, euGated, zoneCountry } from "../src/discovery/eu.ts";
import { guessedPaths, keywordsFor, keywordStrength } from "../src/discovery/keywords.ts";
import {
  googleEmbedFeeds,
  platformsIn,
  probe,
  ProbeFetcher,
  probeHostAllowance,
  type ProbeResult,
  trumbaFeeds,
} from "../src/discovery/probe.ts";
import { probeHash } from "../src/discovery/version.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import { hostOf, siteOf } from "../src/util/url.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const denylist = Denylist.load();
const cfg = loadDiscoveryConfig();

function fetcherWith(routes: Record<string, FakeResponse>) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  const fetcher = new PoliteFetcher({ denylist, transport, now: c.now, sleep: c.sleep });
  return { fetcher, log };
}

const html = (body: string, head = "") =>
  `<!doctype html><html><head><title>t</title>${head}</head><body>${body}</body></html>`;

/** A schema.org Event inside Atlanta, inside the run window. */
const eventLd = (name: string, day = "2026-11-20") =>
  `<script type="application/ld+json">${JSON.stringify({
    "@context": "https://schema.org",
    "@type": "Event",
    name,
    startDate: `${day}T19:00:00-05:00`,
    endDate: `${day}T21:00:00-05:00`,
    url: `https://museum.example.org/event/${name.toLowerCase().replace(/\W+/g, "-")}/`,
    location: {
      "@type": "Place",
      name: "Main hall",
      geo: { "@type": "GeoCoordinates", latitude: 33.79, longitude: -84.38 },
    },
  })}</script>`;

const row = (
  ref: string,
  kind: string,
  name: string,
  website: string | null,
  lat = 33.78,
  lng = -84.38,
  tags: Record<string, unknown> | null = null,
): TileRow => [ref, lng, lat, kind, name, [], null, null, null, website, tags];

describe("discovery config", () => {
  it("lists exactly the Atlanta seeds that are on today as the gate's expectations", () => {
    const atl = loadCities().find((c) => c.region.id === cfg.gate.city)!;
    const on = atl.seeds.filter((s) => s.enabled !== false);
    expect(cfg.gate.expected.map((e) => e.seed).sort()).toEqual(on.map((s) => s.id).sort());
    for (const e of cfg.gate.expected) {
      const seed = on.find((s) => s.id === e.seed)!;
      expect(siteOf(hostOf(seed.url))).toBe(e.site);
    }
    expect(cfg.gate.expected).toHaveLength(9);
    expect(cfg.gate.required).toBe(6);
  });

  it("keeps the EU gate's countries in step with source_discovery_allowed (migration 46)", () => {
    const sql = readFileSync(
      new URL("../../../supabase/migrations/20261210000100_source_discovery.sql", import.meta.url),
      "utf8",
    );
    const fn = sql.slice(sql.indexOf("function public.source_discovery_allowed"));
    const list = /not in \(([^)]*)\)/.exec(fn)![1]!;
    const db = [...list.matchAll(/'([A-Z]{2})'/g)].map((m) => m[1]).sort();
    expect([...cfg.euGate.countries].sort()).toEqual(db);
    expect(cfg.euGate.enabled).toBe(true);
  });

  it("refuses caps the design does not allow", () => {
    const base = JSON.parse(
      readFileSync(new URL("../data/discovery.json", import.meta.url), "utf8"),
    ) as Record<string, Record<string, unknown>>;
    const bad = { ...base, caps: { ...base.caps, requestsPerHostPerProbe: 12 } };
    expect(() => parseDiscoveryConfig(JSON.stringify(bad))).toThrow(/2\.\.8/);
    const req = { ...base, gate: { ...base.gate, required: 10 } };
    expect(() => parseDiscoveryConfig(JSON.stringify(req))).toThrow(/required/);
  });
});

describe("EU gate by time zone", () => {
  it("gates EU, EEA and UK zones, an unlisted European zone and a missing zone", () => {
    const gate = cfg.euGate;
    expect(euGated("Europe/Berlin", gate)).toBe(true);
    expect(euGated("Europe/London", gate)).toBe(true);
    expect(euGated("Atlantic/Canary", gate)).toBe(true);
    expect(euGated("Indian/Reunion", gate)).toBe(true);
    expect(euGated("Europe/Oslo", gate)).toBe(true);
    expect(euGated("Europe/Nowhere", gate)).toBe(true);
    expect(euGated(null, gate)).toBe(true);
    expect(euGated("Europe/Zurich", gate)).toBe(false);
    expect(euGated("America/New_York", gate)).toBe(false);
    expect(euGated("Asia/Tokyo", gate)).toBe(false);
    expect(euGated("Europe/Berlin", { ...gate, enabled: false })).toBe(false);
    expect(zoneCountry("Europe/Berlin")).toBe("DE");
    expect(zoneCountry("America/New_York")).toBeNull();
  });
  it("judges each candidate by its own place when a region's circle crosses a border", () => {
    const gate = cfg.euGate;
    // A Basel region (Europe/Zurich): Basel itself is Swiss, Weil am Rhein German, Saint-Louis French.
    expect(candidateGate({ lat: 47.5596, lng: 7.5886 }, "Europe/Zurich", gate)).toEqual({
      gated: false,
      country: "CH",
    });
    expect(candidateGate({ lat: 47.5944, lng: 7.6206 }, "Europe/Zurich", gate).gated).toBe(true);
    expect(candidateGate({ lat: 47.59, lng: 7.5568 }, "Europe/Zurich", gate).gated).toBe(true);
    // Zurich centre is far enough from any border.
    expect(candidateGate({ lat: 47.3769, lng: 8.5417 }, "Europe/Zurich", gate).gated).toBe(false);
    // No point: fine outside Europe, gated in a European or unknown region.
    expect(candidateGate({}, "America/New_York", gate).gated).toBe(false);
    expect(candidateGate({}, "Europe/Zurich", gate).gated).toBe(true);
    expect(candidateGate({}, null, gate).gated).toBe(true);
    // Its own (Wikidata) country is gated.
    expect(candidateGate({ country: "FR" }, "Europe/Zurich", gate).gated).toBe(true);
    // Atlanta stays open and keeps its own country.
    expect(
      candidateGate({ lat: 33.75, lng: -84.39, country: "US" }, "America/New_York", gate),
    ).toEqual({ gated: false, country: "US" });
    expect(
      candidateGate({ lat: 47.59, lng: 7.5568 }, "Europe/Zurich", { ...gate, enabled: false }),
    ).toEqual({ gated: false, country: null });
  });
});

describe("keywords", () => {
  it("matches path segments, the host's first label and link text, in the region's languages", () => {
    const en = keywordsFor(null);
    expect(keywordStrength("https://a.org/events/", "", en)).toBe(3);
    expect(keywordStrength("https://a.org/content/shows-events", "", en)).toBe(3);
    expect(keywordStrength("https://calendar.a.edu/", "", en)).toBe(3);
    expect(keywordStrength("https://a.org/visit/", "What's On", en)).toBe(2);
    expect(keywordStrength("https://a.org/about/", "About us", en)).toBe(0);
    const de = keywordsFor("DE");
    expect(keywordStrength("https://a.de/veranstaltungen/", "", de)).toBe(3);
    expect(keywordStrength("https://a.de/veranstaltungen/", "", en)).toBe(0);
    expect(keywordStrength("https://a.fr/x/", "Événements", keywordsFor("FR"))).toBe(2);
    expect(guessedPaths("DE")[0]).toBe("/veranstaltungen/");
    expect(guessedPaths(null)).toEqual(["/events/", "/calendar/"]);
  });
});

describe("candidates", () => {
  it("covers the region's circle with place tiles", () => {
    const tiles = tilesForRegion(ATL);
    expect(tiles).toContain(178031);
    expect(tiles).toContain(178030);
    // 60 km around Atlanta: 3 rows by 4 columns of 0.5 degree tiles.
    expect(tiles.length).toBe(12);
  });

  it("reads website values like OSM writes them", () => {
    expect(siteUrl("http://www.atlantahistorycenter.com/")).toEqual({
      host: "atlantahistorycenter.com",
      home: "https://www.atlantahistorycenter.com/",
      url: "https://www.atlantahistorycenter.com/",
    });
    expect(siteUrl("atlantabg.org")?.host).toBe("atlantabg.org");
    expect(siteUrl("https://a.org/x; https://b.org/")?.host).toBe("a.org");
    expect(siteUrl("mailto:x@y.org")).toBeNull();
    expect(siteUrl("https://a.org:8443/")).toBeNull();
  });

  it("keeps event-likely kinds, one per host, and drops denylisted and known sites", () => {
    const rows = [
      row("n1", "park", "Lake Park", "http://www.mariettaga.gov/Facilities/Lake-Park-20"),
      row("n2", "park", "Hill Park", "https://mariettaga.gov/Facilities/Hill-Park-18"),
      row("n3", "sports_centre", "Custer Park", "https://www.mariettaga.gov/facilities/12"),
      row(
        "n4",
        "arts_venue",
        "History Center",
        "http://www.atlantahistorycenter.com/",
        33.84,
        -84.39,
        {
          wikidata: "Q2945111",
        },
      ),
      row("n5", "restaurant", "Diner", "https://diner.example.com/"),
      row("n6", "worship", "Church", "https://church.example.org/"),
      row("n7", "bar", "Pub", "https://www.facebook.com/somepub"),
      row("n8", "library", "Far library", "https://far.example.org/", 40.0, -80.0),
      row("n9", "arts_venue", "Alliance", "https://www.alliancetheatre.org/content/shows-events"),
      row("n10", "library", "Known", "https://www.fulcolibrary.org/"),
    ];
    const { candidates, wikidataIds, dropped } = osmCandidates(rows, ATL, {
      denylist,
      skipSites: new Set(["fulcolibrary.org"]),
    });
    const hosts = candidates.map((c) => c.host).sort();
    expect(hosts).toEqual(["alliancetheatre.org", "atlantahistorycenter.com", "mariettaga.gov"]);
    const marietta = candidates.find((c) => c.host === "mariettaga.gov")!;
    expect(marietta.places).toBe(3);
    expect(marietta.place_kind).toBe("sports_centre");
    expect(marietta.url).toBe("https://www.mariettaga.gov/");
    expect(dropped).toEqual({ denylisted: 1, known_source: 1 });
    expect(wikidataIds.get("Q2945111")).toBe("atlantahistorycenter.com");
    const alliance = candidates.find((c) => c.host === "alliancetheatre.org")!;
    expect(alliance.extra_urls).toEqual(["https://www.alliancetheatre.org/content/shows-events"]);
    // kind prior x 20, +25 Wikidata (COLLECTOR_COMPLETION 2.9), +2 per extra place up to 10.
    expect(cheapScore({ place_kind: "arts_venue", wikidata_id: "Q1", places: 1 })).toBe(37);
    expect(marietta.score).toBe(12);
  });

  it("builds Wikidata queries and reads their answers", () => {
    expect(entitiesQuery(["Q1", "Q2"])).toContain("VALUES ?item { wd:Q1 wd:Q2 }");
    const q = aroundQuery(33.749, -84.388, 25);
    expect(q).toContain('"Point(-84.3880 33.7490)"^^geo:wktLiteral');
    expect(q).toContain("wdt:P31/wdt:P279? ?cls");
    const ent = JSON.stringify({
      results: {
        bindings: [
          {
            item: { value: "http://www.wikidata.org/entity/Q3445053" },
            site: { value: "https://www.kennesaw.edu/" },
          },
        ],
      },
    });
    expect(parseEntities(ent).get("Q3445053")).toBe("https://www.kennesaw.edu/");
    const around = JSON.stringify({
      results: {
        bindings: [
          {
            item: { value: "http://www.wikidata.org/entity/Q2028223" },
            site: { value: "https://atlantabg.org/" },
            cls: { value: "http://www.wikidata.org/entity/Q167346" },
            label: { value: "Atlanta Botanical Garden" },
            cc: { value: "US" },
            loc: { value: "Point(-84.373 33.790)" },
          },
          {
            item: { value: "http://www.wikidata.org/entity/Q9" },
            site: { value: "https://far.example.org/" },
            cls: { value: "http://www.wikidata.org/entity/Q33506" },
            loc: { value: "Point(-80 40)" },
          },
        ],
      },
    });
    const list = parseAround(around, ATL, { denylist });
    expect(list).toHaveLength(1);
    expect(list[0]).toMatchObject({
      host: "atlantabg.org",
      origin: "wikidata",
      place_kind: "attraction",
      country: "US",
      wikidata_id: "Q2028223",
    });
    const merged = mergeCandidates(
      osmCandidates([row("n1", "school", "KSU Marietta", "https://www.kennesaw.edu/")], ATL, {
        denylist,
      }).candidates,
      new Map([["Q3445053", "https://www.kennesaw.edu/"]]),
      new Map(),
      list,
      10,
    );
    // school 10 + Wikidata 25 ties attraction 10 + Wikidata 25 (school's prior is 0.5 since
    // COLLECTOR_COMPLETION 2.9); the host breaks the tie.
    expect(merged.map((c) => c.host)).toEqual(["atlantabg.org", "kennesaw.edu"]);
    expect(merged.find((c) => c.host === "kennesaw.edu")?.wikidata_id).toBe("Q3445053");
  });
});

describe("platform marks", () => {
  it("recognises calendar platforms from markup and links only", () => {
    expect(platformsIn('<div class="tribe-events-calendar-list">')).toEqual(["tec"]);
    expect(platformsIn('<script src="https://cdn.localist.com/widget.js"></script>')).toEqual([
      "localist",
    ]);
    expect(platformsIn("<p>Powered by <a href='/x'>Localist</a></p>")).toContain("localist");
    expect(platformsIn("<p>We are not a localist group</p>")).toEqual([]);
    expect(platformsIn('<a href="/iCalendar.aspx">Calendar</a>')).toEqual(["civicplus"]);
    expect(trumbaFeeds('$Trumba.addSpud({ webName: "emory-events", spudType: "main" });')).toEqual([
      "https://www.trumba.com/calendars/emory-events.ics",
    ]);
    expect(
      googleEmbedFeeds(
        '<iframe src="https://calendar.google.com/calendar/embed?src=abc%40group.calendar.google.com&amp;ctz=America%2FNew_York"></iframe>',
      ),
    ).toEqual([
      "https://calendar.google.com/calendar/ical/abc%40group.calendar.google.com/public/basic.ics",
    ]);
  });
});

const HOME = "https://museum.example.org/";
const robots = { "https://museum.example.org/robots.txt": { body: "User-agent: *\nAllow: /\n" } };

describe("probe", () => {
  it("finds an events page from a homepage link and reads its schema.org events", async () => {
    const { fetcher, log } = fetcherWith({
      ...robots,
      [HOME]: { body: html('<a href="/about/">About</a><a href="/whats-on/">What\'s on</a>') },
      "https://museum.example.org/whats-on/": {
        body: html(eventLd("Lecture") + eventLd("Gallery talk", "2026-11-21") + eventLd("Tour")),
      },
    });
    const r = await probe(
      { url: HOME, host: "museum.example.org", origin: "osm", place_kind: "arts_venue" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("ok");
    expect(r.kind).toBe("page");
    expect(r.url).toBe("https://museum.example.org/whats-on/");
    expect(r.in_region).toBe(3);
    expect(r.complete).toBe(true);
    // kind 12 + 3+ JSON-LD events 40.
    expect(r.score).toBe(52);
    // robots.txt, the homepage, the events page: the page collect() reads again is remembered.
    expect(log.map((l) => l.url)).toEqual([
      "https://museum.example.org/robots.txt",
      HOME,
      "https://museum.example.org/whats-on/",
    ]);
    expect(foundCalendar(r)).toBe(true);
  });

  it("prefers the site's own calendar feed and scores it", async () => {
    const { fetcher } = fetcherWith({
      ...robots,
      [HOME]: {
        body: html(
          '<a href="/events/">Events</a>',
          '<link rel="alternate" type="text/calendar" href="/calendar.ics">',
        ),
      },
      "https://museum.example.org/events/": { body: html("<p>See the calendar</p>") },
      "https://museum.example.org/calendar.ics": {
        headers: { "content-type": "text/calendar" },
        body: fixture("calendar.ics"),
      },
    });
    const r = await probe(
      { url: HOME, host: "museum.example.org", origin: "osm", place_kind: "library" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("ok");
    expect(r.kind).toBe("ics");
    expect(r.url).toBe("https://museum.example.org/calendar.ics");
    expect(r.in_region).toBeGreaterThan(0);
    // library 16 + a feed with events 50.
    expect(r.score).toBe(66);
  });

  it("samples The Events Calendar's event pages when its export and list view say noindex", async () => {
    const { fetcher, log } = fetcherWith({
      ...robots,
      [HOME]: {
        body: html(
          '<a href="/visit/">Visit</a>',
          '<link rel="alternate" type="text/calendar" href="https://museum.example.org/events/?ical=1">',
        ),
      },
      "https://museum.example.org/events/": {
        body: html(
          '<div class="tribe-events"><a href="/event/talk/">Talk</a><a href="/event/tour/">Tour</a><a href="/events/list/">List</a></div>',
        ),
      },
      "https://museum.example.org/events/?ical=1": {
        headers: { "content-type": "text/calendar", "x-robots-tag": "noindex" },
        body: fixture("calendar.ics"),
      },
      "https://museum.example.org/events/list/": {
        body: html("", '<meta name="robots" content="noindex, nofollow">'),
      },
      "https://museum.example.org/event/talk/": { body: html(eventLd("Talk")) },
      "https://museum.example.org/event/tour/": { body: html(eventLd("Tour")) },
    });
    const r = await probe(
      { url: HOME, host: "museum.example.org", origin: "osm", place_kind: "arts_venue" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("ok");
    expect(r.kind).toBe("page");
    expect(r.url).toBe("https://museum.example.org/events/");
    expect(r.platform).toBe("tec");
    expect(r.notes).toContain("tec_event_page_sample");
    expect(log.filter((l) => l.url.startsWith(HOME)).length).toBeLessThanOrEqual(8);
  });

  it("marks Localist calendars needs_permission without reading their events", async () => {
    const cal = "https://calendar.example.edu/";
    const { fetcher, log } = fetcherWith({
      "https://www.example.edu/robots.txt": { body: "" },
      "https://calendar.example.edu/robots.txt": { body: "" },
      "https://www.example.edu/": { body: html(`<a href="${cal}">Events</a>`) },
      [cal]: {
        body: html(
          eventLd("Talk"),
          '<link rel="stylesheet" href="https://assets.localist.com/assets/main.css">',
        ),
      },
    });
    const r = await probe(
      { url: "https://www.example.edu/", host: "example.edu", origin: "osm", place_kind: "school" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("needs_permission");
    expect(r.platform).toBe("localist");
    expect(r.url).toBe(cal);
    expect(r.items).toBe(0);
    expect(log.some((l) => l.url.includes("/api/2/"))).toBe(false);
    expect(foundCalendar(r)).toBe(true);
  });

  it("stops at the homepage when it already shows the Localist mark", async () => {
    const { fetcher, log } = fetcherWith({
      "https://www.example.edu/robots.txt": { body: "" },
      "https://www.example.edu/": {
        body: html(
          '<a href="/events/">Events</a><a href="https://example.localist.com/calendar">Calendar</a>',
          '<script src="https://cdn.localist.com/widget.js"></script>',
        ),
      },
      "https://www.example.edu/events/": { body: html(eventLd("Talk")) },
    });
    const r = await probe(
      { url: "https://www.example.edu/", host: "example.edu", origin: "osm", place_kind: "school" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("needs_permission");
    expect(r.platform).toBe("localist");
    expect(r.url).toBe("https://www.example.edu/");
    expect(r.notes).toContain("localist_home");
    expect(log.map((l) => l.url).sort()).toEqual([
      "https://www.example.edu/",
      "https://www.example.edu/robots.txt",
    ]);
  });

  it("guesses /events/ only when no link names an event page", async () => {
    const { fetcher, log } = fetcherWith({
      ...robots,
      [HOME]: { body: html('<a href="/about/">About</a>') },
      "https://museum.example.org/events/": { body: html(eventLd("Open day")) },
    });
    const r = await probe(
      { url: HOME, host: "museum.example.org", origin: "osm" },
      { fetcher, region: ATL, now: NOW },
    );
    expect(r.outcome).toBe("ok");
    expect(r.notes.join(" ")).toContain("guessed");
    expect(log.map((l) => l.url)).toContain("https://museum.example.org/calendar/");
  });

  it("answers robots, blocked, noindex and no_feed", async () => {
    const cases: [Record<string, FakeResponse>, string][] = [
      [
        { "https://museum.example.org/robots.txt": { body: "User-agent: *\nDisallow: /\n" } },
        "robots",
      ],
      [{ ...robots, [HOME]: { status: 403 } }, "blocked"],
      [
        { ...robots, [HOME]: { body: html("", '<meta name="robots" content="noindex">') } },
        "noindex",
      ],
      [{ ...robots, [HOME]: { body: html("<p>Hello</p>") } }, "no_feed"],
    ];
    for (const [routes, outcome] of cases) {
      const { fetcher } = fetcherWith(routes);
      const r = await probe(
        { url: HOME, host: "museum.example.org", origin: "osm" },
        { fetcher, region: ATL, now: NOW },
      );
      expect(r.outcome).toBe(outcome);
    }
  });

  it("calls events outside the region empty and sends at most 8 requests to a host", async () => {
    const far = eventLd("Far away").replace("33.79", "40.7").replace("-84.38", "-74.0");
    const links = Array.from({ length: 12 }, (_, i) => `<a href="/events/e${i}/">Event ${i}</a>`);
    const routes: Record<string, FakeResponse> = {
      ...robots,
      [HOME]: { body: html(`<a href="/events/">Events</a>${links.join("")}`) },
      "https://museum.example.org/events/": { body: html(far + links.join("")) },
    };
    for (let i = 0; i < 12; i++)
      routes[`https://museum.example.org/events/e${i}/`] = { body: html(far) };
    const { fetcher, log } = fetcherWith(routes);
    const r = await probe(
      { url: HOME, host: "museum.example.org", origin: "osm" },
      { fetcher, region: ATL, now: NOW, requestsPerHost: 8 },
    );
    expect(r.outcome).toBe("empty");
    expect(r.in_region).toBe(0);
    expect(log.filter((l) => l.url.startsWith(HOME)).length).toBeLessThanOrEqual(8);
  });

  it("remembers pages within one probe and caps requests per host", async () => {
    const { fetcher, log } = fetcherWith({ ...robots, [HOME]: { body: "x" } });
    const pf = new ProbeFetcher(fetcher, 3);
    await pf.get(HOME);
    await pf.get(HOME);
    expect(log.filter((l) => l.url === HOME)).toHaveLength(1);
    await pf.get(`${HOME}a`);
    const r = await pf.get(`${HOME}b`);
    expect(r.ok).toBe(false);
    expect(!r.ok && r.reason).toBe("host_budget_spent");
  });
});

describe("probe request cap", () => {
  it("counts redirect hops and robots.txt against a host's 8 requests", async () => {
    const routes: Record<string, FakeResponse> = { ...robots };
    for (let i = 0; i < 10; i++)
      routes[`https://museum.example.org/p${i}`] = {
        status: 301,
        headers: { location: `https://museum.example.org/p${i}/` },
      };
    const c = fakeClock();
    const { transport, log } = fakeTransport(routes, c.clock);
    const fetcher = new PoliteFetcher({
      denylist,
      transport,
      now: c.now,
      sleep: c.sleep,
      maxRequestsFor: probeHostAllowance(8),
    });
    const pf = new ProbeFetcher(fetcher, 8);
    for (let i = 0; i < 10; i++) await pf.get(`https://museum.example.org/p${i}`);
    expect(log.filter((l) => l.url.startsWith(HOME)).length).toBe(8);
    expect(probeHostAllowance(8)("www.trumba.com")).toBeUndefined();
    expect(probeHostAllowance(8)("museum.example.org")).toBe(8);
  });
});

describe("gate report", () => {
  it("counts a site as rediscovered when a probe found a calendar on it", async () => {
    const res = (host: string, outcome: ProbeResult["outcome"], inRegion = 0, url?: string) =>
      ({
        candidate: { host, url: `https://${host}/`, origin: "osm" },
        outcome,
        in_region: inRegion,
        url: url ?? null,
        kind: null,
        platform: null,
      }) as unknown as ProbeResult;
    const expected = [
      { seed: "a", site: "a.org" },
      { seed: "b", site: "b.edu" },
      { seed: "c", site: "c.org" },
      { seed: "d", site: "d.org" },
    ];
    const report = gateReport(
      [
        res("a.org", "ok", 4),
        res("b.edu", "needs_permission", 0, "https://calendar.b.edu/"),
        res("c.org", "empty"),
        res("x.org", "ok", 2, "https://www.trumba.com/calendars/x.ics"),
      ],
      [],
      expected,
      2,
    );
    expect(report.found).toBe(2);
    expect(report.foundWithItems).toBe(1);
    expect(report.passed).toBe(true);
    expect(report.rows.map((r) => r.found)).toEqual([true, true, false, false]);
    expect(gateReport([], [], expected, 3).passed).toBe(false);
  });

  it("probes several hosts with one shared fetcher", async () => {
    const { fetcher } = fetcherWith({
      ...robots,
      [HOME]: { body: html('<a href="/events/">Events</a>') },
      "https://museum.example.org/events/": { body: html(eventLd("Talk")) },
      "https://other.example.org/robots.txt": { body: "" },
      "https://other.example.org/": { status: 500 },
    });
    const out = await probeAll(
      [
        { url: HOME, host: "museum.example.org", origin: "osm" },
        { url: "https://other.example.org/", host: "other.example.org", origin: "osm" },
      ],
      { region: ATL, fetcher, now: NOW, caps: cfg.caps },
    );
    expect(out.map((r) => r.outcome)).toEqual(["ok", "error"]);
  });
});

describe("probe hash", () => {
  it("is 32 hex and stable", () => {
    const h = probeHash();
    expect(h).toMatch(/^[0-9a-f]{32}$/);
    expect(probeHash()).toBe(h);
  });
});

// Collector completion 2.9: discovery tuning from the staging numbers.
describe("discovery tuning", () => {
  it("uses the tuned priors and the Wikidata bonus as the fallback", () => {
    expect([
      KIND_PRIOR.community,
      KIND_PRIOR.cinema,
      KIND_PRIOR.school,
      KIND_PRIOR.library,
    ]).toEqual([0.7, 0.15, 0.5, 0.8]);
    expect(WIKIDATA_BONUS).toBe(25);
    expect(score2({ place_kind: "community", places: 1 })).toBe(14);
    expect(score2({ place_kind: "community", wikidata_id: "Q1", places: 1 })).toBe(39);
  });
  it("switches a kind to its learned yield at 30 probes", () => {
    const below = { cinema: { probed: LEARNED_MIN_PROBES - 1, good: 20 } };
    expect(learnedPrior("cinema", below)).toBe(0.15);
    const at = { cinema: { probed: 30, good: 0 }, community: { probed: 35, good: 9 } };
    expect(learnedPrior("cinema", at)).toBe(0.1); // max(0.1, 1/35)
    expect(learnedPrior("community", at)).toBe(0.25); // (9 + 1) / (35 + 5)
    expect(score2({ place_kind: "community", places: 1 }, at)).toBe(5);
    expect(learnedPrior("library", at)).toBe(0.8);
  });
  it("reads GET /collector/discovery/yield and drops junk", () => {
    expect(
      parseYield({
        kinds: {
          cinema: { probed: 30, good: 0 },
          "Bad Kind": { probed: 1, good: 1 },
          park: { probed: "x" },
        },
      }),
    ).toEqual({
      cinema: { probed: 30, good: 0 },
    });
    expect(parseYield(null)).toEqual({});
  });
});
