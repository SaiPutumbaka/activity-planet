import {
  EVENT_FLAG,
  MAP_LAYERS,
  PLACE_FLAG,
  bboxContains,
  bboxTooLargeForPlaces,
  cellCenter,
  type BBox,
  type CellTuple,
  type EventTuple,
  type HubTuple,
  type MapAdapter,
  type MapInViewArgs,
  type MapInViewPayload,
  type PlaceTuple,
  type PlacesInViewArgs,
} from "./map";

/**
 * Deterministic fixtures in the exact encoding of `map_in_view`, `places_in_view` and
 * `place_detail` as built (migrations 29, 30 and 32; HUB_MAP_DESIGN §5), used only under Vitest
 * and when VITE_MAP_MOCK=true. The same arguments always give the same payload (no Math.random,
 * no clock other than the `p_from` / `p_to` window passed in). Places are generated per requested
 * hub around a handful of cities on several continents, so whatever hubs the viewer joined, the
 * map has something to show; signed out with no hubs (`p_hub_ids` null) stands in for every
 * specific hub. Hub references are indexes into `hubs`, plans and shows carry their hub, and
 * approved-only events are cells only, as on the server.
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

// Real place_kinds slugs (migration 27), so pins and labels match what staging returns.
const SPECIFIC_KINDS = [
  "court_field",
  "sports_centre",
  "game_store",
  "community",
  "gym",
  "arts_venue",
  "anime_store",
  "music_venue",
  "trail",
  "pool",
  "club",
  "dojo",
];
const GENERIC_KINDS = ["cafe", "park", "library"];
const KIND_LABEL: Record<string, string> = {
  court_field: "Courts",
  sports_centre: "Sports Centre",
  game_store: "Games",
  community: "Community Room",
  gym: "Gym",
  arts_venue: "Arts Centre",
  anime_store: "Anime",
  music_venue: "Music Hall",
  trail: "Trail",
  pool: "Pool",
  club: "Club Room",
  dojo: "Dojo",
  cafe: "Café",
  park: "Park",
  library: "Library",
};
const KIND_TITLE: Record<string, string> = {
  court_field: "Court or field",
  sports_centre: "Sports centre",
  game_store: "Game store",
  community: "Community space",
  gym: "Gym or studio",
  arts_venue: "Arts venue or museum",
  anime_store: "Anime store",
  music_venue: "Music venue",
  trail: "Trail or route",
  pool: "Pool or swim spot",
  club: "Club",
  dojo: "Dojo",
  cafe: "Café",
  park: "Park or garden",
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
/** Hubs the mock's public plans and shows belong to (the RPC lists them after the selected hubs). */
const OPEN_HUBS = ["mock-hub-open-1", "mock-hub-open-2", "mock-hub-shows"];
/** Signed out with no hubs: every specific hub, which the mock stands in for with one key. */
const ALL_KEY = "all";

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

function round5(v: number): number {
  return Math.round(v * 1e5) / 1e5;
}

/** A point within about `spread` degrees of the city, wrapped back into [-180, 180]. */
function near(city: MockCity, rand: () => number, spread = 0.09): [number, number] {
  let lng = city.lng + (rand() * 2 - 1) * spread;
  if (lng > 180) lng -= 360;
  if (lng < -180) lng += 360;
  const lat = city.lat + (rand() * 2 - 1) * spread * 0.8;
  return [round5(lng), round5(lat)];
}

/** A mock place before encoding: the hub key it belongs to, not yet an index. */
interface MockPlace {
  id: string;
  lng: number;
  lat: number;
  kind: string;
  hubKey: string;
  flags: number;
  name: string;
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
  if (m.source === "geoapify") return PLACE_FLAG.GEOAPIFY;
  if (m.source === "user") {
    return PLACE_FLAG.MEMBER | (m.pending ? PLACE_FLAG.PENDING | PLACE_FLAG.MINE : 0);
  }
  return 0;
}

