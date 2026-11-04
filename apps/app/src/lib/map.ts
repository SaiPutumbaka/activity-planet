import { keepPreviousData, queryOptions } from "@tanstack/react-query";
import { EVENT_FLAGS, PLACE_FLAGS } from "@ap/core/map";

/**
 * Hub map client (HUB_MAP_DESIGN §5, §7, §9; D-038, D-041). Everything the Map tab needs that is
 * not a component: the typed contract of `map_in_view`, `places_in_view` and `place_detail` as
 * built (migrations 29, 30 and 32), the decoder for their compact encoding, bbox snapping, the
 * 0.1-degree cell geometry for approved-only events, the hub-chip rules (generic spots only with
 * exactly one hub chip), the time windows, distance sorting and the directions hand-off.
 *
 * The real adapter (lib/map-rpc.ts) calls the RPCs; the mock (lib/map-mock.ts) speaks the same
 * encoding and is used only under Vitest and with VITE_MAP_MOCK=true. A database without the RPCs
 * gives `MapUnavailableError` and the Map tab shows a friendly "coming soon" state.
 *
 * Privacy (§7): nothing here logs a bbox or a user id. Approved-only events only ever arrive as
 * cells and are drawn as shaded squares, never as points. Sensitive-hub chips filter on the client
 * from the response for every chip hub. A sensitive hub the viewer has not joined (picked through
 * "+ Explore") is sent inside the full set of sensitive catalog hubs, so the server can tell that
 * one of them is wanted but not which (planHubRequest). Its slug never goes into the URL either
 * (routes/map.tsx keeps it in component state).
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
 * Arguments of `map_in_view` (§5, migration 32). `p_hub_ids` null means the viewer's joined hubs
 * when signed in and every specific hub when signed out (D-041); `[]` means no hubs (plans only).
 * Signed in, this client always sends the chip hubs explicitly so explored hubs are included.
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

export type PlaceMode = "specific" | "generic" | "none";

/** `hubs` entry: the selected hubs first, then the other hubs the events are in. */
export type HubTuple = [
  id: string,
  slug: string,
  name: string,
  emoji: string,
  placeMode: PlaceMode,
];

/** A place: `hubIdx` is the first matching selected hub, `hubIdxs` every one (indexes into hubs). */
export type PlaceTuple = [
  id: string,
  lng: number,
  lat: number,
  kind: string,
  hubIdx: number | null,
  flags: number,
  name: string,
  hubIdxs: number[],
];

/** A plan or show: `startsAt` in unix seconds; every event has a hub. */
export type EventTuple = [
  id: string,
  lng: number,
  lat: number,
  kind: string,
  hubIdx: number,
  flags: number,
  title: string,
  startsAt: number,
];

/**
 * Approved-only events in one 0.1-degree cell (D-038): the cell centre, the count, and per event
 * its id, hub index, title and start (unix seconds), in parallel arrays. Never a point.
 * `titles` and `starts` arrived with migration 32; the decoder tolerates their absence.
 */
export type CellTuple = [
  lng: number,
  lat: number,
  n: number,
  ids: string[],
  hubIdxs: number[],
  titles?: string[],
  starts?: number[],
];

export interface MapInViewPayload {
  v?: number;
  /** null when the places layer is off or the bbox needs zoom_in. */
  places?: PlaceTuple[] | null;
  plans?: EventTuple[] | null;
  shows?: EventTuple[] | null;
  cells?: CellTuple[];
  hubs?: HubTuple[];
  /** More than 50 hubs, or more places, plans, shows or cell events than the caps. */
  truncated?: boolean;
  more?: Partial<Record<"places" | "hubs" | "plans" | "shows" | "cells", boolean>>;
  /** The bbox is larger than 1.0 lat x 1.5 lng: places are left out, plans and shows still come. */
  zoom_in?: boolean;
  /** A signed-in viewer with no hubs (plans only). */
  no_hubs?: boolean;
  /** The one selected hub is generic and its general spots are in. */
  generic?: boolean;
  /** Migration 32: a place tile in view is still wanted or filling (§3.5), so places may be missing. */
  mapping?: boolean;
}

