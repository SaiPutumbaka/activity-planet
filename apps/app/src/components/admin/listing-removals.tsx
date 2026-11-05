import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Inbox } from "lucide-react";
import { toast } from "sonner";

import { DuePill } from "@/components/admin/admin-tabs";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  adminErrorMessage,
  adminKeys,
  dueLabel,
  dueTone,
  formatWhen,
  minutesUntil,
} from "@/lib/admin";
import {
  RELATIONSHIP_LABELS,
  canRemove,
  listingRemovalQueueQuery,
  removalExplainer,
  resolveListingRemoval,
  type ListingRemovalAction,
  type ListingRemovalItem,
} from "@/lib/collector-admin";

/**
 * The Listings tab of /admin/takedowns (collector Slice 2): removal requests for imported
 * listings from the site's /bot/remove form, oldest first with the 72-hour timer. Remove acts on
 * the request's scope (this listing, or everything from its source), Reject needs a note. No
 * account is linked to a request, so there is no own-item rule here.
 */
export function ListingRemovals({ closed }: { closed: boolean }) {
  const queue = useQuery(listingRemovalQueueQuery(closed));
  if (queue.isPending) return <ListSkeleton rows={3} rowClassName="h-40" />;
  if (queue.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load requests"
        body={adminErrorMessage(queue.error)}
        action={
          <Button variant="secondary" onClick={() => void queue.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  if (queue.data.length === 0) {
    return (
      <EmptyState
        icon={Inbox}
        title={closed ? "No closed requests" : "No open requests"}
        body="Requests sent from the listing removal page show up here."
      />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {queue.data.map((r) => (
        <li key={r.id}>
          <RemovalCard item={r} />
        </li>
      ))}
    </ul>
  );
}

const STATUS: Record<ListingRemovalItem["status"], string> = {
  open: "Open",
  removed: "Removed",
  rejected: "Rejected",
};

function RemovalCard({ item }: { item: ListingRemovalItem }) {
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");
  const resolve = useMutation({
    mutationFn: (action: ListingRemovalAction) => resolveListingRemoval(item.id, action, note),
    onSuccess: () => {
      setNote("");
      void queryClient.invalidateQueries({ queryKey: adminKeys.all });
      toast.success("Saved.");
    },
    onError: (err) => toast.error(adminErrorMessage(err)),
  });
  const open = item.status === "open";
  const minutesLeft = minutesUntil(item.due_at);

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[13px] text-text-2">
            {STATUS[item.status]} · {item.scope === "source" ? "Whole source" : "One listing"} ·
            received {formatWhen(item.received_at)}
          </p>
          <h2 className="text-[17px] font-bold tabular">{item.reference}</h2>
        </div>
        {open ? <DuePill tone={dueTone(minutesLeft)}>{dueLabel(minutesLeft)}</DuePill> : null}
      </header>

      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        <dt className="text-text-2">From</dt>
        <dd className="min-w-0 break-words">
          {item.requester.name || "Cleared"}
          {item.requester.relationship
            ? ` (${RELATIONSHIP_LABELS[item.requester.relationship] ?? item.requester.relationship})`
            : ""}
        </dd>
        <dt className="text-text-2">Reply to</dt>
        <dd className="min-w-0 break-all">{item.requester.email || "Cleared"}</dd>
        {item.event ? (
          <>
            <dt className="text-text-2">Listing</dt>
            <dd className="min-w-0 break-words">
              <Link
                to="/events/$id"
                params={{ id: item.event.id }}
                className="font-semibold text-link underline-offset-2 hover:underline"
              >
                {item.event.title}
              </Link>
              {item.event.moderation_state === "removed" ? " · removed" : ""}
            </dd>
          </>
        ) : null}
        {item.source ? (
          <>
            <dt className="text-text-2">Source</dt>
            <dd className="min-w-0 break-words">
              {item.source.name}
              {item.source.enabled ? "" : " · off"}
              {item.source.origin === "organizer" ? " · connected by its organizer" : ""}
            </dd>
          </>
        ) : null}
        {item.url ? (
          <>
            <dt className="text-text-2">Link given</dt>
            <dd className="min-w-0 break-all">
              <a
                href={item.url}
                target="_blank"
                rel="noopener noreferrer"
                className="font-semibold text-link underline-offset-2 hover:underline"
              >
                {item.url.replace(/^https:\/\//, "")}
              </a>
            </dd>
          </>
        ) : null}
      </dl>

      {item.reason ? (
        <p className="rounded-tile bg-surface-2 p-3 text-[14px] break-words whitespace-pre-wrap">
          {item.reason}
        </p>
      ) : null}
      {item.resolution_note ? (
        <p className="text-[14px] break-words text-text-2">Note: {item.resolution_note}</p>
      ) : null}

      {open ? (
        <>
          <p className="text-[13px] text-text-2">{removalExplainer(item)}</p>
          {!canRemove(item) ? (
            <p className="text-[13px] text-text-2">
              {item.scope === "source"
                ? "No source is linked to this request. Find it from the link given, or reject with a note."
                : "No listing is linked to this request. Find it from the link given, or reject with a note."}
            </p>
          ) : null}
          <FieldTextArea
            label="Note for the log"
            hint="Needed to reject. The requester doesn't see it; reply from the support inbox."
            rows={2}
            maxLength={1000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={resolve.isPending}
          />
          <div className="flex flex-wrap justify-end gap-2">
            <Button
              size="sm"
              variant="secondary"
              loading={resolve.isPending && resolve.variables === "rejected"}
              disabled={resolve.isPending || !note.trim()}
              onClick={() => resolve.mutate("rejected")}
            >
              Reject
            </Button>
            <Button
              size="sm"
              variant="danger"
              loading={resolve.isPending && resolve.variables === "removed"}
              disabled={resolve.isPending || !canRemove(item)}
              onClick={() => resolve.mutate("removed")}
            >
              {item.scope === "source" ? "Remove source" : "Remove listing"}
            </Button>
          </div>
        </>
      ) : item.requester.email ? (
        <div className="flex justify-end">
          <Button
            size="sm"
            variant="secondary"
            loading={resolve.isPending}
            disabled={resolve.isPending}
            onClick={() => resolve.mutate("reopen")}
          >
            Reopen
          </Button>
        </div>
      ) : null}
    </article>
  );
}
