import { useState } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Inbox } from "lucide-react";
import { toast } from "sonner";

import { AdminTabs, DuePill } from "@/components/admin/admin-tabs";
import { ModeratorGate } from "@/components/admin/moderator-gate";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  MODERATE_ACTIONS,
  adminErrorMessage,
  adminKeys,
  dueLabel,
  dueTone,
  formatWhen,
  minutesUntil,
  moderate,
  reasonLabel,
  removeExplainer,
  reportQueueQuery,
  targetKindLabel,
  type ModerateAction,
  type ReportGroup,
} from "@/lib/admin";

/**
 * Reports on people, plans, chapters and hubs (mod_report_queue, mod_moderate; migration 51),
 * grouped by what was reported, most urgent first with the SLA timer. Never who reported. Hide
 * holds it for review, Remove is the soft delete, Dismiss closes the reports and undoes an
 * automatic hide. A moderator's own items say so and offer nothing; the RPC refuses them anyway.
 */
export const Route = createFileRoute("/_app/admin/reports")({
  component: ReportsPage,
});

function ReportsPage() {
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/reports" />
        <ModeratorGate>
          <Queue />
        </ModeratorGate>
      </main>
    </>
  );
}

function Queue() {
  const queue = useQuery(reportQueueQuery());
  if (queue.isPending) return <ListSkeleton rows={3} rowClassName="h-32" />;
  if (queue.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load reports"
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
        title="No open reports"
        body="Reports on profiles, plans, chapters and hubs show up here."
      />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {queue.data.map((g) => (
        <li key={`${g.kind}:${g.target_id}`}>
          <ReportCard group={g} />
        </li>
      ))}
    </ul>
  );
}

const STATE_LABELS: Record<string, string> = {
  hidden: "Hidden for review",
  removed: "Removed",
};

function TargetLink({ group }: { group: ReportGroup }) {
  const cls = "font-semibold text-link underline-offset-2 hover:underline";
  if (group.kind === "event") {
    return (
      <Link to="/events/$id" params={{ id: group.target_id }} className={cls}>
        Open the plan
      </Link>
    );
  }
  if (group.target_user) {
    return (
      <Link to="/admin/users" search={{ user: group.target_user.id }} className={cls}>
        Look up @{group.target_user.handle}
      </Link>
    );
  }
  return null;
}

function ReportCard({ group }: { group: ReportGroup }) {
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");
  const [confirmRemove, setConfirmRemove] = useState(false);
  const minutes = minutesUntil(group.due_at);
  const act = useMutation({
    mutationFn: (action: ModerateAction) => moderate(group.kind, group.target_id, action, note),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: adminKeys.all });
      toast.success("Done.");
    },
    onError: (err) => toast.error(adminErrorMessage(err)),
  });
  const reasons = Object.entries(group.reasons).sort((a, b) => b[1] - a[1]);

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[13px] text-text-2">
            {targetKindLabel(group.kind)}
            {group.priority === 0 ? " · Urgent" : ""}
            {group.state ? ` · ${STATE_LABELS[group.state] ?? group.state}` : ""}
          </p>
          <h2 className="text-[17px] font-bold break-words">{group.label || "Untitled"}</h2>
        </div>
        <DuePill tone={dueTone(minutes)}>{dueLabel(minutes)}</DuePill>
      </header>

      <div className="flex flex-col gap-1 rounded-tile bg-surface-2 p-3 text-[14px]">
        <p className="font-semibold">
          {group.report_count} {group.report_count === 1 ? "report" : "reports"} from{" "}
          {group.reporter_count} {group.reporter_count === 1 ? "person" : "people"} · first{" "}
          {formatWhen(group.first_reported_at)}
        </p>
        <ul className="flex flex-wrap gap-x-3 gap-y-1">
          {reasons.map(([r, n]) => (
            <li key={r}>
              {reasonLabel(r)}
              {n > 1 ? ` ×${n}` : ""}
            </li>
          ))}
        </ul>
        {group.notes.length ? (
          <ul className="flex flex-col gap-1 pt-1 text-text-2">
            {group.notes.map((n, i) => (
              <li key={i} className="break-words whitespace-pre-wrap">
                “{n}”
              </li>
            ))}
          </ul>
        ) : null}
      </div>

      <div className="text-[14px]">
        <TargetLink group={group} />
      </div>

      {!group.can_act ? (
        <p className="text-[14px] text-text-2">
          This one involves you. Another moderator handles it.
        </p>
      ) : (
        <>
          <FieldTextArea
            label="Note for the log (optional)"
            rows={2}
            maxLength={500}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={act.isPending}
          />
          {confirmRemove ? (
            <div className="flex flex-col gap-2 rounded-tile bg-danger-tint p-3 text-[14px]">
              <p className="text-danger">{removeExplainer(group.kind)}</p>
              <div className="flex flex-wrap justify-end gap-2">
                <Button
                  size="sm"
                  variant="secondary"
                  disabled={act.isPending}
                  onClick={() => setConfirmRemove(false)}
                >
                  Keep it
                </Button>
                <Button
                  size="sm"
                  variant="danger"
                  loading={act.isPending && act.variables === "remove"}
                  disabled={act.isPending}
                  onClick={() => act.mutate("remove")}
                >
                  Remove
                </Button>
              </div>
            </div>
          ) : (
            <div className="flex flex-wrap justify-end gap-2">
              {group.state ? (
                <Button
                  size="sm"
                  variant="secondary"
                  loading={act.isPending && act.variables === "restore"}
                  disabled={act.isPending}
                  onClick={() => act.mutate("restore")}
                >
                  Restore
                </Button>
              ) : null}
              {MODERATE_ACTIONS.filter((a) => !(a.action === "hide" && group.state)).map((a) => (
                <Button
                  key={a.action}
                  size="sm"
                  variant={a.action === "remove" ? "danger" : "secondary"}
                  loading={act.isPending && act.variables === a.action}
                  disabled={act.isPending}
                  onClick={() =>
                    a.action === "remove" ? setConfirmRemove(true) : act.mutate(a.action)
                  }
                >
                  {a.label}
                </Button>
              ))}
            </div>
          )}
        </>
      )}
    </article>
  );
}
