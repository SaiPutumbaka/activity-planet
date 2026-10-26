import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CalendarPlus } from "lucide-react";
import { DefaultCover } from "@ap/ui/brand";

import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { formatRelativeDay, formatTime, isHappeningNow } from "@/lib/datetime";
import {
  UPCOMING_WINDOW_DAYS,
  eventPath,
  formatGoing,
  hubUpcomingEventsQuery,
  isFull,
  type HubEvent,
} from "@/lib/hubs";

import { HubBadges } from "./hub-badges";
import { InlineError, ListSkeleton } from "./hub-states";

/** The hub page's "Upcoming" list: published events in the next 30 days, each a link to its page. */
export function HubEvents({ hubId, hubSlug }: { hubId: string; hubSlug: string }) {
  const events = useQuery(hubUpcomingEventsQuery(hubId));
  // Not a literal on the Link so the key passes through to /post, whose schema another build owns.
  const postSearch = { hub: hubSlug };

  if (events.isPending) return <ListSkeleton rows={3} rowClassName="h-24" />;
  if (events.isError) {
    return (
      <InlineError
        message="Couldn't load this hub's plans."
        onRetry={() => {
          void events.refetch();
        }}
      />
    );
  }
  if (events.data.length === 0) {
    return (
      <EmptyState
        icon={CalendarPlus}
        title="Nothing scheduled yet"
        body={`Plans in the next ${UPCOMING_WINDOW_DAYS} days show up here.`}
        action={
          <Link to="/post" search={postSearch} className={buttonVariants({ variant: "secondary" })}>
            Post the first plan
          </Link>
        }
        className="py-8"
      />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {events.data.map((event) => (
        <li key={event.id}>
          <EventRow event={event} />
        </li>
      ))}
    </ul>
  );
}

function EventRow({ event }: { event: HubEvent }) {
  const live = isHappeningNow(event.starts_at, event.ends_at);
  const full = isFull(event);
  const where = [event.location_hint, formatGoing(event)].filter(Boolean).join(" · ");

  return (
    <Link
      to={eventPath(event.id)}
      className="flex gap-3 rounded-card border border-border bg-surface p-3 shadow-[var(--shadow-card)] transition-colors hover:bg-surface-2"
    >
      <div className="h-[72px] w-[88px] shrink-0 overflow-hidden rounded-tile bg-surface-2">
        {event.cover_url ? (
          <img src={event.cover_url} alt="" loading="lazy" className="size-full object-cover" />
        ) : (
          <DefaultCover seed={event.id} />
        )}
      </div>
      <div className="min-w-0 flex-1">
        <p className="flex flex-wrap items-center gap-1.5 text-[12px] font-semibold">
          {live ? (
            <span className="rounded-full bg-live-tint px-2 py-0.5 text-live">Happening now</span>
          ) : (
            <span className="text-text-2">
              {formatRelativeDay(event.starts_at, event.timezone)} ·{" "}
              {formatTime(event.starts_at, event.timezone)}
            </span>
          )}
          {full ? (
            <span className="rounded-full bg-warning-tint px-2 py-0.5 text-warning">Full</span>
          ) : null}
          {event.kind === "imported" ? (
            <span className="rounded-full bg-info-tint px-2 py-0.5 text-info">Imported</span>
          ) : null}
          <HubBadges
            minAge={event.min_age}
            scope={event.visibility === "campus" ? "campus" : "general"}
          />
        </p>
        <p className="mt-0.5 line-clamp-2 text-[15px] leading-tight font-semibold">{event.title}</p>
        {where ? <p className="mt-1 truncate text-[13px] text-text-2">{where}</p> : null}
      </div>
    </Link>
  );
}
