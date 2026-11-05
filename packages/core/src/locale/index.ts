/**
 * The viewer's units and formats (D-040: everyone, anywhere), one helper for the app and the site.
 * The words stay English; only the conventions follow the viewer's locale:
 *
 *   distance unit   miles in the US, the UK and a few others, kilometres elsewhere
 *   clock           12-hour ("4:00 PM") or 24-hour ("16:00")
 *   date order      month first ("Thu, Nov 5") or day first ("Thu 5 Nov")
 *
 *   const prefs = localePrefs("de-DE");        // { unit: "km", hour12: false, dayFirst: true }
 *   formatClock(date, "Europe/Berlin", prefs);  // "16:00"
 *   formatDay(date, "Europe/Berlin", prefs);    // "Thu 5 Nov"
 *   formatKm(25, prefs.unit);                   // "25 km" (en-US: "16 mi")
 *   formatMeters(1800, "mi");                   // "1.1 mi"
 *
 * Times are always wall-clock times in a given IANA zone (the venue's, the coach's, the
 * viewer's); the locale never changes the zone. Without a locale (server rendering, tests) the
 * defaults are US_PREFS, so a server-rendered page matches what it showed before and the
 * browser's own locale is applied after it loads.
 */

import { distanceUnitForLocale, type DistanceUnit } from "../feed/distance";

export { distanceUnitForLocale, type DistanceUnit };

export interface LocalePrefs {
  unit: DistanceUnit;
  /** 12-hour clock with AM and PM. */
  hour12: boolean;
  /** Day before month in written dates ("5 Nov"). */
  dayFirst: boolean;
}

/** en-US conventions: miles, 12-hour clock, month first. */
export const US_PREFS: Readonly<LocalePrefs> = Object.freeze({
  unit: "mi",
  hour12: true,
  dayFirst: false,
});

const SAMPLE = new Date(Date.UTC(2026, 10, 5, 16, 0));

/** The conventions of a BCP 47 locale; an unknown or empty locale gives US_PREFS. */
export function localePrefs(locale: string | null | undefined): LocalePrefs {
  if (!locale) return { ...US_PREFS };
  let hour12 = true;
  let dayFirst = false;
  try {
    const clock = new Intl.DateTimeFormat(locale, { hour: "numeric", timeZone: "UTC" });
    const ro = clock.resolvedOptions();
    hour12 = ro.hourCycle ? ro.hourCycle === "h11" || ro.hourCycle === "h12" : ro.hour12 !== false;
    const parts = new Intl.DateTimeFormat(locale, {
      month: "short",
      day: "numeric",
      timeZone: "UTC",
    }).formatToParts(SAMPLE);
    const day = parts.findIndex((p) => p.type === "day");
    const month = parts.findIndex((p) => p.type === "month");
    dayFirst = day >= 0 && month >= 0 && day < month;
  } catch {
    return { ...US_PREFS };
  }
  return { unit: distanceUnitForLocale(locale), hour12, dayFirst };
}

/** The browser's preferred locale, or undefined outside a browser. */
export function browserLocale(): string | undefined {
  if (typeof navigator === "undefined") return undefined;
  return navigator.languages?.[0] ?? navigator.language ?? undefined;
}

/** The first language tag of an Accept-Language header, or undefined. */
export function acceptLanguageLocale(header: string | null | undefined): string | undefined {
  if (!header) return undefined;
  const first = header.split(",")[0]?.split(";")[0]?.trim();
  return first && first !== "*" ? first : undefined;
}

let cached: { locale: string | undefined; prefs: LocalePrefs } | null = null;

/** The browser's conventions (US_PREFS outside a browser), worked out once per locale. */
export function viewerPrefs(): LocalePrefs {
  const locale = browserLocale();
  if (!cached || cached.locale !== locale) cached = { locale, prefs: localePrefs(locale) };
  return cached.prefs;
}

/* ------------------------------------------------------------------ */
/* Times and dates                                                      */
/* ------------------------------------------------------------------ */

type DateInput = string | Date;

function toDate(value: DateInput): Date {
  return value instanceof Date ? value : new Date(value);
}

function partsIn(date: Date, timeZone: string | undefined, opts: Intl.DateTimeFormatOptions) {
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone, ...opts }).formatToParts(date);
  } catch {
    return new Intl.DateTimeFormat("en-US", opts).formatToParts(date);
  }
}

