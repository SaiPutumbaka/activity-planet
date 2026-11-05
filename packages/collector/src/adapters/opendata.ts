// Lane 1, city open-data portals: Socrata (SODA) datasets and ArcGIS feature layers that list
// events. Each seed names its columns in a field map, because every city names them
// differently. Requests are filtered to the region server-side where the portal can do it.

import type { FieldMap, RawEvent, Region, Seed } from "../types.ts";
import { htmlToText, num, pick, str } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";
import type { ApiWindow } from "./api.ts";

type Obj = Record<string, unknown>;

/** A Socrata floating timestamp ("2026-11-10T19:00:00.000") for a $where bound. */
function sodaTime(d: Date): string {
  return d.toISOString().slice(0, 19);
}

export function socrataUrl(seed: Seed, region: Region, window: ApiWindow, limit = 1000): string {
  const f = seed.fields;
  if (!f) throw new Error(`seed ${seed.id}: socrata needs fields`);
  const u = new URL(seed.url);
  const where = [
    `${f.start} >= '${sodaTime(window.start)}'`,
    `${f.start} < '${sodaTime(window.end)}'`,
  ];
  if (f.where) where.push(`(${f.where})`);
  if (seed.geoColumn) {
    where.push(
      `within_circle(${seed.geoColumn}, ${region.lat}, ${region.lng}, ${Math.round(region.radiusKm * 1000)})`,
    );
  }
  u.searchParams.set("$where", where.join(" AND "));
  u.searchParams.set("$order", f.start);
  u.searchParams.set("$limit", String(limit));
  return u.toString();
}

export function arcgisUrl(seed: Seed, region: Region, limit = 1000): string {
  const base = seed.url.replace(/\/+$/, "").replace(/\/query$/, "");
  const u = new URL(`${base}/query`);
  u.searchParams.set("where", seed.fields?.where ? seed.fields.where : "1=1");
  u.searchParams.set("outFields", "*");
  u.searchParams.set("returnGeometry", "true");
  u.searchParams.set("outSR", "4326");
  u.searchParams.set("geometry", `${region.lng},${region.lat}`);
  u.searchParams.set("geometryType", "esriGeometryPoint");
  u.searchParams.set("inSR", "4326");
  u.searchParams.set("spatialRel", "esriSpatialRelIntersects");
  u.searchParams.set("distance", String(Math.round(region.radiusKm * 1000)));
  u.searchParams.set("units", "esriSRUnit_Meter");
  u.searchParams.set("resultRecordCount", String(limit));
  u.searchParams.set("f", "json");
  return u.toString();
}

/** Epoch milliseconds (ArcGIS date fields) or a date string. */
function timeValue(v: unknown): string | null {
  if (typeof v === "number" && Number.isFinite(v)) return new Date(v).toISOString();
  return str(v);
}

function rowToRaw(
  row: Obj,
  f: FieldMap,
  seed: Seed,
  sourceUrl: string,
  point?: { x?: unknown; y?: unknown },
): RawEvent | null {
  const start = timeValue(pick(row, f.start));
  if (!start) return null;
  const urlValue = f.url ? pick(row, f.url) : undefined;
  const url =
    httpsUrl(typeof urlValue === "object" && urlValue ? (urlValue as Obj).url : urlValue) ?? null;
  // Socrata location columns are {latitude, longitude} or GeoJSON points.
  let lat = f.lat ? num(pick(row, f.lat)) : null;
  let lng = f.lng ? num(pick(row, f.lng)) : null;
  if (lat === null && seed.geoColumn) {
    const g = pick(row, seed.geoColumn) as Obj | undefined;
    if (g && typeof g === "object") {
      const coords = Array.isArray(g.coordinates) ? g.coordinates : null;
      lat = coords ? num(coords[1]) : num(g.latitude);
      lng = coords ? num(coords[0]) : num(g.longitude);
    }
  }
  if (lat === null && point) {
    lat = num(point.y);
    lng = num(point.x);
  }
  const category = f.category ? str(pick(row, f.category)) : null;
  return {
    lane: "api",
    uid: f.id ? str(pick(row, f.id)) : null,
    title: htmlToText(str(pick(row, f.title)) ?? ""),
    description: htmlToText(f.description ? (str(pick(row, f.description)) ?? "") : ""),
    url,
    start,
    end: f.end ? timeValue(pick(row, f.end)) : null,
    location: f.location ? (str(pick(row, f.location)) ?? "") : "",
    lat,
    lng,
    categories: [...(seed.categories ?? []), ...(category ? [category] : [])],
    host: seed.host_org ?? null,
    sourceUrl,
  };
}

export function parseSocrata(body: string, seed: Seed): RawEvent[] {
  const rows = JSON.parse(body) as unknown;
  if (!Array.isArray(rows) || !seed.fields) return [];
  return rows
    .map((r) =>
      r && typeof r === "object"
        ? rowToRaw(r as Obj, seed.fields as FieldMap, seed, seed.url)
        : null,
    )
    .filter((r): r is RawEvent => r !== null);
}

export function parseArcgis(body: string, seed: Seed): RawEvent[] {
  const root = JSON.parse(body) as Obj;
  const features = Array.isArray(root.features) ? root.features : [];
  if (!seed.fields) return [];
  const out: RawEvent[] = [];
  for (const f of features) {
    const feat = (f ?? {}) as Obj;
    // f=json puts columns under attributes; f=geojson under properties.
    const row = (feat.attributes ?? feat.properties ?? {}) as Obj;
    const geom = (feat.geometry ?? {}) as Obj;
    const coords = Array.isArray(geom.coordinates) ? geom.coordinates : null;
    const point = coords ? { x: coords[0], y: coords[1] } : { x: geom.x, y: geom.y };
    const raw = rowToRaw(row, seed.fields, seed, seed.url, point);
    if (raw) out.push(raw);
  }
  return out;
}
