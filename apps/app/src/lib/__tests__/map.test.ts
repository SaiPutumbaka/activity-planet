import { describe, expect, it } from "vitest";

import {
  EMPTY_VIEW,
  EVENT_FLAG,
  PLACE_FLAG,
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
  decodeHubs,
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
  canStartPlan,
  startPlanSearch,
  timeWindow,
  toggleHubChip,
  toggleLayer,
  type ChipHub,
  mappingNotice,
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

const HUBS = decodeHubs([
  ["h1", "basketball", "Basketball", "🏀", "specific"],
  ["h2", "cafes", "Cafés", "☕", "generic"],
  ["h9", "hunting", "Hunting", "🦌", "none"],
]);

describe("decodeFeature (encoding as built)", () => {
  it("reads a place: hub index, every matching hub, name and flags", () => {
    const f = decodeFeature(
      [
        "p1",
        -84.39,
        33.75,
        "court_field",
        0,
        PLACE_FLAG.GEOAPIFY | PLACE_FLAG.MINE,
        "Court A",
        [0, 1],
      ],
      "place",
      HUBS,
    );
    expect(f).toMatchObject({
      id: "p1",
      kind: "place",
      lng: -84.39,
      lat: 33.75,
      type: "court_field",
      hubId: "h1",
      hubIds: ["h1", "h2"],
      name: "Court A",
      startsAt: null,
      generic: false,
      geoapify: true,
      mine: true,
      pending: false,
      imported: false,
    });
  });

  it("reads a plan: its hub, title, start and event flags", () => {
    const f = decodeFeature(
      ["e1", 1, 1, "imported", 1, EVENT_FLAG.IMPORTED | EVENT_FLAG.FREE, "Run", 1_800_000_000],
      "plan",
      HUBS,
    );
    expect(f).toMatchObject({
      hubId: "h2",
      hubIds: ["h2"],
      name: "Run",
      imported: true,
      free: true,
    });
    expect(f?.startsAt?.toISOString()).toBe(new Date(1_800_000_000_000).toISOString());
    // Event bits never read as place bits (1 is "imported" on a plan, "general" on a place).
    expect(f?.generic).toBe(false);
    expect(
      decodeFeature(["e", 1, 1, "member", 0, EVENT_FLAG.ADULTS_ONLY, "x", 1], "plan", HUBS),
    ).toMatchObject({ adultsOnly: true, imported: false, pending: false });
  });

  it("falls back to a kind label when the name is missing", () => {
    expect(decodeFeature(["p1", 0, 0, "library", null, 0], "place")?.name).toBe("Library");
    expect(decodeFeature(["p1", 0, 0, "court_field", null, 0, ""], "place")?.name).toBe(
      "Court or field",
    );
    expect(decodeFeature(["e1", 0, 0, "member", 0, 0], "plan")?.name).toBe("Plan");
    expect(decodeFeature(["s1", 0, 0, "imported", 0, 0], "show")?.name).toBe("Show");
    expect(decodeFeature(["p1", 0, 0, "nope", null, 0], "place")?.name).toBe("Place");
  });

  it("reads the place flag bits", () => {
    const f = decodeFeature(
      ["p", 1, 1, "spot", null, PLACE_FLAG.PENDING | PLACE_FLAG.PRIVATE | PLACE_FLAG.GENERAL],
      "place",
    );
    expect(f).toMatchObject({ pending: true, private: true, generic: true, geoapify: false });
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

  it("treats junk flags and hub indexes as empty", () => {
    const f = decodeFeature(["x", 1, 2, "", "h1", "7", "", [7, "a", 1.5]], "place", HUBS);
    expect(f?.flags).toBe(0);
    expect(f?.hubId).toBeNull();
    expect(f?.hubIds).toEqual([]);
    expect(f?.type).toBe("place");
  });
});

describe("decodeMapInView", () => {
  it("decodes every list, the hubs and the flags", () => {
    const v = decodeMapInView({
      v: 1,
      places: [["p1", 1, 1, "park", 1, PLACE_FLAG.GENERAL, "Park", [1]]],
      plans: [["e1", 1, 1, "member", 0, 0, "Run", 1]],
      shows: [["s1", 1, 1, "imported", 3, EVENT_FLAG.IMPORTED, "Final", 2]],
      cells: [[1.1, 2.2, 2, ["a", "b"], [0, 3], ["A"], [10]]],
      hubs: [
        ["h1", "basketball", "Basketball", "🏀", "specific"],
        ["h2", "cafes", "Cafés", "☕", "generic"],
        ["h9", "hunting", "Hunting", "🦌", "none"],
        ["h4", "music", "Music", "🎵", "specific"],
      ],
      truncated: true,
      zoom_in: false,
      mapping: true,
      no_hubs: false,
      generic: true,
    });
    expect(v.places[0]).toMatchObject({ hubId: "h2", hubIds: ["h2"], generic: true });
    expect(v.plans[0]).toMatchObject({ name: "Run", hubId: "h1" });
    expect(v.shows[0]).toMatchObject({ kind: "show", hubId: "h4", imported: true });
    expect(v.cells).toEqual([
      {
        key: "1.1,2.2",
        center: { lng: 1.1, lat: 2.2 },
        count: 2,
        events: [
          { id: "a", name: "A", startsAt: new Date(10_000), hubId: "h1" },
          { id: "b", name: "Plan", startsAt: null, hubId: "h4" },
        ],
        hubsKnown: true,
      },
    ]);
    expect(v.hubs.map((h) => h.slug)).toEqual(["basketball", "cafes", "hunting", "music"]);
    expect(v.truncated).toBe(true);
    expect(v.zoomIn).toBe(false);
    expect(v.mapping).toBe(true);
    expect(v.mappingReason).toBeNull();
    expect(v.generic).toBe(true);
    expect(v.eventsOnlyHubIds).toEqual(["h9"]);
  });

  it("reads mapping_reason only while mapping (migration 41)", () => {
    expect(decodeMapInView({ mapping: true, mapping_reason: "budget" }).mappingReason).toBe(
      "budget",
    );
    expect(
      decodeMapInView({ mapping: true, mapping_reason: "extract_too_big" }).mappingReason,
    ).toBe("extract_too_big");
    expect(decodeMapInView({ mapping: true, mapping_reason: "bogus" }).mappingReason).toBeNull();
    expect(
      decodeMapInView({ mapping: false, mapping_reason: "size_cap" }).mappingReason,
    ).toBeNull();
  });

  it("words the mapping notice for each reason", () => {
    expect(mappingNotice(null)).toMatch(/usually appear within a day/);
    expect(mappingNotice("budget")).toMatch(/few nights/);
    expect(mappingNotice("size_cap")).toMatch(/paused/);
    expect(mappingNotice("extract_too_big")).toMatch(/can't be mapped here automatically/);
    for (const r of [null, "budget", "size_cap", "extract_too_big"] as const) {
      expect(mappingNotice(r)).not.toMatch(/student|Atlanta|GSU/i);
    }
  });

  it("reads a migration 29 cell (no titles or starts) and a zoom_in reply", () => {
    const v = decodeMapInView({
      places: null,
      plans: [],
      cells: [[1, 1, 1, ["a"], [0]]],
      hubs: [["h1", "x", "X", "", "specific"]],
      zoom_in: true,
    });
    expect(v.places).toEqual([]);
    expect(v.zoomIn).toBe(true);
    expect(v.cells[0]?.events).toEqual([{ id: "a", name: "Plan", startsAt: null, hubId: "h1" }]);
    expect(v.cells[0]?.hubsKnown).toBe(true);
    expect(v.mapping).toBe(false);
  });

  it("returns the empty view for junk and drops bad rows without throwing", () => {
    expect(decodeMapInView(null)).toEqual(EMPTY_VIEW);
    expect(decodeMapInView("x")).toEqual(EMPTY_VIEW);
    expect(decodeMapInView([1])).toEqual(EMPTY_VIEW);
    const v = decodeMapInView({
      places: [["ok", 0, 0, "park", null, 0, "Ok", []], "bad", ["no"]],
      plans: "nope",
      hubs: "nope",
    });
    expect(v.places.map((p) => p.id)).toEqual(["ok"]);
    expect(v.plans).toEqual([]);
    expect(v.hubs).toEqual([]);
  });

  it("keeps hub indexes right past a malformed hub entry", () => {
    const v = decodeMapInView({
      hubs: ["junk", ["h2", "b", "B", "", "specific"]],
      places: [["p", 0, 0, "park", 1, 0, "P", [0, 1]]],
    });
    expect(v.places[0]?.hubIds).toEqual(["h2"]);
    expect(v.hubs.map((h) => h.id)).toEqual(["h2"]);
  });

  it("deduplicates features by id and merges cells with the same centre", () => {
    const v = decodeMapInView({
      places: [
        ["p", 0, 0, "park", null, 0],
        ["p", 1, 1, "park", null, 0],
      ],
      hubs: [["h", "h", "H", "", "specific"]],
      cells: [
        [3.4, 5.6, 1, ["a"], [0]],
        [3.4000000001, 5.6, 2, ["b", "c"], [0, 0]],
        [3.4, 5.6, 0, [], []],
        [500, 1, 1, ["z"], [0]],
      ],
    });
    expect(v.places).toHaveLength(1);
    expect(v.cells).toHaveLength(1);
    expect(v.cells[0]?.count).toBe(3);
    expect(v.cells[0]?.events.map((e) => e.id)).toEqual(["a", "b", "c"]);
  });

  it("never turns a cell into a point", () => {
    const v = decodeMapInView({ cells: [[1, 1, 1, ["secret"], [0]]] });
    const all = [...v.places, ...v.plans, ...v.shows].map((f) => f.id);
    expect(all).not.toContain("secret");
    // No hub list: the cell cannot be matched to a chip.
    expect(v.cells[0]?.hubsKnown).toBe(false);
  });
});

describe("decodePlaceDetail", () => {
  it("reads place_detail as built and sanitizes links", () => {
    const d = decodePlaceDetail({
      v: 1,
      id: "p",
      name: "Court",
      kind: "court_field",
      kind_label: "Court or field",
      kind_icon: "trophy",
      lng: 1,
      lat: 2,
      address_text: "1 Main St",
      locality: "Decatur",
      opening_hours: "Mo-Su 06:00-22:00",
      hubs: [
        { id: "h", slug: "b", name: "Basketball", emoji: "🏀", general: false, joined: true },
        { slug: "no id" },
      ],
      more_hubs: true,
      website: "javascript:alert(1)",
      osm_url: "https://www.openstreetmap.org/way/123",
      source: "osm",
      status: "active",
      is_public: true,
      mine: false,
      checked_at: "2026-11-01T00:00:00Z",
      plans_here: [
        { id: "e", title: "Game", starts_at: "2026-11-05T18:00:00Z", hub_id: "h" },
        { title: "no id" },
      ],
    });
    expect(d).toMatchObject({
      kindLabel: "Court or field",
      address: "1 Main St",
      locality: "Decatur",
      hours: "Mo-Su 06:00-22:00",
      website: null,
      osmUrl: "https://www.openstreetmap.org/way/123",
      moreHubs: true,
      generic: false,
      reviewed: false,
      pending: false,
      private: false,
    });
    expect(d?.hubs).toEqual([
      { id: "h", slug: "b", name: "Basketball", emoji: "🏀", general: false, joined: true },
    ]);
    expect(d?.plansHere).toEqual([
      { id: "e", title: "Game", startsAt: new Date("2026-11-05T18:00:00Z"), hubId: "h" },
    ]);
    expect(
      decodePlaceDetail({ id: "p", lng: 1, lat: 2, osm_url: "https://evil.example/node/1" })
        ?.osmUrl,
    ).toBeNull();
    expect(decodePlaceDetail({ id: "p", lng: 1, lat: 2, website: "https://x.org" })?.website).toBe(
      "https://x.org/",
    );
    expect(decodePlaceDetail({ lng: 1, lat: 2 })).toBeNull();
  });

  it("derives reviewed, pending, private and general spot", () => {
    const base = { id: "p", lng: 1, lat: 2, source: "user" };
    expect(decodePlaceDetail({ ...base, status: "active", is_public: true })?.reviewed).toBe(true);
    expect(decodePlaceDetail({ ...base, status: "pending", is_public: true })).toMatchObject({
      reviewed: false,
      pending: true,
    });
    const priv = decodePlaceDetail({
      ...base,
      status: "active",
      is_public: false,
      address_text: "should not show",
    });
    expect(priv).toMatchObject({ reviewed: false, private: true, address: null });
    expect(
      decodePlaceDetail({
        ...base,
        source: "osm",
        hubs: [{ id: "c", general: true }],
      })?.generic,
    ).toBe(true);
    expect(decodePlaceDetail({ ...base, kind: "court_field" })?.kindLabel).toBe("Court or field");
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
      placeFilter: null,
      eventFilter: ["b"],
    });
  });

  it("asks for every chip hub and filters locally otherwise", () => {
    const all = ["a", "b", "faith", "x"];
    expect(planHubRequest(null, hubs)).toEqual({
      hubIds: all,
      generic: false,
      placeFilter: null,
      eventFilter: null,
    });
    expect(planHubRequest(["b", "a"], hubs)).toEqual({
      hubIds: all,
      generic: false,
      placeFilter: ["a", "b"],
      eventFilter: ["a", "b"],
    });
  });

  it("asks for every specific hub when signed out with no hub picked (D-041)", () => {
    expect(planHubRequest(null, [], [], { signedOut: true })).toEqual({
      hubIds: null,
      generic: false,
      placeFilter: null,
      eventFilter: null,
    });
    // Signed in with no hubs: none (plans only).
    expect(planHubRequest(null, [])).toEqual({
      hubIds: [],
      generic: false,
      placeFilter: null,
      eventFilter: null,
    });
    // Signed out with a picked hub: that hub.
    expect(
      planHubRequest(["x"], [hub("x", { joined: false })], [], { signedOut: true }).hubIds,
    ).toEqual(["x"]);
  });

  it("sends an explored sensitive hub only inside the full sensitive cover (§7.6)", () => {
    const explored = [hub("lgbtq", { sensitive: true, joined: false })];
    const cover = ["lgbtq", "faith-1", "faith-2", "wellness"];
    // Alone (signed out, or a member with no other hubs), with the chip selected or not.
    for (const sel of [["lgbtq"], null]) {
      const p = planHubRequest(sel, explored, cover, { signedOut: true });
      expect(p.hubIds).toEqual([...cover].sort());
      expect(p.generic).toBe(false);
      expect(p.placeFilter).toEqual(["lgbtq"]);
    }
    // With joined hubs: the cover is added and the place filter keeps the chip hubs only; every
    // plan in view stays under "All my hubs".
    const mixed = [hub("a"), ...explored];
    const p = planHubRequest(null, mixed, cover);
    expect(p.hubIds).toEqual(["a", ...cover].sort());
    expect(p.placeFilter).toEqual(["a", "lgbtq"]);
    expect(p.eventFilter).toBeNull();
    // A joined sensitive hub needs no cover: the server knows the membership.
    expect(planHubRequest(null, hubs, cover).hubIds).toEqual(["a", "b", "faith", "x"]);
    // The cover never pushes the request past the hub cap.
    const many = Array.from({ length: 80 }, (_, i) => `s${String(i).padStart(2, "0")}`);
    expect(planHubRequest(["lgbtq"], explored, many).hubIds).toHaveLength(MAX_REQUEST_HUBS);
    expect(planHubRequest(["lgbtq"], explored, many).hubIds).toContain("lgbtq");
  });

  it("hides cells without per-event hubs under a hub filter", () => {
    const view = decodeMapInView({
      hubs: [["a", "a", "A", "", "specific"]],
      cells: [
        [0, 0, 3, ["c1", "c2", "c3"]],
        [1, 1, 1, ["d1"], [0]],
      ],
    });
    expect(view.cells.map((c) => c.hubsKnown)).toEqual([false, true]);
    const only = (ids: string[] | null) => ({ placeFilter: ids, eventFilter: ids });
    expect(applyHubFilter(view, only(null)).cells).toHaveLength(2);
    expect(applyHubFilter(view, only(["a"])).cells.map((c) => c.key)).toEqual(["1.0,1.0"]);
    expect(applyHubFilter(view, only(["b"])).cells).toEqual([]);
    // Merging a cell without hubs into one with hubs makes the merged cell unknown.
    const merged = decodeMapInView({
      hubs: [["a", "a", "A", "", "specific"]],
      cells: [
        [0, 0, 1, ["x"], [0]],
        [0, 0, 1, ["y"]],
      ],
    });
    expect(merged.cells[0]?.hubsKnown).toBe(false);
  });

  it("never sends a sensitive chip on its own (§7.6)", () => {
    const p = planHubRequest(["faith"], hubs);
    expect(p.hubIds?.length).toBeGreaterThan(1);
    expect(p.generic).toBe(false);
    expect(p.placeFilter).toEqual(["faith"]);
  });

  it("ignores selected ids that are not chips", () => {
    expect(planHubRequest(["gone"], hubs).placeFilter).toBeNull();
  });

  it("filters features locally by hub; own places always stay", () => {
    const view = decodeMapInView({
      hubs: [
        ["a", "a", "A", "", "specific"],
        ["b", "b", "B", "", "specific"],
      ],
      places: [
        ["p1", 0, 0, "park", 0, 0, "P1", [0]],
        ["p2", 0, 0, "park", 1, 0, "P2", [1]],
        ["p3", 0, 0, "park", null, 0, "P3", []],
        ["p4", 0, 0, "park", 1, 0, "P4", [1, 0]],
        ["p5", 0, 0, "spot", null, PLACE_FLAG.MINE | PLACE_FLAG.PRIVATE, "Mine", []],
      ],
      plans: [
        ["e1", 0, 0, "member", 0, 0, "E1", 1],
        ["e2", 0, 0, "member", 1, 0, "E2", 1],
      ],
      shows: [["s1", 0, 0, "imported", 1, 1, "S1", 1]],
      cells: [[0, 0, 2, ["c1", "c2"], [0, 1]]],
    });
    const f = applyHubFilter(view, { placeFilter: ["a"], eventFilter: ["a"] });
    expect(f.places.map((p) => p.id)).toEqual(["p1", "p4", "p5"]);
    expect(f.plans.map((p) => p.id)).toEqual(["e1"]);
    expect(f.shows).toEqual([]);
    expect(f.cells[0]?.count).toBe(1);
    // Places only (the sensitive cover under "All my hubs"): every event stays.
    const placesOnly = applyHubFilter(view, { placeFilter: ["a"], eventFilter: null });
    expect(placesOnly.plans).toHaveLength(2);
    expect(placesOnly.cells[0]?.count).toBe(2);
    expect(applyHubFilter(view, { placeFilter: null, eventFilter: null })).toBe(view);
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
      cells: [[0, 0, 3, []]],
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
        ["p1", 0, 0, "park", 0, 0, "P1", [0]],
        ["p2", 0, 0, "park", 0, PLACE_FLAG.GENERAL, "P2", [0]],
        ["p3", 0, 0, "park", 0, PLACE_FLAG.PENDING, "P3", [0]],
      ],
      plans: [
        ["e1", 0, 0, "member", 0, 0, "E1", 1],
        ["e2", 0, 0, "imported", 0, EVENT_FLAG.IMPORTED, "E2", 1],
      ],
      cells: [[0, 0, 2, ["c1", "c2"], [0, 0], ["C1", "C2"], [1, 2]]],
      hubs: [["a", "a", "A", "", "specific"]],
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

describe("Start a plan here", () => {
  const h = (slug: string, joined: boolean, general: boolean) => ({
    id: `id-${slug}`,
    slug,
    name: slug,
    emoji: "",
    joined,
    general,
  });

  it("is offered for active public places only", () => {
    expect(canStartPlan({ private: false, pending: false })).toBe(true);
    expect(canStartPlan({ private: true, pending: false })).toBe(false);
    expect(canStartPlan({ private: false, pending: true })).toBe(false);
  });

  it("passes the place and the first joined specific hub", () => {
    expect(
      startPlanSearch({
        id: "p1",
        hubs: [h("parks", true, true), h("chess", false, false), h("basketball", true, false)],
      }),
    ).toEqual({ place: "p1", hub: "basketball" });
    expect(startPlanSearch({ id: "p1", hubs: [h("parks", true, true)] })).toEqual({
      place: "p1",
      hub: "parks",
    });
    expect(startPlanSearch({ id: "p1", hubs: [h("chess", false, false)] })).toEqual({
      place: "p1",
    });
  });
});
