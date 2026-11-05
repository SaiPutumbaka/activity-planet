// Steps 2 and 3 of venue geocoding (design 2.5): Geoapify (only with GEOAPIFY_SERVER_KEY, within
// its daily budget), then Nominatim under its usage policy, with Photon as the fallback when
// Nominatim answers 429 or 5xx. Every request goes through the PoliteFetcher's API lane: https
// only, public hosts only, the denylist, the identifying User-Agent with the /bot contact URL, no
// cache (answers are cached in venue_geocodes instead), and one request per 2 seconds per host,
// which keeps Nominatim under its 1 a second. Requests are bounded to the region's box.

import type { Fetcher } from "../net/fetcher.ts";

export interface Region {
  lat: number;
  lng: number;
  radius_km: number;
}

export type GeoAnswer =
  | { kind: "hit"; lat: number; lng: number; place_ref: string | null; confidence: number | null }
  | { kind: "none" }
  | { kind: "unavailable"; status?: number; reason: string };

/** The region's bounding box: [minLng, minLat, maxLng, maxLat]. */
export function bbox(r: Region): [number, number, number, number] {
  const dLat = r.radius_km / 111.32;
  const cos = Math.max(0.01, Math.cos((r.lat * Math.PI) / 180));
  const dLng = Math.min(180, r.radius_km / (111.32 * cos));
  const f = (x: number) => Math.round(x * 10000) / 10000;
  return [
    f(Math.max(-180, r.lng - dLng)),
    f(Math.max(-90, r.lat - dLat)),
    f(Math.min(180, r.lng + dLng)),
    f(Math.min(90, r.lat + dLat)),
  ];
}

export const NOMINATIM = "https://nominatim.openstreetmap.org/search";
export const PHOTON = "https://photon.komoot.io/api/";
export const GEOAPIFY = "https://api.geoapify.com/v1/geocode/search";

export function nominatimUrl(text: string, r: Region): string {
  const [w, s, e, n] = bbox(r);
  const u = new URL(NOMINATIM);
  u.searchParams.set("q", text);
  u.searchParams.set("format", "jsonv2");
  u.searchParams.set("limit", "1");
  // viewbox is x1,y1,x2,y2 (left, top, right, bottom); bounded=1 keeps answers inside it.
  u.searchParams.set("viewbox", `${w},${n},${e},${s}`);
  u.searchParams.set("bounded", "1");
  return u.toString();
}

export function photonUrl(text: string, r: Region): string {
  const [w, s, e, n] = bbox(r);
  const u = new URL(PHOTON);
  u.searchParams.set("q", text);
  u.searchParams.set("limit", "1");
  u.searchParams.set("bbox", `${w},${s},${e},${n}`);
  return u.toString();
}

export function geoapifyUrl(text: string, r: Region, key: string): string {
  const [w, s, e, n] = bbox(r);
  const u = new URL(GEOAPIFY);
  u.searchParams.set("text", text);
  u.searchParams.set("filter", `rect:${w},${s},${e},${n}`);
  u.searchParams.set("limit", "1");
  u.searchParams.set("format", "json");
  u.searchParams.set("apiKey", key);
  return u.toString();
}

const num = (v: unknown): number | null => {
  const n = typeof v === "string" ? Number(v) : typeof v === "number" ? v : NaN;
  return Number.isFinite(n) ? n : null;
};
const clamp01 = (v: number | null) => (v === null ? null : Math.max(0, Math.min(1, v)));
const ref = (type: unknown, id: unknown): string | null => {
  const t = typeof type === "string" ? type.slice(0, 1).toLowerCase() : "";
  const i = typeof id === "number" || typeof id === "string" ? String(id) : "";
  return /^[nwr]$/.test(t) && /^[0-9]{1,15}$/.test(i) ? `osm:${t}${i}` : null;
};

export function parseNominatim(body: string): GeoAnswer {
  const rows = JSON.parse(body) as unknown;
  const first = Array.isArray(rows) ? (rows[0] as Record<string, unknown> | undefined) : undefined;
  if (!first) return { kind: "none" };
  const lat = num(first.lat);
  const lng = num(first.lon);
  if (lat === null || lng === null) return { kind: "none" };
  return {
    kind: "hit",
    lat,
    lng,
    place_ref: ref(first.osm_type, first.osm_id),
    confidence: clamp01(num(first.importance)),
  };
}

export function parsePhoton(body: string): GeoAnswer {
  const root = JSON.parse(body) as { features?: unknown };
  const f = Array.isArray(root.features)
    ? (root.features[0] as Record<string, unknown> | undefined)
    : undefined;
  const coords = (f?.geometry as { coordinates?: unknown } | undefined)?.coordinates;
  if (!Array.isArray(coords)) return { kind: "none" };
  const lng = num(coords[0]);
  const lat = num(coords[1]);
  if (lat === null || lng === null) return { kind: "none" };
  const p = (f?.properties ?? {}) as Record<string, unknown>;
  return { kind: "hit", lat, lng, place_ref: ref(p.osm_type, p.osm_id), confidence: null };
}

export function parseGeoapify(body: string): GeoAnswer {
  const root = JSON.parse(body) as { results?: unknown };
  const r = Array.isArray(root.results)
    ? (root.results[0] as Record<string, unknown> | undefined)
    : undefined;
  if (!r) return { kind: "none" };
  const lat = num(r.lat);
  const lng = num(r.lon);
  if (lat === null || lng === null) return { kind: "none" };
  const conf = num((r.rank as Record<string, unknown> | undefined)?.confidence);
  return { kind: "hit", lat, lng, place_ref: null, confidence: clamp01(conf) };
}

/** One provider request: a hit, no result, or unavailable (an error, 429, 5xx). */
export async function ask(
  fetcher: Pick<Fetcher, "get">,
  url: string,
  parse: (body: string) => GeoAnswer,
): Promise<GeoAnswer> {
  const res = await fetcher.get(url, { api: true, accept: "application/json" });
  if (!res.ok) return { kind: "unavailable", status: res.status, reason: res.reason };
  try {
    return parse(res.body);
  } catch {
    return { kind: "unavailable", reason: "bad_json" };
  }
}
