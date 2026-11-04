// Collector regions for the nightly event run (D-042 slice 6, docs/design/auto-coverage
// AUTO_COVERAGE_DESIGN.md 5.3). Coverage follows people: the collector_regions rows (a point
// rounded to 0.1 degree and a radius, no user id) are the run's regions. Each one gets the seeds
// of every hand-written city file that overlaps it (config.ts citiesFor) and the discovered
// sources the database lists for it (GET /collector/sources, D-042 slice 7; absent until then).
//
//   fetchRegions   GET  <base>/regions?due=1&limit=N  (collector_regions_due, migration 45)
//   fetchSources   GET  <base>/sources?regions=<ids>  (404 until slice 7: no discovered sources)
//   recordRegions  POST <base>/regions/record         (collector_regions_record)
//   recordSources  POST <base>/sources/record         (source_candidates_record, migration 46:
//                                                      each discovered source's run result, which
//                                                      moves it through probation to enabled)
//
// Nothing here prints a region's point: public logs carry counts and region ids only.

import tzlookup from "tz-lookup";
import { citiesFor, validateRegion, validateSeed } from "./config.ts";
import type { CityFile, Region, Seed, SourceBatch } from "./types.ts";
import { haversineKm } from "./util/geo.ts";
import { isValidZone } from "./util/time.ts";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** collector_regions_due's and collector_regions_record's largest list (migration 45). */
export const MAX_REGIONS = 100;
/** GET /collector/regions answers at most this many ids per sources request. */
const SOURCES_CHUNK = 25;

/** One entry of GET /collector/regions. */
export interface CollectorRegionRow {
  id: string;
  lat: number;
  lng: number;
  radius_km: number;
  label: string | null;
  timezone: string | null;
  priority: number;
  last_collected_at: string | null;
}

/** A run region made from a collector region, and whether its zone was looked up here. */
export interface ResolvedRegion {
  region: Region;
  /** The zone came from tz-lookup (the row had none): the record step stores it. */
  timezoneResolved: boolean;
}

/** The IANA zone at a point, offline (tz-lookup); null when the name is unusable here. */
export function zoneAt(lat: number, lng: number): string | null {
  try {
    const z = tzlookup(lat, lng);
    return typeof z === "string" && isValidZone(z) ? z : null;
  } catch {
    return null;
  }
}

/** Checks a GET /collector/regions entry and turns it into a run region. */
export function regionFromRow(row: unknown): ResolvedRegion {
  const o = (row ?? {}) as Record<string, unknown>;
  if (typeof o.id !== "string" || !UUID.test(o.id)) throw new Error("region row: bad id");
  const lat = o.lat;
  const lng = o.lng;
  const radius = o.radius_km;
  if (typeof lat !== "number" || typeof lng !== "number" || typeof radius !== "number")
    throw new Error(`region row ${o.id}: bad point or radius`);
  const stored = typeof o.timezone === "string" && isValidZone(o.timezone) ? o.timezone : null;
  const looked = stored ? null : zoneAt(lat, lng);
  const label =
    typeof o.label === "string" && o.label.trim() !== ""
      ? o.label.trim().slice(0, 120)
      : `Collector region ${o.id.slice(0, 8)}`;
  const region = validateRegion(
    {
      id: o.id,
      label,
      lat,
      lng,
      radiusKm: radius,
      ...((stored ?? looked) ? { timezone: stored ?? looked } : {}),
      collector: true,
    },
    `region ${o.id}`,
  );
  return { region, timezoneResolved: looked !== null };
}

/**
 * Adds the area of every city file that contains a collector region's centre, marked seedsOnly,
 * so a city's seeds keep their whole hand-drawn area (Atlanta's file is 60 km, its collector
 * region 50 km) while API adapters run once, for the collector region. Collector regions first,
 * in the order given; city areas after, by city id.
 */
export function withCityRegions(regions: Region[], cities: CityFile[]): Region[] {
  const extra = new Map<string, Region>();
  for (const r of regions) {
    for (const c of cities) {
      const d = haversineKm(c.region.lat, c.region.lng, r.lat, r.lng);
      if (d <= c.region.radiusKm && !regions.some((x) => x.id === c.region.id))
        extra.set(c.region.id, { ...c.region, seedsOnly: true });
    }
  }
  return [...regions, ...[...extra.values()].sort((a, b) => a.id.localeCompare(b.id))];
}

/** One discovered source as GET /collector/sources lists it: a seed and its collector region. */
export interface DiscoveredSource {
  region_id: string;
  seed: Seed;
}

/**
 * Discovered sources as city-file-shaped groups, one per collector region, so collect() treats
 * them like hand-written seeds of that region (same fetcher, politeness, dedupe by seed id).
 * Entries for regions not in the run and seeds that fail validation are dropped and counted.
 */
