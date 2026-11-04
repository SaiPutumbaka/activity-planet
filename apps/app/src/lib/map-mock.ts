import {
  FLAG,
  MAP_LAYERS,
  bboxContains,
  bboxTooLargeForPlaces,
  cellCenter,
  type BBox,
  type CellPayload,
  type FeatureTuple,
  type MapAdapter,
  type MapInViewArgs,
  type MapInViewPayload,
  type PlacesInViewArgs,
} from "./map";

/**
 * Deterministic fixtures for the §5 map RPCs, used when VITE_MAP_MOCK=true and in every test.
 * The same arguments always give the same payload (no Math.random, no clock other than the
 * `p_from` / `p_to` window passed in). Places are generated per requested hub around a handful of
 * cities on several continents, so whatever hubs the viewer joined, the map has something to show.
 * The payload follows the real contract exactly, compact tuples and all, so the decoder is
 * exercised end to end.
 *
 * TODO(map-rpc): delete this file's use outside tests once slice 6 ships (see lib/map.ts).
 */

export interface MockCity {
  slug: string;
  name: string;
  lng: number;
  lat: number;
}

export const MOCK_CITIES: readonly MockCity[] = [
  { slug: "lagos", name: "Lagos", lng: 3.3792, lat: 6.5244 },
  { slug: "sao-paulo", name: "São Paulo", lng: -46.6333, lat: -23.5505 },
  { slug: "berlin", name: "Berlin", lng: 13.405, lat: 52.52 },
  { slug: "tokyo", name: "Tokyo", lng: 139.6917, lat: 35.6895 },
  { slug: "toronto", name: "Toronto", lng: -79.3832, lat: 43.6532 },
  { slug: "mumbai", name: "Mumbai", lng: 72.8777, lat: 19.076 },
  { slug: "sydney", name: "Sydney", lng: 151.2093, lat: -33.8688 },
  { slug: "atlanta", name: "Atlanta", lng: -84.388, lat: 33.749 },
  // Straddles the antimeridian, to exercise the split.
  { slug: "suva", name: "Suva", lng: 179.99, lat: -18.1416 },
];

const NEIGHBOURHOODS = [
  "Riverside",
  "Old Town",
  "Northgate",
  "Harbour",
  "Hillcrest",
  "Market Street",
  "Eastside",
  "Westfield",
  "Central",
  "Lakeview",
];

const SPECIFIC_KINDS = [
  "basketball_court",
  "pitch",
  "comic_store",
  "meeting_spot",
  "gym",
  "studio",
  "game_store",
  "music_venue",
  "trailhead",
  "swimming_pool",
  "community_centre",
  "tennis_court",
];
const GENERIC_KINDS = ["cafe", "park", "library"];
const KIND_LABEL: Record<string, string> = {
  basketball_court: "Courts",
  pitch: "Fields",
  comic_store: "Comics",
  meeting_spot: "Club Room",
  gym: "Gym",
  studio: "Studio",
  game_store: "Games",
  music_venue: "Music Hall",
  trailhead: "Trailhead",
  swimming_pool: "Pool",
  community_centre: "Community Centre",
  tennis_court: "Tennis",
  cafe: "Café",
  park: "Park",
  library: "Library",
};
const PLAN_TITLES = [
  "Pickup game",
  "Sunday meetup",
  "Beginners' night",
  "Morning run",
  "Board game evening",
  "Open session",
  "Sketch walk",
  "Watch party",
];
const SHOW_TITLES = ["Cup final", "Live: The Comets", "Comedy night", "League match"];
/** Hours after `p_from` at which mock plans start; spread over a month. */
const START_OFFSETS_H = [1, 3, 6, 20, 30, 52, 75, 100, 140, 210, 330, 520, 690];

export const MOCK_LIMITS = { places: 800, happenings: 300, hubs: 50 } as const;
export const PLACES_PER_HUB_PER_CITY = 6;
export const GENERIC_PER_CITY = 9;

