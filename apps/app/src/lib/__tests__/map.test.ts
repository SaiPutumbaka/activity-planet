import { describe, expect, it } from "vitest";

import {
  EMPTY_VIEW,
  FLAG,
  MAP_MOCK,
  applyHubFilter,
  applyLayerFilter,
  bboxAround,
  bboxContains,
  bboxTooLargeForPlaces,
  cellCenter,
  cellKey,
  cellLabel,
  cellMapLabel,
  cellRing,
  countLine,
  decodeFeature,
  decodeMapInView,
  decodePlaceDetail,
  detectPlatform,
  directionsUrl,
  genericSpotsOn,
  isMissingRpc,
  MAX_REQUEST_HUBS,
  layersParam,
  mapInViewArgs,
  normalizeBBox,
  parseHubsParam,
  parseLayersParam,
  planHubRequest,
  snapBBox,
  sourceLine,
  timeWindow,
  toggleHubChip,
  toggleLayer,
  type ChipHub,
} from "../map";

const hub = (id: string, extra: Partial<ChipHub> = {}): ChipHub => ({
  id,
  slug: id,
  name: id,
  emoji: "*",
  colorKey: null,
  sensitive: false,
  joined: true,
  ...extra,
});

describe("decodeFeature (compact encoding)", () => {
  it("reads the six contract positions plus the optional name and start", () => {
    const f = decodeFeature(
      ["p1", -84.39, 33.75, "basketball_court", "h1", FLAG.GENERIC, "Court A", 1_800_000_000],
      "place",
    );
    expect(f).toMatchObject({
      id: "p1",
      kind: "place",
      lng: -84.39,
      lat: 33.75,
      type: "basketball_court",
      hubId: "h1",
      name: "Court A",
      generic: true,
      imported: false,
      pending: false,
    });
    expect(f?.startsAt?.toISOString()).toBe(new Date(1_800_000_000_000).toISOString());
  });

  it("falls back to a kind label when the name is missing", () => {
    expect(decodeFeature(["p1", 0, 0, "library", null, 0], "place")?.name).toBe("Library");
    expect(decodeFeature(["e1", 0, 0, "member", "h", 0], "plan")?.name).toBe("Plan");
    expect(decodeFeature(["s1", 0, 0, "show", null, 0], "show")?.name).toBe("Show");
    expect(decodeFeature(["p1", 0, 0, "nope", null, 0], "place")?.name).toBe("Place");
  });

  it("reads the flag bits", () => {
    const f = decodeFeature(["e1", 1, 1, "imported", "h", FLAG.IMPORTED | FLAG.PENDING], "plan");
    expect(f?.imported).toBe(true);
    expect(f?.pending).toBe(true);
    expect(f?.generic).toBe(false);
  });

  it("rejects malformed tuples", () => {
    expect(decodeFeature(null, "place")).toBeNull();
    expect(decodeFeature({ id: "x" }, "place")).toBeNull();
    expect(decodeFeature(["x", 1, 2, "k", null], "place")).toBeNull(); // too short
    expect(decodeFeature(["", 1, 2, "k", null, 0], "place")).toBeNull(); // no id
    expect(decodeFeature(["x", 181, 2, "k", null, 0], "place")).toBeNull();
    expect(decodeFeature(["x", 1, -91, "k", null, 0], "place")).toBeNull();
    expect(decodeFeature(["x", Number.NaN, 2, "k", null, 0], "place")).toBeNull();
    expect(decodeFeature(["x", "1", 2, "k", null, 0], "place")).toBeNull();
  });

  it("treats junk flags and hub ids as empty", () => {
    const f = decodeFeature(["x", 1, 2, "", "", "7"], "place");
    expect(f?.flags).toBe(0);
    expect(f?.hubId).toBeNull();
    expect(f?.type).toBe("place");
  });
});

