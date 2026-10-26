import { useMemo } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CircleAlert, Compass } from "lucide-react";

import { HubChapters } from "@/components/hubs/hub-chapters";
import { HubEvents } from "@/components/hubs/hub-events";
import { HubHeader } from "@/components/hubs/hub-header";
import { HubMembers } from "@/components/hubs/hub-members";
import { HubPageSkeleton, SectionHeading } from "@/components/hubs/hub-states";
import { useHubMembership } from "@/components/hubs/use-hub-membership";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import {
  UPCOMING_WINDOW_DAYS,
  hubBySlugQuery,
  hubMemberCountsQuery,
  joinBlockedReason,
  viewerAgeQuery,
  type HubPage,
} from "@/lib/hubs";
import { myHubsQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

/**
 * One hub: header with Join, the next 30 days of plans, its chapters and a glimpse of who is in
 * it. The file is `hubs_.$slug.tsx` so /hubs/:slug is a sibling of the Hubs tab, not a child
 * rendered inside it.
 */
export const Route = createFileRoute("/_app/hubs_/$slug")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(hubBySlugQuery(params.slug));
  },
  component: HubPageRoute,
});

function HubPageRoute() {
  const { slug } = Route.useParams();
  const hub = useQuery(hubBySlugQuery(slug));

  return (
    <>
      <TopBar title={hub.data?.name ?? "Hub"} back />
      <main className="flex flex-col gap-7 pb-8 safe-px">
        {hub.isPending ? (
          <HubPageSkeleton />
        ) : hub.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't load this hub"
            body="Check your connection and try again."
            action={
              <Button
                variant="secondary"
                onClick={() => {
                  void hub.refetch();
                }}
              >
                Try again
              </Button>
            }
          />
        ) : !hub.data ? (
          <EmptyState
            icon={Compass}
            title="No hub here"
            body="That hub doesn't exist, or it was merged into another one."
            action={
              <Link to="/hubs" className={buttonVariants({ variant: "secondary" })}>
                Browse hubs
              </Link>
            }
          />
        ) : (
          <HubPageContent hub={hub.data} />
        )}
      </main>
    </>
  );
}

function HubPageContent({ hub }: { hub: HubPage }) {
  const { session, profile } = appRoute.useRouteContext();
  const userId = session.user.id;
  const myHubs = useQuery(myHubsQuery(userId));
  const viewerAge = useQuery(viewerAgeQuery);
  const hubIds = useMemo(() => [hub.id], [hub.id]);
  const counts = useQuery(hubMemberCountsQuery(hubIds));
  const membership = useHubMembership(userId);

  const joined = (myHubs.data ?? []).some((m) => m.hub_id === hub.id);
  const pending = membership.join.isPending || membership.leave.isPending;
  const count = counts.data ? (counts.data[hub.id] ?? 0) : undefined;
  const blocked = joined
    ? null
    : joinBlockedReason(hub, { homeOrgId: profile.home_org_id, viewerAge: viewerAge.data });
  const isSensitive = hub.hub_categories?.is_sensitive ?? false;

  return (
    <>
      <HubHeader
        hub={hub}
        count={count}
        joined={joined}
        pending={pending}
        blocked={blocked}
        onJoin={() => membership.join.mutate(hub)}
        onLeave={() => membership.leave.mutate(hub)}
      />

      <section className="flex flex-col gap-3" aria-labelledby="hub-upcoming">
        <SectionHeading
          id="hub-upcoming"
          title="Upcoming"
          trailing={`Next ${UPCOMING_WINDOW_DAYS} days`}
        />
        <HubEvents hubId={hub.id} hubSlug={hub.slug} />
      </section>

      <section className="flex flex-col gap-3" aria-labelledby="hub-chapters">
        <SectionHeading id="hub-chapters" title="Chapters" />
        <HubChapters hubId={hub.id} hubName={hub.name} isSensitive={isSensitive} />
      </section>

      <section className="flex flex-col gap-3" aria-labelledby="hub-members">
        <SectionHeading id="hub-members" title="Members" />
        <HubMembers hubId={hub.id} count={count} isSensitive={isSensitive} />
      </section>
    </>
  );
}