/** Place flag bits (§5 as built). */
export const PLACE_FLAG = {
  /** Matched through a generic hub's rules (café, park, library): "General spot". */
  GENERAL: PLACE_FLAGS.general,
  /** The viewer's own place awaiting review (§7.3): dashed pin, visible only to its creator. */
  PENDING: PLACE_FLAGS.pending,
  /** The viewer's own private place (§7.1). */
  PRIVATE: PLACE_FLAGS.private,
  MEMBER: PLACE_FLAGS.member,
  MEETING_SPOT: PLACE_FLAGS.meetingSpot,
  /** Data through Geoapify (§8): "Powered by Geoapify" while one is in view. */
  GEOAPIFY: PLACE_FLAGS.geoapify,
  MINE: PLACE_FLAGS.mine,
} as const;

/** Plan and show flag bits (§5 as built). */
export const EVENT_FLAG = {
  /** Listed from a feed (D-037): grey-blue teardrop. */
  IMPORTED: EVENT_FLAGS.imported,
  SELECTED_HUB: EVENT_FLAGS.selectedHub,
  FREE: EVENT_FLAGS.free,
  /** 21+ (§7.8). */
  ADULTS_ONLY: EVENT_FLAGS.adultsOnly21,
} as const;

export type FeatureKind = "place" | "plan" | "show";

export interface MapHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  placeMode: PlaceMode;
}

export interface MapFeature {
  id: string;
  kind: FeatureKind;
  lng: number;
  lat: number;
  /** Place kind slug (court_field, park...), or the event kind (member, imported...). */
  type: string;
  /** First matching selected hub (places; null when every specific hub was asked for), or the event's hub. */
  hubId: string | null;
  /** Places: every selected hub the place matches. Events: their one hub. */
  hubIds: string[];
  flags: number;
  name: string;
  startsAt: Date | null;
  generic: boolean;
  imported: boolean;
  pending: boolean;
  geoapify: boolean;
  /** The viewer's own place (always shown, whatever the chip). */
  mine: boolean;
  private: boolean;
  free: boolean;
  adultsOnly: boolean;
}

export interface MapCell {
  /** "lng,lat" of the centre, one decimal each. */
  key: string;
  center: LngLat;
  count: number;
  events: { id: string; name: string; startsAt: Date | null; hubId: string | null }[];
  /** Every listed event came with its hub, so the cell can be matched to a hub chip. */
  hubsKnown: boolean;
}

export interface MapView {
  places: MapFeature[];
  plans: MapFeature[];
  shows: MapFeature[];
  cells: MapCell[];
  hubs: MapHub[];
  truncated: boolean;
  zoomIn: boolean;
  mapping: boolean;
  noHubs: boolean;
  generic: boolean;
  /** Hubs in the response with `place_mode = 'none'` ("Events only" chips). */
  eventsOnlyHubIds: string[];
}

