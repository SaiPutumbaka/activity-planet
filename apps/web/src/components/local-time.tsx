"use client";

import { formatEventTime, formatRelativeDay } from "@/lib/event-time";
import { useLocalePrefs } from "@/lib/use-locale-prefs";

/**
 * An event's day and time in the reader's formats ("Thu, Nov 5 · 4:00 to 6:00 PM", or
 * "Thu 5 Nov · 16:00 to 18:00"), always at the venue's zone. For server-rendered pages: the HTML
 * carries the US form and the browser swaps in its own after hydration.
 */
export function LocalEventTime({
  startsAt,
  endsAt,
  timeZone,
  now,
}: {
  startsAt: string;
  endsAt?: string | null;
  timeZone: string;
  /** The server's render time (ISO), so the year rule matches the HTML. */
  now: string;
}) {
  const prefs = useLocalePrefs();
  return <>{formatEventTime(startsAt, endsAt, timeZone, new Date(now), prefs)}</>;
}

/** "Today", "Tomorrow", a weekday, otherwise the date in the reader's order. */
export function LocalRelativeDay({
  value,
  timeZone,
  now,
}: {
  value: string;
  timeZone: string;
  now: string;
}) {
  const prefs = useLocalePrefs();
  return <>{formatRelativeDay(value, timeZone, new Date(now), prefs)}</>;
}
