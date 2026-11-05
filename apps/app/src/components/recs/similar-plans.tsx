import { useQuery } from "@tanstack/react-query";

import { recsSimilarQuery, useRecOrigin } from "@/lib/recs";
import { RecEventCard } from "./rec-event-card";
import { RecRow, RecSlot } from "./rec-row";

/**
 * "Similar plans" below an event's details: up to six plans like this one, nearby and soon. Not
 * personal, so it shows with personalization off too. Hidden while loading, on an error and when
 * nothing is similar enough.
 */
export function SimilarPlans({ eventId, userId }: { eventId: string; userId: string }) {
  const origin = useRecOrigin(userId);
  const recs = useQuery(recsSimilarQuery(eventId, origin));
  const rows = recs.data ?? [];
  if (rows.length === 0) return null;
  return (
    <RecRow id="similar-plans" title="Similar plans" subtitle="Like this one, nearby and soon.">
      {rows.map((e) => (
        <RecSlot key={e.id}>
          <RecEventCard event={e} why="similar" className="w-full" />
        </RecSlot>
      ))}
    </RecRow>
  );
}
