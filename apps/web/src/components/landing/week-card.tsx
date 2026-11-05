import Link from "next/link";
import { distanceBandLabel } from "@ap/core/feed";
import { goingLabel, namesGeorgiaState, priceLabel, type WeekCard } from "@ap/core/recs";

import { formatEventTime } from "@/lib/event-time";

/**
 * One plan in "This week near you": hub, title, day and time at the venue, the distance band,
 * Free or the price, a rough going count and, for an imported listing, its source. No host, no
 * address and no description. A Georgia State source carries the not-affiliated line on this
 * card only (D-022). Opens the public share page, which applies its own rules.
 */
export function WeekCardView({ card }: { card: WeekCard }) {
  const when = formatEventTime(card.starts_at, null, card.timezone);
  const band = distanceBandLabel(card.distance_band);
  const price = priceLabel(card);
  const going = goingLabel(card.going_bucket);
  const facts = [band, price, going].filter(Boolean) as string[];
  return (
    <li className="min-w-0">
      <Link
        href={`/e/${card.id}`}
        className="flex h-full min-w-0 flex-col gap-1.5 rounded-card border border-border bg-surface p-4 transition-colors hover:bg-surface-2 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-link"
      >
        {card.hub ? (
          <span className="truncate text-[13px] font-semibold text-text-2">
            {card.hub.emoji ? <span aria-hidden="true">{card.hub.emoji} </span> : null}
            {card.hub.name}
          </span>
        ) : null}
        <span className="line-clamp-2 text-[17px] leading-snug font-bold tracking-[-0.01em] text-text">
          {card.title}
        </span>
        <span className="text-[14px] text-text-2 tabular-nums">{when}</span>
        {facts.length > 0 ? (
          <span className="text-[13px] text-text-2">{facts.join(" · ")}</span>
        ) : null}
        {card.is_imported && card.source_name ? (
          <span className="truncate text-[13px] text-text-2">From {card.source_name}</span>
        ) : null}
        {card.is_imported && namesGeorgiaState(card.source_name) ? (
          <span className="text-[12px] text-text-2">
            Not affiliated with or endorsed by Georgia State University.
          </span>
        ) : null}
      </Link>
    </li>
  );
}
