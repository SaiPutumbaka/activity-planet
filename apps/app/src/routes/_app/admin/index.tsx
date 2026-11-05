import { Link, createFileRoute } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { ChevronRight, Inbox } from "lucide-react";

import { AdminTabs, DuePill } from "@/components/admin/admin-tabs";
import { ModeratorGate } from "@/components/admin/moderator-gate";
import { InlineError, ListSkeleton, SectionHeading } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { EmptyState } from "@/components/ui/empty-state";
import {
  QUEUE_SOURCES,
  SOURCE_LABELS,
  SOURCE_PLURALS,
  SOURCE_TARGETS,
  actionLabel,
  adminErrorMessage,
  dueLabel,
  dueTone,
  formatHours,
  modQueueQuery,
  queueItemDetail,
  queueItemLink,
  scorecardQuery,
  totalBreaches,
  totalOpen,
  formatWhen,
  type QueueItem,
  type Scorecard,
} from "@/lib/admin";
import { cn } from "@/lib/cn";

/**
 * Admin panel v1 overview (migration 53): the scorecard and the one moderation queue across
 * reports, intimate-image requests, places, chapter claims and calendar suggestions, most urgent
 * first, each with its SLA timer. Items link to the page that holds their actions.
 */
export const Route = createFileRoute("/_app/admin/")({
  component: AdminOverviewPage,
});

function AdminOverviewPage() {
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-6 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin" />
        <ModeratorGate>
          <ScorecardSection />
          <QueueSection />
        </ModeratorGate>
      </main>
    </>
  );
}

function Stat({
  label,
  value,
  tone = "plain",
}: {
  label: string;
  value: string | number;
  tone?: "plain" | "danger" | "warning";
}) {
  return (
    <div className="flex min-w-0 flex-col gap-0.5 rounded-tile bg-surface-2 p-3">
      <span
        className={cn(
          "text-[22px] leading-tight font-bold tabular",
          tone === "danger" && "text-danger",
          tone === "warning" && "text-warning",
        )}
      >
        {value}
      </span>
      <span className="text-[13px] text-text-2">{label}</span>
    </div>
  );
}

function ScorecardSection() {
  const card = useQuery(scorecardQuery());
  return (
    <section aria-labelledby="scorecard-heading" className="flex flex-col gap-3">
      <SectionHeading
        id="scorecard-heading"
        title="Scorecard"
        trailing={card.data ? `Updated ${formatWhen(card.data.generated_at)}` : undefined}
      />
      {card.isPending ? (
        <ListSkeleton rows={2} rowClassName="h-20" />
      ) : card.isError ? (
        <InlineError message={adminErrorMessage(card.error)} onRetry={() => void card.refetch()} />
      ) : (
        <ScorecardBody s={card.data} />
      )}
    </section>
  );
}

