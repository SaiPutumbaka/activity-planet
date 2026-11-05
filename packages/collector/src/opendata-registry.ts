// The open-data event datasets (design 2.7): data/opendata/*.json, one dataset per entry, each
// with a bounding box, the zone of its times, kind socrata | arcgis, the endpoint, the field map
// (with an optional `where` filter), the licence (name and URL, read by a person before the
// dataset is switched on), the attribution line, verified and a note. Any run region whose circle
// overlaps a dataset's box gets it as a lane 1 seed, the way city files contribute seeds, so a
// dataset serves the people near it without a city file. The scout (opendata-scout.ts) finds
// candidates; a person adds them here.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { validateSeed } from "./config.ts";
import type { CityFile, Region, Seed } from "./types.ts";
import { haversineKm } from "./util/geo.ts";
import { isValidZone } from "./util/time.ts";

export const OPENDATA_DIR = fileURLToPath(new URL("../data/opendata/", import.meta.url));

/** [minLng, minLat, maxLng, maxLat] */
export type Bbox = [number, number, number, number];

export interface Dataset extends Seed {
  kind: "socrata" | "arcgis";
  bbox: Bbox;
  timezone?: string;
  licence: { name: string; url: string };
}

export function validateDataset(d: unknown, where: string): Dataset {
  const o = (d ?? {}) as Record<string, unknown>;
  const fail = (msg: string): never => {
    throw new Error(`${where}: dataset ${String(o.id ?? "?")}: ${msg}`);
  };
  if (o.kind !== "socrata" && o.kind !== "arcgis") fail("kind must be socrata or arcgis");
  const seed = validateSeed(o, where);
  const b = o.bbox;
  if (
    !Array.isArray(b) ||
    b.length !== 4 ||
    b.some((x) => typeof x !== "number" || !Number.isFinite(x)) ||
    (b[0] as number) < -180 ||
    (b[2] as number) > 180 ||
    (b[1] as number) < -90 ||
    (b[3] as number) > 90 ||
    (b[0] as number) >= (b[2] as number) ||
    (b[1] as number) >= (b[3] as number)
  )
    fail("bbox must be [minLng, minLat, maxLng, maxLat]");
  const lic = (o.licence ?? {}) as Record<string, unknown>;
  if (typeof lic.name !== "string" || lic.name.trim().length < 3) fail("licence name required");
  if (typeof lic.url !== "string" || !lic.url.startsWith("https://"))
    fail("licence url must be https");
  if (o.timezone !== undefined && (typeof o.timezone !== "string" || !isValidZone(o.timezone)))
    fail("unknown timezone");
  const f = seed.fields;
  if (!f || typeof f.title !== "string" || typeof f.start !== "string")
    fail("fields need title and start");
  if (
    f?.where !== undefined &&
    (typeof f.where !== "string" || f.where.length > 500 || /;|--/.test(f.where))
  )
    fail("fields.where must be one filter expression of at most 500 characters");
  if (f?.startFormat !== undefined && f.startFormat !== "text_range")
    fail("fields.startFormat must be text_range");
  if (typeof o.verified !== "boolean") fail("verified must be true or false");
  if (typeof o.note !== "string" || o.note.length < 10) fail("a note is required");
  return o as unknown as Dataset;
}

export function loadRegistry(dir: string = OPENDATA_DIR): Dataset[] {
  let files: string[];
  try {
    files = readdirSync(dir)
      .filter((f) => f.endsWith(".json"))
      .sort();
  } catch {
    return [];
  }
  const out: Dataset[] = [];
  const ids = new Set<string>();
  for (const f of files) {
    const data = JSON.parse(readFileSync(join(dir, f), "utf8")) as { datasets?: unknown };
    for (const [i, d] of (Array.isArray(data.datasets) ? data.datasets : []).entries()) {
      const ds = validateDataset(d, `${f}[${i}]`);
      if (ids.has(ds.id)) throw new Error(`${f}: duplicate dataset id ${ds.id}`);
      ids.add(ds.id);
      out.push(ds);
    }
  }
  return out;
}

/** Whether a region's circle reaches a box (nearest point of the box within the radius). */
export function circleOverlapsBbox(r: Pick<Region, "lat" | "lng" | "radiusKm">, b: Bbox): boolean {
  const lat = Math.min(Math.max(r.lat, b[1]), b[3]);
  const lng = Math.min(Math.max(r.lng, b[0]), b[2]);
  return haversineKm(r.lat, r.lng, lat, lng) <= r.radiusKm;
}

/**
 * A region that covers a dataset's box (its centre, the radius to the farthest corner), for a
 * diagnostic run of one dataset (`collect --dataset <id> --dry-run --diagnose`).
 */
export function datasetRegion(d: Dataset): Region {
  const lat = (d.bbox[1] + d.bbox[3]) / 2;
  const lng = (d.bbox[0] + d.bbox[2]) / 2;
  const radiusKm = Math.min(300, Math.ceil(haversineKm(lat, lng, d.bbox[3], d.bbox[2])));
  return {
    id: d.id.slice(0, 40),
    label: d.name,
    lat,
    lng,
    radiusKm,
    ...(d.timezone ? { timezone: d.timezone } : {}),
  };
}

/** A dataset as a seed: registry-only fields dropped, the licence kept in the note. */
export function datasetSeed(d: Dataset): Seed {
  const { bbox: _b, licence, timezone: _t, ...seed } = d;
  void _b;
  void _t;
  return { ...seed, note: `${d.note} Licence: ${licence.name}.` };
}

/**
 * The registry's datasets as city-file-shaped groups: each dataset once, with the first run
 * region (in run order) whose circle overlaps its box, so it is read once per run. A region
 * without a zone takes the dataset's.
 */
export function registrySeeds(regions: Region[], datasets: Dataset[] = loadRegistry()): CityFile[] {
  const out: CityFile[] = [];
  for (const d of datasets) {
    const r = regions.find((x) => circleOverlapsBbox(x, d.bbox));
    if (!r) continue;
    out.push({
      region: { ...r, seedsOnly: undefined, timezone: r.timezone ?? d.timezone },
      seeds: [datasetSeed(d)],
    });
  }
  return out;
}
