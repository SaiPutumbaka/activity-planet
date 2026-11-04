/**
 * Hub map view decoding (D-041, design sections 5 and 9). `map_in_view` and `places_in_view`
 * return compact arrays to keep a 1,000-feature view small; these helpers turn them into objects
 * and snap a viewport outward to the 0.05-degree grid the design asks for, so nearby views share
 * one cached request.
 *
 *   snapBbox({ west: -84.43, south: 33.71, east: -84.31, north: 33.82 })
 *                       // { west: -84.45, south: 33.7, east: -84.3, north: 33.85 }
 *   decodeMapView(data) // { places: [{ id, lng, lat, kind, hubIds, general, ... }], plans, ... }
 */

export interface Bbox {
  west: number;
  south: number;
  east: number;
  north: number;
}

/** Place flags (bit values) as the server sets them. */
export const PLACE_FLAGS = {
  general: 1,
  pending: 2,
  private: 4,
  member: 8,
  meetingSpot: 16,
  geoapify: 32,
  mine: 64,
} as const;

/** Plan and show flags (bit values). */
export const EVENT_FLAGS = { imported: 1, selectedHub: 2, free: 4, adultsOnly21: 8 } as const;

/** The server's largest view that still returns places (degrees). */
export const MAP_PLACES_MAX_SPAN = { lat: 1.0, lng: 1.5 } as const;

export interface MapHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  placeMode: "specific" | "generic" | "none";
}

export interface MapPlace {
  id: string;
  lng: number;
  lat: number;
  kind: string;
  /** First matching hub id, or null when the view is "every specific hub" (signed out). */
  hubId: string | null;
  /** Every selected hub this place matches, for chip filtering on the client. */
  hubIds: string[];
  name: string;
  general: boolean;
  pending: boolean;
  private: boolean;
  member: boolean;
  meetingSpot: boolean;
  geoapify: boolean;
  mine: boolean;
}

export interface MapEvent {
  id: string;
  lng: number;
  lat: number;
  kind: string;
  hubId: string | null;
  title: string;
  startsAt: Date;
  imported: boolean;
  inSelectedHub: boolean;
  free: boolean;
  adultsOnly21: boolean;
}

/** Approved-only events: a count in a 0.1-degree cell, never a point. */
export interface MapCell {
  lng: number;
  lat: number;
  count: number;
  /** Title and start arrived with migration 32 (empty and null before). */
  events: { id: string; hubId: string | null; title: string; startsAt: Date | null }[];
}

export interface MapView {
  places: MapPlace[] | null;
  plans: MapEvent[] | null;
  shows: MapEvent[] | null;
  cells: MapCell[];
  hubs: MapHub[];
  zoomIn: boolean;
  truncated: boolean;
  noHubs: boolean;
  generic: boolean;
  /** Migration 32: a place tile in view is still being mapped. */
  mapping: boolean;
}

type Raw = Record<string, unknown>;

function asArray(v: unknown): unknown[] {
  return Array.isArray(v) ? v : [];
}

function hubAt(hubs: MapHub[], idx: unknown): string | null {
  return typeof idx === "number" ? (hubs[idx]?.id ?? null) : null;
}

function decodeEvent(row: unknown, hubs: MapHub[]): MapEvent {
  const r = asArray(row);
  const flags = Number(r[5] ?? 0);
  return {
    id: String(r[0]),
    lng: Number(r[1]),
    lat: Number(r[2]),
    kind: String(r[3]),
    hubId: hubAt(hubs, r[4]),
    title: String(r[6] ?? ""),
    startsAt: new Date(Number(r[7]) * 1000),
    imported: (flags & EVENT_FLAGS.imported) !== 0,
    inSelectedHub: (flags & EVENT_FLAGS.selectedHub) !== 0,
    free: (flags & EVENT_FLAGS.free) !== 0,
    adultsOnly21: (flags & EVENT_FLAGS.adultsOnly21) !== 0,
  };
}

