import { deviceTimeZone } from "@ap/core/feed";
import { clockParts, formatDay as formatDayIn, type LocalePrefs } from "@ap/core/locale";

import { VIEWER_PREFS } from "./units";

/**
 * Event times, Intl only. Every function takes an IANA timezone (events.timezone, default
 * America/New_York) because a time is a wall-clock fact at the venue, not on the phone.
 *
 * Clock and date order follow the viewer's locale (VIEWER_PREFS: "16:00", "Thu 5 Nov"); the
 * examples are en-US.
 *
 *   formatEventTime(e.starts_at, e.ends_at, e.timezone)  // "Thu, Nov 5 · 4:00 to 6:00 PM"
 *   formatRelativeDay(e.starts_at, e.timezone)            // "Today" | "Tomorrow" | "Thu" | "Thu, Nov 5"
 *   isHappeningNow(e.starts_at, e.ends_at)                // raspberry "Happening now"
 *   isOver(e.ends_at)
 *   toLocalDateTimeInputValue(e.starts_at, tz)            // "2026-11-05T16:00" for <input type="datetime-local">
 *   fromLocalDateTimeInputValue("2026-11-05T16:00", tz)   // ISO string in UTC, or null
 */
export const DEFAULT_TIMEZONE = "America/New_York";

/**
 * The zone of the person using the app (D-040: anyone, anywhere): the device's IANA zone, else
 * DEFAULT_TIMEZONE. A new plan is posted in it (the host is almost always where the plan is), and
 * the event page names an event's zone only when it differs from this one.
 */
export function viewerZone(device: string | null = deviceTimeZone()): string {
  return device ?? DEFAULT_TIMEZONE;
}

type DateInput = string | Date;

function toDate(value: DateInput): Date {
  return value instanceof Date ? value : new Date(value);
}

/** Wall-clock parts of an instant in a timezone. */
function wallClock(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).formatToParts(date);
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((p) => p.type === type)?.value ?? "0");
  return {
    year: get("year"),
    month: get("month"),
    day: get("day"),
    hour: get("hour") % 24,
    minute: get("minute"),
    second: get("second"),
  };
}

/** Local calendar date as a day number (days since epoch), for "today / tomorrow" arithmetic. */
function dayNumber(date: Date, timeZone: string): number {
  const w = wallClock(date, timeZone);
  return Math.floor(Date.UTC(w.year, w.month - 1, w.day) / 86_400_000);
}

function formatTimeParts(
  date: Date,
  timeZone: string,
  prefs: LocalePrefs = VIEWER_PREFS,
): { clock: string; period: string } {
  return clockParts(date, timeZone, prefs);
}

function formatDay(date: Date, timeZone: string, now: Date, prefs: LocalePrefs = VIEWER_PREFS) {
  return formatDayIn(date, timeZone, prefs, { now });
}

/** "4:00 PM" or "16:00": a clock with its period, if any. */
function joinClock(t: { clock: string; period: string }): string {
  return t.period ? `${t.clock} ${t.period}` : t.clock;
}

/** "Thu, Nov 5 · 4:00 to 6:00 PM"; "11:30 AM to 1:00 PM" across noon; the end day when it differs. */
export function formatEventTime(
  startsAt: DateInput,
  endsAt?: DateInput | null,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
  prefs: LocalePrefs = VIEWER_PREFS,
): string {
  const start = toDate(startsAt);
  if (Number.isNaN(start.getTime())) return "";
  const day = formatDay(start, timeZone, now, prefs);
  const s = formatTimeParts(start, timeZone, prefs);
  const end = endsAt ? toDate(endsAt) : null;
  if (!end || Number.isNaN(end.getTime()) || end <= start) return `${day} · ${joinClock(s)}`;

  const e = formatTimeParts(end, timeZone, prefs);
  if (dayNumber(end, timeZone) !== dayNumber(start, timeZone)) {
    return `${day} · ${joinClock(s)} to ${formatDay(end, timeZone, now, prefs)} · ${joinClock(e)}`;
  }
  return s.period === e.period
    ? `${day} · ${s.clock} to ${joinClock(e)}`
    : `${day} · ${joinClock(s)} to ${joinClock(e)}`;
}

/** "4:00 PM" (or "16:00") on its own, for rows that already show the day. */
export function formatTime(
  value: DateInput,
  timeZone: string = DEFAULT_TIMEZONE,
  prefs: LocalePrefs = VIEWER_PREFS,
): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  return joinClock(formatTimeParts(date, timeZone, prefs));
}

/** "Today", "Tomorrow", "Yesterday", a weekday within the week, otherwise "Thu, Nov 5". */
export function formatRelativeDay(
  value: DateInput,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
  prefs: LocalePrefs = VIEWER_PREFS,
): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  const diff = dayNumber(date, timeZone) - dayNumber(now, timeZone);
  if (diff === 0) return "Today";
  if (diff === 1) return "Tomorrow";
  if (diff === -1) return "Yesterday";
  if (diff > 1 && diff < 7) {
    return new Intl.DateTimeFormat("en-US", { timeZone, weekday: "long" }).format(date);
  }
  return formatDay(date, timeZone, now, prefs);
}

/** Started and not yet ended. Raspberry "Happening now" in the UI. */
export function isHappeningNow(
  startsAt: DateInput,
  endsAt: DateInput,
  now: Date = new Date(),
): boolean {
  const start = toDate(startsAt).getTime();
  const end = toDate(endsAt).getTime();
  const t = now.getTime();
  return start <= t && t < end;
}

export function isOver(endsAt: DateInput, now: Date = new Date()): boolean {
  return toDate(endsAt).getTime() <= now.getTime();
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}

/** An instant as the "YYYY-MM-DDTHH:MM" wall-clock string <input type="datetime-local"> wants. */
export function toLocalDateTimeInputValue(
  value: DateInput,
  timeZone: string = DEFAULT_TIMEZONE,
): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  const w = wallClock(date, timeZone);
  return `${w.year}-${pad(w.month)}-${pad(w.day)}T${pad(w.hour)}:${pad(w.minute)}`;
}

/** Milliseconds the timezone is ahead of UTC at the given instant. */
function offsetAt(utcMs: number, timeZone: string): number {
  const w = wallClock(new Date(utcMs), timeZone);
  return Date.UTC(w.year, w.month - 1, w.day, w.hour, w.minute, w.second) - utcMs;
}

/**
 * A "YYYY-MM-DDTHH:MM" wall-clock string in the timezone as an ISO instant (UTC), or null when
 * the input is not a date. Two passes over the offset settle the DST transitions: an ambiguous
 * fall-back time takes its first occurrence, a time in the spring gap moves forward an hour.
 */
export function fromLocalDateTimeInputValue(
  value: string,
  timeZone: string = DEFAULT_TIMEZONE,
): string | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(value.trim());
  if (!m) return null;
  const [, y, mo, d, h, mi, s] = m;
  const asUtc = Date.UTC(
    Number(y),
    Number(mo) - 1,
    Number(d),
    Number(h),
    Number(mi),
    Number(s ?? 0),
  );
  if (Number.isNaN(asUtc)) return null;
  const first = asUtc - offsetAt(asUtc, timeZone);
  const second = asUtc - offsetAt(first, timeZone);
  // Agreement means a plain time or the first of an ambiguous fall-back hour. Disagreement with a
  // round trip means the second guess is right; with none, the time fell in the spring gap and the
  // later instant moves it forward by the missing hour.
  const utc =
    first === second || toLocalDateTimeInputValue(new Date(second), timeZone) === value.slice(0, 16)
      ? second
      : Math.max(first, second);
  return new Date(utc).toISOString();
}
