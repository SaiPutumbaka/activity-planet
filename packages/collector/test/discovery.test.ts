import { describe, expect, it } from "vitest";
import { localistEventsUrl, parseLocalist } from "../src/adapters/localist.ts";
import { collect } from "../src/collect.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { discoverLinks, scanHtml } from "../src/parse/html.ts";
import {
  classifyLink,
  googlePublicIcs,
  isActionPath,
  isPerEventExport,
} from "../src/parse/links.ts";
import { Denylist } from "../src/policy/denylist.ts";
import type { CityFile, Seed } from "../src/types.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const PAGE = "https://calendar.example.edu/";
const b64 = (s: string) => Buffer.from(s, "utf8").toString("base64");

describe("Google Calendar links", () => {
  it("turns a public calendar id (plain or base64) into its public ICS", () => {
    const id = "c_abc123@group.calendar.google.com";
    const ics = googlePublicIcs(id);
    expect(ics).toBe(
      "https://calendar.google.com/calendar/ical/c_abc123%40group.calendar.google.com/public/basic.ics",
    );
    expect(
      classifyLink(`https://calendar.google.com/calendar/embed?src=${encodeURIComponent(id)}`),
    ).toEqual({ kind: "feed", urls: [ics] });
    expect(classifyLink(`https://calendar.google.com/calendar/u/0/r?cid=${b64(id)}`)).toEqual({
      kind: "feed",
      urls: [ics],
    });
    // Already the public export: kept as is.
    expect(classifyLink(ics)).toEqual({ kind: "feed", urls: [ics] });
  });

  it("unwraps a subscribe link to the site's own feed", () => {
    const sub = `https://calendar.google.com/calendar/render?cid=${encodeURIComponent("webcal://calendar.example.edu/calendar.ics")}`;
    expect(classifyLink(sub)).toEqual({
      kind: "feed",
      urls: ["https://calendar.example.edu/calendar.ics"],
    });
    expect(
      classifyLink(
        `https://calendar.google.com/calendar/r?cid=${b64("https://calendar.example.edu/x.ics")}`,
      ),
    ).toEqual({ kind: "feed", urls: ["https://calendar.example.edu/x.ics"] });
  });

  it("never follows render, add-to-calendar or private pages", () => {
    expect(
      classifyLink(
        "https://calendar.google.com/calendar/render?action=TEMPLATE&text=Talk&dates=20261110T190000Z/20261110T200000Z",
      ),
    ).toEqual({ kind: "skip", reason: "calendar_action" });
    expect(classifyLink("https://www.google.com/calendar/event?action=TEMPLATE&text=x")).toEqual({
      kind: "skip",
      reason: "calendar_action",
    });
    expect(classifyLink("https://calendar.google.com/calendar/render")).toEqual({
      kind: "skip",
      reason: "google_calendar_page",
    });
    expect(
      classifyLink(
        "https://calendar.google.com/calendar/ical/me%40gmail.com/private-abc/basic.ics",
      ),
    ).toEqual({ kind: "skip", reason: "google_calendar_page" });
    expect(classifyLink("https://calendar.google.com/calendar/r?cid=not*valid")).toEqual({
      kind: "skip",
      reason: "google_calendar_page",
    });
    expect(
      classifyLink("https://outlook.live.com/calendar/0/deeplink/compose?subject=x").kind,
    ).toBe("skip");
    // A cid that points back into Google Calendar is resolved once, never looped.
    const inner = `https://calendar.google.com/calendar/render?cid=${encodeURIComponent("https://calendar.google.com/calendar/render")}`;
    expect(classifyLink(inner)).toEqual({ kind: "skip", reason: "google_calendar_page" });
  });
});

