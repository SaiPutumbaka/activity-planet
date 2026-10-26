import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Bell, CalendarX, Search } from "lucide-react";

import { EventCard } from "@/components/events/event-card";
import { GuidelinesSheet } from "@/components/events/guidelines-sheet";
import { useRsvp } from "@/components/events/use-rsvp";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { formatRelativeDay } from "@/lib/datetime";
import { feedQuery, type FeedEvent } from "@/lib/events";
import { myHubsQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

export const Route = createFileRoute("/_app/")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(feedQuery(session.user.id));
  },
  component: HomePage,
});

function HomePage() {
  const { session, profile } = appRoute.useRouteContext();
  const hubs = useQuery(myHubsQuery(session.user.id));

  return (
    <>
      <TopBar
        actions={
          <>
            <Button variant="secondary" size="icon-sm" className="rounded-full" aria-label="Search">
              <Search className="size-5" aria-hidden="true" />
            </Button>
            <Button
              variant="secondary"
              size="icon-sm"
              className="rounded-full"
              aria-label="Notifications"
            >
              <Bell className="size-5" aria-hidden="true" />
            </Button>
          </>
        }
      />
      <main className="flex flex-col gap-5 pb-6 safe-px">
        <section className="pt-2">
          <h2 className="text-[28px] font-extrabold tracking-[-0.025em]">
            Hi, {profile.first_name}.
          </h2>
          <p className="text-text-2">Here's what your hubs are up to this week.</p>
        </section>

        <section>
          <div className="flex items-baseline justify-between">
            <h3 className="text-[17px] font-bold tracking-[-0.01em]">Your hubs</h3>
            <Link to="/hubs" className="text-[14px] font-semibold text-primary-text">
              Edit
            </Link>
          </div>
          <div className="no-scrollbar -mx-4 mt-3 flex gap-3 overflow-x-auto px-4">
            {(hubs.data ?? []).map((m) =>
              m.hubs ? (
                <div key={m.hub_id} className="flex w-16 shrink-0 flex-col items-center gap-1.5">
                  <div className="flex size-16 items-center justify-center rounded-full border-2 border-border-strong bg-surface-2 text-[26px]">
                    <span aria-hidden="true">{m.hubs.emoji}</span>
                  </div>
                  <span className="w-full truncate text-center text-[11px] font-medium">
                    {m.hubs.name}
                  </span>
                </div>
              ) : null,
            )}
            {hubs.isPending
              ? Array.from({ length: 5 }).map((_, i) => (
                  <div
                    key={i}
                    className="size-16 shrink-0 animate-pulse rounded-full bg-surface-2"
                  />
                ))
              : null}
          </div>
        </section>

        <ThisWeek userId={session.user.id} />
      </main>
    </>
  );
}

const SECTIONS = ["Today", "Tomorrow", "This week"] as const;

function groupByDay(events: FeedEvent[], now: Date) {
  const groups = new Map<(typeof SECTIONS)[number], FeedEvent[]>();
  for (const e of events) {
    const day = formatRelativeDay(e.starts_at, e.timezone, now);
    const key = day === "Today" || day === "Tomorrow" ? day : "This week";
    groups.set(key, [...(groups.get(key) ?? []), e]);
  }
  return SECTIONS.flatMap((title) => {
    const list = groups.get(title);
    return list ? [{ title, events: list }] : [];
  });
}

/** feed_events for the next seven days, grouped Today / Tomorrow / This week, Going in place. */
function ThisWeek({ userId }: { userId: string }) {
  const feed = useQuery(feedQuery(userId));
  const rsvp = useRsvp();
  const groups = groupByDay(feed.data ?? [], new Date());

  return (
    <section className="flex flex-col gap-3">
      <h3 className="text-[17px] font-bold tracking-[-0.01em]">This week</h3>

      {feed.isPending ? (
        <div className="flex flex-col gap-3" aria-busy="true">
          <Skeleton className="h-[232px] rounded-card" />
          <Skeleton className="h-[232px] rounded-card" />
        </div>
      ) : feed.isError ? (
        <div className="flex flex-col gap-3">
          <FormError>
            Couldn't load this week's plans. Check your connection and try again.
          </FormError>
          <Button variant="secondary" onClick={() => void feed.refetch()}>
            Try again
          </Button>
        </div>
      ) : feed.data.length === 0 ? (
        <EmptyState
          icon={CalendarX}
          title="Nothing this week yet"
          body="Plans from your hubs land here. Post the first one, or join more hubs."
          action={
            <Link to="/post" className={buttonVariants({ variant: "secondary" })}>
              Post a plan
            </Link>
          }
          className="py-8"
        />
      ) : (
        groups.map((g) => (
          <div key={g.title} className="flex flex-col gap-3">
            <h4 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              {g.title}
            </h4>
            {g.events.map((e) => (
              <EventCard
                key={e.id}
                event={e}
                onGoing={() => rsvp.set(e.id, "going")}
                pending={rsvp.isPending(e.id)}
              />
            ))}
          </div>
        ))
      )}

      {feed.data && feed.data.length < 3 ? (
        <Link
          to="/hubs"
          className="block rounded-card border border-border px-4 py-3 hover:bg-surface-2"
        >
          <p className="text-[15px] font-semibold">Also this week</p>
          <p className="text-[14px] text-text-2">Join more hubs to see more plans.</p>
        </Link>
      ) : null}

      <GuidelinesSheet {...rsvp.guidelines} />
    </section>
  );
}
