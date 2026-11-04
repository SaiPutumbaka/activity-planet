import { keepPreviousData, queryOptions } from "@tanstack/react-query";

/**
 * Hub map client (HUB_MAP_DESIGN §5, §7, §9; D-038). Everything the Map tab needs that is not a
 * component: the typed contract of `map_in_view`, `places_in_view` and `place_detail`, the
 * decoder for their compact encoding, bbox snapping, the 0.1-degree cell geometry for
 * approved-only events, the hub-chip rules (generic spots only with exactly one hub chip), the
 * time windows, distance sorting and the directions hand-off.
 *
 * TODO(map-rpc): slice 6 adds the three RPCs. Until then a build without VITE_MAP_MOCK=true gets
 * `MapUnavailableError` from the real adapter (PostgREST answers "function not found") and the Map
 * tab shows a friendly "coming soon" state. Once the RPCs land on staging: regenerate
 * packages/core/src/types/database.ts, type `rpcMapAdapter` (lib/map-rpc.ts) against it, check the
 * argument names below match the migration, and drop VITE_MAP_MOCK from preview envs.
 *
 * Privacy (§7): nothing here logs a bbox or a user id. Approved-only events only ever arrive as
 * cells and are drawn as shaded squares, never as points. Sensitive-hub chips filter on the client
 * from the "All my hubs" response, so the server never learns which sensitive chip was tapped.
 */

/* ------------------------------------------------------------------ */
/* Contract                                                             */
/* ------------------------------------------------------------------ */

export type MapLayer = "places" | "plans" | "shows";
export const MAP_LAYERS: readonly MapLayer[] = ["places", "plans", "shows"];
export const LAYER_LABELS: Record<MapLayer, string> = {
  places: "Places",
  plans: "Plans",
  shows: "Shows and games",
};

export type MapWhen = "today" | "week" | "month";
export const WHEN_OPTIONS: readonly { value: MapWhen; label: string }[] = [
  { value: "today", label: "Today" },
  { value: "week", label: "This week" },
  { value: "month", label: "30 days" },
];

export interface BBox {
  west: number;
  south: number;
  east: number;
  north: number;
}

export interface LngLat {
  lng: number;
  lat: number;
}

/**
 * Arguments of `map_in_view` (§5). Repo convention prefixes RPC arguments with `p_`; the design
 * table lists them without. `p_hub_ids` null means "the viewer's joined hubs" server-side, but this
 * client always sends the list explicitly so explored hubs are included and anon works the same.
 */
export interface MapInViewArgs {
  p_west: number;
  p_south: number;
  p_east: number;
  p_north: number;
  p_hub_ids: string[] | null;
  p_layers: MapLayer[];
  p_from: string;
  p_to: string;
  p_generic: boolean;
}

export type PlacesInViewArgs = Omit<MapInViewArgs, "p_layers" | "p_from" | "p_to">;

/**
 * One feature, an array and not an object (§5: about 60 KB gzip per 1,000 features):
 *   [id, lng, lat, kind_or_type, hub_id_primary, flags, name?, starts_at_epoch_s?]
 * Positions 0 to 5 are the §5 contract. Positions 6 and 7 are this client's proposed amendment for
 * slice 6: the list panel (the accessible alternative to the canvas) needs a name per row and a
 * start time per plan, and a second request per row would break the one-request-per-view budget.
 * The decoder tolerates their absence.
 */
export type FeatureTuple = [
  id: string,
  lng: number,
  lat: number,
  kind: string,
  hubId: string | null,
  flags: number,
  name?: string,
  startsAt?: number,
];

/**
 * Approved-only events in one 0.1-degree cell (D-038). `cell` is the cell centre, [lng, lat], the
 * same rounding as the stored `approx_point`. `names`, `starts` and `hubs` run parallel to `ids`
 * (same amendment as FeatureTuple); they never carry a point.
 */
export interface CellPayload {
  cell: [number, number];
  n: number;
  ids: string[];
  names?: string[];
  starts?: number[];
  hubs?: (string | null)[];
}

export interface MapInViewPayload {
  places?: FeatureTuple[];
  plans?: FeatureTuple[];
  shows?: FeatureTuple[];
  cells?: CellPayload[];
  /** More than 50 hubs or more than 800 places: the result is a sample. */
  truncated?: boolean;
  /** The bbox is larger than 1.0 lat x 1.5 lng: places are left out, plans and shows still come. */
  zoom_in?: boolean;
  /** Proposed: a place tile in view is still `wanted` (§3.5), so places may be missing. */
  mapping?: boolean;
  /** Proposed: hubs in the request with `place_mode = 'none'` ("Events only" chips). */
  events_only?: string[];
}

