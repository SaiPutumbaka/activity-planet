import { viewerPrefs, type DistanceUnit, type LocalePrefs } from "@ap/core/locale";

/**
 * The viewer's units and formats from the browser's language (packages/core/src/locale): miles or
 * kilometres, a 12- or 24-hour clock, month or day first (en-US: miles, 4:00 PM, Nov 5; de-DE:
 * km, 16:00, 5 Nov). Read once; it does not change while the app runs.
 */
export const VIEWER_PREFS: LocalePrefs = viewerPrefs();

/** The viewer's distance unit, for the server's distance bands, radii and map distances. */
export const DISTANCE_UNIT: DistanceUnit = VIEWER_PREFS.unit;
