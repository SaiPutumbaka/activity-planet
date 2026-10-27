import { Link } from "@tanstack/react-router";
import { MapPin } from "lucide-react";
import { DefaultCover } from "@ap/ui/brand";

import { Button } from "@/components/ui/button";
import { formatTime } from "@/lib/datetime";
import type { FeedEvent } from "@/lib/events";
import { canRsvp, eventState, isFull, rsvpState } from "./event-state";
import { EventStateChip } from "./event-state-chip";

/**
 * One plan in the Home list. The whole card opens the event page; the quiet Going button RSVPs
 * in place (the parent owns the useRsvp controller and its guidelines sheet). The accent stays
 * on the event page's RsvpBar: a list of cards is not the place for N loud things.
 */
export function EventCard({
  event,
  onGoing,
  pending,
}: {
  event: FeedEvent;
  onGoing: () => void;
  pending: boolean;
}) {
  const state = eventState(event);
  const ownStatus = event.rsvps[0]?.status;
  const mine = ownStatus && ownStatus !== "cancelled" ? ownStatus : null;
  const myState = rsvpState(mine);
  const full = isFull(event);
  // A full plan without a waitlist has nothing to tap; the Full chip above already says so.
  const showGoing =
    canRsvp(event) &&
    mine !== "going" &&
    mine !== "waitlisted" &&
    !(full && !event.waitlist_enabled);
  const goingLabel = full ? "Join waitlist" : "Going";
  const hub = event.hubs;
  const time = `${formatTime(event.starts_at, event.timezone)} to ${formatTime(event.ends_at, event.timezone)}`;

  return (
    <article className="relative overflow-hidden rounded-card border border-border bg-surface shadow-[var(--shadow-card)]">
      <Link
        to="/events/$id"
        params={{ id: event.id }}
        className="absolute inset-0 z-[1] rounded-card focus-visible:outline-offset-[-3px]"
        aria-label={event.title}
      />
      <div className="h-[120px] bg-surface-2">
        {event.cover_url ? (
          <img src={event.cover_url} alt="" className="size-full object-cover" loading="lazy" />
        ) : (
          <DefaultCover seed={event.id} />
        )}
      </div>
      <div className="flex flex-col gap-1.5 p-4">
        {myState || state ? (
          <div className="flex flex-wrap gap-1.5">
            <EventStateChip state={myState} />
            <EventStateChip state={state} />
          </div>
        ) : null}
        <h4 className="text-[17px] leading-snug font-bold tracking-[-0.01em]">{event.title}</h4>
        <p className="text-[14px] text-text-2">
          {hub ? (
            <>
              <span aria-hidden="true">{hub.emoji}</span> {hub.name} ·{" "}
            </>
          ) : null}
          <span className="tabular">{time}</span>
        </p>
        {event.location_hint ? (
          <p className="flex items-center gap-1 text-[14px] text-text-2">
            <MapPin className="size-4 shrink-0" aria-hidden="true" />
            <span className="truncate">{event.location_hint}</span>
          </p>
        ) : null}
        <div className="mt-1 flex min-h-11 items-center justify-between gap-3">
          <span className="text-[13px] text-text-2 tabular">
            {event.going_count} going{event.capacity !== null ? ` of ${event.capacity}` : ""}
            {event.interested_count > 0 ? ` · ${event.interested_count} interested` : ""}
          </span>
          {showGoing ? (
            <Button
              variant="outline"
              className="relative z-[2]"
              onClick={onGoing}
              loading={pending}
            >
              {goingLabel}
            </Button>
          ) : null}
        </div>
      </div>
    </article>
  );
}
