/**
 * Event times, Intl only. Every function takes an IANA timezone (events.timezone, default
 * America/New_York) because a time is a wall-clock fact at the venue, not on the phone.
 *
 *   formatEventTime(e.starts_at, e.ends_at, e.timezone)  // "Thu, Nov 5 · 4:00 to 6:00 PM"
 *   formatRelativeDay(e.starts_at, e.timezone)            // "Today" | "Tomorrow" | "Thu" | "Thu, Nov 5"
 *   isHappeningNow(e.starts_at, e.ends_at)                // raspberry "Happening now"
 *   isOver(e.ends_at)
 *   toLocalDateTimeInputValue(e.starts_at, tz)            // "2026-11-05T16:00" for <input type="datetime-local">
 *   fromLocalDateTimeInputValue("2026-11-05T16:00", tz)   // ISO string in UTC, or null
 */
export const DEFAULT_TIMEZONE = "America/New_York";

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

function formatTimeParts(date: Date, timeZone: string): { clock: string; period: string } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hour: "numeric",
    minute: "2-digit",
    hour12: true,
  }).formatToParts(date);
  const hour = parts.find((p) => p.type === "hour")?.value ?? "";
  const minute = parts.find((p) => p.type === "minute")?.value ?? "00";
  const period = parts.find((p) => p.type === "dayPeriod")?.value ?? "";
  return { clock: `${hour}:${minute}`, period };
}

function formatDay(date: Date, timeZone: string, now: Date): string {
  const sameYear = wallClock(date, timeZone).year === wallClock(now, timeZone).year;
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    month: "short",
    day: "numeric",
    ...(sameYear ? {} : { year: "numeric" }),
  }).format(date);
}

/** "Thu, Nov 5 · 4:00 to 6:00 PM"; "11:30 AM to 1:00 PM" across noon; the end day when it differs. */
export function formatEventTime(
  startsAt: DateInput,
  endsAt?: DateInput | null,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
): string {
  const start = toDate(startsAt);
  if (Number.isNaN(start.getTime())) return "";
  const day = formatDay(start, timeZone, now);
  const s = formatTimeParts(start, timeZone);
  const end = endsAt ? toDate(endsAt) : null;
  if (!end || Number.isNaN(end.getTime()) || end <= start) return `${day} · ${s.clock} ${s.period}`;

  const e = formatTimeParts(end, timeZone);
  if (dayNumber(end, timeZone) !== dayNumber(start, timeZone)) {
    return `${day} · ${s.clock} ${s.period} to ${formatDay(end, timeZone, now)} · ${e.clock} ${e.period}`;
  }
  return s.period === e.period
    ? `${day} · ${s.clock} to ${e.clock} ${s.period}`
    : `${day} · ${s.clock} ${s.period} to ${e.clock} ${e.period}`;
}

/** "4:00 PM" on its own, for rows that already show the day. */
export function formatTime(value: DateInput, timeZone: string = DEFAULT_TIMEZONE): string {
  const date = toDate(value);
  if (Number.isNaN(date.getTime())) return "";
  const t = formatTimeParts(date, timeZone);
  return `${t.clock} ${t.period}`;
}

/** "Today", "Tomorrow", "Yesterday", a weekday within the week, otherwise "Thu, Nov 5". */
export function formatRelativeDay(
  value: DateInput,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
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
  return formatDay(date, timeZone, now);
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