function hubPlaces(city: MockCity, hubKey: string): MockPlace[] {
  const rand = seeded(hashString(`${city.slug}|${hubKey}`));
  const h = hashString(hubKey);
  const kinds = [
    SPECIFIC_KINDS[h % SPECIFIC_KINDS.length]!,
    SPECIFIC_KINDS[(h >>> 8) % SPECIFIC_KINDS.length]!,
  ];
  return Array.from({ length: PLACES_PER_HUB_PER_CITY }, (_, i) => {
    const kind = kinds[i % kinds.length]!;
    const [lng, lat] = near(city, rand);
    const hood = NEIGHBOURHOODS[Math.floor(rand() * NEIGHBOURHOODS.length)]!;
    const id = `mock:place:${city.slug}:${hubKey}:${i}`;
    return {
      id,
      lng,
      lat,
      kind,
      hubKey,
      flags: sourceFlags(id),
      name: `${hood} ${KIND_LABEL[kind] ?? "Spot"}`,
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
      id: `mock:place:${city.slug}:generic~${hubId}:${i}`,
      lng,
      lat,
      kind,
      hubKey: hubId,
      flags: PLACE_FLAG.GENERAL,
      name: `${hood} ${KIND_LABEL[kind]}`,
    };
  });
}

function startsAt(fromMs: number, i: number): number {
  return Math.floor(fromMs / 1000) + START_OFFSETS_H[i % START_OFFSETS_H.length]! * 3600;
}

function inWindow(epochS: number, fromMs: number, toMs: number): boolean {
  return epochS * 1000 >= fromMs && epochS * 1000 <= toMs;
}

interface MockEvent {
  id: string;
  lng: number;
  lat: number;
  kind: string;
  hubId: string;
  flags: number;
  title: string;
  starts: number;
}

interface MockCellEvent {
  id: string;
  hubId: string;
  title: string;
  starts: number;
}

