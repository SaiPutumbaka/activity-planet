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
  withVenue,
  type EventArgsContext,
  type EventFormValues,
} from "@/components/events/event-form-schema";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { chapterKeys, myManagedChaptersQuery } from "@/lib/chapters";
import { DEFAULT_TIMEZONE } from "@/lib/datetime";
import { createEvent, createEventSeries, myPostableHubsQuery } from "@/lib/events";
import { venueForPlaceQuery } from "@/lib/venues";

const appRoute = getRouteApi("/_app");
const searchSchema = z.object({
  hub: z.string().optional(),
  chapterId: z.string().optional(),
  /** A map place (the place sheet's "Start a plan here"): its venue is prefilled. */
  place: z.string().optional(),
});

/**
 * Post a plan: one form, create_event or (weekly) create_event_series, then the event page.
 * `?hub=<slug>` preselects the hub (a hub page's "start a plan here"); `?chapterId=<id>` posts
 * as that chapter when the viewer captains or organizes it; `?place=<id>` (the map's "Start a
 * plan here") prefills the venue with that place's public venue (venue_for_place, migration 33),
 * so the plan makes the place a meeting spot for its hub.
 */
export const Route = createFileRoute("/_app/post")({
  validateSearch: searchSchema,
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(myPostableHubsQuery(session.user.id));
    void queryClient.prefetchQuery(myManagedChaptersQuery(session.user.id));
  },
  component: PostPage,
});

function PostPage() {
  const { session, profile } = appRoute.useRouteContext();
  const { hub: hubSlug, chapterId, place } = Route.useSearch();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const hubs = useQuery(myPostableHubsQuery(session.user.id));
  const managed = useQuery(myManagedChaptersQuery(session.user.id));
  const placeVenue = useQuery({ ...venueForPlaceQuery(place ?? ""), enabled: Boolean(place) });
  // A place that can't be used (gone, or not public) just leaves the venue empty.
  const venue = place ? (placeVenue.data ?? null) : null;
  // "Post as" is an extra; a failed load just means posting as yourself.
  const chapters = managed.data ?? [];
  const loading = hubs.isPending || managed.isPending || (Boolean(place) && placeVenue.isPending);

  const initialValues = useMemo(() => {
    const list = hubs.data ?? [];
    const asChapter = (managed.data ?? []).find((c) => c.id === chapterId);
    if (asChapter) {
      return defaultEventFormValues({
        hubId: asChapter.hubId,
        chapterId: asChapter.id,
        timeZone: DEFAULT_TIMEZONE,
      });
    }
    const chosen = list.find((h) => h.slug === hubSlug) ?? list[0];
    const values = defaultEventFormValues({ hubId: chosen?.id ?? "", timeZone: DEFAULT_TIMEZONE });
    return venue ? withVenue(values, venue) : values;
  }, [hubs.data, managed.data, hubSlug, chapterId, venue]);

  function invalidateLists() {
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    void queryClient.invalidateQueries({ queryKey: ["hubs", "events"] });
    void queryClient.invalidateQueries({ queryKey: chapterKeys.all });
  }

  async function onSubmit(values: EventFormValues, ctx: EventArgsContext) {
    if (values.repeatWeekly) {
      const { firstEventId } = await createEventSeries(toCreateEventSeriesArgs(values, ctx));
      invalidateLists();
      toast.success("Weekly plan posted.");
      if (firstEventId) {
        await navigate({ to: "/events/$id", params: { id: firstEventId }, replace: true });
      } else {
        await navigate({ to: "/", replace: true });
      }
      return;
    }
    const event = await createEvent(toCreateEventArgs(values, ctx));
    invalidateLists();
    toast.success("Plan posted.");
    await navigate({ to: "/events/$id", params: { id: event.id }, replace: true });
  }

  return (
    <>
      <TopBar title="Post a plan" />
      <main className="flex flex-col gap-5 pt-2 safe-px">
        {loading ? (
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
        ) : hubs.data.length === 0 && chapters.length === 0 ? (
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
          <>
            {place && !venue ? (
              <p className="text-[13px] text-text-2" role="status">
                {placeVenue.isError
                  ? "Couldn't load that place. Pick where to meet below."
                  : "That place isn't available any more. Pick where to meet below."}
              </p>
            ) : null}
            <EventForm
              mode="create"
              initialValues={initialValues}
              // Remount when a chapter link or a place's venue arrives after the form first rendered.
              key={`${initialValues.postAs}:${initialValues.venueId ?? ""}`}
              hubs={hubs.data}
              chapters={chapters}
              canCampus={profile.home_org_id !== null}
              campusId={profile.home_campus_id}
              timeZone={DEFAULT_TIMEZONE}
              submitLabel="Post plan"
              onSubmit={onSubmit}
            />
          </>
        )}
      </main>
    </>
  );
}
