import { describe, expect, it } from "vitest";

import {
  FLAG,
  decodeMapInView,
  decodePlaceDetail,
  getMapAdapter,
  type MapInViewArgs,
} from "../map";
import {
  GENERIC_PER_CITY,
  MOCK_CITIES,
  PLACES_PER_HUB_PER_CITY,
  hashString,
  mockMapAdapter,
  mockMapInView,
  mockPlaceDetail,
  seeded,
} from "../map-mock";

const BERLIN = MOCK_CITIES.find((c) => c.slug === "berlin")!;
const FROM = "2026-11-04T12:00:00.000Z";
const TO = "2026-11-11T12:00:00.000Z";

function argsAround(
  city: { lng: number; lat: number },
  extra: Partial<MapInViewArgs> = {},
): MapInViewArgs {
  return {
    p_west: city.lng - 0.4,
    p_south: city.lat - 0.3,
    p_east: city.lng + 0.4,
    p_north: city.lat + 0.3,
    p_hub_ids: ["hub-a", "hub-b"],
    p_layers: ["places", "plans", "shows"],
    p_from: FROM,
    p_to: TO,
    p_generic: false,
    ...extra,
  };
}

describe("mock map adapter", () => {
  it("is the adapter under test", async () => {
    expect(await getMapAdapter()).toBe(mockMapAdapter);
  });

  it("is deterministic", () => {
    expect(mockMapInView(argsAround(BERLIN))).toEqual(mockMapInView(argsAround(BERLIN)));
    expect(seeded(42)()).toBe(seeded(42)());
    expect(hashString("abc")).toBe(hashString("abc"));
  });

  it("returns places per requested hub, inside the bbox", () => {
    const raw = mockMapInView(argsAround(BERLIN));
    const v = decodeMapInView(raw);
    expect(v.places).toHaveLength(2 * PLACES_PER_HUB_PER_CITY);
    expect(new Set(v.places.map((p) => p.hubId))).toEqual(new Set(["hub-a", "hub-b"]));
    const a = argsAround(BERLIN);
    for (const f of [...v.places, ...v.plans, ...v.shows]) {
      expect(f.lng).toBeGreaterThanOrEqual(a.p_west);
      expect(f.lng).toBeLessThanOrEqual(a.p_east);
      expect(f.lat).toBeGreaterThanOrEqual(a.p_south);
      expect(f.lat).toBeLessThanOrEqual(a.p_north);
    }
    expect(v.places.some((p) => p.generic)).toBe(false);
  });

  it("adds generic spots only for one hub with generic set", () => {
    const one = decodeMapInView(
      mockMapInView(argsAround(BERLIN, { p_hub_ids: ["hub-a"], p_generic: true })),
    );
    expect(one.places.filter((p) => p.generic)).toHaveLength(GENERIC_PER_CITY);
    expect(
      one.places
        .filter((p) => p.generic)
        .every((p) => ["cafe", "park", "library"].includes(p.type)),
    ).toBe(true);
    const two = decodeMapInView(mockMapInView(argsAround(BERLIN, { p_generic: true })));
    expect(two.places.some((p) => p.generic)).toBe(false);
  });

  it("gives anon (no hubs) plans and shows but no places", () => {
    const v = decodeMapInView(mockMapInView(argsAround(BERLIN, { p_hub_ids: [] })));
    expect(v.places).toEqual([]);
    expect(v.plans.length).toBeGreaterThan(0);
    expect(v.shows.length).toBeGreaterThan(0);
  });

  it("keeps approved-only events as cells only", () => {
    const raw = mockMapInView(argsAround(BERLIN, { p_to: "2026-12-04T12:00:00.000Z" }));
    const v = decodeMapInView(raw);
    expect(v.cells.length).toBeGreaterThan(0);
    const cellIds = v.cells.flatMap((c) => c.events.map((e) => e.id));
    const pointIds = [...v.plans, ...v.shows, ...v.places].map((f) => f.id);
    expect(cellIds.every((id) => id.startsWith("mock-private-"))).toBe(true);
    expect(pointIds.some((id) => id.startsWith("mock-private-"))).toBe(false);
    for (const c of v.cells) {
      expect(Math.round(c.center.lng * 10) / 10).toBeCloseTo(c.center.lng, 9);
      expect(Math.round(c.center.lat * 10) / 10).toBeCloseTo(c.center.lat, 9);
    }
  });

  it("respects the time window", () => {
    const today = decodeMapInView(
      mockMapInView(argsAround(BERLIN, { p_to: "2026-11-04T20:00:00.000Z" })),
    );
    const month = decodeMapInView(
      mockMapInView(argsAround(BERLIN, { p_to: "2026-12-04T12:00:00.000Z" })),
    );
    expect(today.plans.length).toBeLessThan(month.plans.length);
    const toMs = Date.parse("2026-11-04T20:00:00.000Z");
    expect(today.plans.every((p) => p.startsAt!.getTime() <= toMs)).toBe(true);
  });

  it("filters layers server-side like the RPC", () => {
    const v = decodeMapInView(mockMapInView(argsAround(BERLIN, { p_layers: ["shows"] })));
    expect(v.places).toEqual([]);
    expect(v.plans).toEqual([]);
    expect(v.cells).toEqual([]);
    expect(v.shows.length).toBeGreaterThan(0);
  });

  it("says zoom_in for a large bbox but still sends plans", () => {
    const raw = mockMapInView({
      ...argsAround(BERLIN),
      p_west: -180,
      p_east: 180,
      p_south: -85,
      p_north: 85,
    });
    expect(raw.zoom_in).toBe(true);
    expect(raw.places).toEqual([]);
    expect((raw.plans ?? []).length).toBeGreaterThan(0);
  });

  it("marks an area with no data as still being mapped", () => {
    const raw = mockMapInView(argsAround({ lng: -150, lat: 60 }));
    expect(raw.mapping).toBe(true);
    expect(mockMapInView(argsAround(BERLIN)).mapping).toBe(false);
  });

  it("handles a bbox across the antimeridian", () => {
    const suva = MOCK_CITIES.find((c) => c.slug === "suva")!;
    const raw = mockMapInView({
      ...argsAround(suva),
      p_west: 179.6,
      p_east: -179.6,
    });
    const v = decodeMapInView(raw);
    expect(v.places.length).toBeGreaterThan(0);
    expect(v.places.some((p) => p.lng < 0)).toBe(true);
    expect(v.places.some((p) => p.lng > 0)).toBe(true);
  });

  it("returns a decodable detail for every place it lists", () => {
    const v = decodeMapInView(
      mockMapInView(argsAround(BERLIN, { p_hub_ids: ["hub-a"], p_generic: true })),
    );
    for (const p of v.places) {
      const d = decodePlaceDetail(mockPlaceDetail(p.id));
      expect(d?.id).toBe(p.id);
      expect(d?.name).toBe(p.name);
      expect(d?.lng).toBe(p.lng);
      expect(d?.generic).toBe((p.flags & FLAG.GENERIC) !== 0);
    }
    expect(mockPlaceDetail("nope")).toBeNull();
    expect(mockPlaceDetail("mock:place:berlin:hub-a:99")).toBeNull();
  });

  it("flags Geoapify and pending places consistently with their detail", () => {
    const places = MOCK_CITIES.flatMap(
      (city) =>
        decodeMapInView(mockMapInView(argsAround(city, { p_hub_ids: ["hub-a", "hub-b", "hub-c"] })))
          .places,
    );
    const geo = places.filter((p) => p.geoapify);
    const pending = places.filter((p) => p.pending);
    expect(geo.length).toBeGreaterThan(0);
    expect(pending.length).toBeGreaterThan(0);
    for (const p of geo) expect(decodePlaceDetail(mockPlaceDetail(p.id))?.source).toBe("geoapify");
    for (const p of pending) {
      const d = decodePlaceDetail(mockPlaceDetail(p.id));
      expect(d?.source).toBe("user");
      expect(d?.reviewed).toBe(false);
    }
    for (const p of places.filter((x) => !x.geoapify)) {
      expect(decodePlaceDetail(mockPlaceDetail(p.id))?.source).not.toBe("geoapify");
    }
  });

  it("works through the adapter", async () => {
    const adapter = await getMapAdapter();
    const v = decodeMapInView(await adapter.mapInView(argsAround(BERLIN)));
    expect(v.places.length).toBeGreaterThan(0);
  });
});
