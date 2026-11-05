import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { MessageCircle, UsersRound } from "lucide-react";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { peopleYouMetQuery } from "@/lib/messaging";

const appRoute = getRouteApi("/_app");

/**
 * People you've met (design 14.1, people_you_met): mutual "who did you meet" picks and people
 * checked in at the same plan, in the last year, newest plan first. One-sided picks stay private.
 */
export const Route = createFileRoute("/_app/you_/met")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(peopleYouMetQuery(session.user.id));
  },
  component: MetPage,
});

function MetPage() {
  const { session } = appRoute.useRouteContext();
  const met = useQuery(peopleYouMetQuery(session.user.id));
  const openChat = useOpenChat();
  const rows = met.data ?? [];
  return (
    <>
      <TopBar title="People you've met" back />
      <main className="flex flex-col gap-4 pb-8 pt-2 safe-px">
        <p className="text-[14px] text-text-2">
          After a plan, you pick who you met. When they pick you too, or you both checked in, they
          show up here. Nobody sees a pick that isn&apos;t mutual.
        </p>
        {met.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-16 rounded-card" />
          </div>
        ) : met.isError ? (
          <FormError>Couldn&apos;t load this list. Try again.</FormError>
        ) : rows.length === 0 ? (
          <EmptyState
            icon={UsersRound}
            title="No one yet"
            body="Go to a plan, then answer “Did you go?” the next day and pick who you met."
          />
        ) : (
          <ul
            className="divide-y divide-border overflow-hidden rounded-card border border-border"
            aria-label="People you've met"
          >
            {rows.map((p) => (
              <li key={p.user_id} className="flex min-h-16 items-center gap-3 px-4 py-2.5">
                <Avatar src={p.avatar_url} name={p.first_name} size={44} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[15px] font-semibold">{p.first_name}</span>
                  <span className="block truncate text-[13px] text-text-2">
                    {p.last_plan?.title
                      ? `Met at ${p.last_plan.title}`
                      : p.handle
                        ? `@${p.handle}`
                        : ""}
                  </span>
                </span>
                {p.can_message ? (
                  <Button
                    variant="secondary"
                    size="sm"
                    leading={<MessageCircle className="size-4" aria-hidden="true" />}
                    aria-label={`Message ${p.first_name}`}
                    disabled={openChat.isPending}
                    onClick={() => openChat.mutate({ kind: "dm", userId: p.user_id })}
                  >
                    Message
                  </Button>
                ) : null}
              </li>
            ))}
          </ul>
        )}
      </main>
    </>
  );
}
