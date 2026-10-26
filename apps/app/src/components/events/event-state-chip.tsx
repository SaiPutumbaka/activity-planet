import type { ReactNode } from "react";

import { cn } from "@/lib/cn";
import type { EventState, StateTone } from "./event-state";

/**
 * A word on a tinted pill, with the matching dot. Tones are the five state pairs from
 * tokens.css; the chip never uses the accent (that is for the one primary action).
 *
 *   <StateChip tone="going">You're in</StateChip>
 *   <EventStateChip state={eventState(event)} />
 */
const TONE: Record<StateTone, { pill: string; dot: string }> = {
  going: { pill: "bg-going-tint text-going", dot: "bg-going-dot" },
  live: { pill: "bg-live-tint text-live", dot: "bg-live-dot" },
  warning: { pill: "bg-warning-tint text-warning", dot: "bg-warning-dot" },
  danger: { pill: "bg-danger-tint text-danger", dot: "bg-danger-dot" },
  info: { pill: "bg-info-tint text-info", dot: "bg-info-dot" },
};

export function StateChip({
  tone,
  children,
  className,
}: {
  tone: StateTone;
  children: ReactNode;
  className?: string;
}) {
  const t = TONE[tone];
  return (
    <span
      className={cn(
        "inline-flex h-7 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-control px-2.5 text-[13px] font-semibold",
        t.pill,
        className,
      )}
    >
      <span aria-hidden="true" className={cn("size-1.5 rounded-full", t.dot)} />
      {children}
    </span>
  );
}

export function EventStateChip({
  state,
  className,
}: {
  state: EventState | null;
  className?: string;
}) {
  if (!state) return null;
  return (
    <StateChip tone={state.tone} className={className}>
      {state.label}
    </StateChip>
  );
}
