import { useState } from "react";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Check, UserX } from "lucide-react";
import { toast } from "sonner";

import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  approveRsvp,
  eventErrorMessage,
  removeRsvp,
  type Attendee,
  type EventDetail,
} from "@/lib/events";

/**
 * The host's attendee list (event_attendees() returns every live row for the host). Approve
 * reveals an approved-only address to that person; Remove cancels their RSVP and keeps them
 * out until a moderator steps in.
 */
export function AttendeesSection({
  event,
  attendees,
}: {
  event: EventDetail;
  attendees: Attendee[];
}) {
  const queryClient = useQueryClient();
  const [removing, setRemoving] = useState<Attendee | null>(null);
  const [reason, setReason] = useState("");
  const needsApproval = event.address_visibility === "approved_only";

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

  const going = attendees.filter((a) => a.status === "going");
  const waitlisted = attendees
    .filter((a) => a.status === "waitlisted")
    .sort((a, b) => (a.waitlist_position ?? 0) - (b.waitlist_position ?? 0));
  const interested = attendees.filter((a) => a.status === "interested");

  function row(a: Attendee) {
    const isHost = a.user_id === event.host_id;
    const name = a.profiles?.first_name ?? "Deleted user";
    const detail = isHost
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
        {!isHost && a.status === "going" && needsApproval ? (
          <Button
            variant={a.approved_by_host ? "secondary" : "outline"}
            size="sm"
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
        {!isHost ? (
          <Button
            variant="ghost"
            size="icon-sm"
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

  const groups: { title: string; rows: Attendee[] }[] = [
    { title: `Going · ${going.length}`, rows: going },
    { title: `Waitlist · ${waitlisted.length}`, rows: waitlisted },
    { title: `Interested · ${interested.length}`, rows: interested },
  ].filter((g) => g.rows.length > 0);

  return (
    <section className="flex flex-col gap-3">
      <h3 className="text-[17px] font-bold tracking-[-0.01em]">Attendees</h3>
      {needsApproval ? (
        <p className="text-[13px] text-text-2">
          The exact address goes only to people you approve here.
        </p>
      ) : null}
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
