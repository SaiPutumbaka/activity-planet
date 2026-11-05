import { useQuery } from "@tanstack/react-query";

import { recPrefsQuery, recsForYouQuery, type RecOrigin } from "@/lib/recs";
import { RecEventCard } from "./rec-event-card";
import { RecRow, RecSlot } from "./rec-row";

/**
 * "For you" on Home, above the day sections (RECS_DESIGN slice 2). Plans the feed would show
 * anyway, re-ranked by the viewer's hubs and plans; the server returns nothing under three, and
 * the row is hidden then, while loading, on an error and while a hub filter is on.
 */
export function ForYouRow({ origin, hidden }: { origin: RecOrigin; hidden?: boolean }) {
  const recs = useQuery({ ...recsForYouQuery(origin), enabled: !hidden });
  const prefs = useQuery(recPrefsQuery(origin.userId));
  const rows = recs.data ?? [];
  if (hidden || rows.length < 3) return null;
  const why = prefs.data?.personalize === false ? "rules" : "personal";
  return (
    <RecRow
      id="for-you"
      title="For you"
      subtitle={
        why === "personal"
          ? "Picked from your hubs and plans, close by and soon."
          : "Close by and soon."
      }
    >
      {rows.map((e) => (
        <RecSlot key={e.id}>
          <RecEventCard event={e} why={why} className="w-full" />
        </RecSlot>
      ))}
    </RecRow>
  );
}
