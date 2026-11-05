// The geocode queue and its answers, through the collector Edge Function (migration 63):
//   GET  <base>/geocode/queue?limit=N   collector_geocode_queue (and meta.collector_geocode_nominatim)
//   POST <base>/geocode/record          collector_geocode_record (at most 500 a request)
// A 404 (a project without migration 63) means nothing to geocode.

import { call, checkService, type ServiceOptions } from "../regions.ts";
import type { GeocodeJob, GeocodeResult } from "./run.ts";

const KEY = /^[0-9a-f]{64}$/;

export function parseQueue(body: unknown): { jobs: GeocodeJob[]; nominatim: boolean } {
  const b = (body ?? {}) as { queue?: unknown; nominatim?: unknown };
  const jobs: GeocodeJob[] = [];
  for (const e of Array.isArray(b.queue) ? b.queue : []) {
    const o = (e ?? {}) as Record<string, unknown>;
    const r = (o.region ?? {}) as Record<string, unknown>;
    if (typeof o.key !== "string" || !KEY.test(o.key)) continue;
    if (typeof o.location !== "string" || o.location.trim().length < 4) continue;
    if (typeof r.lat !== "number" || typeof r.lng !== "number" || typeof r.radius_km !== "number")
      continue;
    jobs.push({
      key: o.key,
      location: o.location.slice(0, 200),
      region: {
        lat: r.lat,
        lng: r.lng,
        radius_km: Math.min(300, Math.max(1, r.radius_km)),
        timezone: typeof r.timezone === "string" ? r.timezone : null,
      },
    });
  }
  return { jobs, nominatim: b.nominatim !== "off" && b.nominatim !== false };
}

export async function fetchGeocodeQueue(
  opts: ServiceOptions,
  limit: number,
): Promise<{ available: boolean; jobs: GeocodeJob[]; nominatim: boolean }> {
  checkService(opts);
  const { status, body } = await call(opts, `/geocode/queue?limit=${limit}`);
  if (status === 404) return { available: false, jobs: [], nominatim: false };
  if (status !== 200) throw new Error(`GET /geocode/queue failed: ${status}`);
  return { available: true, ...parseQueue(body) };
}

export async function recordGeocodes(
  opts: ServiceOptions,
  results: GeocodeResult[],
): Promise<Record<string, number>> {
  checkService(opts);
  const out: Record<string, number> = {};
  for (let i = 0; i < results.length; i += 500) {
    const { status, body } = await call(opts, "/geocode/record", {
      method: "POST",
      body: JSON.stringify({ results: results.slice(i, i + 500) }),
    });
    if (status !== 200 || typeof body !== "object" || body === null)
      throw new Error(`POST /geocode/record failed: ${status}`);
    for (const [k, v] of Object.entries(body as Record<string, unknown>))
      if (typeof v === "number") out[k] = (out[k] ?? 0) + v;
  }
  return out;
}
