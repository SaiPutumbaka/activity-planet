import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { collect } from "../src/collect.ts";
import { formatDiagnostic } from "../src/diagnose.ts";
import { PoliteFetcher } from "../src/net/fetcher.ts";
import { Denylist } from "../src/policy/denylist.ts";
import {
  circleOverlapsBbox,
  datasetRegion,
  type Dataset,
  loadRegistry,
  registrySeeds,
  validateDataset,
} from "../src/opendata-registry.ts";
import { fakeClock } from "./helpers.ts";
import { enabledAdapters, redactUrl, seatgeek, ticketmaster } from "../src/adapters/api.ts";
import {
  arcgisUrl,
  parseArcgis,
  parseSocrata,
  parseTextDateRange,
  socrataUrl,
} from "../src/adapters/opendata.ts";
import type { Seed } from "../src/types.ts";
import { geohash } from "../src/util/geo.ts";
import { ATL, fixture, NOW, WINDOW_END } from "./helpers.ts";

const window = { start: NOW, end: WINDOW_END };

describe("API keys", () => {
  it("turns adapters on only when their key is set", () => {
    expect(enabledAdapters({})).toEqual([]);
    expect(enabledAdapters({ TICKETMASTER_API_KEY: "  " })).toEqual([]);
    expect(enabledAdapters({ SEATGEEK_CLIENT_ID: "abc" }).map((a) => a.adapter.id)).toEqual([
      "seatgeek",
    ]);
  });
  it("redacts keys from URLs before they are printed", () => {
    expect(
      redactUrl("https://app.ticketmaster.com/discovery/v2/events.json?apikey=SECRET&size=1"),
    ).not.toContain("SECRET");
    expect(redactUrl("https://api.seatgeek.com/2/events?client_id=SECRET")).toContain(
      "client_id=REDACTED",
    );
  });
});

describe("Ticketmaster Discovery", () => {
  it("builds a geoPoint radius query for the region and window", () => {
    const u = new URL(ticketmaster.firstUrl(ATL, window, "k"));
    expect(u.host).toBe("app.ticketmaster.com");
    expect(u.pathname).toBe("/discovery/v2/events.json");
    expect(u.searchParams.get("geoPoint")).toBe(geohash(ATL.lat, ATL.lng, 7));
    expect(u.searchParams.get("radius")).toBe("60");
    expect(u.searchParams.get("unit")).toBe("km");
    expect(u.searchParams.get("startDateTime")).toBe("2026-11-04T12:00:00Z");
  });

  it("parses events, venue points, status and paging", () => {
    const first = ticketmaster.firstUrl(ATL, window, "k");
    const page = ticketmaster.parse(fixture("ticketmaster.json"), first);
    expect(page.events).toHaveLength(2); // the date-TBD show is left out
    expect(page.events[0]).toMatchObject({
      uid: "vvG1abc123",
      title: "Hawks vs. Celtics",
      url: "https://www.ticketmaster.com/event/0E00ABC",
      start: "2026-11-21T00:30:00Z",
      timezone: "America/New_York",
      location: "State Farm Arena, 1 State Farm Drive, Atlanta",
      lat: 33.757222,
      lng: -84.396389,
      priceText: "From $25",
      categories: ["Sports", "Basketball"],
      imageUrl: null,
      lane: "api",
    });
    expect(page.events[1]).toMatchObject({ start: "2026-11-22T20:00:00", cancelled: true });
    expect(new URL(page.next ?? "").searchParams.get("page")).toBe("1");
  });
});

