import { EventCard } from "@/components/events/event-card";
import type { FeedEvent } from "@/lib/events";

/**
 * "Also happening": listings imported from public calendars, always below the plans people
 * host here and hidden when there are none. Each card names its source and links out instead
 * of offering an RSVP.
 */
export function ImportedShelf({ events }: { events: FeedEvent[] }) {
  if (events.length === 0) return null;
  return (
    <section className="flex flex-col gap-3" aria-labelledby="also-happening">
      <div>
        <h3 id="also-happening" className="text-[17px] font-bold tracking-[-0.01em]">
          Also happening
        </h3>
        <p className="text-[13px] text-text-2">
          From public calendars around town. Details and sign-up are on each source's site.
        </p>
      </div>
      {events.map((e) => (
        <EventCard key={e.id} event={e} onGoing={() => undefined} pending={false} />
      ))}
    </section>
  );
}
