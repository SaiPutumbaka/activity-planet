import { US_PREFS, clockParts, formatDay as formatDayIn, type LocalePrefs } from "@ap/core/locale";

/**
 * Event times for the public site, Intl only, mirroring apps/app/src/lib/datetime.ts. Every
 * function takes the event's IANA timezone because a time is a wall-clock fact at the venue, not
 * on the reader's device. Clock and date order follow `prefs` (packages/core/src/locale): pages
 * render with US_PREFS on the server and switch to the reader's locale in the browser
 * (useLocalePrefs, components/local-time.tsx).
 */
export const DEFAULT_TIMEZONE = "America/New_York";

type DateInput = string | Date;

function toDate(value: DateInput): Date {
  return value instanceof Date ? value : new Date(value);
}

function wallClock(date: Date, timeZone: string) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone,
    hourCycle: "h23",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(date);
  const get = (type: Intl.DateTimeFormatPartTypes) =>
    Number(parts.find((p) => p.type === type)?.value ?? "0");
  return { year: get("year"), month: get("month"), day: get("day") };
}

/** Local calendar date as days since the epoch, for "today / tomorrow" arithmetic. */
function dayNumber(date: Date, timeZone: string): number {
  const w = wallClock(date, timeZone);
  return Math.floor(Date.UTC(w.year, w.month - 1, w.day) / 86_400_000);
}

function formatDay(date: Date, timeZone: string, now: Date, prefs: LocalePrefs): string {
  return formatDayIn(date, timeZone, prefs, { now });
}

function joinClock(t: { clock: string; period: string }): string {
  return t.period ? `${t.clock} ${t.period}` : t.clock;
}

/** "Thu, Nov 5 · 4:00 to 6:00 PM"; "11:30 AM to 1:00 PM" across noon; the end day when it differs. */
export function formatEventTime(
  startsAt: DateInput,
  endsAt?: DateInput | null,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
  prefs: LocalePrefs = US_PREFS,
): string {
  const start = toDate(startsAt);
  if (Number.isNaN(start.getTime())) return "";
  const day = formatDay(start, timeZone, now, prefs);
  const s = clockParts(start, timeZone, prefs);
  const end = endsAt ? toDate(endsAt) : null;
  if (!end || Number.isNaN(end.getTime()) || end <= start) return `${day} · ${joinClock(s)}`;

  const e = clockParts(end, timeZone, prefs);
  if (dayNumber(end, timeZone) !== dayNumber(start, timeZone)) {
    return `${day} · ${joinClock(s)} to ${formatDay(end, timeZone, now, prefs)} · ${joinClock(e)}`;
  }
  return s.period === e.period
    ? `${day} · ${s.clock} to ${joinClock(e)}`
    : `${day} · ${joinClock(s)} to ${joinClock(e)}`;
}

/** "Today", "Tomorrow", "Yesterday", a weekday within the week, otherwise "Thu, Nov 5". */
export function formatRelativeDay(
  value: DateInput,
  timeZone: string = DEFAULT_TIMEZONE,
  now: Date = new Date(),
  prefs: LocalePrefs = US_PREFS,
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

/** "America/New_York" as "America/New York" for a "Times in …" note. */
export function timeZoneLabel(timeZone: string): string {
  return timeZone.replace(/_/g, " ");
}
