import type { ReactNode } from "react";
import { Link, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CircleAlert, ShieldX } from "lucide-react";

import { ListSkeleton } from "@/components/hubs/hub-states";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { isModeratorQuery } from "@/lib/chapters";

const appRoute = getRouteApi("/_app");

/**
 * The admin panel's access check: a skeleton while is_moderator() answers, a retry on error, a
 * dead end for everyone else. Only a convenience; every moderator RPC refuses non-moderators.
 */
export function ModeratorGate({ children }: { children: ReactNode }) {
  const { session } = appRoute.useRouteContext();
  const isMod = useQuery(isModeratorQuery(session.user.id));

  if (isMod.isPending) return <ListSkeleton rows={3} rowClassName="h-24" />;
  if (isMod.isError) {
    return (
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
    );
  }
  if (!isMod.data) {
    return (
      <EmptyState
        icon={ShieldX}
        title="Moderators only"
        body="This page is for the people who keep Activity Planet safe."
        action={
          <Link to="/" className={buttonVariants({ variant: "secondary" })}>
            Go home
          </Link>
        }
      />
    );
  }
  return <>{children}</>;
}
