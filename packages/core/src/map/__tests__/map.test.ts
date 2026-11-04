import { describe, expect, it } from "vitest";
import { bboxNeedsZoomIn, decodeMapView, snapBbox } from "../index";

const sample = {
  v: 1,
  hubs: [
    ["h-a", "basketball", "Basketball", "🏀", "specific"],
    ["h-b", "running", "Running", "🏃", "generic"],
  ],
  places: [
    ["p1", -84.38812, 33.749, "court_field", 0, 32 | 64, "Court", [0, 1]],
    ["p2", -84.4, 33.75, "park", null, 1, "Park", []],
  ],
  plans: [["e1", -84.39, 33.76, "member", 1, 2 | 4, "Pickup", 1793885164]],
  shows: [],
  cells: [
    [-84.4, 33.8, 2, ["e2", "e3"], [0, 5], ["Night run", "Board games"], [1793885164, 1793971564]],
  ],
  mapping: true,
  zoom_in: false,
  truncated: true,
  no_hubs: false,
  generic: false,
};

describe("decodeMapView", () => {
  it("decodes places, plans, cells and hubs", () => {
    const v = decodeMapView(sample);
    expect(v.hubs.map((h) => h.slug)).toEqual(["basketball", "running"]);
    expect(v.places?.[0]).toMatchObject({
      id: "p1",
      kind: "court_field",
      hubId: "h-a",
      hubIds: ["h-a", "h-b"],
      geoapify: true,
      mine: true,
      general: false,
    });
    expect(v.places?.[1]).toMatchObject({ hubId: null, hubIds: [], general: true });
    expect(v.plans?.[0]).toMatchObject({
      id: "e1",
      hubId: "h-b",
      inSelectedHub: true,
      free: true,
      imported: false,
      title: "Pickup",
    });
    expect(v.plans?.[0]?.startsAt.getTime()).toBe(1793885164000);
    expect(v.shows).toEqual([]);
    expect(v.cells[0]).toEqual({
      lng: -84.4,
      lat: 33.8,
      count: 2,
      events: [
        { id: "e2", hubId: "h-a", title: "Night run", startsAt: new Date(1793885164000) },
        { id: "e3", hubId: null, title: "Board games", startsAt: new Date(1793971564000) },
      ],
    });
    expect(v.truncated).toBe(true);
    expect(v.mapping).toBe(true);
  });

  it("reads a migration 29 cell without titles or starts", () => {
    const v = decodeMapView({ hubs: [], cells: [[1, 2, 1, ["e9"], [null]]] });
    expect(v.cells[0]?.events).toEqual([{ id: "e9", hubId: null, title: "", startsAt: null }]);
    expect(v.mapping).toBe(false);
  });

  it("keeps null layers null (zoom_in, layer off)", () => {
    const v = decodeMapView({ places: null, plans: null, zoom_in: true, hubs: [], cells: [] });
    expect(v.places).toBeNull();
    expect(v.plans).toBeNull();
    expect(v.zoomIn).toBe(true);
  });
});

describe("snapBbox", () => {
  it("snaps outward to 0.05 degrees", () => {
    expect(snapBbox({ west: -84.43, south: 33.71, east: -84.31, north: 33.82 })).toEqual({
      west: -84.45,
      south: 33.7,
      east: -84.3,
      north: 33.85,
    });
  });
  it("leaves grid values alone and clamps latitude", () => {
    expect(snapBbox({ west: -84.45, south: -89.99, east: -84.3, north: 89.99 })).toEqual({
      west: -84.45,
      south: -90,
      east: -84.3,
      north: 90,
    });
  });
  it("wraps longitude and keeps an antimeridian view crossing", () => {
    expect(snapBbox({ west: 179.93, south: 0, east: 180.07, north: 0.1 })).toEqual({
      west: 179.9,
      south: 0,
      east: -179.9,
      north: 0.1,
    });
  });
});

describe("bboxNeedsZoomIn", () => {
  it("matches the server's 1.0 x 1.5 degree limit", () => {
    expect(bboxNeedsZoomIn({ west: -85, south: 33.5, east: -83.5, north: 34.5 })).toBe(false);
    expect(bboxNeedsZoomIn({ west: -85, south: 33.5, east: -83.45, north: 34.5 })).toBe(true);
    expect(bboxNeedsZoomIn({ west: 179.5, south: 0, east: -179.5, north: 0.5 })).toBe(false);
  });
});
