/**
 * Distance units for the server's distance bands (feed_events_v2, recs_*, coach search). The
 * bands are cut in miles ('<1 mi', '1-5 mi', '5-10 mi', '10-25 mi', '25+ mi'); a viewer whose
 * locale uses kilometres sees the same bands in kilometres, rounded to the nearest whole number
 * (COACHING_DESIGN section 6: "kilometres when the client's locale uses them"). Never a distance.
 *
 *   distanceUnitForLocale("en-US")   // "mi"
 *   distanceUnitForLocale("de-DE")   // "km"
 *   bandText("1-5 mi", "km")         // "2 to 8 km"
 */

export type DistanceUnit = "mi" | "km";

/** Regions that give everyday distances in miles. */
const MILE_REGIONS = new Set(["US", "GB", "LR", "MM", "PR", "GU", "VI", "AS", "MP", "UM"]);

/** "mi" or "km" for a BCP 47 locale; a locale without a region takes its likely region. */
export function distanceUnitForLocale(locale: string | null | undefined): DistanceUnit {
  if (!locale) return "mi";
  let region: string | undefined;
  try {
    const l = new Intl.Locale(locale);
    region = l.region ?? l.maximize().region;
  } catch {
    region = locale.split(/[-_]/)[1]?.toUpperCase();
  }
  if (!region) return "mi";
  return MILE_REGIONS.has(region.toUpperCase()) ? "mi" : "km";
}

const BANDS: Record<string, { mi: string; km: string }> = {
  "<1 mi": { mi: "Under 1 mi", km: "Under 2 km" },
  "1-5 mi": { mi: "1 to 5 mi", km: "2 to 8 km" },
  "5-10 mi": { mi: "5 to 10 mi", km: "8 to 16 km" },
  "10-25 mi": { mi: "10 to 25 mi", km: "16 to 40 km" },
  "25+ mi": { mi: "25+ mi", km: "40+ km" },
};

/** A mile band in words in the viewer's unit; an unknown band comes back as it is. */
export function bandText(band: string, unit: DistanceUnit = "mi"): string {
  return BANDS[band]?.[unit] ?? band;
}