/** FNV-1a, 32-bit. */
export function hashString(s: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

/** mulberry32: a small seeded PRNG, so fixtures are stable across runs and machines. */
export function seeded(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function round6(v: number): number {
  return Math.round(v * 1e6) / 1e6;
}

/** A point within about `spread` degrees of the city, wrapped back into [-180, 180]. */
function near(city: MockCity, rand: () => number, spread = 0.09): [number, number] {
  let lng = city.lng + (rand() * 2 - 1) * spread;
  if (lng > 180) lng -= 360;
  if (lng < -180) lng += 360;
  const lat = city.lat + (rand() * 2 - 1) * spread * 0.8;
  return [round6(lng), round6(lat)];
}

interface MockPlace {
  tuple: FeatureTuple;
  city: MockCity;
}

/**
 * Where a mock place's data came from, from its id: most are OpenStreetMap, some member-added and
 * some through Geoapify (so the "Powered by Geoapify" credit shows). Every fourth member-added
 * place stands in for the viewer's own place still waiting for review (§7.3).
 */
function mockSource(id: string): { source: "osm" | "user" | "geoapify"; pending: boolean } {
  const seed = hashString(id);
  if (seed % 5 === 0) return { source: "user", pending: seed % 4 === 0 };
  return { source: seed % 7 === 0 ? "geoapify" : "osm", pending: false };
}

function sourceFlags(id: string): number {
  const m = mockSource(id);
  return (m.source === "geoapify" ? FLAG.GEOAPIFY : 0) | (m.pending ? FLAG.PENDING : 0);
}

function hubPlaces(city: MockCity, hubId: string): MockPlace[] {
  const rand = seeded(hashString(`${city.slug}|${hubId}`));
  const h = hashString(hubId);
  const kinds = [
    SPECIFIC_KINDS[h % SPECIFIC_KINDS.length]!,
    SPECIFIC_KINDS[(h >>> 8) % SPECIFIC_KINDS.length]!,
  ];
  return Array.from({ length: PLACES_PER_HUB_PER_CITY }, (_, i) => {
    const kind = kinds[i % kinds.length]!;
    const [lng, lat] = near(city, rand);
    const hood = NEIGHBOURHOODS[Math.floor(rand() * NEIGHBOURHOODS.length)]!;
    const id = `mock:place:${city.slug}:${hubId}:${i}`;
    return {
      city,
      tuple: [id, lng, lat, kind, hubId, sourceFlags(id), `${hood} ${KIND_LABEL[kind] ?? "Spot"}`],
    };
  });
}

function genericPlaces(city: MockCity, hubId: string): MockPlace[] {
  const rand = seeded(hashString(`${city.slug}|generic|${hubId}`));
  return Array.from({ length: GENERIC_PER_CITY }, (_, i) => {
    const kind = GENERIC_KINDS[i % GENERIC_KINDS.length]!;
    const [lng, lat] = near(city, rand, 0.11);
    const hood = NEIGHBOURHOODS[Math.floor(rand() * NEIGHBOURHOODS.length)]!;
    return {
      city,
      tuple: [
        `mock:place:${city.slug}:generic~${hubId}:${i}`,
        lng,
        lat,
        kind,
        hubId,
        FLAG.GENERIC,
        `${hood} ${KIND_LABEL[kind]}`,
      ],
    };
  });
}

function startsAt(fromMs: number, i: number): number {
  return Math.floor(fromMs / 1000) + START_OFFSETS_H[i % START_OFFSETS_H.length]! * 3600;
}

function inWindow(epochS: number, fromMs: number, toMs: number): boolean {
  return epochS * 1000 >= fromMs && epochS * 1000 <= toMs;
}

function cityPlans(city: MockCity, hubIds: readonly string[], fromMs: number, toMs: number) {
  const rand = seeded(hashString(`${city.slug}|plans`));
  const plans: FeatureTuple[] = [];
  const shows: FeatureTuple[] = [];
  const cells: CellPayload[] = [];
  // Hub-tagged plans for the requested hubs, then public plans from other hubs nearby.
  const hubsForPlans = [...hubIds.slice(0, 4), "mock-hub-open-1", "mock-hub-open-2"];
  for (let i = 0; i < 10; i++) {
    const [lng, lat] = near(city, rand, 0.08);
    const s = startsAt(fromMs, i);
    const hub = hubsForPlans[i % hubsForPlans.length]!;
    const imported = i % 4 === 3;
    if (!inWindow(s, fromMs, toMs)) continue;
    plans.push([
      `mock-plan-${city.slug}-${i}`,
      lng,
      lat,
      imported ? "imported" : "member",
      hub,
      (imported ? FLAG.IMPORTED : 0) | (i % 3 === 0 ? FLAG.FREE : 0),
      `${PLAN_TITLES[i % PLAN_TITLES.length]} · ${NEIGHBOURHOODS[i % NEIGHBOURHOODS.length]}`,
      s,
    ]);
  }
  for (let i = 0; i < SHOW_TITLES.length; i++) {
    const [lng, lat] = near(city, rand, 0.06);
    const s = startsAt(fromMs, i * 3 + 2);
    if (!inWindow(s, fromMs, toMs)) continue;
    shows.push([`mock-show-${city.slug}-${i}`, lng, lat, "show", null, 0, SHOW_TITLES[i]!, s]);
  }
  // Approved-only events: only their 0.1-degree cell, never a point (D-038).
  for (let c = 0; c < 2; c++) {
    const [vLng, vLat] = near(city, rand, 0.12);
    const centre = cellCenter(vLng, vLat);
    const n = 1 + (hashString(`${city.slug}|cell|${c}`) % 3);
    const ids: string[] = [];
    const names: string[] = [];
    const starts: number[] = [];
    const hubs: (string | null)[] = [];
    for (let k = 0; k < n; k++) {
      const s = startsAt(fromMs, c * 4 + k + 1);
      if (!inWindow(s, fromMs, toMs)) continue;
      ids.push(`mock-private-${city.slug}-${c}-${k}`);
      names.push(`${PLAN_TITLES[(c + k + 2) % PLAN_TITLES.length]} at a member's spot`);
      starts.push(s);
      hubs.push(hubsForPlans[(c + k) % hubsForPlans.length] ?? null);
    }
    if (ids.length)
      cells.push({ cell: [centre.lng, centre.lat], n: ids.length, ids, names, starts, hubs });
  }
  return { plans, shows, cells };
}

function cityTouches(city: MockCity, bbox: BBox): boolean {
  // The city's fixtures sit within about 0.15 degrees of its centre.
  const m = 0.2;
  const probe = [
    { lng: city.lng, lat: city.lat },
    { lng: city.lng - m, lat: city.lat - m },
    { lng: city.lng + m, lat: city.lat + m },
    { lng: city.lng - m, lat: city.lat + m },
    { lng: city.lng + m, lat: city.lat - m },
  ].map((p) => ({
    lng: p.lng > 180 ? p.lng - 360 : p.lng < -180 ? p.lng + 360 : p.lng,
    lat: p.lat,
  }));
  return probe.some((p) => bboxContains(bbox, p));
}

function bboxOf(args: { p_west: number; p_south: number; p_east: number; p_north: number }): BBox {
  return { west: args.p_west, south: args.p_south, east: args.p_east, north: args.p_north };
}

function pointIn(bbox: BBox, t: FeatureTuple | CellPayload): boolean {
  const [lng, lat] = Array.isArray(t) ? [t[1], t[2]] : t.cell;
  return bboxContains(bbox, { lng, lat });
}

export function mockPlaces(args: PlacesInViewArgs): {
  places: FeatureTuple[];
  truncated: boolean;
  zoom_in: boolean;
} {
  const bbox = bboxOf(args);
  if (bboxTooLargeForPlaces(bbox)) return { places: [], truncated: false, zoom_in: true };
  const hubIds = [...new Set(args.p_hub_ids ?? [])];
  const capped = hubIds.slice(0, MOCK_LIMITS.hubs);
  const generic = args.p_generic && capped.length === 1;
  const out: FeatureTuple[] = [];
  for (const city of MOCK_CITIES) {
    if (!cityTouches(city, bbox)) continue;
    for (const hub of capped) out.push(...hubPlaces(city, hub).map((p) => p.tuple));
    if (generic) out.push(...genericPlaces(city, capped[0]!).map((p) => p.tuple));
  }
  const inView = out.filter((t) => pointIn(bbox, t));
  return {
    places: inView.slice(0, MOCK_LIMITS.places),
    truncated: hubIds.length > MOCK_LIMITS.hubs || inView.length > MOCK_LIMITS.places,
    zoom_in: false,
  };
}

export function mockMapInView(args: MapInViewArgs): MapInViewPayload {
  const bbox = bboxOf(args);
  const layers = new Set(args.p_layers?.length ? args.p_layers : MAP_LAYERS);
  const fromMs = Date.parse(args.p_from);
  const toMs = Math.min(Date.parse(args.p_to), fromMs + 31 * 86_400_000);
  const hubIds = [...new Set(args.p_hub_ids ?? [])];

  const placeResult = layers.has("places")
    ? mockPlaces(args)
    : { places: [], truncated: false, zoom_in: false };

  const plans: FeatureTuple[] = [];
  const shows: FeatureTuple[] = [];
  const cells: CellPayload[] = [];
  let touched = false;
  for (const city of MOCK_CITIES) {
    if (!cityTouches(city, bbox)) continue;
    touched = true;
    const c = cityPlans(city, hubIds, fromMs, toMs);
    plans.push(...c.plans.filter((t) => pointIn(bbox, t)));
    shows.push(...c.shows.filter((t) => pointIn(bbox, t)));
    cells.push(...c.cells.filter((t) => pointIn(bbox, t)));
  }

  return {
    places: placeResult.places,
    plans: layers.has("plans") ? plans.slice(0, MOCK_LIMITS.happenings) : [],
    shows: layers.has("shows") ? shows.slice(0, MOCK_LIMITS.happenings) : [],
    cells: layers.has("plans") ? cells : [],
    truncated: placeResult.truncated,
    zoom_in: placeResult.zoom_in,
    // An area with no fixtures stands in for a tile that is still being mapped (§9 empty state).
    mapping: !placeResult.zoom_in && !touched,
    events_only: [],
  };
}

/** Rebuilds a place from its id (`mock:place:<city>:<hub or generic~hub>:<i>`). */
export function mockPlaceDetail(id: string): Record<string, unknown> | null {
  const m = /^mock:place:([^:]+):([^:]+):(\d+)$/.exec(id);
  if (!m) return null;
  const [, citySlug, hubKey, idx] = m;
  const city = MOCK_CITIES.find((c) => c.slug === citySlug);
  if (!city) return null;
  const generic = hubKey!.startsWith("generic~");
  const hubId = generic ? hubKey!.slice("generic~".length) : hubKey!;
  const list = generic ? genericPlaces(city, hubId) : hubPlaces(city, hubId);
  const place = list[Number(idx)];
  if (!place) return null;
  const [pid, lng, lat, kind, hub, flags, name] = place.tuple;
  const seed = hashString(pid);
  const isGeneric = (flags & FLAG.GENERIC) !== 0;
  const origin = isGeneric ? { source: "osm" as const, pending: false } : mockSource(pid);
  const fromOsm = origin.source !== "user";
  return {
    id: pid,
    name,
    kind,
    lng,
    lat,
    hub_ids: hub ? [hub] : [],
    address: `${NEIGHBOURHOODS[seed % NEIGHBOURHOODS.length]} Road ${1 + (seed % 90)}, ${city.name}`,
    hours: seed % 3 === 0 ? null : seed % 3 === 1 ? "Mo-Fr 07:00-22:00; Sa-Su 09:00-20:00" : "24/7",
    website: seed % 2 === 0 ? `https://example.org/${city.slug}/${Number(idx) + 1}` : null,
    source: origin.source,
    osm_ref: fromOsm ? `node/${1_000_000 + (seed % 9_000_000)}` : null,
    checked_at: new Date(Date.UTC(2026, 9, 1 + (seed % 28))).toISOString(),
    reviewed: origin.source === "user" && !origin.pending,
    generic: isGeneric,
    adults_only: false,
    plans_here:
      seed % 2 === 0
        ? [
            {
              id: `mock-plan-${city.slug}-${seed % 10}`,
              title: PLAN_TITLES[seed % PLAN_TITLES.length],
              starts_at: null,
            },
          ]
        : [],
  };
}

const delay = (ms: number) =>
  import.meta.env.MODE === "test" ? Promise.resolve() : new Promise((r) => setTimeout(r, ms));

export const mockMapAdapter: MapAdapter = {
  async mapInView(args) {
    await delay(180);
    return mockMapInView(args);
  },
  async placesInView(args) {
    await delay(120);
    return mockPlaces(args);
  },
  async placeDetail(id) {
    await delay(120);
    return mockPlaceDetail(id);
  },
};
