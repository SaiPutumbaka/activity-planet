/**
 * Event times for the public site, Intl only, mirroring apps/app/src/lib/datetime.ts. Every
 * function takes the event's IANA timezone because a time is a wall-clock fact at the venue, not
 * on the reader's device.
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

/** "America/New_York" as "America/New York" for a "Times in …" note. */
export function timeZoneLabel(timeZone: string): string {
  return timeZone.replace(/_/g, " ");
}
