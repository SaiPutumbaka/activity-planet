import { useMemo } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarX, CircleAlert } from "lucide-react";
import { toast } from "sonner";

import { EventForm } from "@/components/events/event-form";
import {
  defaultEventFormValues,
  toCreateEventSeriesArgs,
  type EventArgsContext,
  type EventFormValues,
} from "@/components/events/event-form-schema";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Skeleton } from "@/components/ui/skeleton";
import {
  chapterBySlugQuery,
  chapterKeys,
  chapterPlaceLabel,
  isModeratorQuery,
  myManagedChaptersQuery,
  type ChapterDetail,
  type ManagedChapter,
} from "@/lib/chapters";
import { DEFAULT_TIMEZONE } from "@/lib/datetime";
import { createEventSeries } from "@/lib/events";

const appRoute = getRouteApi("/_app");

/**
 * A chapter's weekly schedule: captains, organizers and moderators post a recurring plan as the
 * chapter (create_event_series, kind 'chapter') with a start date and an optional last date.
 * `chapters_.$slug_.schedule.tsx` makes /chapters/:slug/schedule a sibling of the chapter page.
 */
export const Route = createFileRoute("/_app/chapters_/$slug_/schedule")({
  loader: ({ context: { queryClient, session }, params }) => {
    void queryClient.prefetchQuery(chapterBySlugQuery(params.slug));
    void queryClient.prefetchQuery(myManagedChaptersQuery(session.user.id));
  },
  component: SchedulePage,
});

function SchedulePage() {
  const { slug } = Route.useParams();
  const { session } = appRoute.useRouteContext();
  const chapter = useQuery(chapterBySlugQuery(slug));
  const managed = useQuery(myManagedChaptersQuery(session.user.id));
  const isMod = useQuery(isModeratorQuery(session.user.id));

  const asChapter = useMemo((): ManagedChapter | null => {
    if (!chapter.data) return null;
    const own = managed.data?.find((c) => c.id === chapter.data!.id);
    if (own) return own;
    return isMod.data ? fromDetail(chapter.data) : null;
  }, [chapter.data, managed.data, isMod.data]);

  const loading = chapter.isPending || managed.isPending || isMod.isPending;

  return (
    <>
      <TopBar title="Weekly schedule" back />
      <main className="flex flex-col gap-5 pt-2 safe-px">
        {loading ? (
          <div className="flex flex-col gap-4" aria-busy="true">
            <Skeleton className="h-12" />
            <Skeleton className="h-12" />
            <Skeleton className="h-28" />
          </div>
        ) : chapter.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't load this chapter"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void chapter.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !chapter.data ? (
          <EmptyState
            icon={CalendarX}
            title="No chapter here"
            body="That chapter doesn't exist, or it isn't active anymore."
          />
        ) : !asChapter || !asChapter.hub ? (
          <EmptyState
            icon={CalendarX}
            title="Only captains add a schedule"
            body="Captains and organizers of this chapter post its weekly plans."
            action={
              <Link
                to="/chapters/$slug"
                params={{ slug }}
                className={buttonVariants({ variant: "secondary" })}
              >
                Back to the chapter
              </Link>
            }
          />
        ) : (
          <ScheduleForm chapter={asChapter} />
        )}
      </main>
    </>
  );
}

function fromDetail(c: ChapterDetail): ManagedChapter {
  return {
    id: c.id,
    slug: c.slug,
    name: c.name,
    role: "organizer",
    hubId: c.hub_id,
    campusId: c.campus_id,
    placeLabel: chapterPlaceLabel(c),
    isActive: c.is_active,
    hub: c.hubs,
  };
}

function ScheduleForm({ chapter }: { chapter: ManagedChapter }) {
  const { profile } = appRoute.useRouteContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const initialValues = useMemo(
    () =>
      defaultEventFormValues({
        hubId: chapter.hubId,
        chapterId: chapter.id,
        repeatWeekly: true,
        timeZone: DEFAULT_TIMEZONE,
      }),
    [chapter.hubId, chapter.id],
  );

  async function onSubmit(values: EventFormValues, ctx: EventArgsContext) {
    const { firstEventId } = await createEventSeries(
      toCreateEventSeriesArgs({ ...values, repeatWeekly: true, postAs: chapter.id }, ctx),
    );
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    void queryClient.invalidateQueries({ queryKey: ["hubs", "events"] });
    void queryClient.invalidateQueries({ queryKey: chapterKeys.all });
    toast.success("Weekly schedule posted.");
    if (firstEventId) {
      await navigate({ to: "/events/$id", params: { id: firstEventId }, replace: true });
    } else {
      await navigate({ to: "/chapters/$slug", params: { slug: chapter.slug }, replace: true });
    }
  }

  return (
    <EventForm
      mode="create"
      seriesOnly
      initialValues={initialValues}
      hubs={chapter.hub ? [chapter.hub] : []}
      chapters={[chapter]}
      canCampus={profile.home_org_id !== null}
      campusId={profile.home_campus_id}
      timeZone={DEFAULT_TIMEZONE}
      submitLabel="Post schedule"
      onSubmit={onSubmit}
    />
  );
}