/** Bits of the `flags` element. Proposed for slice 6; unknown bits are ignored. */
export const FLAG = {
  /** A place matched through a generic rule (café, park, library): "General spot". */
  GENERIC: 1,
  /** A plan that came from a feed (D-037): grey-blue teardrop. */
  IMPORTED: 2,
  /** The viewer's own place awaiting review (§7.3): dashed pin, visible only to its creator. */
  PENDING: 4,
  /** The viewer's own private place (§7.1). */
  OWN_PRIVATE: 8,
  /** Alcohol and gambling hubs: "21+ at venue" (§7.8). */
  ADULTS_ONLY: 16,
  /** A plan that is free to join. */
  FREE: 32,
} as const;

export type FeatureKind = "place" | "plan" | "show";

export interface MapFeature {
  id: string;
  kind: FeatureKind;
  lng: number;
  lat: number;
  /** Place kind slug (court, store, park...), or the event kind / show type. */
  type: string;
  hubId: string | null;
  flags: number;
  name: string;
  startsAt: Date | null;
  generic: boolean;
  imported: boolean;
  pending: boolean;
}

export interface MapCell {
  /** "lng,lat" of the centre, one decimal each. */
  key: string;
  center: LngLat;
  count: number;
  events: { id: string; name: string; startsAt: Date | null; hubId: string | null }[];
}

export interface MapView {
  places: MapFeature[];
  plans: MapFeature[];
  shows: MapFeature[];
  cells: MapCell[];
  truncated: boolean;
  zoomIn: boolean;
  mapping: boolean;
  eventsOnlyHubIds: string[];
}

export const EMPTY_VIEW: MapView = {
  places: [],
  plans: [],
  shows: [],
  cells: [],
  truncated: false,
  zoomIn: false,
  mapping: false,
  eventsOnlyHubIds: [],
};

/* ------------------------------------------------------------------ */
/* Decoding                                                             */
/* ------------------------------------------------------------------ */

function isFiniteNumber(v: unknown): v is number {
  return typeof v === "number" && Number.isFinite(v);
}

function validPoint(lng: unknown, lat: unknown): boolean {
  return (
    isFiniteNumber(lng) &&
    isFiniteNumber(lat) &&
    lng >= -180 &&
    lng <= 180 &&
    lat >= -90 &&
    lat <= 90
  );
}

function fallbackName(kind: FeatureKind, type: string): string {
  if (kind === "plan") return "Plan";
  if (kind === "show") return "Show";
  return placeKindInfo(type).label;
}

function epochToDate(v: unknown): Date | null {
  return isFiniteNumber(v) ? new Date(v * 1000) : null;
}

/** One tuple to a feature, or null when it is malformed (wrong length, bad point, no id). */
export function decodeFeature(tuple: unknown, kind: FeatureKind): MapFeature | null {
  if (!Array.isArray(tuple) || tuple.length < 6) return null;
  const [id, lng, lat, type, hubId, flags, name, startsAt] = tuple as unknown[];
  if (typeof id !== "string" || id === "") return null;
  if (!validPoint(lng, lat)) return null;
  const t = typeof type === "string" && type ? type : kind;
  const f = isFiniteNumber(flags) ? flags | 0 : 0;
  return {
    id,
    kind,
    lng: lng as number,
    lat: lat as number,
    type: t,
    hubId: typeof hubId === "string" && hubId ? hubId : null,
    flags: f,
    name: typeof name === "string" && name.trim() ? name.trim() : fallbackName(kind, t),
    startsAt: epochToDate(startsAt),
    generic: (f & FLAG.GENERIC) !== 0,
    imported: (f & FLAG.IMPORTED) !== 0,
    pending: (f & FLAG.PENDING) !== 0,
  };
}

export function decodeCell(raw: unknown): MapCell | null {
  if (!raw || typeof raw !== "object") return null;
  const c = raw as Partial<CellPayload>;
  if (!Array.isArray(c.cell) || c.cell.length !== 2) return null;
  const [lng, lat] = c.cell;
  if (!validPoint(lng, lat)) return null;
  const center = cellCenter(lng, lat);
  const ids = Array.isArray(c.ids) ? c.ids.filter((x): x is string => typeof x === "string") : [];
  const count = isFiniteNumber(c.n) && c.n > 0 ? Math.floor(c.n) : ids.length;
  if (count === 0) return null;
  return {
    key: cellKey(center),
    center,
    count: Math.max(count, ids.length),
    events: ids.map((id, i) => ({
      id,
      name: typeof c.names?.[i] === "string" && c.names[i] ? c.names[i] : "Plan",
      startsAt: epochToDate(c.starts?.[i]),
      hubId: typeof c.hubs?.[i] === "string" ? (c.hubs[i] as string) : null,
    })),
  };
}

