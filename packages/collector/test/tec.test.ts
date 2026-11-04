// The Events Calendar (WordPress) sites whose ?ical=1 export answers with X-Robots-Tag:
// noindex. The export is never read; the calendar's own indexable HTML views (list, month,
// ?eventDisplay=list) and single event pages are read as schema.org markup (lane 3) instead,
// each page under its own noindex / nosnippet / nofollow, within the per-host request budget
// and the run deadline.

import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import { loadCities } from "../src/config.ts";
import { PoliteFetcher, type Transport } from "../src/net/fetcher.ts";
import { discoverLinks, isListingView, scanHtml, tecListViewsFor } from "../src/parse/html.ts";
import { Denylist } from "../src/policy/denylist.ts";
import type { CityFile, Seed } from "../src/types.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW, type FakeResponse } from "./helpers.ts";

const ORIGIN = "https://arts.example.org";

const html = (body: string, headers: Record<string, string> = {}): FakeResponse => ({
  body,
  headers: { "content-type": "text/html; charset=UTF-8", ...headers },
});

function eventPage(slug: string, title: string, start: string, end: string, meta = ""): string {
  return fixture("tec-event.html")
    .replaceAll("__SLUG__", slug)
    .replaceAll("__TITLE__", title)
    .replaceAll("__START__", start)
    .replaceAll("__END__", end)
    .replace("<!--META-->", meta);
}

/** TEC sends its iCal export with X-Robots-Tag: noindex. */
const NOINDEX_ICS: FakeResponse = {
  body: fixture("calendar.ics"),
  headers: { "content-type": "text/calendar; charset=UTF-8", "x-robots-tag": "noindex" },
};

const SITE: Record<string, FakeResponse> = {
  [`${ORIGIN}/robots.txt`]: { body: "User-agent: *\nDisallow: /wp-admin/\n" },
  [`${ORIGIN}/events/`]: html(fixture("tec-month.html")),
  [`${ORIGIN}/events/?ical=1`]: NOINDEX_ICS,
  [`${ORIGIN}/events/list/`]: html(fixture("tec-list.html")),
  [`${ORIGIN}/events/month/`]: html(fixture("tec-month.html")),
  [`${ORIGIN}/event/community-choir/`]: html(
    eventPage(
      "community-choir",
      "Community Choir",
      "2026-11-18T18:30:00-05:00",
      "2026-11-18T20:00:00-05:00",
    ),
    { "x-robots-tag": "nosnippet" },
  ),
  [`${ORIGIN}/event/dance-workshop/`]: html(
    eventPage(
      "dance-workshop",
      "Dance Workshop",
      "2026-11-20T19:00:00-05:00",
      "2026-11-20T21:00:00-05:00",
      '<meta name="robots" content="noindex, follow" />',
    ),
  ),
};

const PAGE_SEED: Seed = {
  id: "test-tec",
  kind: "page",
  url: `${ORIGIN}/events/`,
  name: "Example Arts",
  attribution: "Listed from the Example Arts public calendar (arts.example.org).",
};

async function run(
  routes: Record<string, FakeResponse>,
  seed: Seed,
  fetcherOpts: { maxRequestsPerHost?: number; deadlineAt?: number } = {},
) {
  const c = fakeClock();
  const { transport, log } = fakeTransport(routes, c.clock);
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    transport,
    now: c.now,
    sleep: c.sleep,
    ...fetcherOpts,
  });
  const city: CityFile = { region: ATL, seeds: [seed] };
  const result = await collect({ regions: [ATL], cities: [city], fetcher, now: NOW });
  return { result, log, paths: log.map((l) => l.url.slice(ORIGIN.length)), clock: c.clock };
}