function cityPlans(city: MockCity, hubIds: readonly string[], fromMs: number, toMs: number) {
  const rand = seeded(hashString(`${city.slug}|plans`));
  const plans: MockEvent[] = [];
  const shows: MockEvent[] = [];
  const cells: { lng: number; lat: number; events: MockCellEvent[] }[] = [];
  // Plans for the requested hubs, then public plans from other hubs nearby (the RPC sends every
  // published plan in view, the selected hubs' first).
  const hubsForPlans = [...hubIds.slice(0, 4), OPEN_HUBS[0]!, OPEN_HUBS[1]!];
  for (let i = 0; i < 10; i++) {
    const [lng, lat] = near(city, rand, 0.08);
    const s = startsAt(fromMs, i);
    const hub = hubsForPlans[i % hubsForPlans.length]!;
    const imported = i % 4 === 3;
    if (!inWindow(s, fromMs, toMs)) continue;
    plans.push({
      id: `mock-plan-${city.slug}-${i}`,
      lng,
      lat,
      kind: imported ? "imported" : "member",
      hubId: hub,
      flags:
        (imported ? EVENT_FLAG.IMPORTED : 0) |
        (i % 3 === 0 ? EVENT_FLAG.FREE : 0) |
        (hubIds.includes(hub) ? EVENT_FLAG.SELECTED_HUB : 0),
      title: `${PLAN_TITLES[i % PLAN_TITLES.length]} · ${NEIGHBOURHOODS[i % NEIGHBOURHOODS.length]}`,
      starts: s,
    });
  }
  for (let i = 0; i < SHOW_TITLES.length; i++) {
    const [lng, lat] = near(city, rand, 0.06);
    const s = startsAt(fromMs, i * 3 + 2);
    if (!inWindow(s, fromMs, toMs)) continue;
    shows.push({
      id: `mock-show-${city.slug}-${i}`,
      lng,
      lat,
      kind: "imported",
      hubId: OPEN_HUBS[2]!,
      flags: EVENT_FLAG.IMPORTED,
      title: SHOW_TITLES[i]!,
      starts: s,
    });
  }
  // Approved-only events: only their 0.1-degree cell, never a point (D-038).
  for (let c = 0; c < 2; c++) {
    const [vLng, vLat] = near(city, rand, 0.12);
    const centre = cellCenter(vLng, vLat);
    const n = 1 + (hashString(`${city.slug}|cell|${c}`) % 3);
    const events: MockCellEvent[] = [];
    for (let k = 0; k < n; k++) {
      const s = startsAt(fromMs, c * 4 + k + 1);
      if (!inWindow(s, fromMs, toMs)) continue;
      events.push({
        id: `mock-private-${city.slug}-${c}-${k}`,
        hubId: hubsForPlans[(c + k) % hubsForPlans.length]!,
        title: `${PLAN_TITLES[(c + k + 2) % PLAN_TITLES.length]} at a member's spot`,
        starts: s,
      });
    }
    if (events.length) cells.push({ lng: centre.lng, lat: centre.lat, events });
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

function inBox(bbox: BBox, p: { lng: number; lat: number }): boolean {
  return bboxContains(bbox, p);
}

/** The hub list the RPC answers with, and an index lookup that appends hubs as events need them. */
function hubTable(selected: readonly string[], generic: boolean) {
  const hubs: HubTuple[] = selected.map((id) => [
    id,
    id,
    `Hub ${id}`,
    "",
    generic ? "generic" : "specific",
  ]);
  const index = new Map(selected.map((id, i) => [id, i]));
  return {
    hubs,
    selected: (id: string) => index.get(id) ?? null,
    any(id: string): number {
      let i = index.get(id);
      if (i === undefined) {
        i = hubs.length;
        hubs.push([id, id, `Hub ${id}`, "", "specific"]);
        index.set(id, i);
      }
      return i;
    },
  };
}

function selectedHubs(ids: readonly string[] | null): {
  all: boolean;
  ids: string[];
  cut: boolean;
} {
  if (ids === null) return { all: true, ids: [], cut: false };
  const unique = [...new Set(ids)];
  return {
    all: false,
    ids: unique.slice(0, MOCK_LIMITS.hubs),
    cut: unique.length > MOCK_LIMITS.hubs,
  };
}

/** `places_in_view` as built: `[id, lng, lat, kind, hub_idx, flags, name, hub_idxs]`. */
export function mockPlaces(args: PlacesInViewArgs): MapInViewPayload {
  const bbox = bboxOf(args);
  const sel = selectedHubs(args.p_hub_ids);
  const generic = Boolean(args.p_generic) && sel.ids.length === 1;
  const table = hubTable(sel.ids, generic);
  const base = { v: 1, hubs: table.hubs, no_hubs: !sel.all && sel.ids.length === 0 };
  if (bboxTooLargeForPlaces(bbox)) {
    return { ...base, places: null, zoom_in: true, truncated: sel.cut, generic: false };
  }
  const raw: MockPlace[] = [];
  for (const city of MOCK_CITIES) {
    if (!cityTouches(city, bbox)) continue;
    if (sel.all) raw.push(...hubPlaces(city, ALL_KEY));
    // A generic hub has no specific rules: only its general spots.
    else if (generic) raw.push(...genericPlaces(city, sel.ids[0]!));
    else for (const hub of sel.ids) raw.push(...hubPlaces(city, hub));
  }
  const inView = raw.filter((p) => inBox(bbox, p));
  const places: PlaceTuple[] = inView.slice(0, MOCK_LIMITS.places).map((p) => {
    const idx = sel.all ? null : table.selected(p.hubKey);
    return [p.id, p.lng, p.lat, p.kind, idx, p.flags, p.name, idx === null ? [] : [idx]];
  });
  return {
    ...base,
    places,
    zoom_in: false,
    truncated: sel.cut || inView.length > MOCK_LIMITS.places,
    generic,
  };
}

/** `map_in_view` as built (migration 32), from the same fixtures. */
export function mockMapInView(args: MapInViewArgs): MapInViewPayload {
  const bbox = bboxOf(args);
  const layers = new Set(args.p_layers?.length ? args.p_layers : MAP_LAYERS);
  const fromMs = Date.parse(args.p_from);
  const toMs = Math.min(Date.parse(args.p_to), fromMs + 31 * 86_400_000);
  const sel = selectedHubs(args.p_hub_ids);
  const pl = layers.has("places") ? mockPlaces(args) : null;
  const generic = Boolean(args.p_generic) && sel.ids.length === 1 && pl !== null;
  const table = hubTable(sel.ids, generic);

  const plans: EventTuple[] = [];
  const shows: EventTuple[] = [];
  const cells: CellTuple[] = [];
  let touched = false;
  const enc = (e: MockEvent): EventTuple => [
    e.id,
    e.lng,
    e.lat,
    e.kind,
    table.any(e.hubId),
    e.flags,
    e.title,
    e.starts,
  ];
  for (const city of MOCK_CITIES) {
    if (!cityTouches(city, bbox)) continue;
    touched = true;
    const c = cityPlans(city, sel.ids, fromMs, toMs);
    if (layers.has("plans")) {
      plans.push(...c.plans.filter((e) => inBox(bbox, e)).map(enc));
      for (const cell of c.cells.filter((x) => inBox(bbox, x))) {
        const ev = cell.events;
        cells.push([
          cell.lng,
          cell.lat,
          ev.length,
          ev.map((e) => e.id),
          ev.map((e) => table.any(e.hubId)),
          ev.map((e) => e.title),
          ev.map((e) => e.starts),
        ]);
      }
    }
    if (layers.has("shows")) shows.push(...c.shows.filter((e) => inBox(bbox, e)).map(enc));
  }

  const zoomIn = pl?.zoom_in === true;
  return {
    v: 1,
    places: pl ? (pl.places ?? null) : null,
    plans: layers.has("plans") ? plans.slice(0, MOCK_LIMITS.happenings) : null,
    shows: layers.has("shows") ? shows.slice(0, MOCK_LIMITS.happenings) : null,
    cells,
    hubs: table.hubs,
    truncated: (pl?.truncated ?? sel.cut) || plans.length > MOCK_LIMITS.happenings,
    zoom_in: zoomIn,
    no_hubs: !sel.all && sel.ids.length === 0,
    generic: pl?.generic === true,
    // An area with no fixtures stands in for a tile that is still being mapped (§9 empty state).
    mapping: pl !== null && !zoomIn && !touched,
  };
}

/** Rebuilds a place's `place_detail` from its id (`mock:place:<city>:<hub or generic~hub>:<i>`). */
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
  const seed = hashString(place.id);
  const origin = generic ? { source: "osm" as const, pending: false } : mockSource(place.id);
  const fromOsm = origin.source !== "user";
  return {
    v: 1,
    id: place.id,
    name: place.name,
    kind: place.kind,
    kind_label: KIND_TITLE[place.kind] ?? "Spot",
    kind_icon: "map-pin",
    lng: place.lng,
    lat: place.lat,
    address_text: `${NEIGHBOURHOODS[seed % NEIGHBOURHOODS.length]} Road ${1 + (seed % 90)}, ${city.name}`,
    locality: city.name,
    country: null,
    opening_hours:
      seed % 3 === 0 ? null : seed % 3 === 1 ? "Mo-Fr 07:00-22:00; Sa-Su 09:00-20:00" : "24/7",
    website: seed % 2 === 0 ? `https://example.org/${city.slug}/${Number(idx) + 1}` : null,
    tags: {},
    source: origin.source,
    status: origin.pending ? "pending" : "active",
    is_public: true,
    mine: origin.pending,
    attribution: fromOsm ? "© OpenStreetMap contributors" : null,
    license: fromOsm ? "ODbL-1.0" : null,
    checked_at: fromOsm ? new Date(Date.UTC(2026, 9, 1 + (seed % 28))).toISOString() : null,
    osm_url:
      origin.source === "osm"
        ? `https://www.openstreetmap.org/node/${1_000_000 + (seed % 9_000_000)}`
        : null,
    hubs:
      hubId === ALL_KEY
        ? []
        : [
            {
              id: hubId,
              slug: hubId,
              name: `Hub ${hubId}`,
              emoji: "",
              general: generic,
              joined: false,
            },
          ],
    more_hubs: false,
    plans_here:
      seed % 2 === 0
        ? [
            {
              id: `mock-plan-${city.slug}-${seed % 10}`,
              title: PLAN_TITLES[seed % PLAN_TITLES.length],
              starts_at: null,
              ends_at: null,
              timezone: "UTC",
              hub_id: hubId === ALL_KEY ? OPEN_HUBS[0] : hubId,
              hub_slug: hubId,
              kind: "member",
              listing_kind: "plan",
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
