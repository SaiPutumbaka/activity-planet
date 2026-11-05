import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";

import { recPrefsQuery, recsHubsQuery, type RecOrigin } from "@/lib/recs";
import { RecCardMenu } from "./rec-card-menu";
import { ReasonChips } from "./reason-chips";
import { RecRow, RecSlot } from "./rec-row";

/**
 * "Hubs you may like": hubs the viewer can join and has not, nearest to their taste and with
 * plans nearby. At the top of Hubs (full) and as a compact row at the bottom of Home. Hidden
 * while loading, on an error and when there is nothing to suggest.
 */
export function HubsYouMayLike({
  origin,
  compact = false,
}: {
  origin: RecOrigin;
  compact?: boolean;
}) {
  const recs = useQuery(recsHubsQuery(origin, compact ? 6 : 8));
  const prefs = useQuery(recPrefsQuery(origin.userId));
  const rows = recs.data ?? [];
  if (rows.length === 0) return null;
  const why = prefs.data?.personalize === false ? "rules" : "personal";
  return (
    <RecRow
      id={compact ? "hubs-you-may-like-home" : "hubs-you-may-like"}
      title="Hubs you may like"
      subtitle={compact ? undefined : "Join one to see its plans on Home."}
    >
      {rows.map((h) => (
        <RecSlot key={h.id}>
          <article
            data-testid="rec-hub-card"
            className="relative flex w-full items-start gap-3 rounded-card border border-border bg-surface p-3"
          >
            <Link
              to="/hubs/$slug"
              params={{ slug: h.slug }}
              className="absolute inset-0 z-[1] rounded-card focus-visible:outline-offset-[-3px]"
              aria-label={h.name}
            />
            <span
              aria-hidden="true"
              className="flex size-11 shrink-0 items-center justify-center rounded-tile bg-surface-2 text-[22px]"
            >
              {h.emoji ?? "•"}
            </span>
            <span className="flex min-w-0 flex-1 flex-col gap-1 pr-7">
              <span className="truncate text-[15px] font-semibold">{h.name}</span>
              <span className="text-[13px] text-text-2 tabular">
                {h.member_count} {h.member_count === 1 ? "member" : "members"}
              </span>
              <ReasonChips reasons={h.reasons} />
            </span>
            <div className="absolute top-1.5 right-1.5">
              <RecCardMenu kind="hub" id={h.id} name={h.name} reasons={h.reasons} why={why} />
            </div>
          </article>
        </RecSlot>
      ))}
    </RecRow>
  );
}
