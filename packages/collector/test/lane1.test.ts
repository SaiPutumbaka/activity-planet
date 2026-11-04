// Lane 1 by region (D-042 slice 10): Ticketmaster and SeatGeek per collector region, within the
// day's call budget, and a clean no-op without keys.
import { describe, expect, it } from "vitest";
import {
  API_HOSTS,
  callsWanted,
  fromPrice,
  readApiBudget,
  seatgeek,
  ticketmaster,
} from "../src/adapters/api.ts";
import { apiRegionCount, settleApiBudget, takeApiBudget, unusedCalls } from "../src/api-budget.ts";
import { collect } from "../src/collect.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import type { Region } from "../src/types.ts";
import { geohash } from "../src/util/geo.ts";
import {
  ATL,
  fakeClock,
  fakeTransport,
  fixture,
  NOW,
  WINDOW_END,
  type FakeResponse,
} from "./helpers.ts";

const window = { start: NOW, end: WINDOW_END };
const BERLIN: Region = {
  id: "9a1c4f10-0000-4000-8000-000000000001",
  label: "Berlin",
  lat: 52.52,
  lng: 13.405,
  radiusKm: 50,
  timezone: "Europe/Berlin",
  collector: true,
};
const ATL_C: Region = { ...ATL, id: "9a1c4f10-0000-4000-8000-000000000002", collector: true };

function tmBody(events: unknown[], number: number, totalPages: number): string {
  return JSON.stringify({
    _embedded: { events },
    page: { size: 200, totalElements: totalPages * 200, totalPages, number },
  });
}

function tmEvent(id: string, lat: number, lng: number, extra: Record<string, unknown> = {}) {
  return {
    name: `Show ${id}`,
    id,
    url: `https://www.ticketmaster.de/event/${id}`,
    dates: {
      start: { dateTime: "2026-11-20T19:00:00Z" },
      timezone: "Europe/Berlin",
      status: { code: "onsale" },
    },
    priceRanges: [{ currency: "EUR", min: 39.9 }],
    _embedded: {
      venues: [{ name: "Halle", location: { latitude: String(lat), longitude: String(lng) } }],
    },
    ...extra,
  };
}

describe("Ticketmaster anywhere", () => {
  it("queries by geoPoint and radius in every locale, without a country filter", () => {
    const u = new URL(ticketmaster.firstUrl(BERLIN, window, "k"));
    expect(u.searchParams.get("geoPoint")).toBe(geohash(52.52, 13.405, 7));
    expect(u.searchParams.get("radius")).toBe("50");
    expect(u.searchParams.get("locale")).toBe("*");
    expect(u.searchParams.has("countryCode")).toBe(false);
    expect(u.searchParams.has("latlong")).toBe(false);
  });

  it("prices in the listing's currency and leaves out test listings", () => {
    const body = tmBody([tmEvent("a", 52.5, 13.4), tmEvent("b", 52.5, 13.4, { test: true })], 0, 1);
    const page = ticketmaster.parse(body, ticketmaster.firstUrl(BERLIN, window, "k"));
    expect(page.events.map((e) => e.uid)).toEqual(["a"]);
    expect(page.events[0]?.priceText).toBe("From €40");
    expect(page.events[0]?.url).toBe("https://www.ticketmaster.de/event/a");
    expect(page.next).toBeNull();
    expect(page.truncated).toBe(false);
  });

  it("marks a query with more pages than the cap as a sample", () => {
    const u = new URL(ticketmaster.firstUrl(BERLIN, window, "k"));
    u.searchParams.set("page", "4");
    const page = ticketmaster.parse(tmBody([], 4, 9), u.toString());
    expect(page.next).toBeNull();
    expect(page.truncated).toBe(true);
  });
});

describe("prices", () => {
  it("formats the lowest price in its currency", () => {
    expect(fromPrice(24.5, "USD")).toBe("From $25");
    expect(fromPrice(12, "gbp")).toBe("From £12");
    expect(fromPrice(30, null)).toBe("From $30");
    expect(fromPrice(30, "not a code")).toBe("From $30");
    expect(fromPrice(null, "EUR")).toBeNull();
    expect(fromPrice(-1, "EUR")).toBeNull();
  });
});

