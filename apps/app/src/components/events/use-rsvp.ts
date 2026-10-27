import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import {
  acceptGuidelines,
  eventErrorMessage,
  isGuidelinesRequired,
  setRsvp,
  type RsvpStatus,
} from "@/lib/events";

/**
 * set_rsvp with the guidelines gate: the first RSVP of an account raises guidelines_required,
 * which opens the Community guidelines sheet; accepting calls accept_guidelines() and retries the
 * same RSVP. One hook serves a page or a whole list (pass the event id per call). The caller
 * renders <GuidelinesSheet {...rsvp.guidelines} />.
 *
 *   const rsvp = useRsvp();
 *   <Button onClick={() => rsvp.set(event.id, "going")} loading={rsvp.isPending(event.id)}>Going</Button>
 */
export interface RsvpIntent {
  eventId: string;
  status: RsvpStatus;
}

export function useRsvp() {
  const queryClient = useQueryClient();
  const [gated, setGated] = useState<RsvpIntent | null>(null);
  const [accepting, setAccepting] = useState(false);

  const mutation = useMutation({
    mutationFn: ({ eventId, status }: RsvpIntent) => setRsvp(eventId, status),
    onSuccess: (row, { eventId, status }) => {
      void queryClient.invalidateQueries({ queryKey: ["events", eventId] });
      void queryClient.invalidateQueries({ queryKey: ["feed"] });
      void queryClient.invalidateQueries({ queryKey: ["hubs", "events"] });
      const got = row?.status ?? (status === "cancelled" ? "cancelled" : status);
      if (got === "going") toast.success("You're in.");
      else if (got === "waitlisted")
        toast.success(
          row?.waitlist_position
            ? `On the waitlist, #${row.waitlist_position}.`
            : "On the waitlist.",
        );
      else if (got === "interested") toast.success("Marked interested.");
      else toast("You left this plan.");
    },
    onError: (err, intent) => {
      if (isGuidelinesRequired(err)) setGated(intent);
      else toast.error(eventErrorMessage(err));
    },
  });

  async function acceptAndRetry() {
    const pending = gated;
    setAccepting(true);
    try {
      await acceptGuidelines();
      void queryClient.invalidateQueries({ queryKey: ["profile"] });
      setGated(null);
      if (pending) mutation.mutate(pending);
    } catch (err) {
      toast.error(eventErrorMessage(err));
    } finally {
      setAccepting(false);
    }
  }

  return {
    set: (eventId: string, status: RsvpStatus) => mutation.mutate({ eventId, status }),
    /** True while this event's RSVP is in flight (or its guidelines sheet is open). */
    isPending: (eventId: string) =>
      (mutation.isPending && mutation.variables?.eventId === eventId) || gated?.eventId === eventId,
    pendingStatus: mutation.isPending ? mutation.variables?.status : undefined,
    guidelines: {
      open: gated !== null,
      onClose: () => setGated(null),
      onAccept: acceptAndRetry,
      accepting,
    },
  };
}

export type RsvpController = ReturnType<typeof useRsvp>;
