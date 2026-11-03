import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Check, CircleCheck, Megaphone, UserX } from "lucide-react";
import { toast } from "sonner";

import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  approveRsvp,
  eventErrorCode,
  eventErrorMessage,
  hostCheckIn,
  removeRsvp,
  type Attendee,
  type EventDetail,
} from "@/lib/events";
import {
  BROADCAST_DAILY_CAP,
  BROADCAST_MAX,
  broadcastErrorMessage,
  broadcastOpen,
  broadcastSentMessage,
  broadcastToEvent,
} from "@/lib/notifications";
import { inHostCheckInWindow } from "./event-state";

/**
 * The attendee list for whoever manages the plan: the host, a captain or organizer of its
 * chapter, or a moderator (event_attendees() returns every live row to them). Approve reveals an
 * approved-only address to that person; Check in marks them there (host_check_in, from an hour
 * before the start to a day after the end); Remove cancels their RSVP and keeps them out until a
 * moderator steps in. "Message everyone going" sends one note to the going and waitlisted
 * people (broadcast_to_event, up to 3 per plan per day) until a day after the end.
 */
export function AttendeesSection({
  event,
  attendees,
  isHost = true,
  viewerId,
}: {
  event: EventDetail;
  attendees: Attendee[];
  /** The viewer is the host (copy only; captains see "the host" where the host sees "you"). */
  isHost?: boolean;
  /** The signed-in viewer; left out of the broadcast recipient count. */
  viewerId?: string;
}) {
  const queryClient = useQueryClient();
  const [removing, setRemoving] = useState<Attendee | null>(null);
  const [reason, setReason] = useState("");
  const [composing, setComposing] = useState(false);
  const [message, setMessage] = useState("");
  const needsApproval = event.address_visibility === "approved_only";
  const checkInOpen = event.status !== "cancelled" && inHostCheckInWindow(event);

  const invalidate = () => queryClient.invalidateQueries({ queryKey: ["events", event.id] });

  const approve = useMutation({
    mutationFn: ({ userId, approved }: { userId: string; approved: boolean }) =>
      approveRsvp(event.id, userId, approved),
    onSuccess: (row) => {
      void invalidate();
      toast.success(
        row.approved_by_host ? "Approved. They can see the address." : "Approval removed.",
      );
    },
    onError: (err) => toast.error(eventErrorMessage(err)),
  });

  const checkIn = useMutation({
    mutationFn: ({ userId, checked }: { userId: string; checked: boolean }) =>
      hostCheckIn(event.id, userId, checked),
    onSuccess: (row) => {
      void invalidate();
      toast.success(row.checked_in_at ? "Checked in." : "Check-in undone.");
    },
    onError: (err) =>
      toast.error(
        eventErrorCode(err) === "check_in_window"
          ? "Check people in from an hour before the start until a day after the end."
          : eventErrorMessage(err),
      ),
  });

  const remove = useMutation({
    mutationFn: ({ userId, why }: { userId: string; why: string }) =>
      removeRsvp(event.id, userId, why),
    onSuccess: () => {
      void invalidate();
      setRemoving(null);
      setReason("");
      toast.success("Removed from this plan.");
    },
    onError: (err) => toast.error(eventErrorMessage(err)),
  });

  const broadcast = useMutation({
    mutationFn: (body: string) => broadcastToEvent(event.id, body),
    onSuccess: ({ recipients }) => {
      setComposing(false);
      setMessage("");
      toast.success(broadcastSentMessage(recipients));
    },
    onError: (err) => toast.error(broadcastErrorMessage(err)),
  });

  const going = attendees.filter((a) => a.status === "going");
  const waitlisted = attendees
    .filter((a) => a.status === "waitlisted")
    .sort((a, b) => (a.waitlist_position ?? 0) - (b.waitlist_position ?? 0));
  const interested = attendees.filter((a) => a.status === "interested");

  function row(a: Attendee) {
    const isHostRow = a.user_id === event.host_id;
    const name = a.profiles?.first_name ?? "Deleted user";
    const detail = isHostRow
      ? "Host"
      : a.status === "waitlisted"
        ? `Waitlist #${a.waitlist_position ?? "?"}`
        : a.checked_in_at
          ? "Checked in"
          : a.status === "going" && needsApproval
            ? a.approved_by_host
              ? "Has the address"
              : "Waiting for the address"
            : null;
    return (
      <li key={a.user_id} className="flex min-h-14 items-center gap-3 px-4 py-2">
        <Avatar src={a.profiles?.avatar_url} name={name} size={36} />
        <div className="min-w-0 flex-1">
          <p className="truncate text-[15px] font-semibold">
            {name}
            {a.profiles?.handle ? (
              <span className="font-normal text-text-3"> @{a.profiles.handle}</span>
            ) : null}
          </p>
          {detail ? <p className="text-[13px] text-text-2">{detail}</p> : null}
        </div>
        {checkInOpen && a.status === "going" ? (
          <Button
            variant={a.checked_in_at ? "secondary" : "outline"}
            onClick={() => checkIn.mutate({ userId: a.user_id, checked: !a.checked_in_at })}
            loading={checkIn.isPending && checkIn.variables?.userId === a.user_id}
            aria-pressed={Boolean(a.checked_in_at)}
            aria-label={a.checked_in_at ? `Undo check-in for ${name}` : `Check in ${name}`}
            leading={
              a.checked_in_at ? <CircleCheck className="size-4" aria-hidden="true" /> : undefined
            }
          >
            {a.checked_in_at ? "Here" : "Check in"}
          </Button>
        ) : null}
        {!isHostRow && a.status === "going" && needsApproval ? (
          <Button
            variant={a.approved_by_host ? "secondary" : "outline"}
            onClick={() => approve.mutate({ userId: a.user_id, approved: !a.approved_by_host })}
            loading={approve.isPending && approve.variables?.userId === a.user_id}
            aria-pressed={a.approved_by_host}
            leading={
              a.approved_by_host ? <Check className="size-4" aria-hidden="true" /> : undefined
            }
          >
            {a.approved_by_host ? "Approved" : "Approve"}
          </Button>
        ) : null}
        {!isHostRow ? (
          <Button
            variant="ghost"
            size="icon"
            className="text-text-2"
            aria-label={`Remove ${name}`}
            onClick={() => {
              setReason("");
              setRemoving(a);
            }}
          >
            <UserX className="size-5" aria-hidden="true" />
          </Button>
        ) : null}
      </li>
    );
  }

  const recipients = attendees.filter(
    (a) => (a.status === "going" || a.status === "waitlisted") && a.user_id !== viewerId,
  ).length;
  const canBroadcast = broadcastOpen(event);
  const trimmed = message.trim();

  const groups: { title: string; rows: Attendee[] }[] = [
    { title: `Going · ${going.length}`, rows: going },
    { title: `Waitlist · ${waitlisted.length}`, rows: waitlisted },
    { title: `Interested · ${interested.length}`, rows: interested },
  ].filter((g) => g.rows.length > 0);

  return (
    <section className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-3">
        <h3 className="text-[17px] font-bold tracking-[-0.01em]">Attendees</h3>
        {canBroadcast ? (
          <Button
            variant="secondary"
            size="sm"
            disabled={recipients === 0}
            leading={<Megaphone className="size-4" aria-hidden="true" />}
            onClick={() => setComposing(true)}
          >
            Message everyone going
          </Button>
        ) : null}
      </div>
      {needsApproval ? (
        <p className="text-[13px] text-text-2">
          {isHost
            ? "The exact address goes only to people you approve here."
            : "The exact address goes only to people approved here."}
        </p>
      ) : null}
      {groups.length === 0 ? <p className="text-[14px] text-text-2">No one yet.</p> : null}
      {groups.map((g) => (
        <div key={g.title} className="flex flex-col gap-1.5">
          <h4 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            {g.title}
          </h4>
          <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
            {g.rows.map(row)}
          </ul>
        </div>
      ))}

      <Sheet
        open={composing}
        onClose={() => setComposing(false)}
        title="Message everyone going"
        footer={
          <Button
            size="lg"
            block
            loading={broadcast.isPending}
            disabled={trimmed.length === 0 || trimmed.length > BROADCAST_MAX}
            onClick={() => broadcast.mutate(trimmed)}
          >
            {recipients === 1 ? "Send to 1 person" : `Send to ${recipients} people`}
          </Button>
        }
      >
        <p className="text-[15px] text-text-2">
          Goes to everyone going and on the waitlist, in their inbox. Up to {BROADCAST_DAILY_CAP}{" "}
          messages per plan per day.
        </p>
        <FieldTextArea
          label="Message"
          className="mt-4"
          rows={4}
          maxLength={BROADCAST_MAX}
          placeholder="Running 10 minutes late. Meet at the north entrance."
          hint={`${trimmed.length}/${BROADCAST_MAX}`}
          value={message}
          onChange={(e) => setMessage(e.target.value)}
          disabled={broadcast.isPending}
        />
      </Sheet>

      <Sheet
        open={removing !== null}
        onClose={() => setRemoving(null)}
        title={removing ? `Remove ${removing.profiles?.first_name ?? "this person"}?` : "Remove"}
        footer={
          <Button
            variant="danger"
            size="lg"
            block
            loading={remove.isPending}
            onClick={() => removing && remove.mutate({ userId: removing.user_id, why: reason })}
          >
            Remove from this plan
          </Button>
        }
      >
        <p className="text-[15px] text-text-2">
          They lose their spot and can't rejoin this plan. The next person on the waitlist moves up.
        </p>
        <FieldTextArea
          label="Reason (optional, kept for moderators)"
          className="mt-4"
          rows={3}
          maxLength={200}
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          disabled={remove.isPending}
        />
      </Sheet>
    </section>
  );
}
