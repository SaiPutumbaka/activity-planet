import { useState } from "react";
import { useQuery } from "@tanstack/react-query";
import { Link } from "@tanstack/react-router";

import { EventCard } from "@/components/events/event-card";
import { Button } from "@/components/ui/button";
import type { FeedEvent } from "@/lib/events";
import { importLabelsQuery } from "@/lib/imports";

/**
 * "Also happening": listings imported from public calendars, always below the plans people
 * host here and hidden when there are none. Each card names its source and links out instead
 * of offering an RSVP; the labels (source chip, open to the public, not-affiliated line) load
 * in one imported_event_labels() call and the cards render without them until it answers.
 * A city calendar can list hundreds of things, so the shelf opens with ten and grows on request.
 */
const SHELF_STEP = 10;

export function ImportedShelf({ events }: { events: FeedEvent[] }) {
  const [shown, setShown] = useState(SHELF_STEP);
  const visible = events.slice(0, shown);
  const labels = useQuery(importLabelsQuery(visible.map((e) => e.id)));
  if (events.length === 0) return null;
  return (
    <section className="flex flex-col gap-3" aria-labelledby="also-happening">
      <div>
        <h3 id="also-happening" className="text-[17px] font-bold tracking-[-0.01em]">
          Also happening
        </h3>
        <p className="text-[13px] text-text-2">
          From public calendars near you. Details and sign-up are on each source's site.
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
          onClick={() => setShown((n) => n + SHELF_STEP)}
        >
          Show more ({events.length - shown} more)
        </Button>
      ) : null}
      <p className="text-[13px] text-text-2">
        Missing a calendar near you?{" "}
        <Link to="/suggest-calendar" className="font-semibold text-primary-text hover:underline">
          Suggest it
        </Link>
      </p>
    </section>
  );
}
