import { buildIcs, icsFilename } from "@ap/core/calendar";

import { calendarEvent, getEventShareCard } from "@/lib/event-share";

/**
 * GET /e/[id]/calendar.ics: one VEVENT for the share page's Add to Calendar link. Times are UTC
 * instants (the Z form), so every calendar app shows them in its own zone; LOCATION is the coarse
 * location hint only, never the address (D-027). Campus and 21+ stubs have no times, so they 404
 * here. Same freshness window as the page.
 */
export const revalidate = 60;

export async function GET(_request: Request, { params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const card = await getEventShareCard(id);
  if (!card) return new Response("Not found", { status: 404 });

  return new Response(buildIcs(calendarEvent(card)), {
    status: 200,
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": `attachment; filename="${icsFilename(card.title)}"`,
    },
  });
}