export function discoveredCities(
  data: unknown,
  regions: Region[],
): { cities: CityFile[]; dropped: number } {
  const list = Array.isArray((data as { sources?: unknown })?.sources)
    ? ((data as { sources: unknown[] }).sources as unknown[])
    : [];
  const byRegion = new Map<string, Seed[]>();
  const ids = new Set<string>();
  let dropped = 0;
  for (const [i, e] of list.entries()) {
    const o = (e ?? {}) as Record<string, unknown>;
    const region = regions.find((r) => r.collector && r.id === o.region_id);
    let seed: Seed;
    try {
      seed = validateSeed(o.seed, `discovered[${i}]`);
    } catch {
      dropped++;
      continue;
    }
    if (!region || ids.has(seed.id)) {
      dropped++;
      continue;
    }
    ids.add(seed.id);
    byRegion.set(region.id, [...(byRegion.get(region.id) ?? []), seed]);
  }
  const cities = regions
    .filter((r) => byRegion.has(r.id))
    .map((r) => ({ region: { ...r, seedsOnly: undefined }, seeds: byRegion.get(r.id)! }));
  return { cities, dropped };
}

/** Per collector region: the sources that gave at least one item inside it, and those items. */
export function regionCounts(
  regions: Region[],
  batches: SourceBatch[],
): { id: string; sources: number; items: number }[] {
  return regions
    .filter((r) => r.collector)
    .map((r) => {
      let sources = 0;
      let items = 0;
      for (const b of batches) {
        let n = 0;
        for (const it of b.items) {
          const p =
            it.lat !== null && it.lng !== null
              ? { lat: it.lat, lng: it.lng }
              : { lat: b.source.region.lat, lng: b.source.region.lng };
          if (haversineKm(r.lat, r.lng, p.lat, p.lng) <= r.radiusKm) n++;
        }
        if (n > 0) sources++;
        items += n;
      }
      return { id: r.id, sources, items };
    });
}

/** Seeds of the hand-written city files that a run of these regions reads. */
export function citySeedCount(regions: Region[], cities: CityFile[]): number {
  const ids = new Set<string>();
  for (const r of regions)
    for (const c of citiesFor(r, cities))
      for (const s of c.seeds) if (s.enabled !== false) ids.add(s.id);
  return ids.size;
}

export interface ServiceOptions {
  /** https://<ref>.supabase.co/functions/v1/collector */
  baseUrl: string;
  secret: string;
  fetch?: typeof fetch;
}

function checkService(opts: ServiceOptions): void {
  if (!/^https:\/\/[^/]+\/functions\/v1\/collector$/.test(opts.baseUrl))
    throw new Error("collector base URL must be https://<host>/functions/v1/collector");
  if (opts.secret.length < 32) throw new Error("COLLECTOR_SECRET is missing or too short");
}