describe("decodeMapInView", () => {
  it("decodes every list and the flags", () => {
    const v = decodeMapInView({
      places: [["p1", 1, 1, "park", "h1", 1]],
      plans: [["e1", 1, 1, "member", "h1", 0, "Run", 1]],
      shows: [["s1", 1, 1, "show", null, 0, "Final"]],
      cells: [
        { cell: [1.1, 2.2], n: 2, ids: ["a", "b"], names: ["A"], starts: [10], hubs: ["h1", null] },
      ],
      truncated: true,
      zoom_in: false,
      mapping: true,
      events_only: ["h9", 3],
    });
    expect(v.places).toHaveLength(1);
    expect(v.plans[0]?.name).toBe("Run");
    expect(v.shows[0]?.kind).toBe("show");
    expect(v.cells).toEqual([
      {
        key: "1.1,2.2",
        center: { lng: 1.1, lat: 2.2 },
        count: 2,
        events: [
          { id: "a", name: "A", startsAt: new Date(10_000), hubId: "h1" },
          { id: "b", name: "Plan", startsAt: null, hubId: null },
        ],
        hubsKnown: true,
      },
    ]);
    expect(v.truncated).toBe(true);
    expect(v.zoomIn).toBe(false);
    expect(v.mapping).toBe(true);
    expect(v.eventsOnlyHubIds).toEqual(["h9"]);
  });

  it("returns the empty view for junk and drops bad rows without throwing", () => {
    expect(decodeMapInView(null)).toEqual(EMPTY_VIEW);
    expect(decodeMapInView("x")).toEqual(EMPTY_VIEW);
    const v = decodeMapInView({
      places: [["ok", 0, 0, "park", null, 0], "bad", ["no"]],
      plans: "nope",
    });
    expect(v.places.map((p) => p.id)).toEqual(["ok"]);
    expect(v.plans).toEqual([]);
  });

  it("deduplicates features by id and merges cells with the same centre", () => {
    const v = decodeMapInView({
      places: [
        ["p", 0, 0, "park", null, 0],
        ["p", 1, 1, "park", null, 0],
      ],
      cells: [
        { cell: [3.4, 5.6], n: 1, ids: ["a"] },
        { cell: [3.4000000001, 5.6], n: 2, ids: ["b", "c"] },
        { cell: [3.4, 5.6], n: 0, ids: [] },
        { cell: [500, 1], n: 1, ids: ["z"] },
      ],
    });
    expect(v.places).toHaveLength(1);
    expect(v.cells).toHaveLength(1);
    expect(v.cells[0]?.count).toBe(3);
    expect(v.cells[0]?.events.map((e) => e.id)).toEqual(["a", "b", "c"]);
  });

  it("never turns a cell into a point", () => {
    const v = decodeMapInView({ cells: [{ cell: [1, 1], n: 1, ids: ["secret"] }] });
    const all = [...v.places, ...v.plans, ...v.shows].map((f) => f.id);
    expect(all).not.toContain("secret");
  });
});

describe("decodePlaceDetail", () => {
  it("reads a place and sanitizes links", () => {
    const d = decodePlaceDetail({
      id: "p",
      name: "Court",
      kind: "basketball_court",
      lng: 1,
      lat: 2,
      hub_ids: ["h", 4],
      website: "javascript:alert(1)",
      osm_ref: "node/123",
      source: "osm",
      checked_at: "2026-11-01T00:00:00Z",
      plans_here: [
        { id: "e", title: "Game", starts_at: "2026-11-05T18:00:00Z" },
        { title: "no id" },
      ],
    });
    expect(d?.website).toBeNull();
    expect(d?.hubIds).toEqual(["h"]);
    expect(d?.osmRef).toBe("node/123");
    expect(d?.plansHere).toHaveLength(1);
    expect(decodePlaceDetail({ id: "p", lng: 1, lat: 2, osm_ref: "../evil" })?.osmRef).toBeNull();
    expect(decodePlaceDetail({ id: "p", lng: 1, lat: 2, website: "https://x.org" })?.website).toBe(
      "https://x.org/",
    );
    expect(decodePlaceDetail({ lng: 1, lat: 2 })).toBeNull();
  });

  it("writes the §8 source line", () => {
    const now = new Date("2026-11-04T12:00:00Z");
    const checked = new Date("2026-11-01T11:00:00Z");
    expect(sourceLine({ source: "osm", checkedAt: checked, reviewed: false }, now)).toBe(
      "From OpenStreetMap · checked 3 days ago",
    );
    expect(sourceLine({ source: "user", checkedAt: null, reviewed: true }, now)).toBe(
      "Added by a member · reviewed",
    );
    expect(sourceLine({ source: "geoapify", checkedAt: null, reviewed: false }, now)).toBe(
      "From Geoapify (OpenStreetMap data)",
    );
  });
});

