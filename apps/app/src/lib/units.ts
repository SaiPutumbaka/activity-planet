import { distanceUnitForLocale, type DistanceUnit } from "@ap/core/feed";

/**
 * The viewer's distance unit for the server's distance bands, from the browser's language
 * (en-US: miles; de-DE, en-AU: kilometres). Read once; it does not change while the app runs.
 */
export const DISTANCE_UNIT: DistanceUnit = distanceUnitForLocale(
  typeof navigator === "undefined" ? undefined : navigator.language,
);
