// Shared shapes for the collector (D-040). The pipeline is
//   seeds -> fetch (politeness, robots, denylist) -> parse (lane) -> RawEvent
//   -> normalize (events constraints) -> ImportItem -> radius + window + dedupe -> ingest.

import type { SourceInfo } from "./sources.ts";

/** Where coverage is wanted: one entry per area people use the app in. */
export interface Region {
  id: string;
  label: string;
  lat: number;
  lng: number;
  radiusKm: number;
  /** IANA zone for floating and date-only times; defaults to UTC when unknown. */
  timezone?: string;
  /**
   * A city file's own area added to a run of collector regions (regions.ts withCityRegions):
   * its seeds keep their whole area, but API adapters do not run for it (they run for the
   * collector region it contains).
   */
  seedsOnly?: boolean;
  /** A collector_regions row (D-042 slice 6): the run records its counts there afterwards. */
  collector?: boolean;
}

export type Lane = "api" | "feed" | "page";

export type SeedKind =
  /** An HTML page: schema.org events are read and feed links discovered. */
  | "page"
  /** An iCalendar feed (.ics, webcal, CivicPlus iCalendar.aspx?catID=). */
  | "ics"
  /** An RSS 2.0 or Atom feed whose items carry event dates. */
  | "rss"
  /** A Localist calendar: its documented read-only JSON API, /api/2/events (no key). */
  | "localist"
  /** A Socrata SODA dataset (resource/<id>.json) with a field map. */
  | "socrata"
  /** An ArcGIS FeatureServer/MapServer layer with a field map. */
  | "arcgis";

/** Field names in an open-data row; dotted paths reach into nested objects. */
export interface FieldMap {
  id?: string;
  title: string;
  description?: string;
  start: string;
  end?: string;
  location?: string;
  url?: string;
  lat?: string;
  lng?: string;
  category?: string;
  /**
   * A filter the portal applies (Socrata SoQL, ArcGIS where): for example only the rows a column
   * marks public, so a permit register never lists a private event.
   */
  where?: string;
}

export interface Seed {
  id: string;
  kind: SeedKind;
  url: string;
  name: string;
  /** The line shown with every item, e.g. "Listed from the Marietta city calendar (mariettaga.gov)." */
  attribution: string;
  /** Short note on what the seed is and whether its URL has been checked by a person. */
  note?: string;
  /**
   * True once a live run has read the endpoint (or a person confirmed it); false while the URL
   * is inferred from the site's platform. Informational: the collector runs both.
   */
  verified?: boolean;
  enabled?: boolean;
  /** True only when the source licenses its images for reuse; otherwise cover_url is never set. */
  imagesLicensed?: boolean;
  /** Pages only: follow same-site event links one level deep (default true). */
  discover?: boolean;
  /** Pages only: at most this many discovered pages and feeds (default from the run options). */
  maxPages?: number;
  /**
   * Pages only: also crawl discovered event pages when a calendar-wide feed on the page
   * already yielded events (default false: the source's own feed is preferred).
   */
  crawlPages?: boolean;
  /** Open data only. */
  fields?: FieldMap;
  /** Socrata only: column holding a point for within_circle() filtering. */
  geoColumn?: string;
  host_org?: string;
  categories?: string[];
  /**
   * Hub slugs for the source's events (at most 5). The first that is an active 18+ hub is the
   * source's default hub: keyword rules (import_hub_rules) still win, and an item no rule
   * matches and whose seed has no usable hub goes to Happening nearby.
   */
  hubs?: string[];
}

export interface CityFile {
  region: Region;
  seeds: Seed[];
}

/**
 * A time as read from a source, before zone resolution:
 *   - an instant (ends in Z or carries an offset),
 *   - a floating local date-time "YYYY-MM-DDTHH:mm[:ss]" read in `timezone`,
 *   - a date "YYYY-MM-DD" (all day) read in `timezone`.
 */
export interface RawEvent {
  lane: Lane;
  /** Stable id within the source (UID, @id, API id); the URL plus start is used when absent. */
  uid: string | null;
  title: string;
  description: string;
  url: string | null;
  start: string;
  end: string | null;
  allDay?: boolean;
  /** IANA zone the source gives for floating times. */
  timezone?: string | null;
  location: string;
  lat: number | null;
  lng: number | null;
  online?: boolean;
  cancelled?: boolean;
  /** schema.org EventPostponed: no new date yet, so the item is left out. */
  postponed?: boolean;
  isFree?: boolean | null;
  priceText?: string | null;
  categories?: string[];
  host?: string | null;
  imageUrl?: string | null;
  /** Where the event was read (feed or page URL), for raw and debugging. */
  sourceUrl: string;
}

/** The item shape import_upsert_batch() takes (supabase/functions/import-feed/adapters.ts). */
export interface ImportItem {
  external_id: string;
  title: string;
  description: string;
  starts_at: string;
  ends_at: string;
  all_day: boolean;
  location: string;
  lat: number | null;
  lng: number | null;
  url: string;
  cover_url: string | null;
  is_free: boolean | null;
  price_text: string | null;
  categories: string[];
  host_org: string | null;
  open_to_public: boolean | null;
  cancelled: boolean;
  /** Collector extra: the source attribution line (unknown fields are tolerated by the RPC). */
  attribution: string;
  /** Collector extra: which lane produced the item. */
  lane: Lane;
  raw: Record<string, unknown>;
}

/** One source's complete current item set, as import_upsert_batch(p_source_slug, p_items) wants. */
export interface SourceBatch {
  sourceKey: string;
  sourceName: string;
  attribution: string;
  regionId: string;
  items: ImportItem[];
  /**
   * External ids the source still lists that this run does not send (outside the regions,
   * past the window, a duplicate within the source). The RPC counts them as seen, so a known
   * event is not cancelled because the client filtered it. Ids only, never item text.
   */
  seen?: string[];
  /** Why items were dropped before ingest, by reason. */
  skipped: Record<string, number>;
  /**
   * Requests for this source that gave nothing, by reason ("http_error", "not_a_feed:html",
   * ...). Run bookkeeping for the summary; never sent to the RPC.
   */
  errors?: Record<string, number>;
  /**
   * False when part of the source could not be read this run (timeouts, budgets, robots.txt
   * unavailable): the ingest then counts no missed runs, so nothing is cancelled for a gap.
   */
  complete: boolean;
  /**
   * The items came from listing views and event pages (a sample of the calendar), so the batch
   * is not complete for cancelling; the read itself may still have been whole (see gap).
   */
  sampled?: boolean;
  /**
   * A fetch failed in a way that leaves part of the source unread (sources.ts isGap: a 5xx, a
   * timeout, a budget). The discovery lifecycle reads "a complete read" as no gap (D-042 slice 8).
   */
  gap?: boolean;
  /** The feed_sources row this batch is for. */
  source: SourceInfo;
}