describe("cell geometry (approved-only events)", () => {
  it("rounds like Postgres round(numeric, 1): half away from zero", () => {
    expect(cellCenter(-84.35, 33.75)).toEqual({ lng: -84.4, lat: 33.8 });
    expect(cellCenter(-84.34, 33.74)).toEqual({ lng: -84.3, lat: 33.7 });
    expect(cellCenter(0.05, -0.05)).toEqual({ lng: 0.1, lat: -0.1 });
    expect(cellCenter(-0.04, 0.04)).toEqual({ lng: 0, lat: 0 });
    expect(Object.is(cellCenter(-0.04, 0).lng, -0)).toBe(false);
  });

  it("covers every venue that snaps to the centre", () => {
    const centre = cellCenter(13.4049, 52.52);
    const ring = cellRing(centre);
    expect(ring).toHaveLength(5);
    expect(ring[0]).toEqual(ring[4]);
    const [w, s] = ring[0]!;
    const [e, n] = ring[2]!;
    expect(e - w).toBeCloseTo(0.1, 9);
    expect(n - s).toBeCloseTo(0.1, 9);
    // A grid of venue points that round to this centre all fall inside the square.
    for (let dx = -0.0499; dx <= 0.0499; dx += 0.01) {
      for (let dy = -0.0499; dy <= 0.0499; dy += 0.01) {
        const v = { lng: centre.lng + dx, lat: centre.lat + dy };
        expect(cellKey(cellCenter(v.lng, v.lat))).toBe(cellKey(centre));
        expect(v.lng >= w && v.lng <= e && v.lat >= s && v.lat <= n).toBe(true);
      }
    }
  });

  it("clamps at the poles and may run past the antimeridian", () => {
    const north = cellRing({ lng: 0, lat: 85.1 });
    expect(Math.max(...north.map((p) => p[1]))).toBeLessThanOrEqual(85.0511);
    const east = cellRing({ lng: 180, lat: 0 });
    expect(east[1]![0]).toBeCloseTo(180.05, 9);
  });

  it("labels cells", () => {
    expect(cellLabel(1)).toBe("1 event in this area");
    expect(cellLabel(4)).toBe("4 events in this area");
    expect(cellMapLabel(2)).toBe("2 events in this area · exact spot shared after host approval");
  });
});

describe("bbox", () => {
  it("wraps longitudes and marks an antimeridian crossing with west > east", () => {
    expect(normalizeBBox({ west: 170, south: -20, east: 190, north: -10 })).toEqual({
      west: 170,
      south: -20,
      east: -170,
      north: -10,
    });
    expect(normalizeBBox({ west: -200, south: 0, east: 200, north: 10 })).toEqual({
      west: -180,
      south: 0,
      east: 180,
      north: 10,
    });
    expect(normalizeBBox({ west: 0, south: -89, east: 1, north: 89 }).north).toBe(85.0511);
  });

  it("snaps outward to the 0.05 grid", () => {
    expect(snapBBox({ west: -84.43, south: 33.71, east: -84.31, north: 33.79 })).toEqual({
      west: -84.45,
      south: 33.7,
      east: -84.3,
      north: 33.8,
    });
    // Already on the grid stays put (no float creep).
    expect(snapBBox({ west: 1.1, south: 2.2, east: 1.3, north: 2.35 })).toEqual({
      west: 1.1,
      south: 2.2,
      east: 1.3,
      north: 2.35,
    });
  });

  it("mirrors the server's places size limit, across the antimeridian too", () => {
    expect(bboxTooLargeForPlaces({ west: 0, south: 0, east: 1.5, north: 1 })).toBe(false);
    expect(bboxTooLargeForPlaces({ west: 0, south: 0, east: 1.6, north: 1 })).toBe(true);
    expect(bboxTooLargeForPlaces({ west: 0, south: 0, east: 1, north: 1.2 })).toBe(true);
    expect(bboxTooLargeForPlaces({ west: 179.5, south: 0, east: -179.5, north: 0.5 })).toBe(false);
    expect(
      bboxContains({ west: 179.5, south: 0, east: -179.5, north: 1 }, { lng: -179.9, lat: 0.5 }),
    ).toBe(true);
  });

  it("estimates the visible bbox from a camera", () => {
    const b = bboxAround({ lng: 13.4, lat: 52.5 }, 12, 400, 600);
    expect(b.west).toBeLessThan(13.4);
    expect(b.east).toBeGreaterThan(13.4);
    // 400 px at zoom 12 (512 px tiles) is 400 / (512 * 4096) of 360 degrees.
    expect(b.east - b.west).toBeCloseTo((400 / (512 * 4096)) * 360, 6);
    expect(bboxTooLargeForPlaces(b)).toBe(false);
    expect(bboxTooLargeForPlaces(bboxAround({ lng: 0, lat: 0 }, 2, 400, 600))).toBe(true);
  });
});