function part(parts: Intl.DateTimeFormatPart[], type: Intl.DateTimeFormatPartTypes): string {
  return parts.find((p) => p.type === type)?.value ?? "";
}

/**
 * The clock and, on a 12-hour clock, the period: { clock: "4:00", period: "PM" } or
 * { clock: "16:00", period: "" }.
 */
export function clockParts(
  value: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
): { clock: string; period: string } {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return { clock: "", period: "" };
  if (prefs.hour12) {
    const p = partsIn(date, timeZone, { hour: "numeric", minute: "2-digit", hour12: true });
    return {
      clock: `${part(p, "hour")}:${part(p, "minute") || "00"}`,
      period: part(p, "dayPeriod"),
    };
  }
  const p = partsIn(date, timeZone, { hour: "2-digit", minute: "2-digit", hourCycle: "h23" });
  const hour = String(Number(part(p, "hour")) % 24).padStart(2, "0");
  return { clock: `${hour}:${part(p, "minute") || "00"}`, period: "" };
}

/** "4:00 PM" or "16:00". */
export function formatClock(
  value: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
): string {
  const t = clockParts(value, timeZone, prefs);
  return t.period ? `${t.clock} ${t.period}` : t.clock;
}

/**
 * A same-day range: "4:00 to 6:00 PM", "11:30 AM to 1:00 PM" across noon, "16:00 to 18:00" on a
 * 24-hour clock.
 */
export function formatClockRange(
  start: DateInput,
  end: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
): string {
  const s = clockParts(start, timeZone, prefs);
  const e = clockParts(end, timeZone, prefs);
  if (!s.period) return `${s.clock} to ${e.clock}`;
  return s.period === e.period
    ? `${s.clock} to ${e.clock} ${s.period}`
    : `${s.clock} ${s.period} to ${e.clock} ${e.period}`;
}

export interface DayOptions {
  /** "short" (Thu, the default), "long" (Thursday) or false for none. */
  weekday?: "short" | "long" | false;
  /** "short" (Nov, the default) or "long" (November). */
  month?: "short" | "long";
  /** true always, false never, "auto" (the default) when the year differs from now's. */
  year?: boolean | "auto";
  now?: Date;
}

/** "Thu, Nov 5" or "Thu 5 Nov", with the year when it is not this year ("Thu, Nov 5, 2027"). */
export function formatDay(
  value: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
  opts: DayOptions = {},
): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  const weekday = opts.weekday ?? "short";
  const p = partsIn(date, timeZone, {
    ...(weekday ? { weekday } : {}),
    month: opts.month ?? "short",
    day: "numeric",
    year: "numeric",
  });
  const year = part(p, "year");
  const showYear =
    opts.year === true ||
    ((opts.year ?? "auto") === "auto" &&
      year !== part(partsIn(opts.now ?? new Date(), timeZone, { year: "numeric" }), "year"));
  const wd = weekday ? part(p, "weekday") : "";
  const month = part(p, "month");
  const day = part(p, "day");
  if (prefs.dayFirst) {
    return [wd, day, month, showYear ? year : ""].filter(Boolean).join(" ");
  }
  const md = `${month} ${day}${showYear ? `, ${year}` : ""}`;
  return wd ? `${wd}, ${md}` : md;
}

/** "Thu, Nov 5 · 4:00 PM" or "Thu 5 Nov · 16:00". */
export function formatDayClock(
  value: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
  opts: DayOptions = {},
): string {
  const day = formatDay(value, timeZone, prefs, opts);
  return day ? `${day} · ${formatClock(value, timeZone, prefs)}` : "";
}

/** "Thu 4:00 PM" or "Thu 16:00", for a time within the coming week. */
export function formatWeekdayClock(
  value: DateInput,
  timeZone: string | undefined,
  prefs: LocalePrefs = US_PREFS,
): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  const wd = part(partsIn(date, timeZone, { weekday: "short" }), "weekday");
  return `${wd} ${formatClock(date, timeZone, prefs)}`;
}

/* ------------------------------------------------------------------ */
/* Distances                                                            */
/* ------------------------------------------------------------------ */

export const KM_PER_MILE = 1.609344;

