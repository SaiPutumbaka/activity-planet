import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import { citiesFor, loadCities, parseCityFile } from "../src/config.ts";
import { DryRunIngest } from "../src/ingest.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import type { CityFile } from "../src/types.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const html = (body: string, headers: Record<string, string> = {}): FakeResponse => ({
  body,
  headers: { "content-type": "text/html; charset=utf-8", ...headers },
});

const SITE: Record<string, FakeResponse> = {
  "https://parks.example.gov/robots.txt": { body: "User-agent: *\nDisallow: /admin/\n" },
  // Seed page: JSON-LD events, two feed links, a webcal link, event-page links.
  "https://parks.example.gov/events/": html(fixture("jsonld-graph.html")),
  "https://parks.example.gov/events/?ical=1": {
    body: fixture("calendar.ics"),
    headers: { "content-type": "text/calendar" },
  },
  "https://parks.example.gov/events/feed/": {
    body: fixture("events.rss"),
    headers: { "content-type": "application/rss+xml" },
  },
  // Discovered event pages: one says noindex in a header, one is a sign-in page.
  "https://parks.example.gov/events/yoga/": html(fixture("jsonld-graph.html"), {
    "x-robots-tag": "noindex",
  }),
  "https://parks.example.gov/events/tai-chi/": html(
    '<form action="/s"><input type="password"></form>',
  ),
  // A second seed: microdata page with noindex meta is skipped; a plain ICS seed.
  "https://library.example.org/robots.txt": { status: 404 },
  "https://library.example.org/hidden": html(
    '<meta name="robots" content="noindex">' + fixture("microdata.html"),
  ),
  "https://library.example.org/calendar": html(fixture("microdata.html")),
  "https://library.example.org/blocked/cal.ics": { body: fixture("calendar.ics") },
  "https://blocked.example.org/robots.txt": {
    body: "User-agent: ActivityPlanetBot\nDisallow: /\n",
  },
  "https://blocked.example.org/events": html(fixture("jsonld-graph.html")),
  // Ticketmaster page 0 (page 1 is missing: the run records the error and keeps page 0).
};

const CITY: CityFile = {
  region: ATL,
  seeds: [
    {
      id: "test-parks",
      kind: "page",
      url: "https://parks.example.gov/events/",
      name: "Parks",
      attribution: "Listed from the parks calendar (parks.example.gov).",
    },
    {
      id: "test-library",
      kind: "page",
      url: "https://library.example.org/calendar",
      name: "Library",
      attribution: "Listed from the library calendar (library.example.org).",
    },
    {
      id: "test-hidden",
      kind: "page",
      url: "https://library.example.org/hidden",
      name: "Hidden",
      attribution: "Listed from a hidden calendar (library.example.org).",
    },
    {
      id: "test-blocked",
      kind: "page",
      url: "https://blocked.example.org/events",
      name: "Blocked",
      attribution: "Listed from a blocked calendar (blocked.example.org).",
    },
    {
      id: "test-meetup",
      kind: "page",
      url: "https://www.meetup.com/atl/events/",
      name: "Meetup",
      attribution: "Never fetched (denylisted).",
    },
    {
      id: "test-off",
      kind: "ics",
      url: "https://off.example.org/cal.ics",
      name: "Off",
      attribution: "Never fetched (enabled false).",
      enabled: false,
    },
  ],
};

async function run(env: Record<string, string> = {}, routes: Record<string, FakeResponse> = SITE) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    transport,
    now: c.now,
    sleep: c.sleep,
  });
  const result = await collect({
    regions: [ATL],
    cities: [CITY],
    fetcher,
    env,
    now: NOW,
    windowDays: 60,
  });
  return { result, log };
}