async function call(
  opts: ServiceOptions,
  path: string,
  init: RequestInit = {},
): Promise<{ status: number; body: unknown }> {
  const f = opts.fetch ?? fetch;
  const res = await f(`${opts.baseUrl}${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      "x-collector-secret": opts.secret,
      ...(init.headers as Record<string, string> | undefined),
    },
  });
  const text = await res.text();
  let body: unknown;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = null;
  }
  return { status: res.status, body };
}

/** Due collector regions (or every region with all), with zones looked up where missing. */
export async function fetchRegions(
  opts: ServiceOptions & { all?: boolean; limit?: number },
): Promise<ResolvedRegion[]> {
  checkService(opts);
  const limit = Math.min(MAX_REGIONS, Math.max(1, opts.limit ?? 20));
  const { status, body } = await call(opts, `/regions?due=${opts.all ? 0 : 1}&limit=${limit}`);
  const rows = (body as { regions?: unknown })?.regions;
  if (status !== 200 || !Array.isArray(rows)) throw new Error(`GET /regions failed: ${status}`);
  return rows.map(regionFromRow);
}

/**
 * Discovered sources for the run's collector regions (collector_sources_for_regions, migration
 * 46). A 404 (a project without migration 46) means none: the run has hand-written seeds only.
 */
export async function fetchSources(
  opts: ServiceOptions,
  regionIds: string[],
): Promise<{ available: boolean; sources: unknown[] }> {
  checkService(opts);
  const sources: unknown[] = [];
  for (let i = 0; i < regionIds.length; i += SOURCES_CHUNK) {
    const ids = regionIds.slice(i, i + SOURCES_CHUNK);
    const { status, body } = await call(opts, `/sources?regions=${ids.join(",")}`);
    if (status === 404) return { available: false, sources: [] };
    const list = (body as { sources?: unknown })?.sources;
    if (status !== 200 || !Array.isArray(list)) throw new Error(`GET /sources failed: ${status}`);
    sources.push(...list);
  }
  return { available: true, sources };
}

/** Stamps the run on each collector region: counts, and the zone when it was looked up here. */
export async function recordRegions(
  opts: ServiceOptions & { runId: string },
  entries: { id: string; sources: number; items: number; timezone?: string }[],
): Promise<Record<string, unknown>> {
  checkService(opts);
  const out: Record<string, number> = {};
  for (let i = 0; i < entries.length; i += MAX_REGIONS) {
    const { status, body } = await call(opts, "/regions/record", {
      method: "POST",
      body: JSON.stringify({ run_id: opts.runId, regions: entries.slice(i, i + MAX_REGIONS) }),
    });
    if (status !== 200 || typeof body !== "object" || body === null)
      throw new Error(`POST /regions/record failed: ${status}`);
    for (const [k, v] of Object.entries(body as Record<string, unknown>))
      if (typeof v === "number") out[k] = (out[k] ?? 0) + v;
  }
  return out;
}

/** One discovered source's result for POST /collector/sources/record (migration 46). */
export interface SourceResult {
  candidate_id: string;
  outcome: "ok" | "empty" | "no_feed" | "error" | "blocked" | "robots" | "noindex" | "denylisted";
  items: number;
  in_region: number;
  errors: number;
  complete: boolean;
}

/** source_candidates_record's largest list. */
const SOURCE_RESULTS_MAX = 500;

/**
 * The run's result for each discovered source in the sources file: how many of its kept items
 * fall inside its collector region, and the outcome the database's lifecycle reads (a good run
 * needs at least one such item and a complete read). Sources that produced no batch (the run's
 * deadline came first) are left out, so they neither gain nor lose a day. Counts only.
 */
export function sourceResults(
  data: unknown,
  regions: Region[],
  batches: SourceBatch[],
): SourceResult[] {
  const list = Array.isArray((data as { sources?: unknown })?.sources)
    ? ((data as { sources: unknown[] }).sources as unknown[])
    : [];
  const out: SourceResult[] = [];
  const done = new Set<string>();
  for (const e of list) {
    const o = (e ?? {}) as Record<string, unknown>;
    const seedId = (o.seed as { id?: unknown } | undefined)?.id;
    if (typeof o.candidate_id !== "string" || !UUID.test(o.candidate_id)) continue;
    if (typeof seedId !== "string" || done.has(seedId)) continue;
    const region = regions.find((r) => r.collector && r.id === o.region_id);
    const batch = batches.find((b) => b.sourceKey === seedId);
    if (!region || !batch) continue;
    done.add(seedId);
    let inRegion = 0;
    for (const it of batch.items) {
      if (it.lat === null || it.lng === null) continue;
      if (haversineKm(region.lat, region.lng, it.lat, it.lng) <= region.radiusKm) inRegion++;
    }
    const errs = batch.errors ?? {};
    const keys = Object.keys(errs);
    const has = (reason: string) => keys.some((k) => k === reason || k.startsWith(`${reason}:`));
    const errors = Object.values(errs).reduce((n, v) => n + v, 0);
    let outcome: SourceResult["outcome"];
    if (inRegion > 0) outcome = "ok";
    else if (has("denylisted")) outcome = "denylisted";
    else if (has("robots_disallowed")) outcome = "robots";
    else if (has("noindex")) outcome = "noindex";
    else if (has("login_page")) outcome = "blocked";
    else if (keys.length === 0) outcome = "empty";
    else if (keys.every((k) => k.startsWith("not_a_feed"))) outcome = "no_feed";
    else outcome = "error";
    out.push({
      candidate_id: o.candidate_id,
      outcome,
      items: batch.items.length,
      in_region: inRegion,
      errors,
      complete: batch.complete,
    });
  }
  return out;
}

/** Posts the discovered sources' results; returns the lifecycle's summed counts. */
export async function recordSources(
  opts: ServiceOptions & { runId: string },
  results: SourceResult[],
): Promise<Record<string, number>> {
  checkService(opts);
  const out: Record<string, number> = {};
  for (let i = 0; i < results.length; i += SOURCE_RESULTS_MAX) {
    const { status, body } = await call(opts, "/sources/record", {
      method: "POST",
      body: JSON.stringify({
        run_id: opts.runId,
        results: results.slice(i, i + SOURCE_RESULTS_MAX),
      }),
    });
    if (status !== 200 || typeof body !== "object" || body === null)
      throw new Error(`POST /sources/record failed: ${status}`);
    for (const [k, v] of Object.entries(body as Record<string, unknown>))
      if (typeof v === "number") out[k] = (out[k] ?? 0) + v;
  }
  return out;
}
