import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, Circle, GraduationCap } from "lucide-react";
import { toast } from "sonner";
import {
  coachingErrorMessage,
  formatPrice,
  listingShapeLabel,
  type Coach,
} from "@ap/core/coaching";

import { BookingRow, CardList, Note, SectionTitle } from "@/components/coaching/parts";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { LinkRow } from "@/components/you/link-row";
import {
  availabilityQuery,
  coachTermsUrl,
  coaching,
  coachQuery,
  coachingKeys,
  myBookingsQuery,
  myCoachStatusQuery,
  ownListingsQuery,
  useCoachingConfig,
} from "@/lib/coaching";
import { SITE_URL } from "@/lib/site";

const appRoute = getRouteApi("/_app");

/**
 * Coach home (design section 15): "Become a coach" for anyone without a coach profile, else the
 * setup checklist, publish or pause, requests to answer, upcoming sessions and the links to the
 * profile, listings, availability and (payments on only) payouts.
 */
export const Route = createFileRoute("/_app/coach")({
  component: CoachHomePage,
});

function CoachHomePage() {
  const { session, profile } = appRoute.useRouteContext();
  const status = useQuery(myCoachStatusQuery(session.user.id));
  return (
    <>
      <TopBar title="Coaching" back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {status.isPending ? (
          <Skeleton className="mt-2 h-40" />
        ) : status.isError ? (
          <FormError>{coachingErrorMessage(status.error)}</FormError>
        ) : status.data === null ? (
          <BecomeCoach />
        ) : (
          <CoachHome handle={profile.handle} userId={session.user.id} />
        )}
      </main>
    </>
  );
}

function BecomeCoach() {
  return (
    <>
      <EmptyState
        icon={GraduationCap}
        title="Coach on Activity Planet"
        body="Teach what you know: lessons, training or practice sessions, in person or online. You set the price, the times and where you coach."
        action={
          <Link to="/coach/profile" className={buttonVariants({ size: "lg" })}>
            Become a coach
          </Link>
        }
      />
      <Note>
        Coaches are 18 or older, legally allowed to do paid work where they coach, and agree to the{" "}
        <a
          href={coachTermsUrl(SITE_URL)}
          target="_blank"
          rel="noreferrer"
          className="font-semibold text-link underline-offset-2 hover:underline"
        >
          Coach Terms
        </a>
        . Credentials you add are shown as self-reported.
      </Note>
    </>
  );
}

