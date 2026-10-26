import { useMemo } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarX } from "lucide-react";
import { toast } from "sonner";

import { EventForm } from "@/components/events/event-form";
import {
  toUpdateEventArgs,
  valuesFromEvent,
  type EventArgsContext,
  type EventFormValues,
} from "@/components/events/event-form-schema";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { isOver } from "@/lib/datetime";
import { eventErrorMessage, eventQuery, updateEvent, type EventDetail } from "@/lib/events";

const appRoute = getRouteApi("/_app");

/**
 * Edit a plan (host only): the post form prefilled, update_event with only the keys that
 * changed. `events_.$id_.edit.tsx` makes /events/$id/edit a sibling of the event page rather
 * than a child rendered inside it.
 */
export const Route = createFileRoute("/_app/events_/$id_/edit")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(eventQuery(params.id));
  },
  component: EditEventPage,
});

function EditEventPage() {
  const { id } = Route.useParams();
  const { session } = appRoute.useRouteContext();
  const event = useQuery(eventQuery(id));

  return (
    <>
      <TopBar title="Edit plan" back />
      <main className="flex flex-col gap-5 pt-2 safe-px">
        {event.isPending ? (
          <div className="flex flex-col gap-4" aria-busy="true">
            <Skeleton className="h-12" />
            <Skeleton className="h-12" />
            <Skeleton className="h-28" />
          </div>
        ) : event.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>{eventErrorMessage(event.error)}</FormError>
            <Button variant="secondary" onClick={() => void event.refetch()}>
              Try again
            </Button>
          </div>
        ) : !event.data ? (
          <NotEditable title="This plan isn't here" body="It may have been removed." />
        ) : event.data.host_id !== session.user.id ? (
          <NotEditable
            id={id}
            title="Only the host can edit this plan"
            body="Ask them to change it, or post your own."
          />
        ) : event.data.status === "cancelled" ? (
          <NotEditable
            id={id}
            title="This plan was cancelled"
            body="A cancelled plan can't be edited."
          />
        ) : isOver(event.data.ends_at) ? (
          <NotEditable id={id} title="This plan is over" body="Past plans can't be edited." />
        ) : (
          <EditForm event={event.data} />
        )}
      </main>
    </>
  );
}

function NotEditable({ id, title, body }: { id?: string; title: string; body: string }) {
  return (
    <EmptyState
      icon={CalendarX}
      title={title}
      body={body}
      action={
        id ? (
          <Link
            to="/events/$id"
            params={{ id }}
            className={buttonVariants({ variant: "secondary" })}
          >
            Back to the plan
          </Link>
        ) : (
          <Link to="/" className={buttonVariants({ variant: "secondary" })}>
            Go home
          </Link>
        )
      }
    />
  );
}

function EditForm({ event }: { event: EventDetail }) {
  const { profile } = appRoute.useRouteContext();
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const initialValues = useMemo(() => valuesFromEvent(event), [event]);
  const hub = event.hubs;

  const seriesNote = event.series_id
    ? event.detached_at
      ? "This week was edited on its own; changes to the weekly series don't touch it."
      : "This is one week of a weekly plan. Saving changes only this week and detaches it from the series, so later series edits leave it alone."
    : undefined;

  async function onSubmit(values: EventFormValues, ctx: EventArgsContext) {
    const patch = toUpdateEventArgs(initialValues, values, ctx);
    if (Object.keys(patch).length === 0) {
      toast("Nothing changed.");
      await navigate({ to: "/events/$id", params: { id: event.id }, replace: true });
      return;
    }
    await updateEvent(event.id, patch);
    void queryClient.invalidateQueries({ queryKey: ["events", event.id] });
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    toast.success("Saved.");
    await navigate({ to: "/events/$id", params: { id: event.id }, replace: true });
  }

  return (
    <EventForm
      mode="edit"
      initialValues={initialValues}
      hubs={hub ? [{ ...hub, is_active: true }] : []}
      canCampus={profile.home_org_id !== null}
      campusId={event.campus_id ?? profile.home_campus_id}
      timeZone={event.timezone}
      seriesNote={seriesNote}
      submitLabel="Save changes"
      onSubmit={onSubmit}
    />
  );
}
