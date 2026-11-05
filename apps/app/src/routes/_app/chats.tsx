import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useInfiniteQuery } from "@tanstack/react-query";
import { Inbox, MessageCircle, SquarePen } from "lucide-react";
import { z } from "zod";

import { ChatRow } from "@/components/chats/chat-row";
import { InboxBell } from "@/components/shell/inbox-bell";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { SegmentedControl } from "@/components/ui/segmented";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { chatListQuery, useChatsLiveStatus, useUnreadChats } from "@/lib/messaging";

const appRoute = getRouteApi("/_app");

const searchSchema = z.object({ tab: z.enum(["chats", "requests"]).optional() });

/**
 * Chats (D-043, design 14.1): DMs, groups and the chats of your plans, hubs and chapters, newest
 * activity first, with unread counts; Requests holds first messages from people you share
 * nothing with yet. Live over the user's chats channel; refreshed every 60 s and on focus.
 */
export const Route = createFileRoute("/_app/chats")({
  validateSearch: searchSchema,
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchInfiniteQuery(chatListQuery(session.user.id, "chats"));
  },
  component: ChatsPage,
});

function ChatsPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const tab = Route.useSearch().tab ?? "chats";
  const navigate = useNavigate({ from: "/chats" });
  const unread = useUnreadChats(userId);
  const live = useChatsLiveStatus();
  const list = useInfiniteQuery({
    ...chatListQuery(userId, tab),
    // Event, hub and chapter rooms send no personal signal: poll while the list is open.
    refetchInterval: live ? 60_000 : 30_000,
    refetchIntervalInBackground: false,
  });
  // A chat that moved between pages while paging shows once.
  const rows = (list.data?.pages.flat() ?? []).filter(
    (r, i, all) => all.findIndex((x) => x.conversation_id === r.conversation_id) === i,
  );
  const now = new Date();

  return (
    <>
      <TopBar
        title="Chats"
        actions={
          <>
            <Link
              to="/chats/new"
              aria-label="New message"
              className={cn(
                buttonVariants({ variant: "secondary", size: "icon-sm" }),
                "rounded-full",
              )}
            >
              <SquarePen className="size-5" aria-hidden="true" />
            </Link>
            <InboxBell userId={userId} />
          </>
        }
      />
      <main className="flex flex-col gap-4 pb-8 pt-2 safe-px">
        <SegmentedControl
          label="Chats or requests"
          value={tab}
          onChange={(v) =>
            void navigate({ search: v === "chats" ? {} : { tab: v }, replace: true })
          }
          options={[
            { value: "chats", label: "Chats" },
            {
              value: "requests",
              label: unread.requests > 0 ? `Requests (${unread.requests})` : "Requests",
            },
          ]}
        />
        {tab === "requests" ? (
          <p className="text-[13px] text-text-2">
            First messages from people you don&apos;t share a plan, hub or chapter with. They
            can&apos;t see whether you&apos;ve read them. Declining is private.
          </p>
        ) : null}
        {list.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-16 rounded-card" />
          </div>
        ) : list.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>
              Couldn&apos;t load your chats. Check your connection and try again.
            </FormError>
            <Button variant="secondary" onClick={() => void list.refetch()}>
              Try again
            </Button>
          </div>
        ) : rows.length === 0 ? (
          tab === "requests" ? (
            <EmptyState
              icon={Inbox}
              title="No requests"
              body="When someone new messages you, it waits here until you accept."
            />
          ) : (
            <EmptyState
              icon={MessageCircle}
              title="No chats yet"
              body="Every plan you join has a chat, and so do your hubs and chapters. You can also message people you've met."
              action={
                <Link to="/chats/new" className={buttonVariants({ variant: "secondary" })}>
                  New message
                </Link>
              }
            />
          )
        ) : (
          <ul
            className="divide-y divide-border overflow-hidden rounded-card border border-border"
            aria-label={tab === "requests" ? "Message requests" : "Chats"}
          >
            {rows.map((r) => (
              <ChatRow key={r.conversation_id} row={r} now={now} />
            ))}
          </ul>
        )}
        {list.hasNextPage ? (
          <Button
            variant="secondary"
            disabled={list.isFetchingNextPage}
            onClick={() => void list.fetchNextPage()}
          >
            {list.isFetchingNextPage ? "Loading…" : "Show older chats"}
          </Button>
        ) : null}
      </main>
    </>
  );
}