function decodeList(raw: unknown, kind: FeatureKind): MapFeature[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: MapFeature[] = [];
  for (const t of raw) {
    const f = decodeFeature(t, kind);
    if (f && !seen.has(f.id)) {
      seen.add(f.id);
      out.push(f);
    }
  }
  return out;
}

/**
 * The whole `map_in_view` jsonb to a MapView. Defensive: anything malformed is dropped rather
 * than thrown, so one bad row never blanks the map. Cells that share a centre are merged.
 */
export function decodeMapInView(raw: unknown): MapView {
  if (!raw || typeof raw !== "object") return EMPTY_VIEW;
  const p = raw as MapInViewPayload;
  const cells = new Map<string, MapCell>();
  for (const c of Array.isArray(p.cells) ? p.cells : []) {
    const cell = decodeCell(c);
    if (!cell) continue;
    const prev = cells.get(cell.key);
    if (prev) {
      prev.count += cell.count;
      prev.events.push(...cell.events);
    } else cells.set(cell.key, cell);
  }
  return {
    places: decodeList(p.places, "place"),
    plans: decodeList(p.plans, "plan"),
    shows: decodeList(p.shows, "show"),
    cells: [...cells.values()],
    truncated: p.truncated === true,
    zoomIn: p.zoom_in === true,
    mapping: p.mapping === true,
    eventsOnlyHubIds: Array.isArray(p.events_only)
      ? p.events_only.filter((x): x is string => typeof x === "string")
      : [],
  };
}

/* ------------------------------------------------------------------ */
/* Place detail                                                         */
/* ------------------------------------------------------------------ */

export type PlaceSource = "osm" | "user" | "geoapify" | "venue";

export interface PlaceDetail {
  id: string;
  name: string;
  kind: string;
  lng: number;
  lat: number;
  hubIds: string[];
  /** Public places only; null otherwise. */
  address: string | null;
  /** opening_hours as text; no "Open now" parser yet (founder answer). */
  hours: string | null;
  website: string | null;
  source: PlaceSource;
  /** "node/123" style OSM reference, for "Improve it on OpenStreetMap". */
  osmRef: string | null;
  checkedAt: Date | null;
  reviewed: boolean;
  generic: boolean;
  adultsOnly: boolean;
  plansHere: { id: string; title: string; startsAt: Date | null }[];
}

