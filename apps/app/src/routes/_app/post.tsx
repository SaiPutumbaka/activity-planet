import { useMemo } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Users } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";

import { EventForm } from "@/components/events/event-form";
import {
  defaultEventFormValues,
  toCreateEventArgs,
  toCreateEventSeriesArgs,
  type EventArgsContext,
  type EventFormValues,
} from "@/components/events/event-form-schema";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { DEFAULT_TIMEZONE } from "@/lib/datetime";
import { createEvent, createEventSeries, myPostableHubsQuery } from "@/lib/events";

const appRoute = getRouteApi("/_app");
const searchSchema = z.object({ hub: z.string().optional() });

/**
 * Post a plan: one form, create_event or (weekly) create_event_series, then the event page.
 * `?hub=<slug>` preselects the hub (a hub page's "start a plan here").
 */
export const Route = createFileRoute("/_app/post")({
  validateSearch: searchSchema,
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(myPostableHubsQuery(session.user.id));
  },
  component: PostPage,
});

function PostPage() {
  const { session, profile } = appRoute.useRouteContext();
  const { hub: hubSlug } = Route.useSearch();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const hubs = useQuery(myPostableHubsQuery(session.user.id));

  const initialValues = useMemo(() => {
    const list = hubs.data ?? [];
    const chosen = list.find((h) => h.slug === hubSlug) ?? list[0];
    return defaultEventFormValues({ hubId: chosen?.id ?? "", timeZone: DEFAULT_TIMEZONE });
  }, [hubs.data, hubSlug]);

  async function onSubmit(values: EventFormValues, ctx: EventArgsContext) {
    if (values.repeatWeekly) {
      const { firstEventId } = await createEventSeries(toCreateEventSeriesArgs(values, ctx));
      void queryClient.invalidateQueries({ queryKey: ["feed"] });
      toast.success("Weekly plan posted.");
      if (firstEventId) {
        await navigate({ to: "/events/$id", params: { id: firstEventId }, replace: true });
      } else {
        await navigate({ to: "/", replace: true });
      }
      return;
    }
    const event = await createEvent(toCreateEventArgs(values, ctx));
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    toast.success("Plan posted.");
    await navigate({ to: "/events/$id", params: { id: event.id }, replace: true });
  }

  return (
    <>
      <TopBar title="Post a plan" />
      <main className="flex flex-col gap-5 pt-2 safe-px">
        {hubs.isPending ? (
          <div className="flex flex-col gap-4" aria-busy="true">
            <Skeleton className="h-12" />
            <Skeleton className="h-12" />
            <Skeleton className="h-28" />
            <Skeleton className="h-12" />
          </div>
        ) : hubs.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>Couldn't load your hubs. Check your connection and try again.</FormError>
            <Button variant="secondary" onClick={() => void hubs.refetch()}>
              Try again
            </Button>
          </div>
        ) : hubs.data.length === 0 ? (
          <EmptyState
            icon={Users}
            title="Join a hub first"
            body="Plans live in hubs, so the right people see them. Pick one and come back."
            action={
              <Link to="/hubs" className={buttonVariants({ variant: "secondary" })}>
                Browse hubs
              </Link>
            }
          />
        ) : (
          <EventForm
            mode="create"
            initialValues={initialValues}
            hubs={hubs.data}
            canCampus={profile.home_org_id !== null}
            campusId={profile.home_campus_id}
            timeZone={DEFAULT_TIMEZONE}
            submitLabel="Post plan"
            onSubmit={onSubmit}
          />
        )}
      </main>
    </>
  );
}
