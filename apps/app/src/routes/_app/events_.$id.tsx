import { useState, type ReactNode } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import type { LucideIcon } from "lucide-react";
import {
  CalendarPlus,
  CalendarX,
  Clock,
  ExternalLink,
  Lock,
  MapPin,
  Share,
  Ticket,
  Users,
} from "lucide-react";
import { toast } from "sonner";
import { buildIcs, googleCalendarUrl, icsFilename, type CalendarEvent } from "@ap/core/calendar";
import { DefaultCover } from "@ap/ui/brand";

import { AttendeesSection } from "@/components/events/attendees-section";
import { eventState, rsvpState, spotsLeft } from "@/components/events/event-state";
import { EventStateChip } from "@/components/events/event-state-chip";
import { GuidelinesSheet } from "@/components/events/guidelines-sheet";
import { RsvpBar } from "@/components/events/rsvp-bar";
import { useRsvp } from "@/components/events/use-rsvp";
import { ImportedChips, ImportedSourceSection } from "@/components/events/imported-source";
import { HubBadges } from "@/components/hubs/hub-badges";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar, AvatarStack } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { FieldTextArea } from "@/components/ui/textarea";
import { DEFAULT_TIMEZONE, formatEventTime } from "@/lib/datetime";
import {
  canManageEventQuery,
  cancelEvent,
  checkIn,
  eventAttendeesQuery,
  eventErrorMessage,
  eventQuery,
  eventRsvpsQuery,
  type EventDetail,
} from "@/lib/events";
import { importLabelsQuery } from "@/lib/imports";
import { eventShareUrl, shareLink } from "@/lib/share";
import { formatVenueAddress } from "@/lib/venues";

const appRoute = getRouteApi("/_app");

/**
 * The event page. `events_.$id.tsx` keeps /events/$id out of any /events list route, the way
 * you_.delete.tsx does for /you/delete.
 */
export const Route = createFileRoute("/_app/events_/$id")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(eventQuery(params.id));
  },
  component: EventPage,
});

function EventPage() {
  const { id } = Route.useParams();
  const { session } = appRoute.useRouteContext();
  const event = useQuery(eventQuery(id));

  function share() {
    void shareLink({ url: eventShareUrl(id), title: event.data?.title });
  }

  return (
    <>
      <TopBar
        title="Plan"
        back
        actions={
          <Button
            variant="secondary"
            size="icon"
            className="rounded-full"
            aria-label="Share"
            onClick={share}
          >
            <Share className="size-5" aria-hidden="true" />
          </Button>
        }
      />
      {event.isPending ? (
        <EventSkeleton />
      ) : event.isError ? (
        <main className="flex flex-col gap-3 pt-4 safe-px">
          <FormError>{eventErrorMessage(event.error)}</FormError>
          <Button variant="secondary" onClick={() => void event.refetch()}>
            Try again
          </Button>
        </main>
      ) : !event.data ? (
        <EmptyState
          icon={CalendarX}
          title="This plan isn't here"
          body="It may have been removed, or it's for a group you're not part of."
          action={
            <Link to="/" className={buttonVariants({ variant: "secondary" })}>
              Go home
            </Link>
          }
        />
      ) : (
        <EventBody event={event.data} userId={session.user.id} />
      )}
    </>
  );
}

function EventSkeleton() {
  return (
    <main className="flex flex-col gap-5 pb-28" aria-busy="true">
      <Skeleton className="h-[200px] rounded-none" />
      <div className="flex flex-col gap-3 safe-px">
        <Skeleton className="h-7 w-28" />
        <Skeleton className="h-8 w-3/4" />
        <Skeleton className="h-9 w-40 rounded-control" />
        <Skeleton className="mt-2 h-32" />
      </div>
    </main>
  );
}

