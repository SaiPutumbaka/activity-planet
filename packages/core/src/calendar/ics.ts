/**
 * One-event iCalendar files (RFC 5545), shared by the site's /e/[id]/calendar.ics route and the
 * app's in-app Add to Calendar. Times are UTC instants (the Z form), so every calendar app shows
 * them in its own zone. No Node APIs: this also runs in the browser.
 */

export type CalendarEvent = {
  /** Stable id; the UID becomes `<id>@activityplanet.app`, so re-adding updates, not duplicates. */
  id: string;
  title: string;
  startsAt: string | Date;
  endsAt: string | Date;
  description?: string | null;
  location?: string | null;
  url?: string | null;
};

/** "2026-10-28T22:00:00+00:00" as the RFC 5545 UTC form "20261028T220000Z". */
export function icsDate(value: string | Date): string {
  return new Date(value)
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

/** RFC 5545 3.3.11: backslash, semicolon and comma are escaped; CRLF, CR and LF each become "\n". */
export function escapeText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r\n|\r|\n/g, "\\n");
}

const encoder = new TextEncoder();

/**
 * RFC 5545 3.1: lines are at most 75 octets, not counting the CRLF; a continuation line starts
 * with one space, which counts toward its 75. Splits between code points, never inside one.
 */
export function fold(line: string): string {
  const out: string[] = [];
  let current = "";
  let octets = 0;
  for (const ch of line) {
    const n = encoder.encode(ch).length;
    if (octets + n > 75) {
      out.push(current);
      current = " ";
      octets = 1;
    }
    current += ch;
    octets += n;
  }
  out.push(current);
  return out.join("\r\n");
}

/** The whole VCALENDAR with one VEVENT, CRLF line endings and folded lines. */
export function buildIcs(event: CalendarEvent, now: Date = new Date()): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Activity Planet//Event//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${event.id}@activityplanet.app`,
    `DTSTAMP:${icsDate(now)}`,
    `DTSTART:${icsDate(event.startsAt)}`,
    `DTEND:${icsDate(event.endsAt)}`,
    `SUMMARY:${escapeText(event.title)}`,
    event.location ? `LOCATION:${escapeText(event.location)}` : null,
    event.description ? `DESCRIPTION:${escapeText(event.description)}` : null,
    event.url ? `URL:${event.url}` : null,
    "END:VEVENT",
    "END:VCALENDAR",
  ].filter((l) => l !== null);
  return `${lines.map(fold).join("\r\n")}\r\n`;
}

/** A filename for the download: "pickup-basketball.ics". */
export function icsFilename(title: string): string {
  const slug =
    title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "plan";
  return `${slug}.ics`;
}

/**
 * Google Calendar's prefilled "add event" page. Google has no .ics import from a link, so the
 * site and the app offer this next to the file.
 */
export function googleCalendarUrl(event: CalendarEvent): string {
  const params = new URLSearchParams({
    action: "TEMPLATE",
    text: event.title,
    dates: `${icsDate(event.startsAt)}/${icsDate(event.endsAt)}`,
  });
  const withUrl = event.url && !event.description?.includes(event.url);
  const details = [event.description, withUrl ? event.url : null].filter(Boolean).join("\n\n");
  if (details) params.set("details", details);
  if (event.location) params.set("location", event.location);
  return `https://calendar.google.com/calendar/render?${params.toString()}`;
}
