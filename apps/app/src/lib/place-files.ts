import type { BBox, LngLat, MapFeature, MapHub, MapView, PlaceDetail, PlaceDetailHub } from "./map";
import { PLACE_FLAG, placeKindInfo } from "./map";

/**
 * Static place tile files (D-042 slices 3 to 5, AUTO_COVERAGE_DESIGN §4.4 and §4.5).
 *
 * OpenStreetMap places are served as one gzipped JSON file per 0.5-degree tile from GitHub Pages
 * (later Cloudflare R2, same layout), built by .github/workflows/places-files.yml. When the app
 * asks (`map_in_view` p_files, only while VITE_PLACES_BASE_URL is set) and the server switch is on,
 * the RPC leaves those tiles' OSM rows out and returns `place_files`: the files of the tiles in view,
 * the rules file and the OSM refs hidden since a file was built. This module fetches the files
 * (hashed names, so a file never changes; the service worker keeps them cache-first), matches each
 * row to the hubs exactly as places_in_view does, and merges them with the database rows: a
 * database row with the same osm_ref wins (a moderator's correction, a member's hub link), hidden
 * refs are dropped, and the viewer's own pins still come first. The 800-place cap and "nearest the
 * centre" order are the server's, so a view looks the same from either store.
 *
 * If a file cannot be fetched or read, the caller asks the RPC again without p_files, so places
 * never vanish (Postgres keeps every place during the transition; nothing is deleted).
 *
 * Privacy: files are fetched per tile, never per hub, so the host learns a tile, not an interest.
 * Nothing here logs a bbox, a tile or a user id.
 */

/* ------------------------------------------------------------------ */
/* Config                                                               */
/* ------------------------------------------------------------------ */

/** Where the files are served, with a trailing slash; null keeps every place in Postgres. */
export function placesBaseUrl(raw: unknown = import.meta.env.VITE_PLACES_BASE_URL): string | null {
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const u = new URL(raw.trim());
    if (u.protocol !== "https:" && u.hostname !== "localhost") return null;
    return u.toString().endsWith("/") ? u.toString() : `${u.toString()}/`;
  } catch {
    return null;
  }
}

/** The server's largest places answer (places_in_view p_limit default). */
export const FILE_VIEW_CAP = 800;

/* ------------------------------------------------------------------ */
/* place_files in the RPC answer                                        */
/* ------------------------------------------------------------------ */

export interface PlaceFilesInfo {
  rules: string;
  rulesVersion: number;
  tiles: { id: number; path: string; count: number }[];
  /** OSM refs hidden, closed or removed since their file was built. */
  hidden: Set<string>;
  /** How many entries at the start of `hubs` are the selected hubs. */
  sel: number;
  /** Every specific hub (signed out, no chip picked). */
  all: boolean;
}

const TILE_PATH = /^places\/v[0-9]{1,4}\/([0-9]{1,6})\.[0-9a-f]{16}\.json\.gz$/;
const RULES_PATH = /^rules\/v[0-9]{1,4}\.[0-9a-f]{16}\.json\.gz$/;
const OSM_REF = /^[nwr][0-9]{1,15}$/;

/** `place_files` (migration 42) to an object, or null when absent or malformed. */
export function decodePlaceFiles(raw: unknown): PlaceFilesInfo | null {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return null;
  const r = raw as Record<string, unknown>;
  if (typeof r.rules !== "string" || !RULES_PATH.test(r.rules)) return null;
  if (!Array.isArray(r.tiles)) return null;
  const tiles: PlaceFilesInfo["tiles"] = [];
  for (const t of r.tiles) {
    if (!Array.isArray(t)) return null;
    const [id, path, count] = t as unknown[];
    const m = typeof path === "string" ? TILE_PATH.exec(path) : null;
    if (!Number.isInteger(id) || !m || Number(m[1]) !== id) return null;
    tiles.push({ id: id as number, path: path as string, count: Number(count) || 0 });
  }
  if (tiles.length === 0) return null;
  const hidden = new Set(
    (Array.isArray(r.hidden) ? r.hidden : []).filter(
      (x): x is string => typeof x === "string" && OSM_REF.test(x),
    ),
  );
  return {
    rules: r.rules,
    rulesVersion: Number(r.rules_version) || 1,
    tiles,
    hidden,
    sel: Number.isInteger(r.sel) ? (r.sel as number) : 0,
    all: r.all === true,
  };
}