/** Decodes the jsonb of map_in_view (or places_in_view, which has only places and hubs). */
export function decodeMapView(data: unknown): MapView {
  const d = (data ?? {}) as Raw;
  const hubs: MapHub[] = asArray(d.hubs).map((row) => {
    const r = asArray(row);
    return {
      id: String(r[0]),
      slug: String(r[1]),
      name: String(r[2]),
      emoji: String(r[3] ?? ""),
      placeMode: (r[4] as MapHub["placeMode"]) ?? "specific",
    };
  });
  const places = Array.isArray(d.places)
    ? d.places.map((row): MapPlace => {
        const r = asArray(row);
        const flags = Number(r[5] ?? 0);
        return {
          id: String(r[0]),
          lng: Number(r[1]),
          lat: Number(r[2]),
          kind: String(r[3]),
          hubId: hubAt(hubs, r[4]),
          hubIds: asArray(r[7])
            .map((i) => hubAt(hubs, i))
            .filter((h): h is string => h !== null),
          name: String(r[6] ?? ""),
          general: (flags & PLACE_FLAGS.general) !== 0,
          pending: (flags & PLACE_FLAGS.pending) !== 0,
          private: (flags & PLACE_FLAGS.private) !== 0,
          member: (flags & PLACE_FLAGS.member) !== 0,
          meetingSpot: (flags & PLACE_FLAGS.meetingSpot) !== 0,
          geoapify: (flags & PLACE_FLAGS.geoapify) !== 0,
          mine: (flags & PLACE_FLAGS.mine) !== 0,
        };
      })
    : null;
  const cells = asArray(d.cells).map((row): MapCell => {
    const r = asArray(row);
    const hubIdx = asArray(r[4]);
    const titles = asArray(r[5]);
    const starts = asArray(r[6]);
    return {
      lng: Number(r[0]),
      lat: Number(r[1]),
      count: Number(r[2]),
      events: asArray(r[3]).map((id, i) => ({
        id: String(id),
        hubId: hubAt(hubs, hubIdx[i]),
        title: String(titles[i] ?? ""),
        startsAt: typeof starts[i] === "number" ? new Date((starts[i] as number) * 1000) : null,
      })),
    };
  });
  return {
    places,
    plans: Array.isArray(d.plans) ? d.plans.map((r) => decodeEvent(r, hubs)) : null,
    shows: Array.isArray(d.shows) ? d.shows.map((r) => decodeEvent(r, hubs)) : null,
    cells,
    hubs,
    zoomIn: d.zoom_in === true,
    truncated: d.truncated === true,
    noHubs: d.no_hubs === true,
    generic: d.generic === true,
    mapping: d.mapping === true,
  };
}

const GRID = 0.05;

function snapDown(v: number): number {
  return Math.round(Math.floor(v / GRID + 1e-9) * GRID * 100) / 100;
}

function snapUp(v: number): number {
  return Math.round(Math.ceil(v / GRID - 1e-9) * GRID * 100) / 100;
}

/**
 * Snaps a viewport outward to the 0.05-degree grid (design 9: one request per settled view).
 * Latitude is clamped to [-90, 90]; longitude is wrapped to [-180, 180], and a view that
 * crosses the antimeridian keeps west > east, which the server splits in two.
 */
export function snapBbox(b: Bbox): Bbox {
  const wrap = (x: number) => ((((x + 180) % 360) + 360) % 360) - 180;
  const span = b.east - b.west;
  if (span >= 360)
    return {
      west: -180,
      south: snapClampLat(b.south, false),
      east: 180,
      north: snapClampLat(b.north, true),
    };
  let west = snapDown(wrap(b.west));
  let east = snapUp(wrap(b.east));
  if (east === -180) east = 180;
  if (west === 180) west = -180;
  return { west, south: snapClampLat(b.south, false), east, north: snapClampLat(b.north, true) };
}

function snapClampLat(v: number, up: boolean): number {
  return Math.max(-90, Math.min(90, up ? snapUp(v) : snapDown(v)));
}

/** True when the server will answer zoom_in for places at this bbox. */
export function bboxNeedsZoomIn(b: Bbox): boolean {
  const lngSpan = b.west < b.east ? b.east - b.west : 180 - b.west + (b.east + 180);
  return b.north - b.south > MAP_PLACES_MAX_SPAN.lat || lngSpan > MAP_PLACES_MAX_SPAN.lng;
}
