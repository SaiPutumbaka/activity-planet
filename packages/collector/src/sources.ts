// The feed_sources row a collector source maps to (migration 37, collector_ingest_events).
// One row per seed (slug = seed id) and one per API adapter and region (slug = <api>-<region>).

import type { Region, Seed, SeedKind } from "./types.ts";

/** feed_sources.kind (migrations 24 and 37). Page seeds read schema.org Event markup: jsonld. */
export type FeedKind =
  "ics" | "rss" | "jsonld" | "localist" | "socrata" | "arcgis" | "ticketmaster" | "seatgeek";

/** feed_sources.lane: api (lane 1, APIs and open data), feed (lane 2), page (lane 3). */
export type SourceLane = "api" | "feed" | "page";

export interface SourceInfo {
  slug: string;
  kind: FeedKind;
  url: string;
  name: string;
  attribution: string;
  homepage_url: string | null;
  lane: SourceLane;
  enabled: boolean;
  /** Hub slugs from the seed; the first active 18+ one becomes the source's default hub. */
  hubs: string[];
  /**
   * The seed says the source licenses its images for reuse (seed imagesLicensed). Without it
   * collector_ingest_events drops every cover_url.
   */
  images_licensed: boolean;
  region: { lat: number; lng: number; radius_km: number; label: string; timezone: string | null };
}

const SEED_KIND: Record<SeedKind, FeedKind> = {
  page: "jsonld",
  ics: "ics",
  rss: "rss",
  localist: "localist",
  socrata: "socrata",
  arcgis: "arcgis",
};

const SEED_LANE: Record<SeedKind, SourceLane> = {
  page: "page",
  ics: "feed",
  rss: "feed",
  localist: "feed",
  socrata: "api",
  arcgis: "api",
};

/** API endpoints recorded as the source URL (never fetched from here; no key in it). */
const API_URL: Record<string, string> = {
  ticketmaster: "https://app.ticketmaster.com/discovery/v2/events.json",
  seatgeek: "https://api.seatgeek.com/2/events",
};
const API_HOME: Record<string, string> = {
  ticketmaster: "https://www.ticketmaster.com/",
  seatgeek: "https://seatgeek.com/",
};

function regionOf(r: Region): SourceInfo["region"] {
  return {
    lat: r.lat,
    lng: r.lng,
    radius_km: r.radiusKm,
    label: r.label,
    timezone: r.timezone ?? null,
  };
}

function homepage(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "https:" ? `${u.origin}/` : null;
  } catch {
    return null;
  }
}

export function sourceForSeed(seed: Seed, cityRegion: Region): SourceInfo {
  return {
    slug: seed.id,
    kind: SEED_KIND[seed.kind],
    url: seed.url,
    name: seed.name,
    attribution: seed.attribution,
    homepage_url: homepage(seed.url),
    lane: SEED_LANE[seed.kind],
    enabled: seed.enabled !== false,
    hubs: seed.hubs ?? [],
    images_licensed: seed.imagesLicensed === true,
    region: regionOf(cityRegion),
  };
}

export function sourceForApi(
  adapter: { id: string; name: string; attribution: string },
  region: Region,
): SourceInfo {
  const kind: FeedKind = adapter.id === "seatgeek" ? "seatgeek" : "ticketmaster";
  return {
    slug: `${adapter.id}-${region.id}`,
    kind,
    url: API_URL[adapter.id] ?? API_URL.ticketmaster!,
    name: adapter.name,
    attribution: adapter.attribution,
    homepage_url: API_HOME[adapter.id] ?? null,
    lane: "api",
    enabled: true,
    hubs: [],
    images_licensed: false,
    region: regionOf(region),
  };
}

/**
 * Fetch failures that are answers, not gaps: policy refusals (https only, private addresses,
 * the denylist, sign-in pages), robots.txt Disallow, and noindex. Any other failed fetch
 * (5xx, 429, 401/403, timeouts, budgets, redirects, unsupported types, a crawl delay we will not
 * wait for) means part of the source was not read this run, so a missing item may still be
 * listed: the batch is then partial and the RPC counts no missed runs for it.
 */
const ANSWER_REASONS = new Set<string>([
  "not_https",
  "private_address",
  "denylisted",
  "login_page",
  "robots_disallowed",
  "noindex",
  "not_a_feed",
]);

/**
 * True when a failure leaves a gap in the source's set. A 404 or 410 is an answer only on a
 * side URL (a discovered feed, a listing view, an event page, a later API page that is gone);
 * on the source's first request it means nothing was read.
 */
export function isGap(reason: string, status: number | undefined, first: boolean): boolean {
  if (ANSWER_REASONS.has(reason)) return false;
  if (reason === "http_error" && (status === 404 || status === 410) && !first) return false;
  return true;
}
