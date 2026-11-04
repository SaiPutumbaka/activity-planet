import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import { loadCities } from "../src/config.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import {
  discoveredCities,
  fetchRegions,
  fetchSources,
  recordRegions,
  regionCounts,
  regionFromRow,
  withCityRegions,
  zoneAt,
} from "../src/regions.ts";
import type { CityFile, ImportItem, Region, SourceBatch } from "../src/types.ts";
import { ATL, fakeClock, fakeTransport, fixture, NOW } from "./helpers.ts";

const ID_ATL = "0b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
const ID_LEIPZIG = "11111111-2222-4333-8444-555555555555";
const BASE = "https://example.supabase.co/functions/v1/collector";
const SECRET = "s".repeat(64);

const row = (o: Record<string, unknown> = {}) => ({
  id: ID_LEIPZIG,
  lat: 51.3,
  lng: 12.4,
  radius_km: 25,
  label: null,
  timezone: null,
  priority: 10,
  last_collected_at: null,
  ...o,
});

const collectorAtl: Region = {
  id: ID_ATL,
  label: "Atlanta",
  lat: 33.7,
  lng: -84.4,
  radiusKm: 50,
  timezone: "America/New_York",
  collector: true,
};

describe("collector regions (D-042 slice 6)", () => {
  it("looks a missing zone up offline and keeps a stored one", () => {
    expect(zoneAt(51.34, 12.37)).toBe("Europe/Berlin");
    expect(zoneAt(33.75, -84.39)).toBe("America/New_York");
    const looked = regionFromRow(row());
    expect(looked.timezoneResolved).toBe(true);
    expect(looked.region).toEqual({
      id: ID_LEIPZIG,
      label: "Collector region 11111111",
      lat: 51.3,
      lng: 12.4,
      radiusKm: 25,
      timezone: "Europe/Berlin",
      collector: true,
    });
    const stored = regionFromRow(row({ timezone: "Europe/Berlin", label: "Leipzig" }));
    expect(stored.timezoneResolved).toBe(false);
    expect(stored.region.label).toBe("Leipzig");
    expect(() => regionFromRow(row({ id: "atl" }))).toThrow(/bad id/);
    expect(() => regionFromRow(row({ radius_km: 500 }))).toThrow(/radiusKm/);
  });

  it("adds a city file's own area (seeds only) when it contains a collector region", () => {
    const cities = loadCities();
    const regions = withCityRegions([collectorAtl, regionFromRow(row()).region], cities);
    expect(regions.map((r) => r.id)).toEqual([ID_ATL, ID_LEIPZIG, "atl"]);
    expect(regions[2]).toMatchObject({ id: "atl", radiusKm: 60, seedsOnly: true });
    expect(withCityRegions([regionFromRow(row()).region], cities).map((r) => r.id)).toEqual([
      ID_LEIPZIG,
    ]);
  });

  it("turns discovered sources into seeds of their collector region", () => {
    const seed = (id: string, url = `https://${id}.example.org/events`) => ({
      id,
      kind: "page",
      url,
      name: `Source ${id}`,
      attribution: `Events from Source ${id} (${id}.example.org).`,
    });
    const { cities, dropped } = discoveredCities(
      {
        sources: [
          { region_id: ID_ATL, seed: seed("disc-one") },
          { region_id: ID_ATL, seed: seed("disc-one") },
          { region_id: ID_LEIPZIG, seed: seed("disc-two") },
          { region_id: "atl", seed: seed("disc-three") },
          { region_id: ID_ATL, seed: seed("disc-four", "http://insecure.example.org/") },
        ],
      },
      [collectorAtl, { ...ATL, seedsOnly: true }],
    );
    expect(dropped).toBe(4);
    expect(cities).toHaveLength(1);
    expect(cities[0]!.region.id).toBe(ID_ATL);
    expect(cities[0]!.seeds.map((s) => s.id)).toEqual(["disc-one"]);
    expect(discoveredCities({}, [collectorAtl])).toEqual({ cities: [], dropped: 0 });
  });

  it("counts sources and items inside each collector region", () => {
    const item = (lat: number | null, lng: number | null) =>
      ({ lat, lng }) as unknown as ImportItem;
    const batch = (items: ImportItem[], area = { lat: 33.75, lng: -84.39 }) =>
      ({ items, source: { region: { ...area, radius_km: 60 } } }) as unknown as SourceBatch;
    const counts = regionCounts(
      [collectorAtl, { ...ATL, seedsOnly: true }, regionFromRow(row()).region],
      [
        batch([item(33.75, -84.39), item(34.6, -84.4), item(null, null)]),
        batch([item(null, null)], { lat: 51.3, lng: 12.4 }),
        batch([]),
      ],
    );
    expect(counts).toEqual([
      { id: ID_ATL, sources: 1, items: 2 },
      { id: ID_LEIPZIG, sources: 1, items: 1 },
    ]);
  });

  it("talks to the collector function with the secret, and treats a missing sources route as none", async () => {
    const calls: { url: string; method: string; secret: string | null; body?: string }[] = [];
    const f = (async (url: string, init: RequestInit = {}) => {
      const h = init.headers as Record<string, string>;
      calls.push({
        url,
        method: init.method ?? "GET",
        secret: h["x-collector-secret"] ?? null,
        body: init.body as string | undefined,
      });
      if (url.includes("/regions?"))
        return new Response(
          JSON.stringify({
            regions: [
              row(),
              row({ id: ID_ATL, lat: 33.7, lng: -84.4, timezone: "America/New_York" }),
            ],
          }),
        );
      if (url.includes("/sources?")) return new Response('{"error":"not_found"}', { status: 404 });
      if (url.endsWith("/regions/record"))
        return new Response(JSON.stringify({ updated: 2, unknown: 0 }));
      return new Response("", { status: 500 });
    }) as typeof fetch;
    const regions = await fetchRegions({ baseUrl: BASE, secret: SECRET, fetch: f, limit: 500 });
    expect(regions.map((r) => [r.region.id, r.timezoneResolved])).toEqual([
      [ID_LEIPZIG, true],
      [ID_ATL, false],
    ]);
    expect(calls[0]!.url).toBe(`${BASE}/regions?due=1&limit=100`);
    expect(calls[0]!.secret).toBe(SECRET);
    expect(await fetchSources({ baseUrl: BASE, secret: SECRET, fetch: f }, [ID_ATL])).toEqual({
      available: false,
      sources: [],
    });
    const rec = await recordRegions({ baseUrl: BASE, secret: SECRET, fetch: f, runId: "gh-1-1" }, [
      { id: ID_ATL, sources: 1, items: 2 },
      { id: ID_LEIPZIG, sources: 0, items: 0, timezone: "Europe/Berlin" },
    ]);
    expect(rec).toEqual({ updated: 2, unknown: 0 });
    expect(JSON.parse(calls.at(-1)!.body!)).toEqual({
      run_id: "gh-1-1",
      regions: [
        { id: ID_ATL, sources: 1, items: 2 },
        { id: ID_LEIPZIG, sources: 0, items: 0, timezone: "Europe/Berlin" },
      ],
    });
    await expect(fetchRegions({ baseUrl: BASE, secret: "short", fetch: f })).rejects.toThrow(
      /COLLECTOR_SECRET/,
    );
    await expect(
      fetchRegions({ baseUrl: "http://example.org/collector", secret: SECRET, fetch: f }),
    ).rejects.toThrow(/base URL/);
  });

  it("runs a discovered seed as its region's source, and API adapters only for collector regions", async () => {
    const { cities } = discoveredCities(
      {
        sources: [
          {
            region_id: ID_ATL,
            seed: {
              id: "disc-cal",
              kind: "ics",
              url: "https://cal.example.org/events.ics",
              name: "Discovered calendar",
              attribution: "Events from Discovered calendar (cal.example.org).",
            },
          },
        ],
      },
      [collectorAtl],
    );
    const city: CityFile = { region: ATL, seeds: [] };
    const c = fakeClock();
    const { transport, log } = fakeTransport(
      {
        "https://cal.example.org/robots.txt": { status: 404 },
        "https://cal.example.org/events.ics": {
          headers: { "content-type": "text/calendar" },
          body: fixture("calendar.ics"),
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
    const result = await collect({
      regions: withCityRegions([collectorAtl], [city]),
      cities: [city, ...cities],
      fetcher,
      env: { TICKETMASTER_API_KEY: "k".repeat(20) },
      now: NOW,
    });
    const disc = result.batches.find((b) => b.sourceKey === "disc-cal");
    expect(disc?.regionId).toBe(ID_ATL);
    expect(disc?.source.region).toMatchObject({ lat: 33.7, lng: -84.4, radius_km: 50 });
    const apiHosts = log.filter((l) => l.url.startsWith("https://app.ticketmaster.com/"));
    expect(apiHosts).toHaveLength(1);
    expect(result.batches.some((b) => b.sourceKey === "ticketmaster-atl")).toBe(false);
  });
});
