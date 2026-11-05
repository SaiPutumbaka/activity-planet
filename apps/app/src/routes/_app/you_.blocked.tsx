import { useState } from "react";
import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ShieldCheck } from "lucide-react";
import { toast } from "sonner";

import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  blockedOnText,
  myBlocksQuery,
  safetyErrorMessage,
  unblockUser,
  type BlockedPerson,
} from "@/lib/safety";

const appRoute = getRouteApi("/_app");

/**
 * Blocked accounts at /you/blocked (a sibling of the You tab, like you_.notifications.tsx). The
 * list comes from my_blocks(), the one place the blocker sees who they blocked; Unblock asks
 * first and removes only the viewer's own block.
 */
export const Route = createFileRoute("/_app/you_/blocked")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(myBlocksQuery(session.user.id));
  },
  component: BlockedAccountsPage,
});

function BlockedAccountsPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const blocks = useQuery(myBlocksQuery(userId));
  const [unblocking, setUnblocking] = useState<BlockedPerson | null>(null);

  const unblock = useMutation({
    mutationFn: (p: BlockedPerson) => unblockUser(p.user_id),
    onSuccess: (_r, p) => {
      // Their profile, RSVPs and memberships show again everywhere.
      void queryClient.invalidateQueries();
      setUnblocking(null);
      toast.success(`You unblocked ${p.first_name}.`);
    },
    onError: (err) => toast.error(safetyErrorMessage(err)),
  });

  return (
    <>
      <TopBar title="Blocked accounts" back />
      <main className="flex flex-col gap-4 pb-8 safe-px">
        <p className="pt-2 text-[14px] text-text-2">
          People you block can&apos;t see your profile, RSVPs or memberships, and you can&apos;t see
          theirs. They aren&apos;t told when you block or unblock them.
        </p>
        {blocks.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-14" />
            <Skeleton className="h-14" />
          </div>
        ) : blocks.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>{safetyErrorMessage(blocks.error)}</FormError>
            <Button variant="secondary" onClick={() => void blocks.refetch()}>
              Try again
            </Button>
          </div>
        ) : blocks.data.length === 0 ? (
          <EmptyState
            icon={ShieldCheck}
            title="No one blocked"
            body="Block someone from their profile card on a plan or in a chapter."
          />
        ) : (
          <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
            {blocks.data.map((p) => (
              <li key={p.user_id} className="flex min-h-14 items-center gap-3 px-4 py-2">
                <Avatar src={p.avatar_url} name={p.first_name} size={36} />
                <div className="min-w-0 flex-1">
                  <p className="truncate text-[15px] font-semibold">
                    {p.first_name}
                    <span className="font-normal text-text-3"> @{p.handle}</span>
                  </p>
                  <p className="text-[13px] text-text-2">{blockedOnText(p.blocked_at)}</p>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  aria-haspopup="dialog"
                  aria-label={`Unblock ${p.first_name}`}
                  onClick={() => setUnblocking(p)}
                >
                  Unblock
                </Button>
              </li>
            ))}
          </ul>
        )}
      </main>

      <Sheet
        open={unblocking !== null}
        onClose={() => setUnblocking(null)}
        title={unblocking ? `Unblock ${unblocking.first_name}?` : "Unblock"}
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="secondary"
              size="lg"
              onClick={() => setUnblocking(null)}
              disabled={unblock.isPending}
            >
              Cancel
            </Button>
            <Button
              size="lg"
              loading={unblock.isPending}
              onClick={() => unblocking && unblock.mutate(unblocking)}
            >
              Unblock
            </Button>
          </div>
        }
      >
        <p className="text-[15px] text-text-2">
          You&apos;ll see each other&apos;s profiles, RSVPs and memberships again. They aren&apos;t
          told. You can block them again any time.
        </p>
      </Sheet>
    </>
  );
}