export const EMPTY_VIEW: MapView = {
  places: [],
  plans: [],
  shows: [],
  cells: [],
  hubs: [],
  truncated: false,
  zoomIn: false,
  mapping: false,
  noHubs: false,
  generic: false,
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

function nonEmpty(v: unknown): string | null {
  return typeof v === "string" && v.trim() ? v.trim() : null;
}

/** `hubs` to objects; malformed entries keep their slot (so indexes stay right) as null. */
export function decodeHubs(raw: unknown): (MapHub | null)[] {
  if (!Array.isArray(raw)) return [];
  return raw.map((h) => {
    if (!Array.isArray(h)) return null;
    const [id, slug, name, emoji, mode] = h as unknown[];
    if (typeof id !== "string" || !id) return null;
    return {
      id,
      slug: typeof slug === "string" ? slug : "",
      name: typeof name === "string" ? name : "",
      emoji: typeof emoji === "string" ? emoji : "",
      placeMode: mode === "generic" || mode === "none" ? mode : "specific",
    };
  });
}

function hubAt(hubs: readonly (MapHub | null)[], idx: unknown): string | null {
  return Number.isInteger(idx) ? (hubs[idx as number]?.id ?? null) : null;
}

/**
 * One tuple to a feature, or null when it is malformed (too short, bad point, no id). `hubs` is
 * the decoded `hubs` list of the same response, which the hub indexes point into.
 */
export function decodeFeature(
  tuple: unknown,
  kind: FeatureKind,
  hubs: readonly (MapHub | null)[] = [],
): MapFeature | null {
  if (!Array.isArray(tuple) || tuple.length < 6) return null;
  const [id, lng, lat, type, hubIdx, flags, name, extra] = tuple as unknown[];
  if (typeof id !== "string" || id === "") return null;
  if (!validPoint(lng, lat)) return null;
  const t = typeof type === "string" && type ? type : kind;
  const f = isFiniteNumber(flags) ? flags | 0 : 0;
  const hubId = hubAt(hubs, hubIdx);
  const isPlace = kind === "place";
  const hubIds = isPlace
    ? [
        ...new Set(
          (Array.isArray(extra) ? extra : [])
            .map((i) => hubAt(hubs, i))
            .filter((h): h is string => h !== null),
        ),
      ]
    : [];
  if (hubId && !hubIds.includes(hubId)) hubIds.unshift(hubId);
  const bit = (b: number) => (f & b) !== 0;
  return {
    id,
    kind,
    lng: lng as number,
    lat: lat as number,
    type: t,
    hubId,
    hubIds,
    flags: f,
    name: nonEmpty(name) ?? fallbackName(kind, t),
    startsAt: isPlace ? null : epochToDate(extra),
    generic: isPlace && bit(PLACE_FLAG.GENERAL),
    imported: !isPlace && (bit(EVENT_FLAG.IMPORTED) || t === "imported"),
    pending: isPlace && bit(PLACE_FLAG.PENDING),
    geoapify: isPlace && bit(PLACE_FLAG.GEOAPIFY),
    mine: isPlace && bit(PLACE_FLAG.MINE),
    private: isPlace && bit(PLACE_FLAG.PRIVATE),
    free: !isPlace && bit(EVENT_FLAG.FREE),
    adultsOnly: !isPlace && bit(EVENT_FLAG.ADULTS_ONLY),
  };
}

export function decodeCell(raw: unknown, hubs: readonly (MapHub | null)[] = []): MapCell | null {
  if (!Array.isArray(raw) || raw.length < 4) return null;
  const [lng, lat, n, rawIds, rawHubs, rawTitles, rawStarts] = raw as unknown[];
  if (!validPoint(lng, lat)) return null;
  const center = cellCenter(lng as number, lat as number);
  const all = Array.isArray(rawIds) ? rawIds : [];
  const hubIdx = Array.isArray(rawHubs) ? rawHubs : [];
  const titles = Array.isArray(rawTitles) ? rawTitles : [];
  const starts = Array.isArray(rawStarts) ? rawStarts : [];
  const events = all.flatMap((id, i) =>
    typeof id === "string" && id
      ? [
          {
            id,
            name: nonEmpty(titles[i]) ?? "Plan",
            startsAt: epochToDate(starts[i]),
            hubId: hubAt(hubs, hubIdx[i]),
          },
        ]
      : [],
  );
  const count = isFiniteNumber(n) && n > 0 ? Math.floor(n) : events.length;
  if (count === 0) return null;
  return {
    key: cellKey(center),
    center,
    count: Math.max(count, events.length),
    hubsKnown: events.length > 0 && hubIdx.length === all.length && events.every((e) => e.hubId),
    events,
  };
}

function decodeList(
  raw: unknown,
  kind: FeatureKind,
  hubs: readonly (MapHub | null)[],
): MapFeature[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const out: MapFeature[] = [];
  for (const t of raw) {
    const f = decodeFeature(t, kind, hubs);
    if (f && !seen.has(f.id)) {
      seen.add(f.id);
      out.push(f);
    }
  }
  return out;
}

/**
 * The whole `map_in_view` (or `places_in_view`) jsonb to a MapView. Defensive: anything malformed
 * is dropped rather than thrown, so one bad row never blanks the map. Cells that share a centre
 * are merged.
 */
export function decodeMapInView(raw: unknown): MapView {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return EMPTY_VIEW;
  const p = raw as Record<string, unknown>;
  const slots = decodeHubs(p.hubs);
  const cells = new Map<string, MapCell>();
  for (const c of Array.isArray(p.cells) ? p.cells : []) {
    const cell = decodeCell(c, slots);
    if (!cell) continue;
    const prev = cells.get(cell.key);
    if (prev) {
      prev.count += cell.count;
      prev.events.push(...cell.events);
      prev.hubsKnown &&= cell.hubsKnown;
    } else cells.set(cell.key, cell);
  }
  const hubs = [
    ...new Map(slots.filter((h): h is MapHub => h !== null).map((h) => [h.id, h])).values(),
  ];
  return {
    places: decodeList(p.places, "place", slots),
    plans: decodeList(p.plans, "plan", slots),
    shows: decodeList(p.shows, "show", slots),
    cells: [...cells.values()],
    hubs,
    truncated: p.truncated === true,
    zoomIn: p.zoom_in === true,
    mapping: p.mapping === true,
    noHubs: p.no_hubs === true,
    generic: p.generic === true,
    eventsOnlyHubIds: hubs.filter((h) => h.placeMode === "none").map((h) => h.id),
  };
}

/* ------------------------------------------------------------------ */
/* Place detail                                                         */
/* ------------------------------------------------------------------ */

export type PlaceSource = "osm" | "user" | "geoapify" | "venue";

export interface PlaceDetailHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  /** A generic hub (the place suits it as a general spot). */
  general: boolean;
  /** One of the viewer's joined hubs (listed first). */
  joined: boolean;
}

