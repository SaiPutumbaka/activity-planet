/**
 * Feed v2 helpers (D-036), pure so they can be tested without a browser or a database.
 *
 *   feedSection(e.starts_at, now)                 // "today" | "this_week" | "later" (America/New_York)
 *   groupFeed(events, now)                        // { sections: [{ key, title, events }], imported }
 *   nextRadiusKm(10, 3)                           // 25: fewer than 5 results, widen one step
 *   roundCoordinate(33.74901)                     // 33.75 (about 1 km; never send more)
 *   distanceBandLabel("approximate")              // "Approximate area"
 */

/** The feed's day boundaries are Atlanta's, the same zone feed_events_v2 uses. */
export const FEED_TIMEZONE = "America/New_York";

/** Radius choices offered in the location sheet and on the You tab, in km. */
export const RADIUS_OPTIONS_KM = [5, 10, 25, 50] as const;
export type RadiusKm = (typeof RADIUS_OPTIONS_KM)[number];

/** The steps the feed widens through when a radius returns too little. */
export const RADIUS_WIDEN_STEPS_KM = [10, 25, 50] as const;

/** Below this many results the feed widens the radius before showing an empty or thin list. */
export const MIN_FEED_RESULTS = 5;

/** The longest radius anyone can ask for (feed_events_v2 caps at 50 km too). */
export const MAX_RADIUS_KM = 50;

/** How far ahead the Home feed looks: Today, This week and Later share one 30-day window. */
export const FEED_WINDOW_DAYS = 30;

export type FeedSectionKey = "today" | "this_week" | "later";

export const FEED_SECTION_TITLES: Record<FeedSectionKey, string> = {
  today: "Today",
  this_week: "This week",
  later: "Later",
};

const SECTION_ORDER: readonly FeedSectionKey[] = ["today", "this_week", "later"];

/** Days since the epoch of the calendar date an instant falls on in a timezone. */
export function localDayNumber(instant: Date, timeZone: string = FEED_TIMEZONE): number {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(instant);
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((p) => p.type === type)?.value ?? "0");
  return Math.floor(Date.UTC(get("year"), get("month") - 1, get("day")) / 86_400_000);
}

/**
 * Which section an event belongs in, the way feed_events_v2 computes `section`: today (or
 * earlier, for something already under way), the next six days, or later. Recomputed on the
 * client so a feed left open past midnight still files events correctly.
 */
export function feedSection(
  startsAt: string | Date,
  now: Date,
  timeZone: string = FEED_TIMEZONE,
): FeedSectionKey {
  const start = startsAt instanceof Date ? startsAt : new Date(startsAt);
  const diff = localDayNumber(start, timeZone) - localDayNumber(now, timeZone);
  if (diff <= 0) return "today";
  if (diff < 7) return "this_week";
  return "later";
}

export interface FeedGroupable {
  starts_at: string;
  kind: string;
}

export interface FeedGroups<T> {
  /** Human-hosted plans in Today / This week / Later order; empty sections are left out. */
  sections: { key: FeedSectionKey; title: string; events: T[] }[];
  /** Imported listings, for the "Also happening" shelf below the human-hosted ones. */
  imported: T[];
}

/**
 * Splits the feed into its sections. Imported rows never mix into the sections: they go to the
 * shelf, so a person-hosted plan is always above a listing. Order inside each group is kept.
 */
export function groupFeed<T extends FeedGroupable>(
  events: readonly T[],
  now: Date,
  timeZone: string = FEED_TIMEZONE,
): FeedGroups<T> {
  const buckets = new Map<FeedSectionKey, T[]>();
  const imported: T[] = [];
  for (const e of events) {
    if (e.kind === "imported") {
      imported.push(e);
      continue;
    }
    const key = feedSection(e.starts_at, now, timeZone);
    const list = buckets.get(key);
    if (list) list.push(e);
    else buckets.set(key, [e]);
  }
  const sections = SECTION_ORDER.flatMap((key) => {
    const list = buckets.get(key);
    return list ? [{ key, title: FEED_SECTION_TITLES[key], events: list }] : [];
  });
  return { sections, imported };
}

/**
 * The radius to try next, or null to stop. Widening happens only while the results are thin
 * (fewer than MIN_FEED_RESULTS) and there is a wider step left: 10, then 25, then 50 km.
 */
export function nextRadiusKm(
  currentKm: number,
  resultCount: number,
  minResults: number = MIN_FEED_RESULTS,
): number | null {
  if (resultCount >= minResults) return null;
  const next = RADIUS_WIDEN_STEPS_KM.find((step) => step > currentKm);
  return next ?? null;
}

/** A radius the feed accepts: whole km between 1 and 50, with 10 for anything unusable. */
export function clampRadiusKm(value: number | null | undefined): number {
  if (typeof value !== "number" || !Number.isFinite(value)) return 10;
  return Math.min(MAX_RADIUS_KM, Math.max(1, Math.round(value)));
}

/**
 * Rounds a latitude or longitude to two decimals (about 1.1 km of latitude), the precision the
 * device point is kept and sent at. -0 comes back as 0.
 */
export function roundCoordinate(value: number): number {
  const rounded = Math.round(value * 100) / 100;
  return Object.is(rounded, -0) ? 0 : rounded;
}

/** A device point rounded for the feed, or null when the numbers are not a place on Earth. */
export function roundPoint(lat: number, lng: number): { lat: number; lng: number } | null {
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return { lat: roundCoordinate(lat), lng: roundCoordinate(lng) };
}

/** feed_events_v2 distance_band values as words for an event card. Null and unknown give null. */
export function distanceBandLabel(band: string | null | undefined): string | null {
  switch (band) {
    case "approximate":
      return "Approximate area";
    case "<1 mi":
      return "Under 1 mi";
    case "1-5 mi":
      return "1 to 5 mi";
    case "5-10 mi":
      return "5 to 10 mi";
    case "10-25 mi":
      return "10 to 25 mi";
    case "25+ mi":
      return "25+ mi";
    default:
      return null;
  }
}
