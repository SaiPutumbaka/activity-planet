import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery } from "@tanstack/react-query";
import { BadgeCheck, CircleAlert } from "lucide-react";
import { toast } from "sonner";
import { organizerErrorMessage } from "@ap/core/organizer";

import { ClaimCard } from "@/components/organizer/claim-card";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { eventbriteStart, eventbriteStatusQuery, myClaimsQuery } from "@/lib/organizer";
import { SITE_URL } from "@/lib/site";

/**
 * /organizer (COLLECTOR_COMPLETION Slice 2): the signed-in person's organizer claims, newest
 * first, with the proof to put in place and "Check now" while pending, and the sources and
 * connected calendars a verified claim manages. "Connect a calendar" starts a feed claim (the
 * proof for a hosted calendar). "Connect Eventbrite" shows only when the server has its keys.
 */
export const Route = createFileRoute("/_app/organizer")({
  component: OrganizerPage,
});

function OrganizerPage() {
  const claims = useQuery(myClaimsQuery());
  const eventbrite = useQuery(eventbriteStatusQuery());
  const connectEventbrite = useMutation({
    mutationFn: eventbriteStart,
    onSuccess: (url) => window.location.assign(url),
    onError: (err) => toast.error(organizerErrorMessage(err)),
  });

  return (
    <>
      <TopBar title="Organizer" back />
      <main className="flex flex-col gap-5 pt-2 pb-8 safe-px">
        <p className="text-[15px] text-text-2">
          Run an event calendar or a venue? Prove it once and your listings say they&apos;re from
          the organizer. You choose their hub, hide single events, stop the listing, or connect your
          own calendar.{" "}
          <a
            href={`${SITE_URL}/bot`}
            target="_blank"
            rel="noopener noreferrer"
            className="font-semibold text-text underline underline-offset-2"
          >
            How our collector works
          </a>
        </p>

        <div className="flex flex-wrap gap-2">
          <Link
            to="/organizer/claim"
            search={{ feed: true }}
            className={buttonVariants({ variant: "secondary" })}
          >
            Connect a calendar
          </Link>
          {eventbrite.data ? (
            <Button
              variant="outline"
              loading={connectEventbrite.isPending}
              onClick={() => connectEventbrite.mutate()}
            >
              Connect Eventbrite
            </Button>
          ) : null}
        </div>

        <section className="flex flex-col gap-3">
          <h2 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Your claims
          </h2>
          {claims.isPending ? (
            <ListSkeleton rows={2} rowClassName="h-32" />
          ) : claims.isError ? (
            <EmptyState
              icon={CircleAlert}
              title="Couldn't load your claims"
              body={organizerErrorMessage(claims.error)}
              action={
                <Button variant="secondary" onClick={() => void claims.refetch()}>
                  Try again
                </Button>
              }
            />
          ) : claims.data.length === 0 ? (
            <EmptyState
              icon={BadgeCheck}
              title="No claims yet"
              body='Open one of your events and tap "Are you the organizer?", or connect your calendar.'
            />
          ) : (
            <ul className="flex flex-col gap-3">
              {claims.data.map((c) => (
                <li key={c.claim_id}>
                  <ClaimCard claim={c} />
                </li>
              ))}
            </ul>
          )}
        </section>
      </main>
    </>
  );
}