/* ------------------------------------------------------------------ */
/* File formats (v1)                                                    */
/* ------------------------------------------------------------------ */

export interface FileRow {
  osmRef: string;
  lng: number;
  lat: number;
  kind: string;
  name: string;
  ruleIds: number[];
  address: string | null;
  locality: string | null;
  hours: string | null;
  website: string | null;
  tags: Record<string, string>;
}

export interface TileFile {
  tile: number;
  rulesVersion: number;
  rows: FileRow[];
}

export interface RulesHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  mode: "specific" | "generic";
  rules: Set<number>;
}

export interface RulesFile {
  rulesVersion: number;
  hubs: Map<string, RulesHub>;
  /** Every specific hub's rules: what a signed-out view with no chip shows. */
  specificRules: Set<number>;
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

function decodeRow(r: unknown): FileRow | null {
  if (!Array.isArray(r) || r.length < 6) return null;
  const [ref, lng, lat, kind, name, rules, address, locality, hours, website, tags] =
    r as unknown[];
  if (typeof ref !== "string" || !OSM_REF.test(ref)) return null;
  if (typeof lng !== "number" || typeof lat !== "number") return null;
  if (!(lng >= -180 && lng <= 180 && lat >= -90 && lat <= 90)) return null;
  const ruleIds = Array.isArray(rules) ? rules.filter((x): x is number => Number.isInteger(x)) : [];
  if (!ruleIds.length || typeof name !== "string" || !name) return null;
  const web = str(website);
  return {
    osmRef: ref,
    lng,
    lat,
    kind: str(kind) ?? "spot",
    name,
    ruleIds,
    address: str(address),
    locality: str(locality),
    hours: str(hours),
    website: web && /^https?:\/\//.test(web) ? web : null,
    tags:
      tags && typeof tags === "object" && !Array.isArray(tags)
        ? Object.fromEntries(
            Object.entries(tags as Record<string, unknown>).filter(
              (e): e is [string, string] => typeof e[1] === "string",
            ),
          )
        : {},
  };
}

/** A tile file's JSON to rows; malformed rows are dropped, a wrong format throws. */
export function decodeTileFile(json: unknown): TileFile {
  const d = json as Record<string, unknown> | null;
  if (!d || d.v !== 1 || !Array.isArray(d.rows) || !Number.isInteger(d.tile)) {
    throw new Error("place file: unknown format");
  }
  const rows: FileRow[] = [];
  for (const r of d.rows) {
    const row = decodeRow(r);
    if (row) rows.push(row);
  }
  return { tile: d.tile as number, rulesVersion: Number(d.rules_version) || 1, rows };
}

export function decodeRulesFile(json: unknown): RulesFile {
  const d = json as Record<string, unknown> | null;
  if (!d || d.v !== 1 || !Array.isArray(d.hubs)) throw new Error("rules file: unknown format");
  const hubs = new Map<string, RulesHub>();
  const specificRules = new Set<number>();
  for (const h of d.hubs) {
    if (!Array.isArray(h)) continue;
    const [id, slug, name, emoji, mode, rules] = h as unknown[];
    if (typeof id !== "string" || (mode !== "specific" && mode !== "generic")) continue;
    const set = new Set(
      (Array.isArray(rules) ? rules : []).filter((x): x is number => Number.isInteger(x)),
    );
    hubs.set(id, {
      id,
      slug: str(slug) ?? "",
      name: str(name) ?? "",
      emoji: typeof emoji === "string" ? emoji : "",
      mode,
      rules: set,
    });
    if (mode === "specific") set.forEach((r) => specificRules.add(r));
  }
  return { rulesVersion: Number(d.rules_version) || 1, hubs, specificRules };
}

/* ------------------------------------------------------------------ */
/* Fetching                                                             */
/* ------------------------------------------------------------------ */

/** Reads a file body: gzip (GitHub Pages serves the .gz as is) or already-decoded JSON (R2). */
export async function readJsonBody(body: ArrayBuffer | Uint8Array): Promise<unknown> {
  const bytes = body instanceof Uint8Array ? body : new Uint8Array(body);
  let text: string;
  if (bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
    const stream = new Blob([bytes as BlobPart])
      .stream()
      .pipeThrough(new DecompressionStream("gzip"));
    text = await new Response(stream).text();
  } else {
    text = new TextDecoder().decode(bytes);
  }
  return JSON.parse(text);
}

export interface PlaceFileLoader {
  /** The parsed JSON of a published path (places/... or rules/...). */
  load(path: string): Promise<unknown>;
}

/**
 * Fetches from the base URL and keeps the parsed files in memory (the names are content hashes,
 * so nothing ever goes stale). At most `max` files are kept, least recently used dropped.
 */
export function fetchLoader(
  base: string,
  max = 24,
  fetchFn: typeof fetch = fetch,
): PlaceFileLoader {
  const cache = new Map<string, Promise<unknown>>();
  return {
    load(path) {
      const hit = cache.get(path);
      if (hit) {
        cache.delete(path);
        cache.set(path, hit);
        return hit;
      }
      const p = (async () => {
        const res = await fetchFn(new URL(path, base).toString(), { credentials: "omit" });
        if (!res.ok) throw new Error(`place file: HTTP ${res.status}`);
        return readJsonBody(await res.arrayBuffer());
      })();
      p.catch(() => cache.delete(path));
      cache.set(path, p);
      while (cache.size > max) cache.delete(cache.keys().next().value as string);
      return p;
    },
  };
}

let shared: { base: string; loader: PlaceFileLoader } | null = null;

/** One loader per base URL for the app's lifetime. */
export function sharedLoader(base: string): PlaceFileLoader {
  if (shared?.base !== base) shared = { base, loader: fetchLoader(base) };
  return shared.loader;
}

/* ------------------------------------------------------------------ */
/* Matching (places_in_view's rules, on the client)                     */
/* ------------------------------------------------------------------ */

function inBBox(b: BBox, p: LngLat): boolean {
  if (p.lat < b.south || p.lat > b.north) return false;
  return b.west <= b.east ? p.lng >= b.west && p.lng <= b.east : p.lng >= b.west || p.lng <= b.east;
}

/** The view centre places_in_view measures from (planar degrees, as the KNN index does). */
function planarDistance(b: BBox, p: LngLat): number {
  const span = b.west <= b.east ? b.east - b.west : 180 - b.west + (b.east + 180);
  const cLng = b.west + span / 2;
  const cLat = (b.south + b.north) / 2;
  let dx = p.lng - cLng;
  if (dx > 180) dx -= 360;
  if (dx < -180) dx += 360;
  return Math.hypot(dx, p.lat - cLat);
}

/** The registry the place card reads for a place opened from a file (no database row). */
const fileRows = new Map<string, FileRow>();
let lastRules: RulesFile | null = null;

export const FILE_PLACE_PREFIX = "o:";

export function filePlaceId(osmRef: string): string {
  return `${FILE_PLACE_PREFIX}${osmRef}`;
}

export function osmRefOfPlaceId(id: string): string | null {
  if (!id.startsWith(FILE_PLACE_PREFIX)) return null;
  const ref = id.slice(FILE_PLACE_PREFIX.length);
  return OSM_REF.test(ref) ? ref : null;
}

export interface FileMatchContext {
  info: PlaceFilesInfo;
  rules: RulesFile;
  /** The decoded `hubs` of the same answer (selected hubs first). */
  hubs: readonly MapHub[];
  /** The answer's `generic` (one generic hub chip with its general spots on). */
  generic: boolean;
  bbox: BBox;
}

/**
 * File rows to map features, as places_in_view would encode them: matched against the selected
 * hubs' rules (specific hubs, plus a generic hub's when its spots are on), or every specific
 * hub's when `all`; hubIds the matching selected hubs in order; the general flag when the one
 * generic hub is on. Only rows inside the bbox.
 */
export function matchFileRows(rows: readonly FileRow[], ctx: FileMatchContext): MapFeature[] {
  const sel = ctx.hubs.slice(0, ctx.info.sel).map((h) => {
    const r = ctx.rules.hubs.get(h.id);
    const on = r && (r.mode === "specific" || (r.mode === "generic" && ctx.generic));
    return { id: h.id, rules: on ? r.rules : new Set<number>() };
  });
  const out: MapFeature[] = [];
  for (const row of rows) {
    if (!inBBox(ctx.bbox, row)) continue;
    let hubIds: string[];
    if (ctx.info.all) {
      if (!row.ruleIds.some((r) => ctx.rules.specificRules.has(r))) continue;
      hubIds = [];
    } else {
      hubIds = sel.filter((s) => row.ruleIds.some((r) => s.rules.has(r))).map((s) => s.id);
      if (!hubIds.length) continue;
    }
    fileRows.set(row.osmRef, row);
    const flags = ctx.generic ? PLACE_FLAG.GENERAL : 0;
    out.push({
      id: filePlaceId(row.osmRef),
      kind: "place",
      lng: row.lng,
      lat: row.lat,
      type: row.kind,
      hubId: hubIds[0] ?? null,
      hubIds,
      flags,
      name: row.name,
      startsAt: null,
      generic: ctx.generic,
      imported: false,
      pending: false,
      geoapify: false,
      mine: false,
      private: false,
      free: false,
      adultsOnly: false,
      osmRef: row.osmRef,
    });
  }
  return out;
}

/**
 * Database places plus file places: database rows first win by osm_ref, hidden refs go, then the
 * viewer's own pins first and the rest nearest the centre, capped like the server.
 */
export function mergeFilePlaces(
  view: MapView,
  filePlaces: readonly MapFeature[],
  info: PlaceFilesInfo,
  bbox: BBox,
  cap = FILE_VIEW_CAP,
): MapView {
  const fromDb = new Set(view.places.map((p) => p.osmRef).filter((r): r is string => Boolean(r)));
  const seen = new Set<string>();
  const extra = filePlaces.filter((f) => {
    const ref = f.osmRef as string;
    if (fromDb.has(ref) || info.hidden.has(ref) || seen.has(ref)) return false;
    seen.add(ref);
    return true;
  });
  const all = [...view.places, ...extra]
    .map((p) => ({ p, d: planarDistance(bbox, p) - (p.mine ? 1000 : 0) }))
    .sort((a, b) => a.d - b.d || (a.p.id < b.p.id ? -1 : a.p.id > b.p.id ? 1 : 0))
    .map((x) => x.p);
  return {
    ...view,
    places: all.slice(0, cap),
    truncated: view.truncated || all.length > cap,
  };
}

/**
 * Loads the rules and tile files of an answer and merges them into its view. Throws when a file
 * cannot be read (the caller then asks again without files).
 */
export async function withFilePlaces(
  view: MapView,
  info: PlaceFilesInfo,
  bbox: BBox,
  loader: PlaceFileLoader,
): Promise<MapView> {
  const [rulesJson, ...tileJson] = await Promise.all([
    loader.load(info.rules),
    ...info.tiles.map((t) => loader.load(t.path)),
  ]);
  const rules = decodeRulesFile(rulesJson);
  lastRules = rules;
  const ctx: FileMatchContext = { info, rules, hubs: view.hubs, generic: view.generic, bbox };
  const filePlaces = tileJson.flatMap((j) => matchFileRows(decodeTileFile(j).rows, ctx));
  return mergeFilePlaces(view, filePlaces, info, bbox);
}

/* ------------------------------------------------------------------ */
/* Place card for a file place with no database row                     */
/* ------------------------------------------------------------------ */

/** The card from the file alone (after slice 11 removes OSM rows from Postgres). */
export function filePlaceDetail(osmRef: string): PlaceDetail | null {
  const row = fileRows.get(osmRef);
  if (!row) return null;
  const hubs: PlaceDetailHub[] = [];
  for (const h of lastRules?.hubs.values() ?? []) {
    if (row.ruleIds.some((r) => h.rules.has(r))) {
      hubs.push({
        id: h.id,
        slug: h.slug,
        name: h.name,
        emoji: h.emoji,
        general: h.mode === "generic",
        joined: false,
      });
    }
  }
  hubs.sort((a, b) => Number(a.general) - Number(b.general) || a.name.localeCompare(b.name));
  const type = osmRef[0] === "n" ? "node" : osmRef[0] === "w" ? "way" : "relation";
  return {
    id: filePlaceId(osmRef),
    name: row.name,
    kind: row.kind,
    kindLabel: placeKindInfo(row.kind).label,
    lng: row.lng,
    lat: row.lat,
    hubs: hubs.slice(0, 12),
    moreHubs: hubs.length > 12,
    address: row.address,
    locality: row.locality,
    hours: row.hours,
    website: row.website,
    source: "osm",
    osmUrl: `https://www.openstreetmap.org/${type}/${osmRef.slice(1)}`,
    checkedAt: null,
    reviewed: false,
    pending: false,
    private: false,
    mine: false,
    generic: hubs.length > 0 && hubs.every((h) => h.general),
    plansHere: [],
  };
}

/** Test hook: forget the rows and rules seen so far. */
export function resetFilePlaces(): void {
  fileRows.clear();
  lastRules = null;
}