describe("the day's call budget", () => {
  it("asks for every region's full paging, at most 1000", () => {
    expect(callsWanted(ticketmaster, 20)).toBe(100);
    expect(callsWanted(seatgeek, 20)).toBe(200);
    expect(callsWanted(seatgeek, 500)).toBe(1000);
    expect(callsWanted(ticketmaster, 0)).toBe(0);
  });

  it("counts collector regions, not seeds-only city areas", () => {
    expect(apiRegionCount([ATL_C, BERLIN, { ...ATL, seedsOnly: true }])).toBe(2);
  });

  it("reads a calls file strictly: anything odd is 0", () => {
    expect(readApiBudget({ calls: { ticketmaster: 12, seatgeek: "9" } })).toEqual({
      ticketmaster: 12,
      seatgeek: 0,
    });
    expect(readApiBudget(null)).toEqual({ ticketmaster: 0, seatgeek: 0 });
    expect(readApiBudget({ calls: { ticketmaster: 1.5, seatgeek: 5000 } })).toEqual({
      ticketmaster: 0,
      seatgeek: 0,
    });
  });

  it("is a no-op without keys: nothing is asked, every adapter gets 0", async () => {
    let calls = 0;
    const file = await takeApiBudget(
      {
        baseUrl: "https://x.supabase.co/functions/v1/collector",
        secret: "",
        fetch: (async () => {
          calls++;
          return new Response("{}");
        }) as typeof fetch,
      },
      {},
      20,
    );
    expect(calls).toBe(0);
    expect(file).toEqual({ calls: { ticketmaster: 0, seatgeek: 0 }, days: {}, on: [] });
  });

  it("takes regions x pages for each adapter with a key, and returns what was not sent", async () => {
    const bodies: unknown[] = [];
    const urls: string[] = [];
    const fake = (async (url: string, init: RequestInit) => {
      urls.push(url);
      const b = JSON.parse(String(init.body)) as { api: string; calls: number };
      bodies.push(b);
      if (url.endsWith("/api-budget"))
        return new Response(JSON.stringify({ api: b.api, day: "2026-11-04", granted: 7 }));
      return new Response(JSON.stringify({ used: 3 }));
    }) as unknown as typeof fetch;
    const opts = {
      baseUrl: "https://x.supabase.co/functions/v1/collector",
      secret: "s".repeat(64),
      fetch: fake,
    };
    const file = await takeApiBudget(opts, { TICKETMASTER_API_KEY: "tm-secret-key" }, 3);
    expect(bodies).toEqual([{ api: "ticketmaster", calls: 15 }]);
    expect(file).toEqual({
      calls: { ticketmaster: 7, seatgeek: 0 },
      days: { ticketmaster: "2026-11-04" },
      on: ["ticketmaster"],
    });
    expect(JSON.stringify(bodies)).not.toContain("tm-secret-key");
    expect(unusedCalls(file, { ticketmaster: { calls: 4 } })).toEqual({ ticketmaster: 3 });
    expect(unusedCalls(file, { ticketmaster: { calls: 9 } })).toEqual({});
    const back = await settleApiBudget(opts, file, { ticketmaster: { calls: 4 } });
    expect(back).toEqual({ ticketmaster: 3 });
    expect(urls.at(-1)).toBe("https://x.supabase.co/functions/v1/collector/api-budget/return");
    expect(bodies.at(-1)).toEqual({ api: "ticketmaster", day: "2026-11-04", calls: 3 });
  });

  it("knows the API hosts that the budget, not the per-site cap, limits", () => {
    expect(API_HOSTS.has("app.ticketmaster.com")).toBe(true);
    expect(API_HOSTS.has("api.seatgeek.com")).toBe(true);
    expect(API_HOSTS.has("www.ticketmaster.com")).toBe(false);
  });
});