describe("action pages", () => {
  it("skips Localist confirm, register and create pages and sign-in pages", () => {
    for (const u of [
      "https://calendar.example.edu/event/fall_concert/confirm",
      "https://calendar.example.edu/event/fall_concert/register",
      "https://calendar.example.edu/event/create",
      "https://calendar.example.edu/events/new",
      "https://calendar.example.edu/login",
      "https://calendar.example.edu/auth/saml",
      "https://calendar.example.edu/signup",
    ])
      expect(isActionPath(u), u).toBe(true);
    for (const u of [
      "https://calendar.example.edu/event/fall_concert",
      "https://calendar.example.edu/event/creative_writing_workshop",
      "https://calendar.example.edu/events/registration-day-fair",
      "https://calendar.example.edu/calendar/week",
    ])
      expect(isActionPath(u), u).toBe(false);
  });

  it("tells single-event exports from calendar-wide ones", () => {
    expect(isPerEventExport("https://x.org/event/welcome/?ical=1")).toBe(true);
    expect(isPerEventExport("https://x.org/event/welcome.ics")).toBe(true);
    expect(isPerEventExport("https://x.org/events/?ical=1")).toBe(false);
    expect(isPerEventExport("https://x.org/events/list/?ical=1")).toBe(false);
    expect(isPerEventExport("https://x.org/events/category/kids/?ical=1")).toBe(false);
    expect(isPerEventExport("https://x.org/events/2026-11/?ical=1")).toBe(false);
    expect(isPerEventExport("https://x.org/calendar.ics")).toBe(false);
  });

  it("discovery drops Google pages and action links and ranks feeds", () => {
    const html = [
      '<link rel="alternate" type="text/calendar" href="/calendar.ics">',
      '<a href="/event/talk/?ical=1">Export</a>',
      '<a href="/events/?ical=1">All events</a>',
      `<a href="https://calendar.google.com/calendar/render?cid=${encodeURIComponent("webcal://calendar.example.edu/calendar.ics")}">Google</a>`,
      '<a href="https://calendar.google.com/calendar/render?action=TEMPLATE&text=Talk">Add</a>',
      '<a href="/event/talk/confirm">I am going</a>',
      '<a href="/event/create">Submit an event</a>',
      '<a href="/event/talk">Talk</a>',
    ].join("");
    const found = discoverLinks(scanHtml(html, PAGE), () => true);
    expect(found.feeds).toEqual([
      "https://calendar.example.edu/calendar.ics",
      "https://calendar.example.edu/events/?ical=1",
      "https://calendar.example.edu/event/talk/?ical=1",
    ]);
    expect(found.pages).toEqual(["https://calendar.example.edu/event/talk"]);
    expect(found.skipped).toEqual({ calendar_action: 1, action_page: 2 });
  });
});

const LOCALIST_PAGE_1 = JSON.stringify({
  events: [
    {
      event: {
        id: 101,
        title: "Fall Concert &amp; Reception",
        description_text: "An evening of music.",
        localist_url: "https://calendar.example.edu/event/fall_concert",
        location_name: "Bailey Center",
        room_number: "Morgan Hall",
        geo: { latitude: "34.0384", longitude: "-84.5816" },
        free: false,
        ticket_cost: "$10",
        status: "live",
        experience: "inperson",
        departments: [{ name: "School of Music" }],
        filters: { event_types: [{ name: "Arts" }], event_target_audience: [{ name: "Public" }] },
        event_instances: [
          {
            event_instance: {
              id: 9001,
              start: "2026-11-10T19:30:00-05:00",
              end: "2026-11-10T21:00:00-05:00",
              all_day: false,
            },
          },
        ],
      },
    },
    {
      event: {
        id: 102,
        title: "Last day to withdraw",
        filters: { event_types: [{ name: "Academic Calendar & Deadlines" }] },
        event_instances: [{ event_instance: { id: 1, start: "2026-11-12", all_day: true } }],
      },
    },
    {
      event: {
        id: 103,
        title: "Private review",
        private: true,
        event_instances: [{ event_instance: { id: 2, start: "2026-11-12T10:00:00-05:00" } }],
      },
    },
  ],
  page: { current: 1, size: 100, total: 2 },
});
const LOCALIST_PAGE_2 = JSON.stringify({
  events: [
    {
      event: {
        id: 104,
        title: "Webinar: Careers in Data",
        experience: "virtual",
        status: "cancelled",
        localist_url: "https://calendar.example.edu/event/webinar",
        event_instances: [{ event_instance: { id: 3, start: "2026-11-14", all_day: true } }],
      },
    },
  ],
  page: { current: 2, size: 100, total: 2 },
});

