import { Link } from "@tanstack/react-router";
import { useInfiniteQuery } from "@tanstack/react-query";

import { CardList, CoachCard } from "@/components/coaching/parts";
import { coachSearchQuery } from "@/lib/coaching";

/**
 * "Coaches in this hub" (design section 5): search_coaches with the hub, near the viewer or
 * online. Renders nothing when there are none, so a hub without coaches stays as it was.
 */
export function HubCoaches({ hubId }: { hubId: string }) {
  const results = useInfiniteQuery(coachSearchQuery({ hubId }));
  const rows = (results.data?.pages.flat() ?? []).slice(0, 3);
  if (rows.length === 0) return null;
  return (
    <section className="flex flex-col gap-3" aria-labelledby="hub-coaches">
      <div className="flex items-baseline justify-between gap-3">
        <h3 id="hub-coaches" className="text-[17px] font-bold tracking-[-0.01em]">
          Coaches in this hub
        </h3>
        <Link
          to="/coaches"
          search={{ hub: hubId }}
          className="text-[14px] font-semibold text-primary-text"
        >
          See all
        </Link>
      </div>
      <CardList label="Coaches in this hub">
        {rows.map((c) => (
          <li key={c.user_id}>
            <CoachCard coach={c} />
          </li>
        ))}
      </CardList>
    </section>
  );
}
