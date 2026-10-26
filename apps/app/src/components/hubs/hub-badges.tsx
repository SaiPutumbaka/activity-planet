import type { ReactNode } from "react";

import { cn } from "@/lib/cn";

/**
 * "21+" and "Campus" markers for a hub or an event. A neutral surface, not a state hue: the board
 * reserves green, raspberry, amber, red and grey-blue for states, and these are facts.
 */
export function HubBadges({
  minAge,
  scope,
  className,
}: {
  minAge: number;
  scope: string;
  className?: string;
}) {
  const age = minAge > 18;
  const campus = scope === "campus";
  if (!age && !campus) return null;
  return (
    <span className={cn("inline-flex shrink-0 items-center gap-1", className)}>
      {age ? <Badge>{minAge}+</Badge> : null}
      {campus ? <Badge>Campus</Badge> : null}
    </span>
  );
}

function Badge({ children }: { children: ReactNode }) {
  return (
    <span className="rounded-full bg-surface-3 px-1.5 py-0.5 text-[11px] font-bold leading-none text-text-2 tabular">
      {children}
    </span>
  );
}