function str(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

function safeHttpUrl(v: unknown): string | null {
  const s = str(v);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

export function decodePlaceDetail(raw: unknown): PlaceDetail | null {
  if (!raw || typeof raw !== "object") return null;
  const r = raw as Record<string, unknown>;
  const id = str(r.id);
  if (!id || !validPoint(r.lng, r.lat)) return null;
  const source: PlaceSource =
    r.source === "user" || r.source === "geoapify" || r.source === "venue" ? r.source : "osm";
  const checked = str(r.checked_at);
  const checkedAt = checked ? new Date(checked) : null;
  const osmRef = str(r.osm_ref);
  return {
    id,
    name: str(r.name) ?? placeKindInfo(str(r.kind) ?? "").label,
    kind: str(r.kind) ?? "place",
    lng: r.lng as number,
    lat: r.lat as number,
    hubIds: Array.isArray(r.hub_ids)
      ? r.hub_ids.filter((x): x is string => typeof x === "string")
      : [],
    address: str(r.address),
    hours: str(r.hours),
    website: safeHttpUrl(r.website),
    source,
    osmRef: osmRef && /^(node|way|relation)\/\d+$/.test(osmRef) ? osmRef : null,
    checkedAt: checkedAt && !Number.isNaN(checkedAt.getTime()) ? checkedAt : null,
    reviewed: r.reviewed === true,
    generic: r.generic === true,
    adultsOnly: r.adults_only === true,
    plansHere: Array.isArray(r.plans_here)
      ? r.plans_here.flatMap((p) => {
          if (!p || typeof p !== "object") return [];
          const pr = p as Record<string, unknown>;
          const pid = str(pr.id);
          if (!pid) return [];
          const s = str(pr.starts_at);
          const d = s ? new Date(s) : null;
          return [
            {
              id: pid,
              title: str(pr.title) ?? "Plan",
              startsAt: d && !Number.isNaN(d.getTime()) ? d : null,
            },
          ];
        })
      : [],
  };
}

/** The §8 source line under a place. */
export function sourceLine(
  detail: Pick<PlaceDetail, "source" | "checkedAt" | "reviewed">,
  now = new Date(),
): string {
  switch (detail.source) {
    case "user":
      return detail.reviewed ? "Added by a member · reviewed" : "Added by a member";
    case "geoapify":
      return "From Geoapify (OpenStreetMap data)";
    case "venue":
      return "A spot where public plans happen";
    default: {
      if (!detail.checkedAt) return "From OpenStreetMap";
      const days = Math.max(
        0,
        Math.floor((now.getTime() - detail.checkedAt.getTime()) / 86_400_000),
      );
      const ago = days === 0 ? "today" : days === 1 ? "yesterday" : `${days} days ago`;
      return `From OpenStreetMap · checked ${ago}`;
    }
  }
}

export function osmEditUrl(osmRef: string): string {
  return `https://www.openstreetmap.org/${osmRef}`;
}

/* ------------------------------------------------------------------ */
/* Place kinds and pin icons                                            */
/* ------------------------------------------------------------------ */

/** Icon keys the canvas draws with addImage and the list renders with lucide. */
export type MapIconKey =
  | "court"
  | "field"
  | "store"
  | "meet"
  | "park"
  | "cafe"
  | "library"
  | "gym"
  | "studio"
  | "games"
  | "music"
  | "water"
  | "trail"
  | "place";

export const MAP_ICON_KEYS: readonly MapIconKey[] = [
  "court",
  "field",
  "store",
  "meet",
  "park",
  "cafe",
  "library",
  "gym",
  "studio",
  "games",
  "music",
  "water",
  "trail",
  "place",
];

const PLACE_KINDS: Record<string, { label: string; icon: MapIconKey }> = {
  court: { label: "Court", icon: "court" },
  basketball_court: { label: "Basketball court", icon: "court" },
  tennis_court: { label: "Tennis court", icon: "court" },
  pitch: { label: "Field", icon: "field" },
  field: { label: "Field", icon: "field" },
  store: { label: "Store", icon: "store" },
  shop: { label: "Store", icon: "store" },
  comic_store: { label: "Comic store", icon: "store" },
  game_store: { label: "Game store", icon: "games" },
  meeting_spot: { label: "Meeting spot", icon: "meet" },
  community_centre: { label: "Community centre", icon: "meet" },
  park: { label: "Park", icon: "park" },
  cafe: { label: "Café", icon: "cafe" },
  library: { label: "Library", icon: "library" },
  gym: { label: "Gym", icon: "gym" },
  fitness_centre: { label: "Gym", icon: "gym" },
  studio: { label: "Studio", icon: "studio" },
  arts_centre: { label: "Arts centre", icon: "studio" },
  music_venue: { label: "Music venue", icon: "music" },
  pool: { label: "Pool", icon: "water" },
  swimming_pool: { label: "Pool", icon: "water" },
  beach: { label: "Beach", icon: "water" },
  trailhead: { label: "Trailhead", icon: "trail" },
  climbing: { label: "Climbing spot", icon: "trail" },
};

export function placeKindInfo(kind: string): { label: string; icon: MapIconKey } {
  return PLACE_KINDS[kind] ?? { label: "Place", icon: "place" };
}

/* ------------------------------------------------------------------ */
/* Bbox                                                                 */
/* ------------------------------------------------------------------ */

export const BBOX_SNAP_DEG = 0.05;
export const MAX_PLACES_LAT_SPAN = 1.0;
export const MAX_PLACES_LNG_SPAN = 1.5;
/** Web Mercator's latitude limit; MapLibre never shows beyond it. */
export const MAX_LAT = 85.0511;

function wrapLng(lng: number): number {
  const w = ((((lng + 180) % 360) + 360) % 360) - 180;
  // Keep +180 as +180 (the eastern edge) rather than folding it to -180.
  return w === -180 && lng > 0 ? 180 : w;
}

/**
 * Bounds as the map reports them (west can be below -180 after panning across the antimeridian)
 * to a bbox inside [-180, 180] x [-MAX_LAT, MAX_LAT]. A view wider than the world is the world.
 * The result has west > east when it crosses the antimeridian; the RPC splits that in two (§5).
 */
export function normalizeBBox(b: BBox): BBox {
  const south = Math.max(-MAX_LAT, Math.min(b.south, b.north));
  const north = Math.min(MAX_LAT, Math.max(b.south, b.north));
  if (b.east - b.west >= 360) return { west: -180, south, east: 180, north };
  return { west: wrapLng(b.west), south, east: wrapLng(b.east), north };
}

function floorTo(v: number, step: number): number {
  return Math.round(Math.floor(v / step + 1e-9) * step * 1e6) / 1e6;
}
function ceilTo(v: number, step: number): number {
  return Math.round(Math.ceil(v / step - 1e-9) * step * 1e6) / 1e6;
}

/**
 * Snaps a normalized bbox outward to the 0.05-degree grid (§9 budget), so small pans reuse the
 * cached request. Clamped to the world after snapping.
 */
export function snapBBox(b: BBox, step = BBOX_SNAP_DEG): BBox {
  const n = normalizeBBox(b);
  return {
    west: Math.max(-180, floorTo(n.west, step)),
    south: Math.max(-MAX_LAT, floorTo(n.south, step)),
    east: Math.min(180, ceilTo(n.east, step)),
    north: Math.min(MAX_LAT, ceilTo(n.north, step)),
  };
}

export function bboxLngSpan(b: BBox): number {
  return b.west <= b.east ? b.east - b.west : 360 - (b.west - b.east);
}

/** Mirrors the server's places size limit, so the UI can say "Zoom in" before the reply. */
export function bboxTooLargeForPlaces(b: BBox): boolean {
  return b.north - b.south > MAX_PLACES_LAT_SPAN || bboxLngSpan(b) > MAX_PLACES_LNG_SPAN;
}

export function bboxContains(b: BBox, p: LngLat): boolean {
  if (p.lat < b.south || p.lat > b.north) return false;
  return b.west <= b.east ? p.lng >= b.west && p.lng <= b.east : p.lng >= b.west || p.lng <= b.east;
}

/**
 * The bbox a map of `width` x `height` CSS pixels shows at `zoom` around `center` (Web Mercator,
 * 512 px tiles as MapLibre uses). Lets the list load before MapLibre does.
 */
export function bboxAround(center: LngLat, zoom: number, width: number, height: number): BBox {
  const worldPx = 512 * 2 ** zoom;
  const x = ((center.lng + 180) / 360) * worldPx;
  const latRad = (Math.max(-MAX_LAT, Math.min(MAX_LAT, center.lat)) * Math.PI) / 180;
  const y = ((1 - Math.log(Math.tan(latRad) + 1 / Math.cos(latRad)) / Math.PI) / 2) * worldPx;
  const toLng = (px: number) => (px / worldPx) * 360 - 180;
  const toLat = (py: number) => {
    const n = Math.PI - (2 * Math.PI * py) / worldPx;
    return (180 / Math.PI) * Math.atan(Math.sinh(n));
  };
  return normalizeBBox({
    west: toLng(x - width / 2),
    east: toLng(x + width / 2),
    north: Math.min(MAX_LAT, toLat(Math.max(0, y - height / 2))),
    south: Math.max(-MAX_LAT, toLat(Math.min(worldPx, y + height / 2))),
  });
}

export function bboxKey(b: BBox): string {
  return [b.west, b.south, b.east, b.north].map((v) => v.toFixed(2)).join(",");
}

/* ------------------------------------------------------------------ */
/* Cells (approved-only events, D-038)                                  */
/* ------------------------------------------------------------------ */

export const CELL_DEG = 0.1;

/** Postgres `round(numeric, 1)`: half away from zero, so -84.35 goes to -84.4 like the server. */
function roundHalfAway(v: number, decimals: number): number {
  const f = 10 ** decimals;
  const scaled = Math.abs(v) * f;
  // Guard binary noise (84.35 * 10 = 843.4999...) before rounding half up.
  const r = Math.floor(scaled + 0.5 + 1e-9);
  return (Math.sign(v) * r) / f || 0;
}

/** The cell centre a point is snapped to (the stored approx_point of an approved-only event). */
export function cellCenter(lng: number, lat: number): LngLat {
  return { lng: roundHalfAway(lng, 1), lat: roundHalfAway(lat, 1) };
}

export function cellKey(c: LngLat): string {
  return `${c.lng.toFixed(1)},${c.lat.toFixed(1)}`;
}

/**
 * The square a cell covers, as a closed GeoJSON ring: every venue whose point rounds to this
 * centre lies inside [centre - 0.05, centre + 0.05] on both axes. Latitude is clamped to the
 * Mercator limit; longitude may run past ±180 by 0.05, which MapLibre draws correctly.
 */
export function cellRing(center: LngLat): [number, number][] {
  const h = CELL_DEG / 2;
  const r = (v: number) => Math.round(v * 1e6) / 1e6;
  const w = r(center.lng - h);
  const e = r(center.lng + h);
  const s = r(Math.max(-MAX_LAT, center.lat - h));
  const n = r(Math.min(MAX_LAT, center.lat + h));
  return [
    [w, s],
    [e, s],
    [e, n],
    [w, n],
    [w, s],
  ];
}

export function cellLabel(count: number): string {
  return count === 1 ? "1 event in this area" : `${count} events in this area`;
}

export const CELL_NOTE = "Exact spot shared after host approval";

/* ------------------------------------------------------------------ */
/* Hub chips                                                            */
/* ------------------------------------------------------------------ */

export interface ChipHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  colorKey: string | null;
  /** Faith, LGBTQ+, wellness and similar (§7.6). */
  sensitive: boolean;
  /** In the viewer's joined hubs (false for a hub previewed through "+ Explore"). */
  joined: boolean;
}

/** `null` is "All my hubs"; otherwise the hub ids of the selected chips, in tap order. */
export type HubSelection = string[] | null;

/** Tapping a hub chip: from All it selects just that hub; tapping the last one returns to All. */
export function toggleHubChip(selection: HubSelection, hubId: string): HubSelection {
  if (selection === null) return [hubId];
  if (selection.includes(hubId)) {
    const next = selection.filter((id) => id !== hubId);
    return next.length ? next : null;
  }
  return [...selection, hubId];
}

/**
 * Generic spots (cafés, parks, libraries) show only when exactly one hub chip is selected
 * (founder answer; §5 hub filter). Never under "All my hubs", never with two or more chips, and not
 * for a sensitive hub: that would need a request naming it (§7.6), and sensitive hubs only have
 * rules on public institutions anyway.
 */
export function genericSpotsOn(selection: HubSelection, hubs: readonly ChipHub[]): boolean {
  if (selection?.length !== 1) return false;
  const hub = hubs.find((h) => h.id === selection[0]);
  return Boolean(hub && !hub.sensitive);
}

export interface HubRequestPlan {
  /** What goes to the server, sorted (also the cache key). Empty: plans and shows only. */
  hubIds: string[];
  generic: boolean;
  /** Hub ids to keep on the client, or null for everything the server sent. */
  localFilter: string[] | null;
}

/**
 * Turns the chip selection into one request plus a local filter. One non-sensitive chip asks the
 * server for that hub with its generic spots. Anything else asks for every chip hub together
 * ("All my hubs" plus explored ones) and filters on the client, so tapping between chips does not
 * refetch (§9) and a sensitive chip never reaches the server on its own (§7.6).
 */
export function planHubRequest(selection: HubSelection, hubs: readonly ChipHub[]): HubRequestPlan {
  const all = [...new Set(hubs.map((h) => h.id))].sort();
  const known = selection?.filter((id) => all.includes(id)) ?? null;
  const sel = known && known.length ? known : null;
  if (genericSpotsOn(sel, hubs)) {
    return { hubIds: [sel![0]!], generic: true, localFilter: null };
  }
  return { hubIds: all, generic: false, localFilter: sel ? [...sel].sort() : null };
}

/** Keeps the features (and cell events) of the given hubs. A null filter keeps everything. */
export function applyHubFilter(view: MapView, filter: readonly string[] | null): MapView {
  if (!filter) return view;
  const keep = new Set(filter);
  const byHub = (f: MapFeature) => f.hubId !== null && keep.has(f.hubId);
  // Plans and shows with no hub are public listings nearby; they stay under any hub filter, the
  // same way the feed shows public plans around you.
  const happening = (f: MapFeature) => f.hubId === null || keep.has(f.hubId);
  const cells = view.cells.flatMap((c) => {
    if (c.events.length === 0) return [c];
    const events = c.events.filter((e) => e.hubId === null || keep.has(e.hubId));
    return events.length ? [{ ...c, events, count: events.length }] : [];
  });
  return {
    ...view,
    places: view.places.filter(byHub),
    plans: view.plans.filter(happening),
    shows: view.shows.filter(happening),
    cells,
  };
}

export function applyLayerFilter(view: MapView, layers: readonly MapLayer[]): MapView {
  const on = new Set(layers);
  return {
    ...view,
    places: on.has("places") ? view.places : [],
    plans: on.has("plans") ? view.plans : [],
    shows: on.has("shows") ? view.shows : [],
    cells: on.has("plans") ? view.cells : [],
  };
}

/** Layer chips: toggling never leaves zero layers on (the last one stays). */
export function toggleLayer(layers: readonly MapLayer[], layer: MapLayer): MapLayer[] {
  const has = layers.includes(layer);
  if (has && layers.length === 1) return [...layers];
  const next = has ? layers.filter((l) => l !== layer) : [...layers, layer];
  return MAP_LAYERS.filter((l) => next.includes(l));
}

/* ------------------------------------------------------------------ */
/* Time window                                                          */
/* ------------------------------------------------------------------ */

export const MAX_WINDOW_DAYS = 31;

/** Today runs to local midnight; This week is 7 days; 30 days is 30. Capped at 31 (§5). */
export function timeWindow(when: MapWhen, now = new Date()): { from: Date; to: Date } {
  const from = new Date(now);
  let to: Date;
  if (when === "today") {
    to = new Date(now);
    to.setHours(24, 0, 0, 0);
  } else {
    to = new Date(now.getTime() + (when === "week" ? 7 : 30) * 86_400_000);
  }
  const cap = now.getTime() + MAX_WINDOW_DAYS * 86_400_000;
  return { from, to: new Date(Math.min(to.getTime(), cap)) };
}

/* ------------------------------------------------------------------ */
/* Distance and the list                                                */
/* ------------------------------------------------------------------ */

/** Great-circle distance in metres. */
export function distanceM(a: LngLat, b: LngLat): number {
  const R = 6_371_000;
  const toRad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * toRad;
  const dLng = (b.lng - a.lng) * toRad;
  const s =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(a.lat * toRad) * Math.cos(b.lat * toRad) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(s)));
}

