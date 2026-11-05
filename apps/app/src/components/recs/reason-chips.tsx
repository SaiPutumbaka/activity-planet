import { reasonLabel, splitReasons, type Reason } from "@ap/core/recs";

import { cn } from "@/lib/cn";
import { DISTANCE_UNIT } from "@/lib/units";

/**
 * Up to two explain-why chips the server chose (RECS_DESIGN 5.1), plus an imported listing's
 * "From {source}" attribution on a quieter line of its own. Read-only: a chip is never a button.
 */
export function ReasonChips({
  reasons,
  className,
}: {
  reasons: readonly Reason[];
  className?: string;
}) {
  const { chips, attribution } = splitReasons(reasons);
  if (chips.length === 0 && !attribution) return null;
  return (
    <div className={cn("flex min-w-0 flex-col gap-1", className)}>
      {chips.length > 0 ? (
        <ul className="flex min-w-0 flex-wrap gap-1" aria-label="Why this is suggested">
          {chips.map((r) => {
            const label = reasonLabel(r, DISTANCE_UNIT);
            return (
              <li
                key={label}
                data-testid="reason-chip"
                className="max-w-full rounded-control bg-surface-2 px-2 py-0.5 text-[12px] leading-snug font-semibold text-text-2 [overflow-wrap:anywhere]"
              >
                {label}
              </li>
            );
          })}
        </ul>
      ) : null}
      {attribution ? (
        <p className="truncate text-[12px] text-text-3">{reasonLabel(attribution)}</p>
      ) : null}
    </div>
  );
}