describe("The Events Calendar views", () => {
  it("tells listing views from event pages and exports", () => {
    for (const u of [
      `${ORIGIN}/events/list/`,
      `${ORIGIN}/events/month/`,
      `${ORIGIN}/events/list/page/2/`,
      `${ORIGIN}/calendar/month/2026-11/`,
      `${ORIGIN}/events/category/dance/list/`,
      `${ORIGIN}/events/?eventDisplay=list`,
      `${ORIGIN}/offstage/?eventDisplay=month`,
    ])
      expect(isListingView(u), u).toBe(true);
    for (const u of [
      `${ORIGIN}/event/pottery-night/`,
      `${ORIGIN}/events/list/?ical=1`,
      `${ORIGIN}/events/`,
      `${ORIGIN}/event/day-trip/`,
      `${ORIGIN}/list/`,
    ])
      expect(isListingView(u), u).toBe(false);
  });

  it("derives the list view of a calendar-wide export, never of a single event's", () => {
    expect(tecListViewsFor(`${ORIGIN}/events/?ical=1`)).toEqual([
      `${ORIGIN}/events/list/`,
      `${ORIGIN}/events/?eventDisplay=list`,
    ]);
    expect(tecListViewsFor("https://piedmontpark.org/calendar/month/2026-11/?ical=1")).toEqual([
      "https://piedmontpark.org/calendar/list/",
      "https://piedmontpark.org/calendar/?eventDisplay=list",
    ]);
    expect(tecListViewsFor(`${ORIGIN}/event/pottery-night/?ical=1`)).toBeNull();
    expect(tecListViewsFor(`${ORIGIN}/calendar.ics`)).toBeNull();
    expect(tecListViewsFor(`${ORIGIN}/?ical=1`)).toBeNull();
  });

  it("finds the export, the views and the event links on a month view", () => {
    const found = discoverLinks(
      scanHtml(fixture("tec-month.html"), `${ORIGIN}/events/`),
      (u) => new URL(u).hostname === "arts.example.org",
    );
    expect(found.feeds).toEqual([`${ORIGIN}/events/?ical=1`]);
    expect(found.listings).toEqual([`${ORIGIN}/events/list/`, `${ORIGIN}/events/month/`]);
    expect(found.pages).toEqual([
      `${ORIGIN}/event/pottery-night/`,
      `${ORIGIN}/event/community-choir/`,
    ]);
  });

  it("picks up event title links by their TEC class outside /event/ paths", () => {
    const page = `<a class="tribe-events-calendar-list__event-title-link tribe-common-anchor-thin" href="/offstage/teen-acting-lab/">Teen Acting Lab</a><a href="/offstage/about/">About</a>`;
    const found = discoverLinks(scanHtml(page, `${ORIGIN}/offstage/`), () => true);
    expect(found.pages).toEqual([`${ORIGIN}/offstage/teen-acting-lab/`]);
  });
});