/**
 * A radius or other whole distance held in km, in the viewer's unit: "25 km", or "16 mi" (rounded
 * to a whole mile, at least 1).
 */
export function formatKm(km: number, unit: DistanceUnit): string {
  if (unit === "km") return `${km} km`;
  return `${Math.max(1, Math.round(km / KM_PER_MILE))} mi`;
}

/**
 * A rough size held in km, for "about ..." copy: "1 km" or "half a mile"; "10 km" or "6 mi".
 */
export function formatKmRough(km: number, unit: DistanceUnit): string {
  if (unit === "km") return `${km} km`;
  const mi = km / KM_PER_MILE;
  if (mi < 0.75) return "half a mile";
  return `${Math.round(mi)} mi`;
}

/**
 * A measured distance in metres: "350 m", "2.1 km", "12 km"; in miles "0.2 mi" (at least 0.1),
 * "1.4 mi", "12 mi".
 */
export function formatMeters(m: number, unit: DistanceUnit): string {
  if (unit === "km") {
    if (m < 950) return `${Math.max(50, Math.round(m / 50) * 50)} m`;
    const km = m / 1000;
    return km < 10 ? `${km.toFixed(1)} km` : `${Math.round(km)} km`;
  }
  const mi = m / 1000 / KM_PER_MILE;
  if (mi < 9.95) return `${Math.max(0.1, Math.round(mi * 10) / 10).toFixed(1)} mi`;
  return `${Math.round(mi)} mi`;
}

/* ------------------------------------------------------------------ */
/* Addresses                                                            */
/* ------------------------------------------------------------------ */

/**
 * Countries that write the postal code before the town ("79098 Freiburg im Breisgau"). Not an
 * international address formatter: everywhere else keeps "Town, STATE 12345".
 */
const POSTCODE_FIRST = new Set([
  "AD",
  "AT",
  "BE",
  "CH",
  "CZ",
  "DE",
  "DK",
  "ES",
  "FI",
  "FR",
  "GR",
  "HR",
  "IS",
  "IT",
  "LI",
  "LU",
  "MC",
  "NL",
  "NO",
  "PL",
  "PT",
  "SE",
  "SI",
  "SK",
  "SM",
]);

export interface AddressParts {
  address_line1?: string | null;
  address_line2?: string | null;
  city?: string | null;
  state?: string | null;
  postal_code?: string | null;
  /** ISO 3166-1 alpha-2; null when unknown. */
  country?: string | null;
}

/** Words of a string, lower-cased, letters and digits only. */
function addressWords(v: string): string[] {
  return v.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? [];
}

/**
 * True when a part after the first comma of the street line has the town as whole words
 * ("Werthmannstraße 4, 79098 Freiburg im Breisgau"). The first part is the street itself, so
 * "100 Atlanta Ave SE" in Atlanta or "Hauptstr. 1" in Au still get their town added.
 */
function streetHoldsTown(street: string, city: string): boolean {
  const town = addressWords(city);
  if (town.length === 0) return false;
  return street
    .split(",")
    .slice(1)
    .some((part) => {
      const words = addressWords(part);
      for (let i = 0; i + town.length <= words.length; i++) {
        if (town.every((w, j) => words[i + j] === w)) return true;
      }
      return false;
    });
}

/**
 * One line of address. When the street line already holds the town (a source's own formatted
 * address, such as an OpenStreetMap place's), it is used as it is. Otherwise the parts are joined
 * in the country's usual order: "25 Park Pl, Atlanta, GA 30303"; "Schlossbergring, 79098
 * Freiburg im Breisgau".
 */
export function formatAddressLine(a: AddressParts): string {
  const clean = (v: string | null | undefined) => (v ?? "").trim();
  const line1 = clean(a.address_line1);
  const line2 = clean(a.address_line2);
  const city = clean(a.city);
  const state = clean(a.state);
  const postal = clean(a.postal_code);
  const street = [line1, line2].filter(Boolean).join(", ");
  if (street && city && streetHoldsTown(street, city)) return street;
  const country = clean(a.country).toUpperCase();
  const town = POSTCODE_FIRST.has(country)
    ? [[postal, city].filter(Boolean).join(" "), state].filter(Boolean).join(", ")
    : [city, [state, postal].filter(Boolean).join(" ")].filter(Boolean).join(", ");
  return [street, town].filter(Boolean).join(", ");
}
