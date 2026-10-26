import { useState, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { Check, Ellipsis } from "lucide-react";

import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Chip } from "@/components/ui/chip";
import { Sheet } from "@/components/ui/sheet";
import { isOver } from "@/lib/datetime";
import type { Attendee, EventDetail } from "@/lib/events";
import { inCheckInWindow, isFull, rsvpState } from "./event-state";
import { StateChip } from "./event-state-chip";
import type { RsvpController } from "./use-rsvp";

/**
 * The fixed bar above the tab bar on the event page. One loud thing: Going (or Check in while
 * the window is open). Leave and Cancel plan live behind the overflow button in a sheet.
 */
export function RsvpBar({
  event,
  mine,
  isHost,
  rsvp,
  onCheckIn,
  checkingIn,
  onCancelEvent,
}: {
  event: EventDetail;
  mine: Attendee | null;
  isHost: boolean;
  rsvp: RsvpController;
  onCheckIn: () => void;
  checkingIn: boolean;
  onCancelEvent: () => void;
}) {
  const [moreOpen, setMoreOpen] = useState(false);
  const now = new Date();
  const cancelled = event.status === "cancelled";
  const over = isOver(event.ends_at, now);
  const status = mine && mine.status !== "cancelled" ? mine.status : null;
  const checkable = status === "going" && !cancelled && inCheckInWindow(event, now);
  const pending = rsvp.isPending(event.id);
  const full = isFull(event);

  let content: ReactNode;
  if (cancelled) {
    content = (
      <Button size="lg" block disabled>
        Cancelled
      </Button>
    );
  } else if (over && !checkable) {
    content = (
      <Button size="lg" block disabled>
        Over
      </Button>
    );
  } else if (isHost || status === "going" || status === "waitlisted") {
    const own = isHost
      ? { tone: "going" as const, label: "You're hosting" }
      : rsvpState(status, mine?.waitlist_position);
    content = (
      <>
        {own ? <StateChip tone={own.tone}>{own.label}</StateChip> : null}
        <span className="flex-1" />
        {checkable ? (
          mine?.checked_in_at ? (
            <StateChip tone="going">
              <Check className="size-3.5" aria-hidden="true" /> Checked in
            </StateChip>
          ) : (
            <Button onClick={onCheckIn} loading={checkingIn}>
              Check in
            </Button>
          )
        ) : null}
        {isHost ? (
          <Link
            to="/events/$id/edit"
            params={{ id: event.id }}
            className={buttonVariants({ variant: "secondary" })}
          >
            Edit
          </Link>
        ) : null}
        <Button
          variant="secondary"
          size="icon"
          aria-label="More"
          onClick={() => setMoreOpen(true)}
          disabled={pending}
        >
          <Ellipsis className="size-5" aria-hidden="true" />
        </Button>
      </>
    );
  } else {
    const interested = status === "interested";
    content = (
      <>
        <Chip
          selected={interested}
          className="h-11 px-4 text-[15px]"
          onClick={() => rsvp.set(event.id, interested ? "cancelled" : "interested")}
          disabled={pending}
        >
          Interested
        </Chip>
        <Button
          size="lg"
          className="flex-1"
          onClick={() => rsvp.set(event.id, "going")}
          loading={pending && rsvp.pendingStatus === "going"}
          disabled={pending || (full && !event.waitlist_enabled)}
        >
          {full ? (event.waitlist_enabled ? "Join waitlist" : "Full") : "Going"}
        </Button>
      </>
    );
  }

  return (
    <>
      <div className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom,0px))] z-20 border-t border-border bg-surface">
        <div className="mx-auto flex h-[72px] max-w-lg items-center gap-2 px-4">{content}</div>
      </div>

      <Sheet open={moreOpen} onClose={() => setMoreOpen(false)} title={event.title}>
        <div className="flex flex-col gap-2 pb-2">
          {isHost ? (
            <Button
              variant="danger"
              size="lg"
              block
              onClick={() => {
                setMoreOpen(false);
                onCancelEvent();
              }}
            >
              Cancel this plan
            </Button>
          ) : (
            <Button
              variant="danger"
              size="lg"
              block
              onClick={() => {
                setMoreOpen(false);
                rsvp.set(event.id, "cancelled");
              }}
            >
              {status === "waitlisted" ? "Leave the waitlist" : "Leave this plan"}
            </Button>
          )}
          <p className="text-center text-[13px] text-text-3">
            {isHost
              ? "Everyone going sees it as cancelled. This can't be undone."
              : "Your spot goes to the next person on the waitlist."}
          </p>
        </div>
      </Sheet>
    </>
  );
}
