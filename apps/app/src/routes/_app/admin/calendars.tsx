import { useState } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, ExternalLink, Inbox, ShieldX } from "lucide-react";
import { toast } from "sonner";

import { AdminTabs } from "@/components/admin/admin-tabs";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  pendingSuggestionsQuery,
  reviewSuggestion,
  suggestionErrorMessage,
  suggestionKeys,
  type PendingSuggestion,
} from "@/lib/calendar-suggestions";
import { isModeratorQuery } from "@/lib/chapters";
import { formatRelativeDay } from "@/lib/datetime";

const appRoute = getRouteApi("/_app");

/**
 * Moderator queue for member calendar suggestions (D-042 slice 7, mod_review_source_candidate).
 * Approve lets the collector probe the site (D-040 rules, two good days before it is listed);
 * reject means it is never fetched. Rows carry the link only, never who suggested it.
 */
export const Route = createFileRoute("/_app/admin/calendars")({
  component: CalendarQueuePage,
});

function CalendarQueuePage() {
  const { session } = appRoute.useRouteContext();
  const isMod = useQuery(isModeratorQuery(session.user.id));
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/calendars" />
        {isMod.isPending ? (
          <ListSkeleton rows={3} rowClassName="h-28" />
        ) : isMod.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't check your access"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void isMod.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !isMod.data ? (
          <EmptyState
            icon={ShieldX}
            title="Moderators only"
            body="This page is for the people who review calendar suggestions."
            action={
              <Link to="/" className={buttonVariants({ variant: "secondary" })}>
                Go home
              </Link>
            }
          />
        ) : (
          <Queue />
        )}
      </main>
    </>
  );
}

function Queue() {
  const q = useQuery(pendingSuggestionsQuery());
  if (q.isPending) return <ListSkeleton rows={3} rowClassName="h-28" />;
  if (q.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load suggestions"
        body={suggestionErrorMessage(q.error)}
        action={
          <Button variant="secondary" onClick={() => void q.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  if (q.data.length === 0) {
    return (
      <EmptyState icon={Inbox} title="Nothing to review" body="New suggestions show up here." />
    );
  }
  return (
    <ul className="flex flex-col gap-3">
      {q.data.map((s) => (
        <li key={s.id}>
          <SuggestionCard item={s} />
        </li>
      ))}
    </ul>
  );
}

function SuggestionCard({ item }: { item: PendingSuggestion }) {
  const queryClient = useQueryClient();
  const [reason, setReason] = useState("");
  const review = useMutation({
    mutationFn: (approve: boolean) => reviewSuggestion(item.id, approve, reason),
    onSuccess: (_, approve) => {
      void queryClient.invalidateQueries({ queryKey: suggestionKeys.pending });
      toast.success(approve ? "Approved. The collector will check it." : "Rejected.");
    },
    onError: (err) => toast.error(suggestionErrorMessage(err)),
  });
  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="min-w-0">
        <p className="text-[13px] text-text-2">
          {item.regionLabel ?? "No region"} · {formatRelativeDay(item.createdAt)}
          {item.suggestCount > 1 ? ` · suggested ${item.suggestCount} times` : ""}
        </p>
        <h2 className="truncate text-[17px] font-bold">{item.host}</h2>
        <a
          href={item.url}
          target="_blank"
          rel="noopener noreferrer nofollow"
          className="inline-flex max-w-full items-center gap-1 text-[14px] text-primary underline-offset-2 hover:underline"
        >
          <span className="truncate">{item.url}</span>
          <ExternalLink className="size-3.5 shrink-0" aria-hidden="true" />
        </a>
      </header>
      <p className="text-[13px] text-text-2">
        Approve a public events page or feed of a real organisation. Reject private pages, spam, and
        anything that is not a calendar.
      </p>
      <FieldTextArea
        label="Reason (optional)"
        rows={2}
        maxLength={200}
        value={reason}
        onChange={(e) => setReason(e.target.value)}
      />
      <div className="flex gap-2">
        <Button
          variant="secondary"
          className="flex-1"
          loading={review.isPending && review.variables === false}
          disabled={review.isPending}
          onClick={() => review.mutate(false)}
        >
          Reject
        </Button>
        <Button
          className="flex-1"
          loading={review.isPending && review.variables === true}
          disabled={review.isPending}
          onClick={() => review.mutate(true)}
        >
          Approve
        </Button>
      </div>
    </article>
  );
}