const LOCALIST_SEED: Seed = {
  id: "test-localist",
  kind: "localist",
  url: "https://calendar.example.edu/api/2/events",
  name: "Example Localist",
  attribution: "Listed from the Example public calendar (calendar.example.edu).",
};

describe("Localist API seeds", () => {
  it("builds the documented /api/2/events URL", () => {
    expect(localistEventsUrl(LOCALIST_SEED, 60, 1)).toBe(
      "https://calendar.example.edu/api/2/events?days=60&pp=100&page=1",
    );
    expect(
      localistEventsUrl({ ...LOCALIST_SEED, url: "https://cal.example.edu/?type=123" }, 999, 2),
    ).toBe("https://cal.example.edu/api/2/events?type=123&days=370&pp=100&page=2");
  });

  it("parses instances, skips private and academic-calendar entries", () => {
    const p = parseLocalist(LOCALIST_PAGE_1, "https://calendar.example.edu/api/2/events");
    expect(p).toMatchObject({ page: 1, totalPages: 2 });
    expect(p.events).toHaveLength(1);
    expect(p.events[0]).toMatchObject({
      lane: "feed",
      uid: "101:9001",
      title: "Fall Concert & Reception",
      start: "2026-11-10T19:30:00-05:00",
      location: "Bailey Center, Morgan Hall",
      lat: 34.0384,
      lng: -84.5816,
      isFree: false,
      priceText: "$10",
      host: "School of Music",
      url: "https://calendar.example.edu/event/fall_concert",
    });
    expect(p.events[0]?.categories).toEqual(["Arts"]);
  });

  it("pages through the API politely and never crawls the calendar's HTML", async () => {
    const c = fakeClock();
    const json = (body: string): FakeResponse => ({
      body,
      headers: { "content-type": "application/json" },
    });
    const routes: Record<string, FakeResponse> = {
      "https://calendar.example.edu/robots.txt": {
        body: "User-agent: *\nDisallow: /event/*/confirm\n",
      },
      "https://calendar.example.edu/api/2/events?days=60&pp=100&page=1": json(LOCALIST_PAGE_1),
      "https://calendar.example.edu/api/2/events?days=60&pp=100&page=2": json(LOCALIST_PAGE_2),
    };
    const { transport, log } = fakeTransport(routes, c.clock);
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
    });
    const city: CityFile = { region: ATL, seeds: [LOCALIST_SEED] };
    const result = await collect({ regions: [ATL], cities: [city], fetcher, now: NOW });
    const batch = result.batches[0]!;
    expect(batch.items.map((i) => i.title)).toEqual([
      "Fall Concert & Reception",
      "Webinar: Careers in Data",
    ]);
    const webinar = batch.items[1]!;
    expect(webinar).toMatchObject({ location: "Online", cancelled: true, all_day: true });
    expect(log.map((l) => new URL(l.url).pathname)).toEqual([
      "/robots.txt",
      "/api/2/events",
      "/api/2/events",
    ]);
    expect(result.errors).toEqual([]);
  });

  it("honours X-Robots-Tag nosnippet and noindex on the API response", async () => {
    const ONE_PAGE = JSON.stringify({
      events: [
        {
          event: {
            id: 201,
            title: "Lecture",
            description_text: "A talk about birds in the city and where to find them.",
            localist_url: "https://calendar.example.edu/event/lecture",
            event_instances: [{ event_instance: { id: 1, start: "2026-11-12T18:00:00-05:00" } }],
          },
        },
      ],
      page: { current: 1, size: 100, total: 1 },
    });
    const run = async (xrt: string) => {
      const c = fakeClock();
      const { transport } = fakeTransport(
        {
          "https://calendar.example.edu/robots.txt": { body: "User-agent: *\nAllow: /\n" },
          "https://calendar.example.edu/api/2/events?days=60&pp=100&page=1": {
            body: ONE_PAGE,
            headers: { "content-type": "application/json", "x-robots-tag": xrt },
          },
        },
        c.clock,
      );
      const fetcher = new PoliteFetcher({
        denylist: Denylist.load(),
        transport,
        now: c.now,
        sleep: c.sleep,
      });
      return collect({
        regions: [ATL],
        cities: [{ region: ATL, seeds: [LOCALIST_SEED] }],
        fetcher,
        now: NOW,
      });
    };
    const plain = await run("all");
    expect(plain.batches[0]!.items[0]?.description).toContain("birds");
    const snipped = await run("nosnippet");
    expect(snipped.batches[0]!.items).toHaveLength(1);
    expect(snipped.batches[0]!.items[0]?.description ?? "").toBe("");
    const hidden = await run("noindex");
    expect(hidden.batches[0]?.items ?? []).toEqual([]);
    expect(hidden.errors.map((e) => e.reason)).toEqual(["noindex"]);
  });

  it("reads the calendar as a page when robots.txt keeps us off the API", async () => {
    const c = fakeClock();
    const page = [
      fixture("jsonld-graph.html"),
      '<a href="/event/fall_concert/confirm">Going</a>',
      '<a href="https://calendar.google.com/calendar/render?action=TEMPLATE&text=x">Add</a>',
    ].join("");
    const { transport, log } = fakeTransport(
      {
        "https://calendar.example.edu/robots.txt": { body: "User-agent: *\nDisallow: /api/\n" },
        "https://calendar.example.edu/": { body: page, headers: { "content-type": "text/html" } },
      },
      c.clock,
    );
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
    });
    const result = await collect({
      regions: [ATL],
      cities: [{ region: ATL, seeds: [LOCALIST_SEED] }],
      fetcher,
      now: NOW,
    });
    expect(result.errors.map((e) => e.reason)).toContain("robots_disallowed");
    expect(result.batches[0]!.items.length).toBeGreaterThan(0);
    const paths = log.map((l) => new URL(l.url).pathname);
    expect(paths.some((p) => p.startsWith("/api/"))).toBe(false);
    expect(paths.some((p) => p.endsWith("/confirm"))).toBe(false);
    expect(log.some((l) => l.url.includes("google.com"))).toBe(false);
    // The confirm link and the fixture's /login link; the Google add-to-calendar button.
    expect(result.stats.linksSkipped).toMatchObject({ action_page: 2, calendar_action: 1 });
  });
});

