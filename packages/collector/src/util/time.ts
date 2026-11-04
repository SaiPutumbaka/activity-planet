// Time zones without a dependency: Intl gives the offset of any IANA zone at any instant, and a
// wall-clock time is turned into an instant by guessing and correcting once (DST gaps resolve
// forward, overlaps to the earlier instant, as RFC 5545 3.3.5 asks).

export interface Civil {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
  second: number;
}

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(tz: string): Intl.DateTimeFormat {
  let f = formatters.get(tz);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone: tz,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(tz, f);
  }
  return f;
}

/** Windows zone names some Outlook and Exchange exports put in TZID. */
const WINDOWS_ZONES: Record<string, string> = {
  "eastern standard time": "America/New_York",
  "us eastern standard time": "America/Indiana/Indianapolis",
  "central standard time": "America/Chicago",
  "mountain standard time": "America/Denver",
  "us mountain standard time": "America/Phoenix",
  "pacific standard time": "America/Los_Angeles",
  "alaskan standard time": "America/Anchorage",
  "hawaiian standard time": "Pacific/Honolulu",
  "atlantic standard time": "America/Halifax",
  "gmt standard time": "Europe/London",
  "greenwich standard time": "Atlantic/Reykjavik",
  "w. europe standard time": "Europe/Berlin",
  "romance standard time": "Europe/Paris",
  "central europe standard time": "Europe/Budapest",
  "central european standard time": "Europe/Warsaw",
  "e. europe standard time": "Europe/Chisinau",
  "fle standard time": "Europe/Kiev",
  "tokyo standard time": "Asia/Tokyo",
  "china standard time": "Asia/Shanghai",
  "india standard time": "Asia/Kolkata",
  "aus eastern standard time": "Australia/Sydney",
  utc: "UTC",
  "coordinated universal time": "UTC",
};

export function isValidZone(tz: string): boolean {
  try {
    formatter(tz);
    return true;
  } catch {
    return false;
  }
}

/**
 * An IANA zone for a TZID as sources write it: IANA names as is, quoted names, the
 * "/mozilla.org/20050126_1/America/New_York" prefix form, and common Windows names.
 */
export function resolveZone(tzid: string | null | undefined): string | null {
  if (!tzid) return null;
  let t = tzid.trim().replace(/^"|"$/g, "");
  if (t === "") return null;
  if (isValidZone(t)) return t;
  const win = WINDOWS_ZONES[t.toLowerCase()];
  if (win) return win;
  // "/mozilla.org/20050126_1/America/New_York", "/softwarestudio.org/Olson_20011030_5/America/New_York"
  const m = /([A-Za-z]+\/[A-Za-z_]+(?:\/[A-Za-z_]+)?)$/.exec(t);
  if (m && m[1] && isValidZone(m[1])) return m[1];
  // "(UTC-05:00) Eastern Time (US & Canada)"
  t = t.toLowerCase();
  if (t.includes("eastern time")) return "America/New_York";
  if (t.includes("central time")) return "America/Chicago";
  if (t.includes("mountain time")) return "America/Denver";
  if (t.includes("pacific time")) return "America/Los_Angeles";
  return null;
}

/** Offset of tz from UTC at the instant, in milliseconds (America/New_York in winter: -5 h). */
export function zoneOffsetMs(utcMs: number, tz: string): number {
  const parts = formatter(tz).formatToParts(new Date(utcMs));
  const get = (type: string) => Number(parts.find((p) => p.type === type)?.value ?? 0);
  const asUtc = Date.UTC(
    get("year"),
    get("month") - 1,
    get("day"),
    get("hour") % 24,
    get("minute"),
    get("second"),
  );
  return asUtc - Math.floor(utcMs / 1000) * 1000;
}

function civilMs(c: Civil): number {
  return Date.UTC(c.year, c.month - 1, c.day, c.hour, c.minute, c.second);
}

/** The instant a wall-clock time in tz names. */
export function zonedToUtc(c: Civil, tz: string): Date {
  const local = civilMs(c);
  const first = local - zoneOffsetMs(local, tz);
  const firstOffset = zoneOffsetMs(first, tz);
  const second = local - firstOffset;
  if (second === first) return new Date(first);
  // Ambiguous or skipped: take the candidate that maps back to the wall time, else the later.
  const back = second + zoneOffsetMs(second, tz);
  return new Date(back === local ? Math.min(first, second) : Math.max(first, second));
}

/** The wall-clock time of an instant in tz. */
export function utcToCivil(date: Date, tz: string): Civil {
  const local = new Date(date.getTime() + zoneOffsetMs(date.getTime(), tz));
  return {
    year: local.getUTCFullYear(),
    month: local.getUTCMonth() + 1,
    day: local.getUTCDate(),
    hour: local.getUTCHours(),
    minute: local.getUTCMinutes(),
    second: local.getUTCSeconds(),
  };
}

export function addDays(c: Civil, days: number): Civil {
  const d = new Date(Date.UTC(c.year, c.month - 1, c.day + days, c.hour, c.minute, c.second));
  return {
    year: d.getUTCFullYear(),
    month: d.getUTCMonth() + 1,
    day: d.getUTCDate(),
    hour: d.getUTCHours(),
    minute: d.getUTCMinutes(),
    second: d.getUTCSeconds(),
  };
}

/** 0 = Sunday ... 6 = Saturday. */
export function weekday(c: Civil): number {
  return new Date(Date.UTC(c.year, c.month - 1, c.day)).getUTCDay();
}

export function daysInMonth(year: number, month: number): number {
  return new Date(Date.UTC(year, month, 0)).getUTCDate();
}

export function compareCivil(a: Civil, b: Civil): number {
  return civilMs(a) - civilMs(b);
}

const LOCAL_RE = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$/;
const OFFSET_RE = /(?:Z|[+-]\d{2}:?\d{2})$/i;

/**
 * A time string from a source as an instant. Strings with Z or an offset are instants; local
 * forms ("2026-11-10T19:00", "2026-11-10") are read in tz. Returns the instant and whether the
 * source gave only a date.
 */
export function resolveTime(value: string, tz: string): { date: Date; dateOnly: boolean } | null {
  const s = value.trim();
  if (s === "") return null;
  const local = LOCAL_RE.exec(s);
  if (local && !OFFSET_RE.test(s)) {
    const [, y, mo, d, h, mi, se] = local;
    const civil: Civil = {
      year: Number(y),
      month: Number(mo),
      day: Number(d),
      hour: Number(h ?? 0),
      minute: Number(mi ?? 0),
      second: Number(se ?? 0),
    };
    if (civil.month < 1 || civil.month > 12 || civil.day < 1 || civil.day > 31) return null;
    return { date: zonedToUtc(civil, tz), dateOnly: h === undefined };
  }
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : { date: d, dateOnly: false };
}