async function runRegions(apiCalls: Record<string, number> | undefined, pages = 1) {
  const c = fakeClock();
  const routes: Record<string, FakeResponse> = {};
  const { transport, log } = fakeTransport(
    new Proxy(routes, {
      get(_t, prop: string) {
        if (!prop.startsWith("https://app.ticketmaster.com/")) return undefined;
        const u = new URL(prop);
        const n = Number(u.searchParams.get("page"));
        const [lat, lng] =
          u.searchParams.get("geoPoint") === geohash(52.52, 13.405, 7)
            ? [52.52, 13.405]
            : [33.75, -84.39];
        return {
          body: tmBody([tmEvent(`${lat}-${n}`, lat, lng)], n, pages),
          headers: { "content-type": "application/json" },
        };
      },
    }),
    c.clock,
  );
  const fetcher = new PoliteFetcher({
    denylist: Denylist.load(),
    transport,
    now: c.now,
    sleep: c.sleep,
  });
  const result = await collect({
    regions: [ATL_C, BERLIN],
    cities: [],
    fetcher,
    env: { TICKETMASTER_API_KEY: "tm-key" },
    now: NOW,
    windowDays: 60,
    apiCalls,
  });
  return { result, log };
}

describe("collect within the budget", () => {
  it("runs one source per collector region, as a show source", async () => {
    const { result } = await runRegions(undefined);
    const keys = result.batches.map((b) => b.sourceKey).sort();
    expect(keys).toEqual([`ticketmaster-${ATL_C.id}`, `ticketmaster-${BERLIN.id}`].sort());
    const ber = result.batches.find((b) => b.regionId === BERLIN.id)!;
    expect(ber.source.kind).toBe("ticketmaster");
    expect(ber.source.lane).toBe("api");
    expect(ber.source.images_licensed).toBe(false);
    expect(ber.items[0]?.price_text ?? null).toBe("From €40");
    expect(ber.complete).toBe(true);
    expect(result.stats.api).toEqual({ ticketmaster: { calls: 2, regions: 2, skipped: 0 } });
  });

  it("leaves out a region the budget does not reach: no batch, so nothing counts as missed", async () => {
    const { result, log } = await runRegions({ ticketmaster: 1 });
    expect(result.batches.map((b) => b.regionId)).toEqual([ATL_C.id]);
    expect(log.filter((l) => l.url.startsWith("https://app.ticketmaster.com/"))).toHaveLength(1);
    expect(result.stats.api.ticketmaster).toEqual({ calls: 1, regions: 1, skipped: 1 });
  });

  it("sends nothing for an adapter missing from the calls file", async () => {
    const { result, log } = await runRegions({ seatgeek: 10 });
    expect(result.batches).toHaveLength(0);
    expect(log).toHaveLength(0);
  });

  it("stops mid-way when the calls run out, as a partial read", async () => {
    const { result } = await runRegions({ ticketmaster: 3 }, 3);
    const atl = result.batches.find((b) => b.regionId === ATL_C.id);
    const ber = result.batches.find((b) => b.regionId === BERLIN.id);
    const partial = [atl, ber].filter((b) => b && !b.complete);
    expect(partial.length).toBeGreaterThanOrEqual(1);
    expect(result.errors.some((e) => e.reason === "api_budget_spent")).toBe(true);
    expect(JSON.stringify(result.errors)).not.toContain("tm-key");
    expect(result.stats.api.ticketmaster?.calls).toBe(3);
  });

  it("treats a query beyond the paging cap as a sample, never complete", async () => {
    const { result } = await runRegions(undefined, 9);
    for (const b of result.batches) {
      expect(b.complete).toBe(false);
      expect(b.sampled).toBe(true);
    }
    expect(result.stats.api.ticketmaster?.calls).toBe(10);
  });
});

describe("the fixtures still parse", () => {
  it("keeps the US fixture's dollar price", () => {
    const page = ticketmaster.parse(
      fixture("ticketmaster.json"),
      ticketmaster.firstUrl(ATL, window, "k"),
    );
    expect(page.events[0]?.priceText).toBe("From $25");
  });
});