function CoachHome({ handle, userId }: { handle: string; userId: string }) {
  const queryClient = useQueryClient();
  const config = useCoachingConfig();
  const coach = useQuery(coachQuery(handle));
  const listings = useQuery(ownListingsQuery(userId));
  const rules = useQuery(availabilityQuery(userId));
  const requests = useInfiniteQuery(myBookingsQuery("coach", "requests"));
  const upcoming = useInfiniteQuery(myBookingsQuery("coach", "upcoming"));

  const toggle = useMutation({
    mutationFn: (on: boolean) => (on ? coaching.publish() : coaching.pause()),
    onSuccess: (_r, on) => {
      void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
      toast.success(on ? "Your coach page is live." : "Your coach page is paused.");
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  if (coach.isPending) return <Skeleton className="mt-2 h-40" />;
  if (coach.isError) return <FormError>{coachingErrorMessage(coach.error)}</FormError>;
  const c: Coach = coach.data;
  const activeListings = (listings.data ?? []).filter((l) => l.status === "active");
  const checklist = [
    { done: c.headline.length >= 3, label: "A headline on your coach profile" },
    { done: c.terms_current === true, label: "Coach Terms accepted" },
    { done: activeListings.length > 0, label: "At least one active listing" },
    { done: (rules.data ?? []).length > 0, label: "Weekly availability (or a group session)" },
  ];
  const ready = checklist.every((x) => x.done);
  const reqRows = requests.data?.pages.flatMap((p) => p.items) ?? [];
  const upRows = upcoming.data?.pages.flatMap((p) => p.items) ?? [];

  return (
    <>
      <section className="flex flex-col gap-3 pt-2">
        <p className="text-[15px]">
          Your coach page is{" "}
          <span className="font-semibold">
            {c.status === "active"
              ? "live"
              : c.status === "paused"
                ? "paused"
                : c.status === "suspended"
                  ? "suspended by moderators"
                  : "a draft"}
          </span>
          .
        </p>
        {c.status !== "active" && c.status !== "suspended" ? (
          <ul className="flex flex-col gap-1.5" aria-label="Before you publish">
            {checklist.map((x) => (
              <li key={x.label} className="flex items-center gap-2 text-[15px]">
                {x.done ? (
                  <Check className="size-4 text-going" aria-hidden="true" />
                ) : (
                  <Circle className="size-4 text-text-3" aria-hidden="true" />
                )}
                <span className={x.done ? "" : "text-text-2"}>{x.label}</span>
              </li>
            ))}
          </ul>
        ) : null}
        <div className="flex flex-wrap gap-2">
          {c.status === "active" ? (
            <Button
              variant="secondary"
              loading={toggle.isPending}
              onClick={() => toggle.mutate(false)}
            >
              Pause my page
            </Button>
          ) : c.status !== "suspended" ? (
            <Button
              loading={toggle.isPending}
              disabled={!ready}
              onClick={() => toggle.mutate(true)}
            >
              Publish
            </Button>
          ) : null}
          <Link
            to="/coaches/$handle"
            params={{ handle }}
            className={buttonVariants({ variant: "outline" })}
          >
            View my page
          </Link>
        </div>
      </section>

      <section className="flex flex-col gap-2">
        <SectionTitle>Set up</SectionTitle>
        <div className="divide-y divide-border overflow-hidden rounded-card border border-border">
          <LinkRow
            to="/coach/profile"
            label="Coach profile"
            value="Edit"
            hint="Headline, area, time zone, Coach Terms"
          />
          <LinkRow
            to="/coach/availability"
            label="Availability"
            value={rules.data ? `${rules.data.length} windows` : ""}
            hint={`Weekly times in ${c.timezone.replace(/_/g, " ")}`}
          />
          {config.paymentsEnabled ? (
            <LinkRow
              to="/coach/payouts"
              label="Get paid in the app"
              value="Open"
              hint="Payouts by Stripe"
            />
          ) : null}
        </div>
        {!config.paymentsEnabled ? (
          <p className="text-[13px] text-text-3">
            Requests only: clients book through the app and you arrange payment with them directly.
          </p>
        ) : null}
      </section>

      <section className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <SectionTitle>Listings</SectionTitle>
          <Link
            to="/coach/listings/$id"
            params={{ id: "new" }}
            className={buttonVariants({ variant: "ghost", size: "sm" })}
          >
            New listing
          </Link>
        </div>
        {(listings.data ?? []).filter((l) => l.status !== "archived").length === 0 ? (
          <p className="text-[15px] text-text-2">
            No listings yet. Add what you offer and its price.
          </p>
        ) : (
          <CardList label="Your listings">
            {(listings.data ?? [])
              .filter((l) => l.status !== "archived")
              .map((l) => (
                <li key={l.id}>
                  <Link
                    to="/coach/listings/$id"
                    params={{ id: l.id }}
                    className="flex min-h-14 items-center justify-between gap-3 px-4 py-3 hover:bg-surface-2"
                  >
                    <span className="min-w-0">
                      <span className="block truncate text-[15px] font-semibold">{l.title}</span>
                      <span className="block text-[13px] text-text-2">
                        {listingShapeLabel(l)}
                        {l.status === "paused" ? " · Paused" : ""}
                        {l.moderation_state ? " · Hidden by moderators" : ""}
                      </span>
                    </span>
                    <span className="shrink-0 text-[15px] font-semibold">
                      {formatPrice(l.price_minor, l.currency)}
                    </span>
                  </Link>
                </li>
              ))}
          </CardList>
        )}
      </section>

      <section className="flex flex-col gap-2">
        <SectionTitle>Requests to answer</SectionTitle>
        {reqRows.length === 0 ? (
          <p className="text-[15px] text-text-2">No requests waiting.</p>
        ) : (
          <CardList label="Requests">
            {reqRows.map((b) => (
              <li key={b.id}>
                <BookingRow booking={b} />
              </li>
            ))}
          </CardList>
        )}
      </section>

      <section className="flex flex-col gap-2">
        <SectionTitle>Upcoming sessions</SectionTitle>
        {upRows.length === 0 ? (
          <p className="text-[15px] text-text-2">Nothing scheduled.</p>
        ) : (
          <CardList label="Upcoming">
            {upRows.map((b) => (
              <li key={b.id}>
                <BookingRow booking={b} />
              </li>
            ))}
          </CardList>
        )}
        <Link
          to="/bookings"
          search={{ role: "coach" }}
          className="text-[14px] font-semibold text-link"
        >
          All bookings
        </Link>
      </section>
    </>
  );
}
