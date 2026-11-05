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

const MONTHS = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

/**
 * A start (and end) written as text, the way some city calendars publish it: "November 7 2026
 * 9 - 10 a.m.", "Nov 14, 2026 10 - 11:30 a.m.", "Saturday, Nov 14 2026 7:30 p.m.", "Nov 14 2026"
 * (all day). The first date of the text is read (a list of dates starts with the next one).
 * Floating local times ("YYYY-MM-DDTHH:mm:00"), read in the dataset's zone; null when unreadable.
 */
export function parseTextDateRange(
  text: string,
): { start: string; end: string | null; allDay: boolean } | null {
  const m =
    /(?:^|[\s,>])([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})(?:,?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?|noon)?(?:\s*(?:-|–|to)\s*(\d{1,2})(?::(\d{2}))?\s*(a\.?\s?m\.?|p\.?\s?m\.?|noon)?)?)?/i.exec(
      text,
    );
  if (!m) return null;
  const month = MONTHS.indexOf(m[1]!.slice(0, 3).toLowerCase());
  if (month < 0) return null;
  const day = Number(m[2]);
  const year = Number(m[3]);
  if (day < 1 || day > 31) return null;
  const date = `${year}-${String(month + 1).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
  if (m[4] === undefined) return { start: date, end: null, allDay: true };
  type Mer = "am" | "pm" | null;
  const mer = (v: string | undefined): Mer => (v ? (/^p|noon/i.test(v) ? "pm" : "am") : null);
  const to24 = (h: number, mm: number, md: Mer) => {
    if (md === "pm" && h < 12) h += 12;
    if (md === "am" && h === 12) h = 0;
    return h * 60 + mm;
  };
  const endMer = mer(m[9]);
  let startMer: Mer = mer(m[6]) ?? endMer;
  const sh = Number(m[4]);
  const sm = Number(m[5] ?? "0");
  let start = to24(sh, sm, startMer);
  let end: number | null = null;
  if (m[7] !== undefined) {
    end = to24(Number(m[7]), Number(m[8] ?? "0"), endMer);
    // "11 - 1 p.m.": the start is in the morning.
    if (!m[6] && endMer === "pm" && start > end) {
      startMer = "am";
      start = to24(sh, sm, startMer);
    }
  }
  if (start >= 24 * 60 || (end !== null && end >= 24 * 60)) return null;
  const t = (mins: number) =>
    `${String(Math.floor(mins / 60)).padStart(2, "0")}:${String(mins % 60).padStart(2, "0")}:00`;
  return {
    start: `${date}T${t(start)}`,
    end: end !== null && end > start ? `${date}T${t(end)}` : null,
    allDay: false,
  };
}

export function socrataUrl(seed: Seed, region: Region, window: ApiWindow, limit = 1000): string {
  const f = seed.fields;
  if (!f) throw new Error(`seed ${seed.id}: socrata needs fields`);
  const u = new URL(seed.url);
  // A text start column cannot be compared server-side; the window is applied after parsing.
  const where =
    f.startFormat === "text_range"
      ? []
      : [`${f.start} >= '${sodaTime(window.start)}'`, `${f.start} < '${sodaTime(window.end)}'`];
  if (f.where) where.push(`(${f.where})`);
  if (seed.geoColumn) {
    where.push(
      `within_circle(${seed.geoColumn}, ${region.lat}, ${region.lng}, ${Math.round(region.radiusKm * 1000)})`,
    );
  }
  if (where.length > 0) u.searchParams.set("$where", where.join(" AND "));
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
  let start = timeValue(pick(row, f.start));
  let textEnd: string | null = null;
  let allDay = false;
  if (f.startFormat === "text_range") {
    const r = start ? parseTextDateRange(start) : null;
    start = r?.start ?? null;
    textEnd = r?.end ?? null;
    allDay = r?.allDay ?? false;
  }
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
    end: f.startFormat === "text_range" ? textEnd : f.end ? timeValue(pick(row, f.end)) : null,
    ...(allDay ? { allDay: true } : {}),
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
