import { useState } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Inbox, TriangleAlert } from "lucide-react";
import { toast } from "sonner";

import { AdminTabs, DuePill } from "@/components/admin/admin-tabs";
import { ModeratorGate } from "@/components/admin/moderator-gate";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { Field } from "@/components/ui/field";
import { SegmentedControl } from "@/components/ui/segmented";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  TAKEDOWN_STATE_LABELS,
  adminErrorMessage,
  adminKeys,
  blockTakedownImage,
  dueLabel,
  dueTone,
  formatWhen,
  resolveTakedown,
  takedownQueueQuery,
  type TakedownAction,
  type TakedownItem,
} from "@/lib/admin";

/**
 * Intimate-image removal requests (Take It Down Act; mod_takedown_queue, mod_takedown_block_image
 * and mod_takedown_resolve, migration 52). Most urgent first with the 48-hour timer (4 hours
 * when someone may be under 18). Paste the Activity Planet link of each image to block it and
 * its copies; then mark the request done. For suspected child sexual abuse material follow
 * docs/ops/ncmec-runbook.md before blocking: hide first, keep a legal-hold copy, then block.
 */
export const Route = createFileRoute("/_app/admin/takedowns")({
  component: TakedownsPage,
});

function TakedownsPage() {
  const [view, setView] = useState<"open" | "closed">("open");
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/takedowns" />
        <ModeratorGate>
          <SegmentedControl
            label="Requests"
            value={view}
            onChange={setView}
            options={[
              { value: "open", label: "Open" },
              { value: "closed", label: "Closed" },
            ]}
          />
          <Queue closed={view === "closed"} />
        </ModeratorGate>
      </main>
    </>
  );
}

function Queue({ closed }: { closed: boolean }) {
  const queue = useQuery(takedownQueueQuery(closed));
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
        body="Requests sent from the intimate-image removal page show up here."
      />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {queue.data.map((t) => (
        <li key={t.id}>
          <RequestCard item={t} />
        </li>
      ))}
    </ul>
  );
}

const STATUS_LABELS: Record<TakedownItem["status"], string> = {
  open: "Open",
  waiting: "Waiting on the requester",
  removed: "Removed",
  rejected: "Rejected",
};

function RequestCard({ item }: { item: TakedownItem }) {
  const queryClient = useQueryClient();
  const [url, setUrl] = useState("");
  const [note, setNote] = useState("");
  const isOpen = item.status === "open" || item.status === "waiting";
  const invalidate = () => void queryClient.invalidateQueries({ queryKey: adminKeys.all });

  const block = useMutation({
    mutationFn: () => blockTakedownImage(item.id, url),
    onSuccess: (state) => {
      setUrl("");
      invalidate();
      toast.success(TAKEDOWN_STATE_LABELS[state] ?? "Done.");
    },
    onError: (err) => toast.error(adminErrorMessage(err)),
  });
  const resolve = useMutation({
    mutationFn: (action: TakedownAction) => resolveTakedown(item.id, action, note),
    onSuccess: () => {
      setNote("");
      invalidate();
      toast.success("Saved.");
    },
    onError: (err) => toast.error(adminErrorMessage(err)),
  });
  const busy = block.isPending || resolve.isPending;

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[13px] text-text-2">
            {STATUS_LABELS[item.status]} · received {formatWhen(item.received_at)}
          </p>
          <h2 className="text-[17px] font-bold tabular">{item.reference}</h2>
        </div>
        {isOpen && item.minutes_left !== null ? (
          <DuePill tone={dueTone(item.minutes_left)}>{dueLabel(item.minutes_left)}</DuePill>
        ) : null}
      </header>

      {item.involves_minor ? (
        <p
          role="note"
          className="flex items-start gap-2 rounded-tile bg-danger-tint p-3 text-[14px] font-medium text-danger"
        >
          <TriangleAlert className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
          The person shown may be under 18. Don't open or forward the image. Follow the NCMEC
          runbook: hide first, keep a legal-hold copy, then block.
        </p>
      ) : null}

      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        <dt className="text-text-2">From</dt>
        <dd className="min-w-0 break-words">
          {item.requester.name || "Cleared"}
          {item.requester.relationship === "authorized"
            ? " (acting for them)"
            : " (the person shown)"}
        </dd>
        <dt className="text-text-2">Reply to</dt>
        <dd className="min-w-0 break-all">{item.requester.email || "Cleared"}</dd>
        <dt className="text-text-2">Signed</dt>
        <dd className="min-w-0 break-words">{item.signature || "Cleared"}</dd>
        {item.target_user ? (
          <>
            <dt className="text-text-2">Account</dt>
            <dd className="min-w-0">
              <Link
                to="/admin/users"
                search={{ user: item.target_user.id }}
                className="font-semibold text-link underline-offset-2 hover:underline"
              >
                @{item.target_user.handle}
              </Link>
            </dd>
          </>
        ) : null}
        <dt className="text-text-2">Blocked</dt>
        <dd className="tabular">
          {item.images_blocked} {item.images_blocked === 1 ? "image" : "images"}
        </dd>
      </dl>

      <div className="flex flex-col gap-1 rounded-tile bg-surface-2 p-3 text-[14px]">
        <p className="font-semibold">Where it is</p>
        <p className="break-words whitespace-pre-wrap">{item.locations}</p>
        {item.description ? (
          <p className="pt-1 break-words whitespace-pre-wrap text-text-2">{item.description}</p>
        ) : null}
      </div>

      {item.resolution_note ? (
        <p className="text-[14px] break-words text-text-2">Note: {item.resolution_note}</p>
      ) : null}

      {!item.can_act ? (
        <p className="text-[14px] text-text-2">
          This one involves you. Another moderator handles it.
        </p>
      ) : isOpen ? (
        <>
          <form
            className="flex flex-col gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              if (url.trim()) block.mutate();
            }}
          >
            <Field
              label="Image link to block"
              hint="The photo's full Activity Planet link. It comes off every profile and plan at once, and copies are blocked."
              type="url"
              inputMode="url"
              autoComplete="off"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
              disabled={busy}
            />
            <div className="flex justify-end">
              <Button
                type="submit"
                size="sm"
                variant="danger"
                loading={block.isPending}
                disabled={busy || !url.trim()}
              >
                Block image
              </Button>
            </div>
          </form>
          <FieldTextArea
            label="Note for the log"
            hint="Needed to reject or to ask for more information. The requester doesn't see it; reply from the support inbox."
            rows={2}
            maxLength={1000}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={busy}
          />
          <div className="flex flex-wrap justify-end gap-2">
            {item.status === "open" ? (
              <Button
                size="sm"
                variant="secondary"
                loading={resolve.isPending && resolve.variables === "waiting"}
                disabled={busy || !note.trim()}
                onClick={() => resolve.mutate("waiting")}
              >
                Waiting on them
              </Button>
            ) : null}
            <Button
              size="sm"
              variant="secondary"
              loading={resolve.isPending && resolve.variables === "rejected"}
              disabled={busy || !note.trim()}
              onClick={() => resolve.mutate("rejected")}
            >
              Reject
            </Button>
            <Button
              size="sm"
              loading={resolve.isPending && resolve.variables === "removed"}
              disabled={busy}
              onClick={() => resolve.mutate("removed")}
            >
              Mark removed
            </Button>
          </div>
        </>
      ) : item.requester.email ? (
        <div className="flex justify-end">
          <Button
            size="sm"
            variant="secondary"
            loading={resolve.isPending}
            disabled={busy}
            onClick={() => resolve.mutate("reopen")}
          >
            Reopen
          </Button>
        </div>
      ) : null}
    </article>
  );
}
