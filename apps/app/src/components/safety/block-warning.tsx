import { useQuery } from "@tanstack/react-query";
import { ShieldAlert } from "lucide-react";

import { blockWarningText, eventBlockWarningQuery } from "@/lib/safety";

/**
 * The co-attendance heads-up on a plan page (event_block_warning): someone the viewer blocked is
 * hosting or on this plan. Only the blocker sees it; the other person is never told.
 */
export function BlockWarning({ eventId, userId }: { eventId: string; userId: string }) {
  const warning = useQuery(eventBlockWarningQuery(eventId, userId));
  const text = blockWarningText(warning.data ?? 0);
  if (!text) return null;
  return (
    <p
      role="status"
      className="flex items-start gap-2 rounded-input bg-surface-2 px-4 py-3 text-[14px]"
    >
      <ShieldAlert className="mt-0.5 size-4 shrink-0 text-text-2" aria-hidden="true" />
      <span>{text} They aren&apos;t told.</span>
    </p>
  );
}