function ScorecardBody({ s }: { s: Scorecard }) {
  const t = totalOpen(s);
  const breaches = totalBreaches(s);
  const actions = Object.entries(s.actions_7d).sort((a, b) => b[1] - a[1]);
  return (
    <>
      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Open in the queue" value={t.open} />
        <Stat label="Overdue now" value={t.overdue} tone={t.overdue > 0 ? "danger" : "plain"} />
        <Stat
          label="Due within 4 hours"
          value={t.due_soon}
          tone={t.due_soon > 0 ? "warning" : "plain"}
        />
        <Stat
          label="Missed targets, 30 days"
          value={breaches}
          tone={breaches > 0 ? "danger" : "plain"}
        />
      </div>

      <div className="overflow-hidden rounded-card border border-border">
        <table className="w-full text-[14px]">
          <caption className="sr-only">Open items by queue</caption>
          <thead className="bg-surface-2 text-left text-[12px] text-text-2">
            <tr>
              <th scope="col" className="px-3 py-2 font-semibold">
                Queue
              </th>
              <th scope="col" className="px-2 py-2 text-right font-semibold">
                Open
              </th>
              <th scope="col" className="px-2 py-2 text-right font-semibold">
                Overdue
              </th>
              <th scope="col" className="px-3 py-2 text-right font-semibold">
                Missed, 30 d
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {QUEUE_SOURCES.map((k) => {
              const q = s.queues[k] ?? { open: 0, overdue: 0, due_soon: 0 };
              const missed = s.breaches_30d[k];
              return (
                <tr key={k}>
                  <th scope="row" className="px-3 py-2 text-left font-medium">
                    {SOURCE_PLURALS[k]}
                    <span className="block text-[12px] font-normal text-text-3">
                      Target {SOURCE_TARGETS[k]}
                    </span>
                  </th>
                  <td className="px-2 py-2 text-right tabular">{q.open}</td>
                  <td
                    className={cn(
                      "px-2 py-2 text-right tabular",
                      q.overdue > 0 && "font-semibold text-danger",
                    )}
                  >
                    {q.overdue}
                  </td>
                  <td className="px-3 py-2 text-right tabular">
                    {missed === undefined ? "–" : missed}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>

      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Reports closed, 7 days" value={s.resolved_7d.report} />
        <Stat label="Median report time, 30 days" value={formatHours(s.median_hours_30d.report)} />
        <Stat label="Image requests closed, 7 days" value={s.resolved_7d.takedown} />
        <Stat
          label="Median image request time, 30 days"
          value={formatHours(s.median_hours_30d.takedown)}
        />
      </div>

      <div className="grid grid-cols-2 gap-2 sm:grid-cols-4">
        <Stat label="Members" value={s.people.members} />
        <Stat label="New accounts, 7 days" value={s.people.signups_7d} />
        <Stat label="Member-hosted plans, next 7 days" value={s.plans.human_hosted_next_7d} />
        <Stat
          label="Plans with 4+ check-ins, last 7 days"
          value={s.plans.four_plus_checked_in_last_7d}
        />
        <Stat label="Member-hosted plans, last 7 days" value={s.plans.human_hosted_last_7d} />
        <Stat label="Active chapters" value={s.chapters_active} />
        <Stat label="Banned accounts" value={s.people.banned} />
      </div>

      <div className="flex flex-col gap-1 text-[14px]">
        <p className="font-semibold">Moderation actions, last 7 days</p>
        {actions.length === 0 ? (
          <p className="text-text-2">None yet.</p>
        ) : (
          <ul className="flex flex-wrap gap-x-4 gap-y-1 text-text-2">
            {actions.map(([a, n]) => (
              <li key={a}>
                {actionLabel(a)}: <span className="font-semibold text-text tabular">{n}</span>
              </li>
            ))}
          </ul>
        )}
      </div>
    </>
  );
}

function QueueSection() {
  const queue = useQuery(modQueueQuery());
  return (
    <section aria-labelledby="queue-heading" className="flex flex-col gap-3">
      <SectionHeading
        id="queue-heading"
        title="Queue"
        trailing={queue.data ? `${queue.data.length} open` : undefined}
      />
      {queue.isPending ? (
        <ListSkeleton rows={4} rowClassName="h-20" />
      ) : queue.isError ? (
        <InlineError
          message={adminErrorMessage(queue.error)}
          onRetry={() => void queue.refetch()}
        />
      ) : queue.data.length === 0 ? (
        <EmptyState
          icon={Inbox}
          title="Nothing waiting"
          body="Reports, image requests, places, chapter claims and calendar suggestions show up here."
        />
      ) : (
        <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
          {queue.data.map((it) => (
            <li key={`${it.source}:${it.id}`}>
              <QueueRow item={it} />
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function QueueRow({ item }: { item: QueueItem }) {
  const detail = queueItemDetail(item);
  return (
    <Link
      to={queueItemLink(item)}
      className="flex min-h-14 items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-2"
    >
      <span className="min-w-0 flex-1">
        <span className="block text-[12px] font-semibold text-text-2">
          {SOURCE_LABELS[item.source]}
          {item.priority === 0 ? " · Urgent" : ""}
          {!item.can_act ? " · Another moderator" : ""}
        </span>
        <span className="block truncate text-[15px] font-medium">{item.title || "Untitled"}</span>
        {detail ? <span className="block truncate text-[13px] text-text-2">{detail}</span> : null}
      </span>
      <DuePill tone={dueTone(item.minutes_left)}>{dueLabel(item.minutes_left)}</DuePill>
      <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
    </Link>
  );
}
