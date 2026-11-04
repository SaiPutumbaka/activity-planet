import { useEffect, useRef, useState } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CalendarX, ChevronDown, LocateFixed, MapPin, Search } from "lucide-react";
import { z } from "zod";
import { deviceTimeZone, feedTimeZone, groupFeed } from "@ap/core/feed";

import { AttendancePromptCard } from "@/components/events/attendance-prompt-card";
import { EventCard } from "@/components/events/event-card";
import { GuidelinesSheet } from "@/components/events/guidelines-sheet";
import { useRsvp } from "@/components/events/use-rsvp";
import { ImportedShelf } from "@/components/feed/imported-shelf";
import { LocationSheet } from "@/components/feed/location-sheet";
import { ChatsButton } from "@/components/shell/chats-button";
import { InboxBell } from "@/components/shell/inbox-bell";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Chip } from "@/components/ui/chip";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { feedQuery } from "@/lib/events";
import { areasQuery, feedPrefsQuery, setMyTimezone, useFeedOrigin } from "@/lib/location";
import { myHubsQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

/** `?hub=<slug>` narrows the feed to one of your hubs; `?free=true` to free plans. */
const searchSchema = z.object({
  hub: z.string().min(1).max(80).optional(),
  free: z.boolean().optional(),
});

/**
 * Home: Feed v2 (D-036, D-040). Plans near the viewer's saved home, anywhere in the world (or,
 * after they tap "Use my location", near them) plus everything in their hubs, in Today / This week / Later over 30
 * days. Imported listings sit in their own shelf below. Nothing here asks for location.
 * Above it all, a "Did you go?" card for the newest plan the viewer hasn't answered for.
 */
export const Route = createFileRoute("/_app/")({
  validateSearch: searchSchema,
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(areasQuery);
    void queryClient.prefetchQuery(feedPrefsQuery(session.user.id));
    void queryClient.prefetchQuery(myHubsQuery(session.user.id));
  },
  component: HomePage,
});

function HomePage() {
  const { session, profile } = appRoute.useRouteContext();

  return (
    <>
      <TopBar
        actions={
          <>
            <Button variant="secondary" size="icon-sm" className="rounded-full" aria-label="Search">
              <Search className="size-5" aria-hidden="true" />
            </Button>
            <ChatsButton />
            <InboxBell userId={session.user.id} />
          </>
        }
      />
      <main className="flex flex-col gap-5 pb-6 pt-2 safe-px">
        <AttendancePromptCard userId={session.user.id} />
        <section>
          <h2 className="text-[28px] font-extrabold tracking-[-0.025em]">
            Hi, {profile.first_name}.
          </h2>
          <p className="text-text-2">Here's what's happening around you.</p>
        </section>

        <Feed userId={session.user.id} />
      </main>
    </>
  );
}