describe("hub chips", () => {
  const hubs = [hub("a"), hub("b"), hub("faith", { sensitive: true }), hub("x", { joined: false })];

  it("toggles from All to one hub, adds and removes, and returns to All", () => {
    let s = toggleHubChip(null, "a");
    expect(s).toEqual(["a"]);
    s = toggleHubChip(s, "b");
    expect(s).toEqual(["a", "b"]);
    s = toggleHubChip(s, "a");
    expect(s).toEqual(["b"]);
    expect(toggleHubChip(s, "b")).toBeNull();
  });

  it("turns generic spots on only with exactly one non-sensitive hub chip", () => {
    expect(genericSpotsOn(null, hubs)).toBe(false); // All my hubs
    expect(genericSpotsOn(["a"], hubs)).toBe(true);
    expect(genericSpotsOn(["x"], hubs)).toBe(true); // explored hub counts
    expect(genericSpotsOn(["a", "b"], hubs)).toBe(false);
    expect(genericSpotsOn(["faith"], hubs)).toBe(false);
    expect(genericSpotsOn(["missing"], hubs)).toBe(false);
    expect(genericSpotsOn([], hubs)).toBe(false);
  });

  it("asks for one hub with generic spots when one chip is selected", () => {
    expect(planHubRequest(["b"], hubs)).toEqual({
      hubIds: ["b"],
      generic: true,
      localFilter: null,
    });
  });

  it("asks for every chip hub and filters locally otherwise", () => {
    const all = ["a", "b", "faith", "x"];
    expect(planHubRequest(null, hubs)).toEqual({ hubIds: all, generic: false, localFilter: null });
    expect(planHubRequest(["b", "a"], hubs)).toEqual({
      hubIds: all,
      generic: false,
      localFilter: ["a", "b"],
    });
  });

  it("sends an explored sensitive hub only inside the full sensitive cover (§7.6)", () => {
    const explored = [hub("lgbtq", { sensitive: true, joined: false })];
    const cover = ["lgbtq", "faith-1", "faith-2", "wellness"];
    // Alone (signed out, or a member with no other hubs), with the chip selected or not.
    for (const sel of [["lgbtq"], null]) {
      const p = planHubRequest(sel, explored, cover);
      expect(p.hubIds).toEqual([...cover].sort());
      expect(p.generic).toBe(false);
      expect(p.localFilter).toEqual(["lgbtq"]);
    }
    // With joined hubs: the cover is added and the local filter keeps the chip hubs only.
    const mixed = [hub("a"), ...explored];
    const p = planHubRequest(null, mixed, cover);
    expect(p.hubIds).toEqual(["a", ...cover].sort());
    expect(p.localFilter).toEqual(["a", "lgbtq"]);
    // A joined sensitive hub needs no cover: the server knows the membership.
    expect(planHubRequest(null, hubs, cover).hubIds).toEqual(["a", "b", "faith", "x"]);
    // The cover never pushes the request past the hub cap.
    const many = Array.from({ length: 80 }, (_, i) => `s${String(i).padStart(2, "0")}`);
    expect(planHubRequest(["lgbtq"], explored, many).hubIds).toHaveLength(MAX_REQUEST_HUBS);
    expect(planHubRequest(["lgbtq"], explored, many).hubIds).toContain("lgbtq");
  });

  it("hides cells without per-event hubs under a hub filter", () => {
    const view = decodeMapInView({
      cells: [
        { cell: [0, 0], n: 3, ids: ["c1", "c2", "c3"] },
        { cell: [1, 1], n: 1, ids: ["d1"], hubs: ["a"] },
      ],
    });
    expect(view.cells.map((c) => c.hubsKnown)).toEqual([false, true]);
    expect(applyHubFilter(view, null).cells).toHaveLength(2);
    expect(applyHubFilter(view, ["a"]).cells.map((c) => c.key)).toEqual(["1.0,1.0"]);
    expect(applyHubFilter(view, ["b"]).cells).toEqual([]);
    // Merging a cell without hubs into one with hubs makes the merged cell unknown.
    const merged = decodeMapInView({
      cells: [
        { cell: [0, 0], n: 1, ids: ["x"], hubs: ["a"] },
        { cell: [0, 0], n: 1, ids: ["y"] },
      ],
    });
    expect(merged.cells[0]?.hubsKnown).toBe(false);
  });

  it("never sends a sensitive chip on its own (§7.6)", () => {
    const p = planHubRequest(["faith"], hubs);
    expect(p.hubIds.length).toBeGreaterThan(1);
    expect(p.generic).toBe(false);
    expect(p.localFilter).toEqual(["faith"]);
  });

  it("ignores selected ids that are not chips, and works with no hubs (anon)", () => {
    expect(planHubRequest(["gone"], hubs).localFilter).toBeNull();
    expect(planHubRequest(null, [])).toEqual({ hubIds: [], generic: false, localFilter: null });
  });

  it("filters features locally by hub; hubless plans and shows stay", () => {
    const view = decodeMapInView({
      places: [
        ["p1", 0, 0, "park", "a", 0],
        ["p2", 0, 0, "park", "b", 0],
        ["p3", 0, 0, "park", null, 0],
      ],
      plans: [
        ["e1", 0, 0, "member", "a", 0],
        ["e2", 0, 0, "member", "b", 0],
      ],
      shows: [["s1", 0, 0, "show", null, 0]],
      cells: [{ cell: [0, 0], n: 2, ids: ["c1", "c2"], hubs: ["a", "b"] }],
    });
    const f = applyHubFilter(view, ["a"]);
    expect(f.places.map((p) => p.id)).toEqual(["p1"]);
    expect(f.plans.map((p) => p.id)).toEqual(["e1"]);
    expect(f.shows.map((p) => p.id)).toEqual(["s1"]);
    expect(f.cells[0]?.count).toBe(1);
    expect(applyHubFilter(view, null)).toBe(view);
  });
});