export function sortByDistance<T extends LngLat>(items: readonly T[], origin: LngLat): T[] {
  return items
    .map((item) => ({ item, d: distanceM(origin, item) }))
    .sort((x, y) => x.d - y.d)
    .map((x) => x.item);
}

export function formatDistance(m: number): string {
  if (m < 950) return `${Math.max(50, Math.round(m / 50) * 50)} m`;
  const km = m / 1000;
  return km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;
}

/** The aria-live count line over the list. */
export function countLine(view: Pick<MapView, "places" | "plans" | "shows" | "cells">): string {
  const parts: string[] = [];
  const n = (count: number, one: string, many: string) =>
    parts.push(`${count} ${count === 1 ? one : many}`);
  n(view.places.length, "place", "places");
  n(view.plans.length + view.cells.reduce((s, c) => s + c.count, 0), "plan", "plans");
  if (view.shows.length) n(view.shows.length, "show or game", "shows and games");
  return `${parts.join(", ")} in this area`;
}

/* ------------------------------------------------------------------ */
/* Directions (§7.10: hand-off to the device, nothing sent to us)        */
/* ------------------------------------------------------------------ */

export type DevicePlatform = "ios" | "android" | "other";

export function detectPlatform(ua: string, maxTouchPoints = 0, platform = ""): DevicePlatform {
  if (/iPad|iPhone|iPod/.test(ua) || (platform === "MacIntel" && maxTouchPoints > 1)) return "ios";
  if (/Android/i.test(ua)) return "android";
  return "other";
}