function Feed({ userId }: { userId: string }) {
  const search = Route.useSearch();
  const navigate = useNavigate({ from: "/" });
  const origin = useFeedOrigin(userId);
  const radius = useQuery(feedPrefsQuery(userId));
  const hubs = useQuery(myHubsQuery(userId));
  const areas = useQuery(areasQuery);
  const [sheetOpen, setSheetOpen] = useState(false);
  const rsvp = useRsvp();

  const myHubs = (hubs.data ?? []).flatMap((m) => (m.hubs ? [m.hubs] : []));
  const hubFilter = search.hub ? myHubs.find((h) => h.slug === search.hub) : undefined;
  const radiusKm = radius.data?.radiusKm ?? 10;
  // Today / This week follow the viewer's own day, wherever they are (D-040): the device zone is
  // sent with each request and saved once it differs from the stored one.
  const deviceZone = deviceTimeZone();
  const savedZone = radius.data?.timeZone ?? null;
  const zoneSaved = useRef(false);
  useEffect(() => {
    if (!deviceZone || !radius.isSuccess || savedZone === deviceZone || zoneSaved.current) return;
    zoneSaved.current = true;
    // Best effort: the feed already sends the zone, so a failed save changes nothing on screen.
    setMyTimezone(deviceZone).catch(() => undefined);
  }, [deviceZone, savedZone, radius.isSuccess]);

  // Wait for the radius, the areas (part of the key) and, when filtering by a slug, the hub list,
  // so the first request is the right one. A failed load of any of them still lets the feed run.
  const ready = !radius.isPending && !areas.isPending && (!search.hub || !hubs.isPending);
  const feed = useQuery({
    ...feedQuery({
      userId,
      point: origin.point,
      areaId: origin.homeArea?.id ?? null,
      homeKey: origin.homePoint
        ? `${origin.homePoint.lat},${origin.homePoint.lng}`
        : (origin.homeLabel ?? null),
      radiusKm,
      hubId: hubFilter?.id,
      free: search.free,
      timeZone: deviceZone,
    }),
    enabled: ready,
  });

  const now = new Date();
  const groups = groupFeed(feed.data?.events ?? [], now, feedTimeZone(deviceZone, savedZone));
  const filtered = Boolean(hubFilter) || Boolean(search.free);

  function setFilter(next: { hub?: string; free?: boolean }) {
    void navigate({ search: next, replace: true });
  }

  return (
    <section className="flex flex-col gap-4">
      <div className="flex flex-col gap-3">
        <button
          type="button"
          onClick={() => setSheetOpen(true)}
          className="inline-flex h-9 items-center gap-1.5 self-start rounded-control border border-border bg-surface px-3 text-[14px] font-semibold hover:bg-surface-2"
          aria-label={
            origin.label === "Near you"
              ? `Showing plans near you, within ${radiusKm} km. Change`
              : `Showing plans around ${origin.label}, within ${radiusKm} km. Change`
          }
        >
          {origin.point ? (
            <LocateFixed className="size-4 text-text-2" aria-hidden="true" />
          ) : (
            <MapPin className="size-4 text-text-2" aria-hidden="true" />
          )}
          {origin.label}
          <span className="font-normal text-text-2 tabular">· {radiusKm} km</span>
          <ChevronDown className="size-4 text-text-2" aria-hidden="true" />
        </button>

        <div
          className="no-scrollbar -mx-4 flex gap-2 overflow-x-auto px-4"
          role="group"
          aria-label="Filters"
        >
          <Chip selected={!filtered} onClick={() => setFilter({})}>
            All
          </Chip>
          <Chip
            selected={Boolean(search.free)}
            onClick={() => setFilter({ hub: search.hub, free: search.free ? undefined : true })}
          >
            Free
          </Chip>
          {myHubs.map((h) => (
            <Chip
              key={h.id}
              leading={h.emoji}
              selected={hubFilter?.id === h.id}
              onClick={() =>
                setFilter({
                  hub: hubFilter?.id === h.id ? undefined : h.slug,
                  free: search.free,
                })
              }
            >
              {h.name}
            </Chip>
          ))}
        </div>
      </div>

      {!ready || feed.isPending ? (
        <div className="flex flex-col gap-3" aria-busy="true">
          <Skeleton className="h-[232px] rounded-card" />
          <Skeleton className="h-[232px] rounded-card" />
        </div>
      ) : feed.isError ? (
        <div className="flex flex-col gap-3">
          <FormError>Couldn't load plans. Check your connection and try again.</FormError>
          <Button variant="secondary" onClick={() => void feed.refetch()}>
            Try again
          </Button>
        </div>
      ) : (
        <>
          {feed.data.widened ? (
            <p className="text-[13px] text-text-2" role="status">
              Not much close by, so this goes a little further out
              <span className="tabular"> (within {feed.data.radiusKm} km)</span>.
            </p>
          ) : null}

          {groups.sections.length === 0 ? (
            filtered ? (
              <EmptyState
                icon={CalendarX}
                title="Nothing matches yet"
                body="Try another filter, or post a plan for this crowd yourself."
                action={
                  <Button variant="secondary" onClick={() => setFilter({})}>
                    Clear filters
                  </Button>
                }
                className="py-8"
              />
            ) : groups.imported.length > 0 ? (
              // Listings below, but no plans from people yet: a nudge, not "it's quiet".
              <div className="flex flex-col items-start gap-3 rounded-card border border-border bg-surface-2 px-4 py-4">
                <p className="text-[15px] font-semibold">No plans from people yet. Post one.</p>
                <Link to="/post" className={buttonVariants({ variant: "secondary" })}>
                  Post a plan
                </Link>
              </div>
            ) : (
              <EmptyState
                icon={CalendarX}
                title="Your plan could be the first"
                body="It's quiet around here this month. Post something you'd like to do, or find a hub for what you're into and meet the people in it."
                action={
                  <div className="flex flex-wrap justify-center gap-2">
                    <Link to="/post" className={buttonVariants({ variant: "secondary" })}>
                      Post a plan
                    </Link>
                    <Link to="/hubs" className={buttonVariants({ variant: "ghost" })}>
                      Browse hubs
                    </Link>
                  </div>
                }
                className="py-8"
              />
            )
          ) : (
            groups.sections.map((g) => (
              <div key={g.key} className="flex flex-col gap-3">
                <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
                  {g.title}
                </h3>
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

          <ImportedShelf events={groups.imported} />
        </>
      )}

      <LocationSheet
        open={sheetOpen}
        onClose={() => setSheetOpen(false)}
        userId={userId}
        origin={origin}
        radiusKm={radiusKm}
      />
      <GuidelinesSheet {...rsvp.guidelines} />
    </section>
  );
}