describe("layers and params", () => {
  it("keeps at least one layer on", () => {
    expect(toggleLayer(["places", "plans", "shows"], "plans")).toEqual(["places", "shows"]);
    expect(toggleLayer(["shows"], "shows")).toEqual(["shows"]);
    expect(toggleLayer(["shows"], "places")).toEqual(["places", "shows"]);
  });

  it("drops cells with the plans layer and shows with theirs", () => {
    const view = decodeMapInView({
      shows: [["s", 0, 0, "show", null, 0]],
      cells: [{ cell: [0, 0], n: 1, ids: ["c"] }],
    });
    expect(applyLayerFilter(view, ["places", "shows"]).cells).toEqual([]);
    expect(applyLayerFilter(view, ["places", "plans"]).shows).toEqual([]);
  });

  it("parses and writes the search params", () => {
    expect(parseLayersParam(undefined)).toEqual(["places", "plans", "shows"]);
    expect(parseLayersParam("shows,bogus,places")).toEqual(["places", "shows"]);
    expect(parseLayersParam("bogus")).toEqual(["places", "plans", "shows"]);
    expect(layersParam(["places", "plans", "shows"])).toBeUndefined();
    expect(layersParam(["shows", "places"])).toBe("places,shows");
    expect(parseHubsParam(" a,b,,a ")).toEqual(["a", "b"]);
    expect(parseHubsParam("")).toBeNull();
  });
});