/**
 * A URL that opens the device's own maps app at the destination: Apple Maps on iOS, the `geo:`
 * intent on Android (the person's default maps app), OpenStreetMap directions elsewhere. The
 * starting point is left to that app; the viewer's location never passes through us.
 */
export function directionsUrl(dest: LngLat & { name?: string }, platform: DevicePlatform): string {
  const lat = dest.lat.toFixed(6);
  const lng = dest.lng.toFixed(6);
  const label = dest.name ? encodeURIComponent(dest.name) : "";
  if (platform === "ios") {
    return `https://maps.apple.com/?daddr=${lat},${lng}${label ? `&q=${label}` : ""}`;
  }
  if (platform === "android") {
    return `geo:${lat},${lng}?q=${lat},${lng}${label ? `(${label})` : ""}`;
  }
  return `https://www.openstreetmap.org/directions?to=${lat}%2C${lng}`;
}

/* ------------------------------------------------------------------ */
/* Adapter and queries                                                  */
/* ------------------------------------------------------------------ */

/** The map RPCs are not deployed (slice 6). The Map tab shows "coming soon" for this one error. */
export class MapUnavailableError extends Error {
  constructor() {
    super("The map is not available yet.");
    this.name = "MapUnavailableError";
  }
}

export function isMapUnavailable(err: unknown): boolean {
  return err instanceof MapUnavailableError;
}