function EventBody({ event, userId }: { event: EventDetail; userId: string }) {
  const queryClient = useQueryClient();
  const rsvps = useQuery(eventRsvpsQuery(event.id));
  const attendees = useQuery(eventAttendeesQuery(event.id));
  const rsvp = useRsvp();
  const [cancelOpen, setCancelOpen] = useState(false);
  const [cancelReason, setCancelReason] = useState("");

  const isHost = event.host_id === userId;
  // Host, a captain or organizer of the event's chapter, or a moderator (viewer_can_manage_event).
  const canManageQuery = useQuery({
    ...canManageEventQuery(event.id, userId),
    enabled: event.kind !== "imported",
  });
  const canManage = canManageQuery.data ?? isHost;
  const mine = attendees.data?.find((a) => a.user_id === userId) ?? null;
  const myStatus = mine && mine.status !== "cancelled" ? mine.status : null;
  const state = eventState(event);
  const own = rsvpState(myStatus, mine?.waitlist_position);
  const hub = event.hubs;
  const host = event.profiles;
  const address = event.event_addresses;
  const venue = address?.venues ?? null;
  const approvedOnly = event.address_visibility === "approved_only";
  const left = spotsLeft(event);
  const going = (rsvps.data ?? []).filter((r) => r.status === "going");
  // Imported listings (D-037): no RSVP, a source block with "Register at source" instead.
  const imported = event.kind === "imported";
  const labels = useQuery({ ...importLabelsQuery([event.id]), enabled: imported });
  const importLabel = imported ? (labels.data?.get(event.id) ?? null) : null;

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: ["events", event.id] });
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    void queryClient.invalidateQueries({ queryKey: ["hubs", "events"] });
    void queryClient.invalidateQueries({ queryKey: ["chapters", "events"] });
  };

  const checkInMutation = useMutation({
    mutationFn: () => checkIn(event.id),
    onSuccess: () => {
      invalidate();
      toast.success("Checked in. Have a good one.");
    },
    onError: (err) => toast.error(eventErrorMessage(err)),
  });

  const cancelMutation = useMutation({
    mutationFn: () => cancelEvent(event.id, cancelReason),
    onSuccess: () => {
      invalidate();
      setCancelOpen(false);
      toast("Plan cancelled.");
    },
    onError: (err) => toast.error(eventErrorMessage(err)),
  });

  const headcount =
    event.min_headcount !== null
      ? event.going_count >= event.min_headcount
        ? `Needs ${event.min_headcount} to happen · that's a go`
        : `Happens if at least ${event.min_headcount} join · ${event.min_headcount - event.going_count} more needed`
      : null;

  return (
    <>
      <main className="flex flex-col gap-5 pb-28">
        <div className="h-[200px] bg-surface-2">
          {event.cover_url ? (
            <img src={event.cover_url} alt="" className="size-full object-cover" />
          ) : (
            <DefaultCover seed={event.id} />
          )}
        </div>

        <div className="flex flex-col gap-5 safe-px">
          <section className="flex flex-col gap-2.5">
            {state ||
            own ||
            importLabel ||
            event.min_age === 21 ||
            event.visibility === "campus" ? (
              <div className="flex flex-wrap gap-1.5">
                <EventStateChip state={own} />
                <EventStateChip state={state} />
                {imported ? <ImportedChips label={importLabel} /> : null}
                {/* Facts, not states: the neutral badges the hub page uses, not the info hue. */}
                <HubBadges
                  minAge={event.min_age}
                  scope={event.visibility === "campus" ? "campus" : "general"}
                  className="self-center"
                />
              </div>
            ) : null}
            <h2 className="text-[26px] leading-tight font-extrabold tracking-[-0.02em] text-balance">
              {event.title}
            </h2>
            {hub ? (
              <Link
                to="/hubs/$slug"
                params={{ slug: hub.slug }}
                className="inline-flex min-h-11 items-center gap-1.5 self-start rounded-control border border-border bg-surface px-3 text-[14px] font-semibold hover:bg-surface-2"
              >
                <span aria-hidden="true">{hub.emoji}</span>
                {hub.name}
              </Link>
            ) : null}
            {event.series_id ? (
              <p className="text-[13px] text-text-2">
                One week of a weekly plan. Each week is its own RSVP.
              </p>
            ) : null}
            {event.status === "cancelled" && event.cancel_reason ? (
              <p className="rounded-input bg-danger-tint px-4 py-3 text-[14px] text-danger">
                {event.cancel_reason}
              </p>
            ) : null}
          </section>

          <section className="flex flex-col gap-4 rounded-card border border-border p-4">
            <Row icon={Clock}>
              <p className="font-semibold tabular">
                {formatEventTime(event.starts_at, event.ends_at, event.timezone)}
              </p>
              {event.timezone !== DEFAULT_TIMEZONE ? (
                <p className="text-[13px] text-text-2">
                  Times in {event.timezone.replace(/_/g, " ")}
                </p>
              ) : null}
            </Row>
            <Row icon={MapPin}>
              <p className="font-semibold">
                {event.location_hint || venue?.name || "Place to be announced"}
              </p>
              {address ? (
                <>
                  {venue && venue.name !== event.location_hint ? <p>{venue.name}</p> : null}
                  {venue && formatVenueAddress(venue) ? (
                    <p className="text-text-2">{formatVenueAddress(venue)}</p>
                  ) : null}
                  {address.location_text && address.location_text !== event.location_hint ? (
                    <p>{address.location_text}</p>
                  ) : null}
                  {address.address_note ? (
                    <p className="text-text-2">{address.address_note}</p>
                  ) : null}
                </>
              ) : approvedOnly ? (
                <p className="flex items-start gap-1.5 text-[14px] text-text-2">
                  <Lock className="mt-0.5 size-4 shrink-0" aria-hidden="true" />
                  {myStatus === "going"
                    ? "The host shares the exact address once they approve you."
                    : "Exact address shared after the host approves you."}
                </p>
              ) : null}
            </Row>
            {imported ? null : (
              <Row icon={Users}>
                <p className="font-semibold tabular">
                  {event.going_count} going
                  {event.capacity !== null ? ` of ${event.capacity}` : ""}
                  {left !== null && left > 0
                    ? ` · ${left} ${left === 1 ? "spot" : "spots"} left`
                    : ""}
                  {event.waitlist_count > 0 ? ` · ${event.waitlist_count} waiting` : ""}
                </p>
                {headcount ? <p className="text-[13px] text-text-2">{headcount}</p> : null}
                {event.members_only ? (
                  <p className="text-[13px] text-text-2">Hub members only.</p>
                ) : null}
              </Row>
            )}
            <Row icon={Ticket}>
              <p className="font-semibold">
                {event.is_free ? "Free" : (event.price_text ?? "Paid")}
              </p>
            </Row>
            {event.external_url && !imported ? (
              <Row icon={ExternalLink}>
                <a
                  href={event.external_url}
                  target="_blank"
                  rel="noreferrer"
                  className="break-all font-semibold text-primary-text underline-offset-2 hover:underline"
                >
                  {event.external_url.replace(/^https:\/\//, "")}
                </a>
              </Row>
            ) : null}
          </section>

          {myStatus === "going" && event.status === "published" ? (
            <AddToCalendar event={event} location={calendarLocation(event)} />
          ) : null}

          {imported ? <ImportedSourceSection event={event} label={importLabel} /> : null}

          {host ? (
            <section className="flex items-center gap-3">
              <Avatar src={host.avatar_url} name={host.first_name} size={44} />
              <div className="min-w-0">
                <p className="truncate text-[15px] font-semibold">{host.first_name}</p>
                <p className="truncate text-[13px] text-text-2">Hosting · @{host.handle}</p>
              </div>
            </section>
          ) : null}

          {imported ? null : (
            <section className="flex flex-col gap-2">
              {rsvps.isPending ? (
                <Skeleton className="h-8 w-48 rounded-control" />
              ) : rsvps.isError ? (
                <p className="text-[13px] text-text-2">Couldn't load who's going.</p>
              ) : (
                <AvatarStack
                  people={going.map((r) => ({
                    src: r.profiles?.avatar_url,
                    name: r.profiles?.first_name ?? "Member",
                  }))}
                  max={5}
                  size={32}
                  totalLabel={`${event.going_count} going${
                    event.interested_count > 0 ? ` · ${event.interested_count} interested` : ""
                  }`}
                />
              )}
            </section>
          )}

          {event.description ? (
            <section className="flex flex-col gap-1.5">
              <h3 className="text-[17px] font-bold tracking-[-0.01em]">About</h3>
              <p className="text-[15px] whitespace-pre-wrap">{event.description}</p>
            </section>
          ) : null}

          {canManage ? (
            attendees.isPending ? (
              <Skeleton className="h-24" />
            ) : attendees.isError ? (
              <p className="text-[13px] text-text-2">Couldn't load the attendee list.</p>
            ) : (
              <AttendeesSection event={event} attendees={attendees.data} isHost={isHost} />
            )
          ) : null}
        </div>
      </main>

      {imported ? null : (
        <RsvpBar
          event={event}
          mine={mine}
          isHost={isHost}
          canManage={canManage}
          rsvp={rsvp}
          onCheckIn={() => checkInMutation.mutate()}
          checkingIn={checkInMutation.isPending}
          onCancelEvent={() => setCancelOpen(true)}
        />
      )}
      <GuidelinesSheet {...rsvp.guidelines} />

      <Sheet
        open={cancelOpen}
        onClose={() => setCancelOpen(false)}
        title="Cancel this plan?"
        footer={
          <Button
            variant="danger"
            size="lg"
            block
            loading={cancelMutation.isPending}
            onClick={() => cancelMutation.mutate()}
          >
            Cancel plan
          </Button>
        }
      >
        <p className="text-[15px] text-text-2">
          Everyone going sees it as cancelled. This can't be undone.
        </p>
        <FieldTextArea
          label="Tell them why (optional)"
          className="mt-4"
          rows={3}
          maxLength={500}
          value={cancelReason}
          onChange={(e) => setCancelReason(e.target.value)}
          disabled={cancelMutation.isPending}
        />
      </Sheet>
    </>
  );
}

/**
 * Where the calendar entry says the plan is: the address the viewer can see (they are going),
 * else the coarse hint.
 */
function calendarLocation(event: EventDetail): string | null {
  const address = event.event_addresses;
  const venue = address?.venues ?? null;
  const exact = venue ? formatVenueAddress(venue) : address?.location_text;
  return [venue?.name, exact].filter(Boolean).join(", ") || event.location_hint || null;
}

/**
 * Add to calendar for a Going viewer: an .ics built on the device (Apple Calendar, Outlook and
 * most phones open it), plus Google Calendar's prefilled page, which cannot import a file.
 */
function AddToCalendar({ event, location }: { event: EventDetail; location: string | null }) {
  const entry: CalendarEvent = {
    id: event.id,
    title: event.title,
    startsAt: event.starts_at,
    endsAt: event.ends_at,
    location,
    description: event.description || null,
    url: eventShareUrl(event.id),
  };

  function download() {
    const blob = new Blob([buildIcs(entry)], { type: "text/calendar;charset=utf-8" });
    const href = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = href;
    a.download = icsFilename(event.title);
    document.body.append(a);
    a.click();
    a.remove();
    // Some browsers read the blob after click() returns.
    setTimeout(() => URL.revokeObjectURL(href), 1000);
  }

  return (
    <section className="flex flex-wrap items-center gap-2">
      <Button variant="outline" size="sm" onClick={download}>
        <CalendarPlus className="size-4" aria-hidden="true" />
        Add to calendar
      </Button>
      <a
        href={googleCalendarUrl(entry)}
        target="_blank"
        rel="noreferrer"
        className={buttonVariants({ variant: "ghost", size: "sm" })}
      >
        Google Calendar
      </a>
    </section>
  );
}

function Row({ icon: Icon, children }: { icon: LucideIcon; children: ReactNode }) {
  return (
    <div className="flex gap-3">
      <Icon className="mt-0.5 size-5 shrink-0 text-text-2" aria-hidden="true" />
      <div className="flex min-w-0 flex-1 flex-col gap-0.5 text-[15px]">{children}</div>
    </div>
  );
}