describe("noindex export: fall back to the calendar's indexable pages", () => {
  it("reads the list view and the event pages it does not already cover, page by page", async () => {
    const { result, paths } = await run(SITE, PAGE_SEED);
    const batch = result.batches[0]!;
    // Nothing from the noindex export (calendar.ics holds other events).
    expect(batch.items.map((i) => i.title).sort()).toEqual([
      "Community Choir",
      "Open Mic Poetry",
      "Pottery Night",
    ]);
    expect(batch.items.every((i) => i.lane === "page")).toBe(true);
    const pottery = batch.items.find((i) => i.title === "Pottery Night")!;
    expect(pottery).toMatchObject({
      url: `${ORIGIN}/event/pottery-night/`,
      starts_at: "2026-11-13T00:00:00.000Z",
      location: expect.stringContaining("Example Arts Studio"),
    });
    expect(pottery.description).toContain("Throw a bowl");
    // X-Robots-Tag nosnippet on the event page: the item has no excerpt.
    expect(batch.items.find((i) => i.title === "Community Choir")!.description).toBe("");
    // The export is requested once and skipped for noindex; the list view is read; the event
    // pages the list view's own markup covered (pottery, poetry) are not fetched; the
    // dance-workshop page says noindex and gives nothing.
    expect(paths).toEqual([
      "/robots.txt",
      "/events/",
      "/events/?ical=1",
      "/events/list/",
      "/events/month/",
      "/event/community-choir/",
      "/event/dance-workshop/",
    ]);
    expect(result.errors.map((e) => `${e.reason} ${e.url.slice(ORIGIN.length)}`).sort()).toEqual([
      "noindex /event/dance-workshop/",
      "noindex /events/?ical=1",
    ]);
  });

  it("falls back from a noindex ics seed to its list view, trying ?eventDisplay=list next", async () => {
    const routes: Record<string, FakeResponse> = {
      [`${ORIGIN}/robots.txt`]: { status: 404 },
      [`${ORIGIN}/events/?ical=1`]: NOINDEX_ICS,
      // Plain permalinks: no /list/ route.
      [`${ORIGIN}/events/?eventDisplay=list`]: html(fixture("tec-list.html")),
      [`${ORIGIN}/event/dance-workshop/`]: html(
        eventPage(
          "dance-workshop",
          "Dance Workshop",
          "2026-11-20T19:00:00-05:00",
          "2026-11-20T21:00:00-05:00",
        ),
      ),
    };
    const seed: Seed = { ...PAGE_SEED, kind: "ics", url: `${ORIGIN}/events/?ical=1` };
    const { result, paths } = await run(routes, seed);
    expect(result.batches[0]!.items.map((i) => i.title).sort()).toEqual([
      "Dance Workshop",
      "Open Mic Poetry",
      "Pottery Night",
    ]);
    expect(paths).toEqual([
      "/robots.txt",
      "/events/?ical=1",
      "/events/list/",
      "/events/?eventDisplay=list",
      "/event/dance-workshop/",
    ]);
  });

  it("reads nothing from a list view that says noindex, and honours nofollow on it", async () => {
    const hidden = fixture("tec-list.html").replace(
      '<meta name="robots" content="index, follow" />',
      '<meta name="robots" content="noindex, nofollow" />',
    );
    const { result, paths } = await run(
      { ...SITE, [`${ORIGIN}/events/list/`]: html(hidden), [`${ORIGIN}/events/month/`]: {} },
      PAGE_SEED,
    );
    // Only the month view's own links remain: choir (nosnippet) and pottery (from its page).
    expect(paths).not.toContain("/event/dance-workshop/");
    expect(paths).not.toContain("/event/open-mic-poetry/");
    expect(result.batches[0]!.items.map((i) => i.title)).not.toContain("Open Mic Poetry");
    expect(result.errors.map((e) => e.reason)).toContain("noindex");
  });

  it("stops at the per-host request cap", async () => {
    const { result, paths } = await run(SITE, PAGE_SEED, { maxRequestsPerHost: 4 });
    expect(paths).toEqual(["/robots.txt", "/events/", "/events/?ical=1", "/events/list/"]);
    expect(result.batches[0]!.items.map((i) => i.title).sort()).toEqual([
      "Open Mic Poetry",
      "Pottery Night",
    ]);
    // One refusal, then the seed stops instead of queueing more refusals.
    expect(result.errors.filter((e) => e.reason === "host_budget_spent")).toHaveLength(1);
  });

  it("starts no request after the run deadline", async () => {
    const { result, paths, clock } = await run(SITE, PAGE_SEED, {
      deadlineAt: NOW.getTime() + 5_000,
    });
    // 2 s spacing: requests at 0, 2 and 4 s; the 6 s slot is past the deadline.
    expect(paths).toEqual(["/robots.txt", "/events/", "/events/?ical=1"]);
    expect(clock.now).toBeLessThan(NOW.getTime() + 5_000);
    expect(result.errors.map((e) => e.reason)).toContain("run_deadline");
  });
});

describe("Atlanta run stays polite", () => {
  it("keeps every host under the request cap and the run under 10 minutes", async () => {
    // Worst case for every enabled Atlanta seed: each page offers a noindex ?ical=1 export,
    // list and month views and 60 event links, and every event page is real.
    const c = fakeClock();
    const links = (host: string) =>
      Array.from(
        { length: 60 },
        (_, i) => `<a href="https://${host}/event/e${i}/">Event ${i}</a>`,
      ).join("");
    const transport: Transport = async (url) => {
      const u = new URL(url);
      if (u.pathname === "/robots.txt") return new Response("User-agent: *\nAllow: /\n");
      if (u.searchParams.get("ical") === "1")
        return new Response(fixture("calendar.ics"), {
          headers: { "content-type": "text/calendar", "x-robots-tag": "noindex" },
        });
      const body = `<html><head><link rel="alternate" type="text/calendar" href="/events/?ical=1"></head><body><a href="/events/list/">List</a><a href="/events/month/">Month</a>${links(u.host)}</body></html>`;
      return new Response(body, { headers: { "content-type": "text/html" } });
    };
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      transport,
      now: c.now,
      sleep: c.sleep,
    });
    const cities = loadCities().filter((city) => city.region.id === "atl");
    const result = await collect({ regions: [ATL], cities, fetcher, now: NOW });
    for (const [host, n] of fetcher.requests)
      expect(n, host).toBeLessThanOrEqual(fetcher.maxRequestsPerHost);
    expect(c.clock.now - NOW.getTime()).toBeLessThan(10 * 60_000);
    expect(result.stats.sources).toBeGreaterThan(5);
  });
});
