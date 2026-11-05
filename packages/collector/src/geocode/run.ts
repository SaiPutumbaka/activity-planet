// Venue geocoding for imported events still on their source's area centroid (design 2.5,
// migration 63). The nightly job reads the queue (GET /collector/geocode/queue), tries three free
// steps in order and keeps an answer only when it lies inside the job's region:
//   1. our own places (match.ts; no request),
//   2. Geoapify, only when GEOAPIFY_SERVER_KEY is set, within the run's share of its daily budget
//      (collector_budget geoapify_geocode_calls, 300 a UTC day); skipped without the key,
//   3. Nominatim, at most 300 requests a night and only while meta.collector_geocode_nominatim is
//      on; Photon only when Nominatim answers 429 or 5xx.
// Every answer, hit or miss, goes back (POST /collector/geocode/record), so the database caches it
// and the same text is not asked again for 180 days (90 for a miss). A job no step could ask
// (limits, deadline, providers down) is left for the next night. Logs carry counts only.

import type { TileRow } from "../discovery/candidates.ts";
import type { Fetcher } from "../net/fetcher.ts";
import { haversineKm } from "../util/geo.ts";
import { PlaceIndex } from "./match.ts";
import {
  ask,
  type GeoAnswer,
  geoapifyUrl,
  nominatimUrl,
  parseGeoapify,
  parseNominatim,
  parsePhoton,
  photonUrl,
  type Region,
} from "./providers.ts";

export const MAX_NOMINATIM_PER_RUN = 300;

export interface GeocodeJob {
  key: string;
  location: string;
  region: Region & { timezone?: string | null };
}

export interface GeocodeResult {
  key: string;
  status: "ok" | "miss";
  lat?: number;
  lng?: number;
  provider: "place" | "geoapify" | "nominatim" | "photon" | "none";
  place_ref?: string | null;
  confidence?: number | null;
}

export interface GeocodeOptions {
  jobs: GeocodeJob[];
  fetcher: Pick<Fetcher, "get">;
  /** The named place rows around a region (tile rows); omitted: no place matching. */
  placesFor?: (region: Region) => Promise<TileRow[]>;
  geoapifyKey?: string | null;
  /** Geoapify calls this run may send (its budget grant). */
  geoapifyCalls?: number;
  nominatim: boolean;
  maxNominatim?: number;
  now?: () => number;
  /** No provider request starts after this clock time. */
  deadlineAt?: number;
}

export interface GeocodeSummary {
  results: GeocodeResult[];
  counts: Record<string, number>;
  calls: { geoapify: number; nominatim: number; photon: number };
}

function inside(r: Region, lat: number, lng: number): boolean {
  return haversineKm(r.lat, r.lng, lat, lng) <= r.radius_km;
}

const regionKey = (r: Region) => `${r.lat.toFixed(3)},${r.lng.toFixed(3)},${r.radius_km}`;

export async function geocode(o: GeocodeOptions): Promise<GeocodeSummary> {
  const now = o.now ?? (() => Date.now());
  const counts: Record<string, number> = {};
  const bump = (k: string) => (counts[k] = (counts[k] ?? 0) + 1);
  const calls = { geoapify: 0, nominatim: 0, photon: 0 };
  const maxNom = Math.min(MAX_NOMINATIM_PER_RUN, o.maxNominatim ?? MAX_NOMINATIM_PER_RUN);
  const geoapifyCap = o.geoapifyKey ? Math.max(0, o.geoapifyCalls ?? 0) : 0;
  const indexes = new Map<string, PlaceIndex>();
  const results: GeocodeResult[] = [];
  const late = () => o.deadlineAt !== undefined && now() >= o.deadlineAt;

  for (const job of o.jobs) {
    // 1. Our own places.
    if (o.placesFor) {
      const k = regionKey(job.region);
      let idx = indexes.get(k);
      if (!idx) {
        idx = new PlaceIndex(await o.placesFor(job.region));
        indexes.set(k, idx);
      }
      const m = idx.match(job.location, job.region);
      if (m) {
        results.push({
          key: job.key,
          status: "ok",
          lat: m.lat,
          lng: m.lng,
          provider: "place",
          place_ref: m.place_ref,
          confidence: m.confidence,
        });
        bump("place_ok");
        continue;
      }
    }
    let answered: GeocodeResult["provider"] | null = null;
    let hit: {
      provider: GeocodeResult["provider"];
      a: Extract<GeoAnswer, { kind: "hit" }>;
    } | null = null;
    const take = (provider: GeocodeResult["provider"], a: GeoAnswer): boolean => {
      if (a.kind === "unavailable") {
        bump(`${provider}_unavailable`);
        return false;
      }
      answered = provider;
      if (a.kind === "hit" && inside(job.region, a.lat, a.lng)) {
        hit = { provider, a };
        return true;
      }
      bump(a.kind === "hit" ? `${provider}_outside_region` : `${provider}_none`);
      return false;
    };

    // 2. Geoapify, with its key and budget only.
    if (!hit && calls.geoapify < geoapifyCap && !late()) {
      calls.geoapify++;
      take(
        "geoapify",
        await ask(o.fetcher, geoapifyUrl(job.location, job.region, o.geoapifyKey!), parseGeoapify),
      );
    } else if (!o.geoapifyKey) bump("geoapify_skipped_no_key");

    // 3. Nominatim, Photon only after a 429 or 5xx.
    if (!hit && o.nominatim && calls.nominatim < maxNom && !late()) {
      calls.nominatim++;
      const a = await ask(o.fetcher, nominatimUrl(job.location, job.region), parseNominatim);
      const fallback = a.kind === "unavailable" && (a.status === 429 || (a.status ?? 0) >= 500);
      if (!take("nominatim", a) && fallback && !late()) {
        calls.photon++;
        take("photon", await ask(o.fetcher, photonUrl(job.location, job.region), parsePhoton));
      }
    }

    const h = hit as {
      provider: GeocodeResult["provider"];
      a: Extract<GeoAnswer, { kind: "hit" }>;
    } | null;
    if (h) {
      results.push({
        key: job.key,
        status: "ok",
        lat: h.a.lat,
        lng: h.a.lng,
        provider: h.provider,
        place_ref: h.a.place_ref,
        confidence: h.a.confidence,
      });
      bump(`${h.provider}_ok`);
    } else if (answered) {
      results.push({ key: job.key, status: "miss", provider: answered });
      bump("miss");
    } else {
      bump("left_for_later");
    }
  }
  return { results, counts, calls };
}