describe("SeatGeek Platform", () => {
  it("builds a lat/lon range query", () => {
    const u = new URL(seatgeek.firstUrl(ATL, window, "id"));
    expect(u.host).toBe("api.seatgeek.com");
    expect(u.searchParams.get("range")).toBe("38mi");
    expect(u.searchParams.get("lat")).toBe("33.7490");
  });
  it("parses events with UTC times and venue points; no next page at the end", () => {
    const page = seatgeek.parse(fixture("seatgeek.json"), seatgeek.firstUrl(ATL, window, "id"));
    expect(page.events[0]).toMatchObject({
      uid: "6100001",
      start: "2026-11-28T00:00:00Z",
      lat: 33.7554,
      lng: -84.4008,
      priceText: "From $41",
      categories: ["sports", "soccer"],
    });
    expect(page.next).toBeNull();
  });
});

describe("open data", () => {
  const socrata: Seed = {
    id: "test-socrata",
    kind: "socrata",
    url: "https://data.example.gov/resource/abcd-1234.json",
    name: "Parks events",
    attribution: "Listed from city open data (data.example.gov).",
    fields: {
      id: "event_id",
      title: "event_name",
      start: "start_date",
      end: "end_date",
      location: "location_name",
      url: "event_url",
      category: "category",
    },
    geoColumn: "location",
  };
  const arcgis: Seed = {
    id: "test-arcgis",
    kind: "arcgis",
    url: "https://services.arcgis.com/abc/arcgis/rest/services/Events/FeatureServer/0",
    name: "City events layer",
    attribution: "Listed from city open data (arcgis.com).",
    fields: {
      id: "OBJECTID",
      title: "NAME",
      start: "START_DATE",
      end: "END_DATE",
      location: "LOCATION",
      url: "URL",
    },
  };

  it("filters Socrata by window and circle server-side", () => {
    const where = new URL(socrataUrl(socrata, ATL, window)).searchParams.get("$where") ?? "";
    expect(where).toContain("start_date >= '2026-11-04T12:00:00'");
    expect(where).toContain("within_circle(location, 33.749, -84.388, 60000)");
  });
  it("maps Socrata rows with GeoJSON points and url objects", () => {
    const rows = parseSocrata(fixture("socrata.json"), socrata);
    expect(rows[0]).toMatchObject({
      uid: "PR-2026-001",
      title: "Tree Planting Day",
      start: "2026-11-14T09:00:00.000",
      url: "https://parks.example.gov/tree-day",
      lat: 33.7652,
      lng: -84.3279,
      categories: ["Volunteer"],
    });
    expect(rows).toHaveLength(2);
  });
  it("queries ArcGIS by distance and maps epoch dates and point geometry", () => {
    const u = new URL(arcgisUrl(arcgis, ATL));
    expect(u.pathname.endsWith("/FeatureServer/0/query")).toBe(true);
    expect(u.searchParams.get("distance")).toBe("60000");
    const rows = parseArcgis(fixture("arcgis.json"), arcgis);
    expect(rows[0]).toMatchObject({
      uid: "7",
      start: "2026-11-15T14:00:00.000Z",
      lat: 33.7287,
      lng: -84.4086,
    });
  });
});