export interface PlaceDetail {
  id: string;
  name: string;
  kind: string;
  /** The server's label for the kind (place_kinds.label). */
  kindLabel: string;
  lng: number;
  lat: number;
  /** Up to 12, joined first. */
  hubs: PlaceDetailHub[];
  moreHubs: boolean;
  /** Public places only; null otherwise. */
  address: string | null;
  locality: string | null;
  /** opening_hours as text; no "Open now" parser yet (founder answer). */
  hours: string | null;
  website: string | null;
  source: PlaceSource;
  /** "https://www.openstreetmap.org/node/123", for "Improve it on OpenStreetMap". */
  osmUrl: string | null;
  checkedAt: Date | null;
  /** A member-added place a moderator approved (active and public). */
  reviewed: boolean;
  /** The viewer's own place still waiting for review. */
  pending: boolean;
  /** Only its creator sees it. */
  private: boolean;
  mine: boolean;
  /** Every hub it is listed for is generic: "General spot". */
  generic: boolean;
  plansHere: { id: string; title: string; startsAt: Date | null; hubId: string | null }[];
}

function safeHttpUrl(v: unknown): string | null {
  const s = nonEmpty(v);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" || u.protocol === "http:" ? u.toString() : null;
  } catch {
    return null;
  }
}

function isoDate(v: unknown): Date | null {
  const s = nonEmpty(v);
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

const OSM_URL = /^https:\/\/www\.openstreetmap\.org\/(node|way|relation)\/\d+$/;

/** The `place_detail` jsonb (migration 29) to a PlaceDetail, or null when malformed. */
export function decodePlaceDetail(raw: unknown): PlaceDetail | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  const id = nonEmpty(r.id);
  if (!id || !validPoint(r.lng, r.lat)) return null;
  const source: PlaceSource =
    r.source === "user" || r.source === "geoapify" || r.source === "venue" ? r.source : "osm";
  const kind = nonEmpty(r.kind) ?? "spot";
  const status = nonEmpty(r.status);
  const isPublic = r.is_public !== false;
  const osmUrl = nonEmpty(r.osm_url);
  const hubs: PlaceDetailHub[] = Array.isArray(r.hubs)
    ? r.hubs.flatMap((h) => {
        if (!h || typeof h !== "object") return [];
        const o = h as Record<string, unknown>;
        const hid = nonEmpty(o.id);
        if (!hid) return [];
        return [
          {
            id: hid,
            slug: nonEmpty(o.slug) ?? "",
            name: nonEmpty(o.name) ?? "",
            emoji: typeof o.emoji === "string" ? o.emoji : "",
            general: o.general === true,
            joined: o.joined === true,
          },
        ];
      })
    : [];
  return {
    id,
    name: nonEmpty(r.name) ?? nonEmpty(r.kind_label) ?? placeKindInfo(kind).label,
    kind,
    kindLabel: nonEmpty(r.kind_label) ?? placeKindInfo(kind).label,
    lng: r.lng as number,
    lat: r.lat as number,
    hubs,
    moreHubs: r.more_hubs === true,
    address: isPublic ? nonEmpty(r.address_text) : null,
    locality: nonEmpty(r.locality),
    hours: nonEmpty(r.opening_hours),
    website: safeHttpUrl(r.website),
    source,
    osmUrl: osmUrl && OSM_URL.test(osmUrl) ? osmUrl : null,
    checkedAt: isoDate(r.checked_at),
    reviewed: source === "user" && status === "active" && isPublic,
    pending: status === "pending",
    private: !isPublic,
    mine: r.mine === true,
    generic: hubs.length > 0 && hubs.every((h) => h.general),
    plansHere: Array.isArray(r.plans_here)
      ? r.plans_here.flatMap((p) => {
          if (!p || typeof p !== "object") return [];
          const pr = p as Record<string, unknown>;
          const pid = nonEmpty(pr.id);
          if (!pid) return [];
          return [
            {
              id: pid,
              title: nonEmpty(pr.title) ?? "Plan",
              startsAt: isoDate(pr.starts_at),
              hubId: nonEmpty(pr.hub_id),
            },
          ];
        })
      : [],
  };
}