describe("time window", () => {
  const now = new Date(2026, 10, 4, 15, 30);
  it("runs Today to local midnight, the week to 7 days and 30 days to 30", () => {
    expect(timeWindow("today", now).to).toEqual(new Date(2026, 10, 5, 0, 0));
    expect(timeWindow("week", now).to.getTime() - now.getTime()).toBe(7 * 86_400_000);
    expect(timeWindow("month", now).to.getTime() - now.getTime()).toBe(30 * 86_400_000);
  });

  it("builds RPC args with every layer (chips filter locally)", () => {
    const args = mapInViewArgs(
      {
        bbox: { west: 1, south: 2, east: 3, north: 4 },
        hubIds: ["a"],
        generic: true,
        when: "week",
      },
      now,
    );
    expect(args).toMatchObject({
      p_west: 1,
      p_south: 2,
      p_east: 3,
      p_north: 4,
      p_hub_ids: ["a"],
      p_layers: ["places", "plans", "shows"],
      p_generic: true,
    });
  });
});

describe("misc", () => {
  it("detects a missing RPC", () => {
    expect(isMissingRpc({ code: "PGRST202" })).toBe(true);
    expect(isMissingRpc({ code: "42883" })).toBe(true);
    expect(isMissingRpc({ code: "X" }, 404)).toBe(true);
    expect(isMissingRpc({ code: "42501" }, 403)).toBe(false);
    expect(isMissingRpc(null, 404)).toBe(false);
  });

  it("hands directions to the device's maps app", () => {
    const dest = { lng: -46.6333, lat: -23.5505, name: "Praça & Court" };
    expect(directionsUrl(dest, "ios")).toBe(
      "https://maps.apple.com/?daddr=-23.550500,-46.633300&q=Pra%C3%A7a%20%26%20Court",
    );
    expect(directionsUrl(dest, "android")).toBe(
      "geo:-23.550500,-46.633300?q=-23.550500,-46.633300(Pra%C3%A7a%20%26%20Court)",
    );
    expect(directionsUrl(dest, "other")).toBe(
      "https://www.openstreetmap.org/directions?to=-23.550500%2C-46.633300",
    );
    expect(detectPlatform("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0)")).toBe("ios");
    expect(detectPlatform("Mozilla/5.0 (Macintosh)", 5, "MacIntel")).toBe("ios");
    expect(detectPlatform("Mozilla/5.0 (Linux; Android 15)")).toBe("android");
    expect(detectPlatform("Mozilla/5.0 (Windows NT 10.0)")).toBe("other");
  });

  it("counts what is in view, cells included", () => {
    const v = decodeMapInView({
      places: [["p", 0, 0, "park", null, 0]],
      cells: [{ cell: [0, 0], n: 3, ids: [] }],
    });
    expect(countLine(v)).toBe("1 place, 3 plans in this area");
  });

  it("runs on the mock adapter under Vitest", () => {
    expect(MAP_MOCK).toBe(true);
  });
});

describe("map overlay data", () => {
  it("labels cells with the approval note and gives each place variant its own image", async () => {
    const { cellsGeoJSON, placeImageId, placesGeoJSON, happeningsGeoJSON, PLAN_IMPORTED_IMAGE } =
      await import("../map-style");
    const view = decodeMapInView({
      places: [
        ["p1", 0, 0, "park", "a", 0],
        ["p2", 0, 0, "park", "a", FLAG.GENERIC],
        ["p3", 0, 0, "park", "a", FLAG.PENDING],
      ],
      plans: [
        ["e1", 0, 0, "member", "a", 0],
        ["e2", 0, 0, "imported", "a", FLAG.IMPORTED],
      ],
      cells: [{ cell: [0, 0], n: 2, ids: ["c1", "c2"] }],
    });
    expect(cellsGeoJSON(view).features[0]?.properties.label).toBe(
      "2 events in this area · exact spot shared after host approval",
    );
    const icons = placesGeoJSON(view).features.map((f) => f.properties.icon);
    expect(new Set(icons).size).toBe(3);
    expect(icons).toEqual([
      placeImageId("park", "place"),
      placeImageId("park", "generic"),
      placeImageId("park", "pending"),
    ]);
    const plans = happeningsGeoJSON({ ...view, shows: [] }).features.map((f) => f.properties.icon);
    expect(plans[1]).toBe(PLAN_IMPORTED_IMAGE);
    expect(plans[0]).not.toBe(plans[1]);
  });
});