// Collector completion 2.7: the open-data registry.
describe("open-data registry", () => {
  const ds: Dataset = {
    id: "test-registry-socrata",
    kind: "socrata",
    url: "https://data.example.gov/resource/abcd-1234.json",
    name: "City events (test)",
    attribution: "Listed from city open data (data.example.gov), Open Government Licence.",
    bbox: [-85.0, 33.4, -84.0, 34.2],
    timezone: "America/New_York",
    licence: { name: "Open Government Licence", url: "https://data.example.gov/licence" },
    fields: { id: "id", title: "event_name", start: "start_date", where: "is_public = true" },
    geoColumn: "location",
    verified: false,
    note: "Test dataset for the registry unit tests.",
  };

  it("validates every registry file (https, a licence, attribution, title and start)", () => {
    expect(() => loadRegistry()).not.toThrow();
    for (const d of loadRegistry()) {
      expect(d.url.startsWith("https://"), d.id).toBe(true);
      expect(d.licence.url.startsWith("https://"), d.id).toBe(true);
      expect(d.attribution.length).toBeGreaterThanOrEqual(10);
    }
    expect(() => validateDataset({ ...ds, licence: { name: "", url: "https://x" } }, "t")).toThrow(
      /licence/,
    );
    expect(() => validateDataset({ ...ds, fields: { title: "t" } }, "t")).toThrow();
    expect(() =>
      validateDataset({ ...ds, fields: { ...ds.fields, where: "1=1; drop" } }, "t"),
    ).toThrow(/where/);
    expect(() => validateDataset({ ...ds, bbox: [1, 2, 0, 3] }, "t")).toThrow(/bbox/);
  });

  it("attaches a dataset to the overlapping regions only, once", () => {
    const far = { id: "far", label: "Far", lat: 51.05, lng: -114.07, radiusKm: 30 };
    expect(circleOverlapsBbox(ATL, ds.bbox)).toBe(true);
    expect(circleOverlapsBbox(far, ds.bbox)).toBe(false);
    expect(registrySeeds([far], [ds])).toEqual([]);
    const near = { id: "edge", label: "Edge", lat: 33.3, lng: -84.5, radiusKm: 20 };
    const got = registrySeeds([far, ATL, near], [ds]);
    expect(got).toHaveLength(1);
    expect(got[0]!.region.id).toBe("atl");
    expect(got[0]!.seeds[0]!.note).toContain("Licence: Open Government Licence");
  });

  it("applies the where filter on both portals", () => {
    const where = new URL(socrataUrl(ds, ATL, window)).searchParams.get("$where") ?? "";
    expect(where).toContain("(is_public = true)");
    const arc = {
      ...ds,
      kind: "arcgis" as const,
      url: "https://services.arcgis.com/a/arcgis/rest/services/E/FeatureServer/0",
    };
    expect(new URL(arcgisUrl(arc, ATL)).searchParams.get("where")).toBe("is_public = true");
  });

  it("sends X-App-Token only with the secret, and never prints it in --diagnose", async () => {
    for (const token of ["", "APP-TOKEN-123"]) {
      const c = fakeClock();
      const seen: Record<string, string>[] = [];
      const lines: string[] = [];
      const fetcher = new PoliteFetcher({
        denylist: Denylist.load(),
        now: c.now,
        sleep: c.sleep,
        transport: async (url, init) => {
          seen.push({ url, ...(init.headers as Record<string, string>) });
          if (url.endsWith("/robots.txt")) return new Response("User-agent: *\nAllow: /\n");
          return new Response(fixture("socrata.json"), {
            headers: { "content-type": "application/json" },
          });
        },
      });
      await collect({
        regions: [ATL],
        cities: registrySeeds([ATL], [ds]),
        fetcher,
        env: token ? { SOCRATA_APP_TOKEN: token } : {},
        now: NOW,
        diagnose: (e) => lines.push(formatDiagnostic(e)),
      });
      const data = seen.filter((h) => (h.url ?? "").includes("/resource/"));
      expect(data).toHaveLength(1);
      expect(data[0]!["X-App-Token"]).toBe(token || undefined);
      expect(lines.join("\n")).not.toContain("APP-TOKEN-123");
    }
  });

  it("reads Socrata floating times in the dataset's zone when the region has none", async () => {
    const c = fakeClock();
    const fetcher = new PoliteFetcher({
      denylist: Denylist.load(),
      now: c.now,
      sleep: c.sleep,
      transport: async (url) =>
        url.endsWith("/robots.txt")
          ? new Response("User-agent: *\nAllow: /\n")
          : new Response(fixture("socrata.json"), {
              headers: { "content-type": "application/json" },
            }),
    });
    const region = { ...ATL, timezone: undefined };
    const fields = {
      id: "event_id",
      title: "event_name",
      start: "start_date",
      url: "event_url",
      location: "location_name",
    };
    const res = await collect({
      regions: [region],
      cities: registrySeeds([region], [{ ...ds, fields }]),
      fetcher,
      now: NOW,
    });
    const item = res.batches[0]?.items.find((i) => i.title === "Tree Planting Day");
    // 09:00 floating in America/New_York (the dataset's zone) is 14:00Z in November.
    expect(item?.starts_at).toBe("2026-11-14T14:00:00.000Z");
  });
});