/**
 * PostgREST's "function not found in the schema cache" (PGRST202), Postgres' "function does not
 * exist" (42883), or a bare 404 from the RPC endpoint: the map is not deployed here yet.
 */
export function isMissingRpc(error: { code?: string } | null, status?: number): boolean {
  if (!error) return false;
  return error.code === "PGRST202" || error.code === "42883" || status === 404;
}

export interface MapAdapter {
  mapInView(args: MapInViewArgs): Promise<unknown>;
  placesInView(args: PlacesInViewArgs): Promise<unknown>;
  placeDetail(id: string): Promise<unknown>;
}

/** Mock fixtures when VITE_MAP_MOCK=true, and always under Vitest. */
export const MAP_MOCK: boolean =
  import.meta.env.VITE_MAP_MOCK === "true" || import.meta.env.MODE === "test";

let adapterPromise: Promise<MapAdapter> | null = null;

/** Loaded on first use, so neither adapter (nor supabase-js through it) is pulled in early. */
export function getMapAdapter(): Promise<MapAdapter> {
  adapterPromise ??= MAP_MOCK
    ? import("./map-mock").then((m) => m.mockMapAdapter)
    : import("./map-rpc").then((m) => m.rpcMapAdapter);
  return adapterPromise;
}

export interface MapQueryParams {
  bbox: BBox;
  hubIds: string[];
  generic: boolean;
  when: MapWhen;
}