describe("a page's own feed is preferred over crawling", () => {
  const html = (body: string): FakeResponse => ({
    body,
    headers: { "content-type": "text/html" },
  });
  const ics: FakeResponse = {
    body: fixture("calendar.ics"),
    headers: { "content-type": "text/calendar" },
  };
  const page = [
    '<link rel="alternate" type="text/calendar" href="/events/?ical=1">',
    '<a href="/event/one/?ical=1">Export one</a>',
    '<a href="/event/one/">One</a>',
    '<a href="/event/two/">Two</a>',
    `<a href="https://calendar.google.com/calendar/render?cid=${encodeURIComponent("webcal://museum.example.org/events/?ical=1")}">Google</a>`,
  ].join("");
  const routes: Record<string, FakeResponse> = {
    "https://museum.example.org/robots.txt": { status: 404 },
    "https://museum.example.org/events/": html(page),
    "https://museum.example.org/events/?ical=1": ics,
    "https://museum.example.org/event/one/?ical=1": ics,
    "https://museum.example.org/event/one/": html(fixture("jsonld-graph.html")),
    "https://museum.example.org/event/two/": html(fixture("jsonld-graph.html")),
  };
  const seed: Seed = {
    id: "test-museum",
    kind: "page",
    url: "https://museum.example.org/events/",
    name: "Museum",
    attribution: "Listed from the museum calendar (museum.example.org).",
  };

  async function runWith(s: Seed, r: Record<string, FakeResponse> = routes) {
    const c = fakeClock();
    const { transport, log } = fakeTransport(r, c.clock);
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
    });
    const result = await collect({
      regions: [ATL],
      cities: [{ region: ATL, seeds: [s] }],
      fetcher,
      now: NOW,
    });
    return { result, urls: log.map((l) => l.url) };
  }

  it("reads the calendar-wide feed once and skips event pages and single-event exports", async () => {
    const { result, urls } = await runWith(seed);
    expect(urls).toEqual([
      "https://museum.example.org/robots.txt",
      "https://museum.example.org/events/",
      "https://museum.example.org/events/?ical=1",
    ]);
    expect(result.batches[0]!.items.length).toBeGreaterThan(0);
    expect(urls.some((u) => u.includes("google.com"))).toBe(false);
  });

  it("falls back to exports and pages when the feed gives nothing", async () => {
    const { urls } = await runWith(seed, {
      ...routes,
      "https://museum.example.org/events/?ical=1": { status: 500 },
    });
    expect(urls).toContain("https://museum.example.org/event/one/?ical=1");
    expect(urls).toContain("https://museum.example.org/event/one/");
    expect(urls).toContain("https://museum.example.org/event/two/");
  });

  it("still crawls pages when the seed asks for it", async () => {
    const { urls } = await runWith({ ...seed, crawlPages: true });
    expect(urls).toContain("https://museum.example.org/event/two/");
    // The single-event export stays skipped: the calendar-wide feed already gave events.
    expect(urls).not.toContain("https://museum.example.org/event/one/?ical=1");
  });
});

