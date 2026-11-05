import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { formatPrice } from "@ap/core/coaching";

import { Avatar } from "@/components/ui/avatar";
import { recPrefsQuery, recsCoachesQuery, type RecOrigin } from "@/lib/recs";
import { RecCardMenu } from "./rec-card-menu";
import { ReasonChips } from "./reason-chips";
import { RecRow } from "./rec-row";

/**
 * "Coaches for you" at the top of Find a coach: coaches search_coaches would show here anyway,
 * ordered by the viewer's hubs and taste. Hidden while loading, on an error and when empty.
 */
export function CoachesForYou({ origin }: { origin: RecOrigin }) {
  const recs = useQuery(recsCoachesQuery(origin));
  const prefs = useQuery(recPrefsQuery(origin.userId));
  const rows = recs.data ?? [];
  if (rows.length === 0) return null;
  const why = prefs.data?.personalize === false ? "rules" : "personal";
  return (
    <RecRow id="coaches-for-you" title="Coaches for you" layout="list">
      {rows.map((c) => (
        <li
          key={c.user_id}
          data-testid="rec-coach-card"
          className="relative flex min-h-16 items-center gap-3 rounded-card border border-border bg-surface px-3 py-3"
        >
          <Link
            to="/coaches/$handle"
            params={{ handle: c.handle }}
            className="absolute inset-0 z-[1] rounded-card focus-visible:outline-offset-[-3px]"
            aria-label={c.first_name}
          />
          <Avatar src={c.avatar_url} name={c.first_name} size={44} />
          <span className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="flex min-w-0 items-baseline justify-between gap-2">
              <span className="truncate text-[15px] font-semibold">{c.first_name}</span>
              {c.from_price_minor != null && c.from_currency ? (
                <span className="shrink-0 text-[13px] font-semibold">
                  {c.from_price_minor === 0
                    ? "Free"
                    : `From ${formatPrice(c.from_price_minor, c.from_currency)}`}
                </span>
              ) : null}
            </span>
            {c.headline ? (
              <span className="truncate text-[13px] text-text-2">{c.headline}</span>
            ) : null}
            <ReasonChips reasons={c.reasons} />
          </span>
          <RecCardMenu
            kind="coach"
            id={c.user_id}
            name={c.first_name}
            reasons={c.reasons}
            why={why}
          />
        </li>
      ))}
    </RecRow>
  );
}
