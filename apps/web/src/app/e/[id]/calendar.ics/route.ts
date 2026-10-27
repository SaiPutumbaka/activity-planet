import { excerpt, getEventShareCard, shareUrl } from "@/lib/event-share";

/**
 * GET /e/[id]/calendar.ics: one VEVENT for the share page's Add to Calendar link. Times are UTC
 * instants (the Z form), so every calendar app shows them in its own zone; LOCATION is the coarse
 * location hint only, never the address (D-027). Same freshness window as the page.
 */
export const revalidate = 60;

/** "2026-10-28T22:00:00+00:00" as the RFC 5545 UTC form "20261028T220000Z". */
function icsDate(iso: string): string {
  return new Date(iso)
    .toISOString()
    .replace(/[-:]/g, "")
    .replace(/\.\d{3}Z$/, "Z");
}

/** RFC 5545 3.3.11: backslash, semicolon and comma are escaped; newlines become "\n". */
function escapeText(value: string): string {
  return value
    .replace(/\\/g, "\\\\")
    .replace(/;/g, "\\;")
    .replace(/,/g, "\\,")
    .replace(/\r?\n/g, "\\n");
}

/** RFC 5545 3.1: lines are at most 75 octets; a continuation line starts with one space. */
function fold(line: string): string {
  const out: string[] = [];
  let current = "";
  let octets = 0;
  for (const ch of line) {
    const n = Buffer.byteLength(ch, "utf8");
    if (octets + n > 73) {
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

function slug(title: string): string {
  return (
    title
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 60) || "plan"
  );
}

export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const card = await getEventShareCard(id);
  if (!card) return new Response("Not found", { status: 404 });

  const url = shareUrl(card.id);
  const about = excerpt(card.description, 600);
  const description = [about, `Open in Activity Planet: ${url}`].filter(Boolean).join("\n\n");

  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Activity Planet//Event//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    "BEGIN:VEVENT",
    `UID:${card.id}@activityplanet.app`,
    `DTSTAMP:${icsDate(new Date().toISOString())}`,
    `DTSTART:${icsDate(card.starts_at)}`,
    `DTEND:${icsDate(card.ends_at)}`,
    `SUMMARY:${escapeText(card.title)}`,
    card.location_hint ? `LOCATION:${escapeText(card.location_hint)}` : null,
    `DESCRIPTION:${escapeText(description)}`,
    `URL:${url}`,
    "END:VEVENT",
    "END:VCALENDAR",
  ].filter((l) => l !== null);

  const body = `${lines.map(fold).join("\r\n")}\r\n`;
  return new Response(body, {
    status: 200,
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": `attachment; filename="${slug(card.title)}.ics"`,
    },
  });
}