describe("long Crawl-delay", () => {
  it("is honoured at its own spacing, with the host's requests capped by the run budget", async () => {
    const c = fakeClock();
    const routes: Record<string, FakeResponse> = {
      "https://slow.example.org/robots.txt": { body: "User-agent: *\nCrawl-delay: 120\n" },
    };
    for (let i = 0; i < 10; i++) routes[`https://slow.example.org/${i}`] = { body: String(i) };
    const { transport, log } = fakeTransport(routes, c.clock);
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
      slowHostBudgetMs: 5 * 60_000,
    });
    expect(fetcher.slowHostAllowance(120)).toBe(3);
    expect(fetcher.slowHostAllowance(301)).toBe(0);
    const results = [];
    for (let i = 0; i < 5; i++) results.push(await fetcher.get(`https://slow.example.org/${i}`));
    expect(results.map((r) => (r.ok ? "ok" : r.reason))).toEqual([
      "ok",
      "ok",
      "ok",
      "crawl_budget_spent",
      "crawl_budget_spent",
    ]);
    const sent = log.filter((l) => !l.url.endsWith("robots.txt"));
    expect(sent).toHaveLength(3);
    for (let i = 1; i < sent.length; i++)
      expect((sent[i]?.at ?? 0) - (sent[i - 1]?.at ?? 0)).toBeGreaterThanOrEqual(120_000);
  });

  it("skips a host whose delay is longer than the whole budget", async () => {
    const c = fakeClock();
    const { transport, log } = fakeTransport(
      { "https://never.example.org/robots.txt": { body: "User-agent: *\nCrawl-delay: 900\n" } },
      c.clock,
    );
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
    });
    expect(await fetcher.get("https://never.example.org/x")).toMatchObject({
      ok: false,
      reason: "crawl_delay_too_long",
    });
    expect(log.map((l) => l.url)).toEqual(["https://never.example.org/robots.txt"]);
  });
});