describe("collect (fixtures, no network)", () => {
  it("runs every lane through politeness and returns one batch per source", async () => {
    const { result, log } = await run();
    const byKey = Object.fromEntries(result.batches.map((b) => [b.sourceKey, b]));
    expect(Object.keys(byKey).sort()).toEqual([
      "test-blocked",
      "test-hidden",
      "test-library",
      "test-meetup",
      "test-parks",
    ]);

    // Parks: JSON-LD (2) + discovered ICS + discovered RSS, minus cross-run duplicates.
    const parks = byKey["test-parks"]!;
    const titles = parks.items.map((i) => i.title);
    expect(titles).toContain("Sunrise Yoga in the Park");
    expect(titles).toContain("Farmers Market, Square Edition");
    expect(titles).toContain("Teen Anime Club");
    expect(
      parks.items.every(
        (i) => i.attribution === "Listed from the parks calendar (parks.example.gov).",
      ),
    ).toBe(true);
    expect(parks.items.every((i) => i.url.startsWith("https://"))).toBe(true);
    expect(parks.items.every((i) => i.cover_url === null)).toBe(true);
    expect(parks.items.every((i) => i.description.length <= 280)).toBe(true);
    // ICS ids from a discovered feed are prefixed so two feeds cannot collide.
    expect(parks.items.find((i) => i.title === "Fall Festival")?.external_id).toMatch(
      /^f[0-9a-f]{8}:allday-1@example\.gov$/,
    );
    // Jazz on the Lawn is cancelled in JSON-LD and still listed as cancelled.
    expect(parks.items.find((i) => i.title === "Jazz on the Lawn")?.cancelled).toBe(true);
    // The Board Game Night item has no point: kept (its source is seeded here).
    expect(parks.items.find((i) => i.title === "Board Game Night")).toBeDefined();

    // Microdata seed.
    expect(byKey["test-library"]!.items.map((i) => i.title).sort()).toEqual([
      "Knitting Circle",
      "Pickup Soccer",
    ]);
    // noindex meta, robots Disallow for our bot, and denylist all yield nothing.
    expect(byKey["test-hidden"]!.items).toHaveLength(0);
    expect(byKey["test-blocked"]!.items).toHaveLength(0);
    expect(byKey["test-meetup"]!.items).toHaveLength(0);

    const reasons = result.errors.map((e) => `${e.sourceKey}:${e.reason}`);
    expect(reasons).toContain("test-parks:noindex"); // yoga page X-Robots-Tag
    expect(reasons).toContain("test-parks:login_page"); // tai-chi sign-in form
    expect(reasons).toContain("test-hidden:noindex");
    expect(reasons).toContain("test-blocked:robots_disallowed");
    expect(reasons).toContain("test-meetup:denylisted");

    // Never requested: denylisted, disabled, nofollow-linked, login and off-site links.
    const urls = log.map((l) => l.url);
    expect(
      urls.some((u) => /meetup|facebook|off\.example|login|other\.example|\/jazz\//.test(u)),
    ).toBe(false);
    expect(urls).not.toContain("https://blocked.example.org/events");
    // robots.txt once per host.
    expect(urls.filter((u) => u === "https://parks.example.gov/robots.txt")).toHaveLength(1);
    // The 404 webcal feed is an error, not a crash.
    expect(reasons).toContain("test-parks:http_error");
  });

  it("drops items outside the region, ended or beyond the window, and duplicates", async () => {
    const { result } = await run();
    const parks = result.batches.find((b) => b.sourceKey === "test-parks")!;
    // calendar.ics: "Long gone" is outside the window in the parser already; the ICS
    // fixture's weekly series has six instances inside the window.
    expect(parks.items.filter((i) => i.title.startsWith("Weekly Run Club"))).toHaveLength(6);
    // Every item's external id is unique within its batch.
    for (const b of result.batches)
      expect(new Set(b.items.map((i) => i.external_id)).size).toBe(b.items.length);
    // The yoga event appears once even though the page lists it in JSON-LD and the yoga
    // page (noindex) would have listed it again.
    expect(parks.items.filter((i) => i.title === "Sunrise Yoga in the Park")).toHaveLength(1);
  });

  it("no-ops the API lane without keys and uses it with them", async () => {
    const without = await run();
    expect(without.result.batches.some((b) => b.sourceKey.startsWith("ticketmaster"))).toBe(false);
    expect(
      without.log.some((l) => l.url.includes("ticketmaster") || l.url.includes("seatgeek")),
    ).toBe(false);

    const routes: Record<string, FakeResponse> = { ...SITE };
    const withKeys = await run(
      { TICKETMASTER_API_KEY: "tm-key", SEATGEEK_CLIENT_ID: "sg-id" },
      new Proxy(routes, {
        get(target, prop: string) {
          if (
            prop.startsWith("https://app.ticketmaster.com/") &&
            new URL(prop).searchParams.get("page") === "0"
          ) {
            return {
              body: fixture("ticketmaster.json"),
              headers: { "content-type": "application/json" },
            };
          }
          if (prop.startsWith("https://api.seatgeek.com/"))
            return { body: fixture("seatgeek.json") };
          return target[prop];
        },
      }),
    );
    const tm = withKeys.result.batches.find((b) => b.sourceKey === "ticketmaster-atl")!;
    expect(tm.items.map((i) => i.title)).toEqual(["Hawks vs. Celtics", "Concert Cancelled"]);
    expect(tm.items[1]?.starts_at).toBe("2026-11-23T01:00:00.000Z"); // 8 pm in the venue zone
    expect(tm.attribution).toMatch(/Ticketmaster/);
    const sg = withKeys.result.batches.find((b) => b.sourceKey === "seatgeek-atl")!;
    expect(sg.items.map((i) => i.title)).toEqual(["Atlanta United FC vs. Inter Miami"]);
    expect(sg.skipped.outside_region).toBe(1); // the New York show
    // Ticketmaster page 1 was a 404: recorded with the key redacted.
    const tmErr = withKeys.result.errors.find((e) => e.sourceKey === "ticketmaster-atl");
    expect(tmErr?.url).toContain("apikey=REDACTED");
    expect(JSON.stringify(withKeys.result.errors)).not.toContain("tm-key");
  });

  it("prints counts only in the dry run", async () => {
    const { result } = await run();
    const lines: string[] = [];
    const ingest = new DryRunIngest((l) => lines.push(l));
    for (const b of result.batches) await ingest.send(b);
    expect(lines).toHaveLength(result.batches.length);
    expect(lines[0]).toMatch(
      /^\[dry-run\] source=test-parks region=atl items=\d+ with_point=\d+ cancelled=\d+ skipped=\{/,
    );
    expect(lines.join("\n")).not.toContain("Yoga");
  });
});

describe("city seed files", () => {
  it("loads and validates every city file; Atlanta covers the required kinds of source", () => {
    const cities = loadCities();
    const atl = cities.find((c) => c.region.id === "atl");
    expect(atl).toBeDefined();
    const ids = atl!.seeds.map((s) => s.id);
    for (const want of [
      "library",
      "parks",
      "beltline",
      "high-museum",
      "georgia-tech",
      "emory",
      "kennesaw",
      "marietta",
      "decatur",
      "open-data",
    ]) {
      expect(
        ids.some((id) => id.includes(want)),
        want,
      ).toBe(true);
    }
    const deny = Denylist.load();
    for (const s of atl!.seeds) expect(deny.check(s.url).denied, s.id).toBe(false);
  });

  it("matches cities to user regions by overlap", () => {
    const cities = loadCities();
    expect(
      citiesFor(
        { id: "decatur", label: "Decatur", lat: 33.7748, lng: -84.2963, radiusKm: 5 },
        cities,
      ).map((c) => c.region.id),
    ).toEqual(["atl"]);
    expect(
      citiesFor({ id: "nyc", label: "NYC", lat: 40.73, lng: -73.99, radiusKm: 20 }, cities),
    ).toEqual([]);
  });

  it("rejects bad seed files", () => {
    const region = { id: "xx", label: "X", lat: 0, lng: 0, radiusKm: 10 };
    expect(() =>
      parseCityFile(
        JSON.stringify({
          region,
          seeds: [
            {
              id: "Bad Id",
              kind: "page",
              url: "https://x.org",
              name: "X",
              attribution: "Listed from X.",
            },
          ],
        }),
        "t",
      ),
    ).toThrow(/seed Bad Id: id must/);
    expect(() =>
      parseCityFile(
        JSON.stringify({
          region,
          seeds: [
            {
              id: "x-1",
              kind: "page",
              url: "http://x.org",
              name: "X",
              attribution: "Listed from X.",
            },
          ],
        }),
        "t",
      ),
    ).toThrow(/https/);
    expect(() =>
      parseCityFile(
        JSON.stringify({ region: { ...region, timezone: "Mars/Base" }, seeds: [] }),
        "t",
      ),
    ).toThrow(/timezone/);
  });
});