/** The §8 source line under a place. */
export function sourceLine(
  detail: Pick<PlaceDetail, "source" | "checkedAt" | "reviewed"> &
    Partial<Pick<PlaceDetail, "pending" | "private">>,
  now = new Date(),
): string {
  switch (detail.source) {
    case "user":
      if (detail.private) return "Added by you · only you can see it";
      if (detail.pending) return "Added by you · waiting for review";
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

/**
 * "Start a plan here" works for an active public place only: venue_for_place (migration 33)
 * makes a public venue from its public facts. A private pin or a place waiting for review has none.
 */
export function canStartPlan(d: Pick<PlaceDetail, "private" | "pending">): boolean {
  return !d.private && !d.pending;
}

/**
 * The `/post` search for "Start a plan here": the place, and the hub to preselect, which is the
 * first of the viewer's joined hubs the place is listed for, a specific one before a generic one.
 */
export function startPlanSearch(d: Pick<PlaceDetail, "id" | "hubs">): {
  place: string;
  hub?: string;
} {
  const joined = d.hubs.filter((h) => h.joined && h.slug);
  const hub = joined.find((h) => !h.general) ?? joined[0];
  return hub ? { place: d.id, hub: hub.slug } : { place: d.id };
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
  | "food"
  | "drink"
  | "landmark"
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
  "food",
  "drink",
  "landmark",
  "place",
];

/**
 * The place_kinds seed (migration 27, as on staging 2026-11-04): slug to its label and the pin
 * icon group. place_detail sends the label too (kind_label); this table serves the list and the
 * pins, which only carry the slug. An unknown slug reads "Place".
 */
const PLACE_KINDS: Record<string, { label: string; icon: MapIconKey }> = {
  adventure: { label: "Adventure spot", icon: "trail" },
  anime_store: { label: "Anime store", icon: "store" },
  arcade: { label: "Arcade or game room", icon: "games" },
  arts_venue: { label: "Arts venue or museum", icon: "studio" },
  attraction: { label: "Attraction", icon: "place" },
  bar: { label: "Bar or pub", icon: "drink" },
  beach: { label: "Beach or waterfront", icon: "water" },
  bookstore: { label: "Bookstore", icon: "library" },
  brewery: { label: "Brewery or winery", icon: "drink" },
  cafe: { label: "Café", icon: "cafe" },
  camp: { label: "Campsite or hut", icon: "trail" },
  cinema: { label: "Cinema", icon: "studio" },
  club: { label: "Club", icon: "meet" },
  collectors_shop: { label: "Collectors' shop", icon: "store" },
  community: { label: "Community space", icon: "meet" },
  court_field: { label: "Court or field", icon: "court" },
  craft_shop: { label: "Craft and hobby shop", icon: "studio" },
  dance: { label: "Dance studio", icon: "music" },
  dojo: { label: "Dojo", icon: "gym" },
  food_shop: { label: "Food shop", icon: "store" },
  game_store: { label: "Game store", icon: "games" },
  golf: { label: "Golf", icon: "field" },
  gym: { label: "Gym or studio", icon: "gym" },
  historic: { label: "Historic site", icon: "landmark" },
  ice_rink: { label: "Ice rink", icon: "court" },
  library: { label: "Library", icon: "library" },
  maker: { label: "Makerspace or workshop", icon: "studio" },
  market: { label: "Market", icon: "store" },
  music_shop: { label: "Music shop", icon: "music" },
  music_venue: { label: "Music venue", icon: "music" },
  nature: { label: "Nature spot", icon: "park" },
  nightlife: { label: "Nightlife", icon: "drink" },
  park: { label: "Park or garden", icon: "park" },
  pool: { label: "Pool or swim spot", icon: "water" },
  range: { label: "Range", icon: "field" },
  restaurant: { label: "Restaurant", icon: "food" },
  riding: { label: "Riding stable", icon: "field" },
  school: { label: "Classes", icon: "library" },
  shop: { label: "Shop", icon: "store" },
  snow: { label: "Snow sports", icon: "trail" },
  sports_centre: { label: "Sports centre", icon: "gym" },
  spot: { label: "Spot", icon: "place" },
  track: { label: "Track or raceway", icon: "field" },
  trail: { label: "Trail or route", icon: "trail" },
  water_launch: { label: "Marina or launch", icon: "water" },
  wellness: { label: "Sauna or spa", icon: "gym" },
  worship: { label: "Place of worship", icon: "landmark" },
};

export function placeKindInfo(kind: string): { label: string; icon: MapIconKey } {
  return PLACE_KINDS[kind] ?? { label: "Place", icon: "place" };
}

/** Every place kind for the add and correct forms, by label. */
export const PLACE_KIND_OPTIONS: readonly { value: string; label: string }[] = Object.entries(
  PLACE_KINDS,
)
  .map(([value, k]) => ({ value, label: k.label }))
  .sort((a, b) => a.label.localeCompare(b.label));

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

/** The label drawn on the map over a cell (§9): the count and the note together. */
export function cellMapLabel(count: number): string {
  return `${cellLabel(count)} · ${CELL_NOTE.toLowerCase()}`;
}

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
  /**
   * What goes to the server, sorted (also the cache key). Null: every specific hub (signed out
   * with no hub picked, D-041). Empty: no hubs, plans and shows only.
   */
  hubIds: string[] | null;
  generic: boolean;
  /** Hub ids whose places to keep on the client, or null for every place the server sent. */
  placeFilter: string[] | null;
  /** Hub ids whose plans, shows and cell events to keep, or null for every one in view. */
  eventFilter: string[] | null;
}

/** The server's hub cap per request (§5). */
export const MAX_REQUEST_HUBS = 50;

/**
 * Turns the chip selection into one request plus local filters. One non-sensitive chip asks the
 * server for that hub with its generic spots. Anything else asks for every chip hub together
 * ("All my hubs" plus explored ones) and filters on the client, so tapping between chips does not
 * refetch (§9) and tapping a sensitive chip is never visible to the server (§7.6). Signed out with
 * no hub picked, it asks for every specific hub (`hubIds` null), the founder's public map.
 *
 * The server sends every published plan and show in view whatever the hubs (selected hubs first),
 * so under "All my hubs" they all stay; a chip keeps its own hub's.
 *
 * A joined sensitive hub is already known to the server through the membership, so it rides with
 * the other joined hubs. A sensitive hub the viewer only explored (a signed-out visitor, or a
 * member with no other hubs) would otherwise be the whole request, so it goes out with
 * `sensitiveCover`, the ids of every sensitive hub in the catalog: the server learns that one of
 * them is wanted, not which. The extra hubs' places are dropped by the place filter.
 */
export function planHubRequest(
  selection: HubSelection,
  hubs: readonly ChipHub[],
  sensitiveCover: readonly string[] = [],
  opts: { signedOut?: boolean } = {},
): HubRequestPlan {
  const all = [...new Set(hubs.map((h) => h.id))].sort();
  if (opts.signedOut && all.length === 0) {
    return { hubIds: null, generic: false, placeFilter: null, eventFilter: null };
  }
  const known = selection?.filter((id) => all.includes(id)) ?? null;
  const sel = known && known.length ? [...known].sort() : null;
  if (genericSpotsOn(sel, hubs)) {
    return { hubIds: [sel![0]!], generic: true, placeFilter: null, eventFilter: [sel![0]!] };
  }
  if (!hubs.some((h) => h.sensitive && !h.joined)) {
    return { hubIds: all, generic: false, placeFilter: sel, eventFilter: sel };
  }
  const chips = new Set(all);
  const room = Math.max(0, MAX_REQUEST_HUBS - all.length);
  const cover = [...new Set(sensitiveCover)]
    .filter((id) => !chips.has(id))
    .sort()
    .slice(0, room);
  return {
    hubIds: [...all, ...cover].sort(),
    generic: false,
    placeFilter: sel ?? all,
    eventFilter: sel,
  };
}

/**
 * Keeps the places and events of the given hubs (a null filter keeps everything). The viewer's
 * own places always stay (§7.3: their private and pending pins show whatever the chip).
 */
export function applyHubFilter(
  view: MapView,
  filters: Pick<HubRequestPlan, "placeFilter" | "eventFilter">,
): MapView {
  const { placeFilter, eventFilter } = filters;
  if (!placeFilter && !eventFilter) return view;
  const places = placeFilter ? new Set(placeFilter) : null;
  const events = eventFilter ? new Set(eventFilter) : null;
  const placeOk = (f: MapFeature) => !places || f.mine || f.hubIds.some((h) => places.has(h));
  const eventOk = (f: MapFeature) => !events || (f.hubId !== null && events.has(f.hubId));
  const cells = !events
    ? view.cells
    : view.cells.flatMap((c) => {
        // Without a hub per event there is no telling whether the cell belongs to the chip: hide
        // it rather than show every hub's approved-only events under any chip with the full count.
        if (!c.hubsKnown) return [];
        const kept = c.events.filter((e) => e.hubId !== null && events.has(e.hubId));
        return kept.length ? [{ ...c, events: kept, count: kept.length }] : [];
      });
  return {
    ...view,
    places: view.places.filter(placeOk),
    plans: view.plans.filter(eventOk),
    shows: view.shows.filter(eventOk),
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

/** The map RPCs are not deployed on this database. The Map tab shows "coming soon" for this one error. */
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
  /** Null: every specific hub (signed out, no hub picked). */
  hubIds: string[] | null;
  generic: boolean;
  when: MapWhen;
}

export const mapKeys = {
  all: ["map"] as const,
  inView: (p: MapQueryParams) =>
    [
      "map",
      "in-view",
      bboxKey(p.bbox),
      p.hubIds === null ? "*" : p.hubIds.join(","),
      p.generic,
      p.when,
    ] as const,
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
