import { ImageResponse } from "next/og";

import { getEventShare, isRestricted, type EventShareCard } from "@/lib/event-share";
import { formatEventTime } from "@/lib/event-time";
import { GenericOgCard, OG_SIZE, OgCard, ogFonts, truncate } from "@/lib/og";

/**
 * The link preview for /e/[id]: the planet scene as a flat band, the title in large type, the
 * time and hub line, and the Activity Planet lockup. Campus and 21+ plans get the site's generic
 * card. Next injects it as og:image and twitter:image for the page. Same freshness window as the
 * page.
 */
export const revalidate = 60;
export const alt = "A plan on Activity Planet";
export const size = OG_SIZE;
export const contentType = "image/png";

export default async function OpenGraphImage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const [share, fonts] = await Promise.all([getEventShare(id), ogFonts()]);

  return new ImageResponse(
    share && isRestricted(share) ? <GenericOgCard /> : <Scene card={share} />,
    { ...size, fonts, status: share ? 200 : 404 },
  );
}

function Scene({ card }: { card: EventShareCard | null }) {
  const title = card ? truncate(card.title, 80) : "This plan isn't here";
  const meta = card
    ? [
        formatEventTime(card.starts_at, card.ends_at, card.timezone),
        card.hub.name,
        card.location_hint,
      ]
        .filter(Boolean)
        .join("  ·  ")
    : "It may have been removed, or it is not public.";
  const host = card?.host ? `Hosted by ${card.host.first_name} · @${card.host.handle}` : null;

  return <OgCard title={title} meta={meta} aside={host} />;
}
