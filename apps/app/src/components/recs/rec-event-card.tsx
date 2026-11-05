import { Link } from "@tanstack/react-router";
import { namesGeorgiaState, type RecEvent } from "@ap/core/recs";
import { EventCover } from "@/components/events/event-cover";

import { formatRelativeDay, formatTime } from "@/lib/datetime";
import { cn } from "@/lib/cn";
import { RecCardMenu, type WhyKind } from "./rec-card-menu";
import { ReasonChips } from "./reason-chips";

/**
 * A compact plan card for the recommendation rows (For you, Similar plans): the cover, the
 * title, hub and day, then the server's reasons. The whole card opens the plan; the "..." sits
 * above the link. A card from a Georgia State source carries the not-affiliated line (D-022).
 */
export function RecEventCard({
  event,
  why,
  className,
}: {
  event: RecEvent;
  why: WhyKind;
  className?: string;
}) {
  const when = `${formatRelativeDay(event.starts_at, event.timezone)} · ${formatTime(event.starts_at, event.timezone)}`;
  return (
    <article
      data-testid="rec-event-card"
      className={cn(
        "relative flex flex-col overflow-hidden rounded-card border border-border bg-surface shadow-[var(--shadow-card)]",
        className,
      )}
    >
      <Link
        to="/events/$id"
        params={{ id: event.id }}
        className="absolute inset-0 z-[1] rounded-card focus-visible:outline-offset-[-3px]"
        aria-label={event.title}
      />
      <div className="relative h-[88px] bg-surface-2">
        <EventCover
          src={event.cover_url}
          seed={event.id}
          width={260}
          height={88}
          loading="lazy"
          decoding="async"
        />
        <div className="absolute top-1.5 right-1.5">
          <RecCardMenu
            kind="event"
            id={event.id}
            name={event.title}
            reasons={event.reasons}
            why={why}
          />
        </div>
      </div>
      <div className="flex min-w-0 flex-1 flex-col gap-1 p-3">
        <h4 className="line-clamp-2 text-[15px] leading-snug font-bold tracking-[-0.01em]">
          {event.title}
        </h4>
        <p className="truncate text-[13px] text-text-2">
          {event.hub_name ? (
            <>
              <span aria-hidden="true">{event.hub_emoji}</span> {event.hub_name} ·{" "}
            </>
          ) : null}
          <span className="tabular">{when}</span>
        </p>
        <ReasonChips reasons={event.reasons} className="mt-auto pt-1" />
        {event.is_imported && namesGeorgiaState(event.source_name) ? (
          <p className="text-[11px] text-text-3">
            Not affiliated with or endorsed by Georgia State University.
          </p>
        ) : null}
      </div>
    </article>
  );
}