export const mapKeys = {
  all: ["map"] as const,
  inView: (p: MapQueryParams) =>
    ["map", "in-view", bboxKey(p.bbox), p.hubIds.join(","), p.generic, p.when] as const,
  place: (id: string) => ["map", "place", id] as const,
};

export function mapInViewArgs(p: MapQueryParams, now = new Date()): MapInViewArgs {
  const { from, to } = timeWindow(p.when, now);
  return {
    p_west: p.bbox.west,
    p_south: p.bbox.south,
    p_east: p.bbox.east,
    p_north: p.bbox.north,
    p_hub_ids: p.hubIds,
    // All layers come back and the layer chips filter locally, so a chip tap never refetches.
    p_layers: [...MAP_LAYERS],
    p_from: from.toISOString(),
    p_to: to.toISOString(),
    p_generic: p.generic,
  };
}

/** One request per settled view: 2-minute cache, previous data kept while the next one loads. */
export const mapInViewQuery = (p: MapQueryParams) =>
  queryOptions({
    queryKey: mapKeys.inView(p),
    queryFn: async (): Promise<MapView> => {
      const adapter = await getMapAdapter();
      return decodeMapInView(await adapter.mapInView(mapInViewArgs(p)));
    },
    staleTime: 2 * 60_000,
    placeholderData: keepPreviousData,
    retry: (count, err) => !isMapUnavailable(err) && count < 2,
  });

export const placeDetailQuery = (id: string) =>
  queryOptions({
    queryKey: mapKeys.place(id),
    queryFn: async (): Promise<PlaceDetail | null> => {
      const adapter = await getMapAdapter();
      return decodePlaceDetail(await adapter.placeDetail(id));
    },
    staleTime: 5 * 60_000,
    retry: (count, err) => !isMapUnavailable(err) && count < 2,
  });

/* ------------------------------------------------------------------ */
/* Camera                                                               */
/* ------------------------------------------------------------------ */

export interface Camera extends LngLat {
  zoom: number;
}

/** No location yet: the whole world, plans and shows only, with "Use my location" on offer. */
export const WORLD_CAMERA: Camera = { lng: 10, lat: 25, zoom: 1.6 };
export const LOCATED_ZOOM = 12.5;
/** Below this, places give way to the "Zoom in to see places" pill (§9). */
export const PLACES_MIN_ZOOM = 10;

const VIEW_KEY = "ap-map-view";

/** The last map view on this device, a per-viewer convenience (never sent anywhere). */
export function readSavedCamera(): Camera | null {
  try {
    const raw = localStorage.getItem(VIEW_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as Partial<Camera>;
    if (!validPoint(v.lng, v.lat) || !isFiniteNumber(v.zoom)) return null;
    return { lng: v.lng!, lat: v.lat!, zoom: Math.max(0, Math.min(20, v.zoom!)) };
  } catch {
    return null;
  }
}

export function saveCamera(c: Camera): void {
  try {
    // Two decimals (about 1 km), the same coarseness as the feed's device point.
    localStorage.setItem(
      VIEW_KEY,
      JSON.stringify({ lng: +c.lng.toFixed(2), lat: +c.lat.toFixed(2), zoom: +c.zoom.toFixed(1) }),
    );
  } catch {
    /* storage unavailable */
  }
}

export function clearSavedCamera(): void {
  try {
    localStorage.removeItem(VIEW_KEY);
  } catch {
    /* storage unavailable */
  }
}

/* ------------------------------------------------------------------ */
/* Search params                                                        */
/* ------------------------------------------------------------------ */

/** `?layers=places,plans` to a layer list; unknown names dropped; empty or absent is all three. */
export function parseLayersParam(value: string | undefined): MapLayer[] {
  if (!value) return [...MAP_LAYERS];
  const parts = new Set(value.split(","));
  const layers = MAP_LAYERS.filter((l) => parts.has(l));
  return layers.length ? layers : [...MAP_LAYERS];
}

/** The inverse; all three layers is the default and leaves the param out. */
export function layersParam(layers: readonly MapLayer[]): string | undefined {
  return layers.length === MAP_LAYERS.length
    ? undefined
    : MAP_LAYERS.filter((l) => layers.includes(l)).join(",");
}

/** `?hubs=basketball,anime` to slugs, deduplicated, at most 50 (the server's hub cap). */
export function parseHubsParam(value: string | undefined): string[] | null {
  if (!value) return null;
  const slugs = [
    ...new Set(
      value
        .split(",")
        .map((s) => s.trim())
        .filter(Boolean),
    ),
  ].slice(0, 50);
  return slugs.length ? slugs : null;
}

/** The viewer's own time zone: the map is for anywhere, so times read in local time. */
export function viewerTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
  } catch {
    return "UTC";
  }
}