describe("text dates (startFormat text_range)", () => {
  it.each([
    ["November 7 2026 9 - 10 a.m.", "2026-11-07T09:00:00", "2026-11-07T10:00:00"],
    ["Nov 14 2026 10 - 11:30 a.m.", "2026-11-14T10:00:00", "2026-11-14T11:30:00"],
    ["Nov 14 2026 11 - 1 p.m.", "2026-11-14T11:00:00", "2026-11-14T13:00:00"],
    ["Saturday, Nov 14 2026 7:30 p.m.", "2026-11-14T19:30:00", null],
    [
      "Nov 14 2026 9 a.m. - 4 p.m.<br>Nov 15 2026 9 - 10 a.m.",
      "2026-11-14T09:00:00",
      "2026-11-14T16:00:00",
    ],
  ])("%s", (text, start, end) => {
    expect(parseTextDateRange(text)).toEqual({ start, end, allDay: false });
  });
  it("reads a date alone as all day and refuses junk", () => {
    expect(parseTextDateRange("Nov 14 2026")).toEqual({
      start: "2026-11-14",
      end: null,
      allDay: true,
    });
    expect(parseTextDateRange("Smarch 40 2026")).toBeNull();
    expect(parseTextDateRange("soon")).toBeNull();
  });
  it("maps rows and leaves the window to the client for a text start", () => {
    const seed = {
      id: "t",
      kind: "socrata" as const,
      url: "https://data.example.gov/resource/abcd-1234.json",
      name: "T",
      attribution: "Listed from test open data.",
      fields: {
        title: "title",
        start: "next_date_times",
        startFormat: "text_range" as const,
        location: "address",
      },
      geoColumn: "point",
    };
    expect(new URL(socrataUrl(seed, ATL, window)).searchParams.get("$where")).toBe(
      "within_circle(point, 33.749, -84.388, 60000)",
    );
    const rows = parseSocrata(
      JSON.stringify([
        { title: "Skating", next_date_times: "Nov 14 2026 9 - 10 a.m.", address: "1 Main St" },
        { title: "Bad", next_date_times: "tbd" },
      ]),
      seed,
    );
    expect(rows).toEqual([
      expect.objectContaining({
        title: "Skating",
        start: "2026-11-14T09:00:00",
        end: "2026-11-14T10:00:00",
      }),
    ]);
  });
  it("the registry's Calgary dataset covers Calgary", () => {
    const cal = loadRegistry().find((d) => d.id === "calgary-city-events")!;
    const r = datasetRegion(cal);
    expect(circleOverlapsBbox({ lat: 51.05, lng: -114.07, radiusKm: 25 }, cal.bbox)).toBe(true);
    expect(r.radiusKm).toBeGreaterThan(15);
    expect(r.timezone).toBe("America/Edmonton");
  });
  it("every dataset that is on is credited word for word on the site (@ap/core OPEN_DATA_CREDITS)", () => {
    const credits = readFileSync(
      fileURLToPath(new URL("../../core/src/imports/index.ts", import.meta.url)),
      "utf8",
    );
    for (const d of loadRegistry().filter((x) => x.enabled === true)) {
      expect(credits).toContain(`id: "${d.id}"`);
      expect(credits).toContain(JSON.stringify(d.attribution));
    }
  });
  it("the Calgary dataset is on with the licence's attribution, word for word", () => {
    const cal = loadRegistry().find((d) => d.id === "calgary-city-events")!;
    expect(cal.enabled).toBe(true);
    expect(cal.attribution).toBe(
      "Contains information licensed under the Open Government Licence – City of Calgary.",
    );
  });
});
