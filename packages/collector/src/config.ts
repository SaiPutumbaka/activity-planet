// City seed files (data/cities/<id>.json) and region lists. A city file names one region and
// the public calendars, feeds and open-data layers in it; see docs/design/collector.md.

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import type { CityFile, Region, Seed, SeedKind } from "./types.ts";
import { haversineKm } from "./util/geo.ts";
import { isValidZone } from "./util/time.ts";

export const CITIES_DIR = fileURLToPath(new URL("../data/cities/", import.meta.url));

const KINDS: SeedKind[] = ["page", "ics", "rss", "localist", "socrata", "arcgis"];

export function validateRegion(r: unknown, where: string): Region {
  const o = (r ?? {}) as Record<string, unknown>;
  const fail = (msg: string): never => {
    throw new Error(`${where}: ${msg}`);
  };
  if (typeof o.id !== "string" || !/^[a-z0-9-]{2,40}$/.test(o.id))
    fail("region id must be 2-40 of a-z, 0-9, -");
  if (typeof o.label !== "string" || o.label.trim() === "") fail("region label required");
  if (typeof o.lat !== "number" || o.lat < -90 || o.lat > 90) fail("region lat must be -90..90");
  if (typeof o.lng !== "number" || o.lng < -180 || o.lng > 180)
    fail("region lng must be -180..180");
  if (typeof o.radiusKm !== "number" || o.radiusKm <= 0 || o.radiusKm > 300)
    fail("region radiusKm must be 0..300");
  if (o.timezone !== undefined && (typeof o.timezone !== "string" || !isValidZone(o.timezone))) {
    fail(`unknown timezone ${String(o.timezone)}`);
  }
  return o as unknown as Region;
}

export function validateSeed(s: unknown, where: string): Seed {
  const o = (s ?? {}) as Record<string, unknown>;
  const fail = (msg: string): never => {
    throw new Error(`${where}: seed ${String(o.id ?? "?")}: ${msg}`);
  };
  if (typeof o.id !== "string" || !/^[a-z0-9-]{3,60}$/.test(o.id))
    fail("id must be 3-60 of a-z, 0-9, -");
  if (!KINDS.includes(o.kind as SeedKind)) fail(`kind must be one of ${KINDS.join(", ")}`);
  if (typeof o.url !== "string" || !o.url.startsWith("https://")) fail("url must be https");
  if (typeof o.name !== "string" || o.name.length < 2 || o.name.length > 80)
    fail("name must be 2-80 characters");
  if (
    typeof o.attribution !== "string" ||
    o.attribution.length < 10 ||
    o.attribution.length > 300
  ) {
    fail("attribution must be 10-300 characters");
  }
  if (o.verified !== undefined && typeof o.verified !== "boolean")
    fail("verified must be true or false");
  if (o.crawlPages !== undefined && typeof o.crawlPages !== "boolean")
    fail("crawlPages must be true or false");
  if (
    o.hubs !== undefined &&
    (!Array.isArray(o.hubs) ||
      o.hubs.length > 5 ||
      o.hubs.some(
        (h) => typeof h !== "string" || !/^[a-z0-9]+(-[a-z0-9]+)*$/.test(h) || h.length > 80,
      ))
  ) {
    fail("hubs must be at most 5 hub slugs");
  }
  if (
    (o.kind === "socrata" || o.kind === "arcgis") &&
    (!o.fields || typeof o.fields !== "object")
  ) {
    fail("open-data seeds need a fields map with at least title and start");
  }
  return o as unknown as Seed;
}

export function parseCityFile(text: string, where: string): CityFile {
  const data = JSON.parse(text) as Record<string, unknown>;
  const region = validateRegion(data.region, where);
  const seeds = (Array.isArray(data.seeds) ? data.seeds : []).map((s, i) =>
    validateSeed(s, `${where}[${i}]`),
  );
  const ids = new Set<string>();
  for (const s of seeds) {
    if (ids.has(s.id)) throw new Error(`${where}: duplicate seed id ${s.id}`);
    ids.add(s.id);
  }
  return { region, seeds };
}

export function loadCities(dir: string = CITIES_DIR): CityFile[] {
  return readdirSync(dir)
    .filter((f) => f.endsWith(".json"))
    .sort()
    .map((f) => parseCityFile(readFileSync(join(dir, f), "utf8"), f));
}

export function loadRegions(path: string): Region[] {
  const data = JSON.parse(readFileSync(path, "utf8")) as unknown;
  const list = Array.isArray(data)
    ? data
    : ((data as Record<string, unknown>).regions as unknown[]);
  if (!Array.isArray(list)) throw new Error(`${path}: expected an array of regions`);
  return list.map((r, i) => validateRegion(r, `${path}[${i}]`));
}

/** Cities whose area overlaps a region: the seeds that can have events inside it. */
export function citiesFor(region: Region, cities: CityFile[]): CityFile[] {
  return cities.filter(
    (c) =>
      haversineKm(c.region.lat, c.region.lng, region.lat, region.lng) <=
      c.region.radiusKm + region.radiusKm,
  );
}
