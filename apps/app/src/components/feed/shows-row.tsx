import { useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { EventCard } from "@/components/events/event-card";
import { Button } from "@/components/ui/button";
import { showsFeedQuery, type FeedParams } from "@/lib/events";
import { importLabelsQuery } from "@/lib/imports";
import { showsAvailableQuery } from "@/lib/shows";

const STEP = 5;

/**
 * "Shows and games" (D-041 slice 10): ticketed shows and games from the ticketing sources, in a
 * row of their own between the plans and "Also happening". Nothing is fetched or shown until
 * shows_available() says a show exists anywhere, and the row is hidden while it has none here.
 * Cards link out to the ticket seller like imported listings; there is no RSVP.
 */
export function ShowsRow(
  props: Pick<FeedParams, "userId" | "point" | "areaId" | "homeKey" | "timeZone">,
) {
  const available = useQuery(showsAvailableQuery);
  const shows = useQuery({ ...showsFeedQuery(props), enabled: available.data === true });
  const [shown, setShown] = useState(STEP);
  const events = shows.data ?? [];
  const visible = events.slice(0, shown);
  const labels = useQuery({
    ...importLabelsQuery(visible.map((e) => e.id)),
    enabled: visible.length > 0,
  });
  if (available.data !== true || events.length === 0) return null;
  return (
    <section className="flex flex-col gap-3" aria-labelledby="shows-and-games">
      <div>
        <h3 id="shows-and-games" className="text-[17px] font-bold tracking-[-0.01em]">
          Shows and games
        </h3>
        <p className="text-[13px] text-text-2">
          Ticketed events nearby. Tickets and details are on the seller's site.
        </p>
      </div>
      {visible.map((e) => (
        <EventCard
          key={e.id}
          event={e}
          onGoing={() => undefined}
          pending={false}
          importLabel={labels.data?.get(e.id) ?? null}
        />
      ))}
      {events.length > shown ? (
        <Button
          variant="secondary"
          className="self-center"
          onClick={() => setShown((n) => n + STEP)}
        >
          Show more ({events.length - shown} more)
        </Button>
      ) : null}
    </section>
  );
}
