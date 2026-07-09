import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";
import { CalendarClock, MapPin, Pencil } from "lucide-react";

import { signOutAction } from "@/actions/auth";
import { Avatar, AvatarFallback, AvatarImage } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardHeader,
  CardTitle,
} from "@/components/ui/card";
import { calculateAge } from "@/lib/age";
import { hubToSlug } from "@/lib/hub-slug";
import { hubEmoji } from "@/lib/hubs";
import { createClient } from "@/lib/supabase/server";
import { isHub } from "@/types/database";

export const metadata: Metadata = {
  title: "Profile",
};

interface EventSummary {
  id: string;
  title: string;
  category: string;
  location: string;
  event_timestamp: string;
}

const TIME_FORMAT = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

function EventList({ events, empty }: { events: EventSummary[]; empty: string }) {
  if (events.length === 0) {
    return <p className="py-4 text-sm text-muted-foreground">{empty}</p>;
  }
  return (
    <ul className="divide-y">
      {events.map((event) => (
        <li key={event.id} className="flex items-center gap-3 py-3">
          <span className="text-2xl" aria-hidden>
            {hubEmoji(event.category)}
          </span>
          <div className="min-w-0">
            <p className="truncate font-medium">{event.title}</p>
            <p className="flex flex-wrap items-center gap-x-3 gap-y-0.5 text-xs text-muted-foreground">
              <span className="flex items-center gap-1">
                <CalendarClock className="h-3.5 w-3.5" aria-hidden />
                <time dateTime={event.event_timestamp} suppressHydrationWarning>
                  {TIME_FORMAT.format(new Date(event.event_timestamp))}
                </time>
              </span>
              <span className="flex items-center gap-1">
                <MapPin className="h-3.5 w-3.5" aria-hidden />
                <span className="truncate">{event.location}</span>
              </span>
            </p>
          </div>
        </li>
      ))}
    </ul>
  );
}

export default async function ProfilePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const nowIso = new Date().toISOString();

  const [{ data: profile }, { data: rsvpRows }, { data: createdEvents }] =
    await Promise.all([
      supabase
        .from("profiles")
        .select(
          "username, full_name, email, organization, bio, birthday, location_text, avatar_url, selected_hobbies, created_at",
        )
        .eq("id", user.id)
        .maybeSingle(),
      supabase
        .from("rsvps")
        .select(
          "events!inner(id, title, category, location, event_timestamp)",
        )
        .eq("user_id", user.id)
        .gte("events.event_timestamp", nowIso),
      supabase
        .from("events")
        .select("id, title, category, location, event_timestamp")
        .eq("creator_id", user.id)
        .gte("event_timestamp", nowIso)
        .order("event_timestamp", { ascending: true }),
    ]);

  if (!profile) {
    redirect("/onboarding");
  }

  const rsvpEvents: EventSummary[] = (rsvpRows ?? [])
    .map((row) => row.events)
    .filter((event): event is EventSummary => event !== null)
    .sort(
      (a, b) =>
        new Date(a.event_timestamp).getTime() -
        new Date(b.event_timestamp).getTime(),
    );

  const age = profile.birthday ? calculateAge(profile.birthday) : null;
  const hostedCount = (createdEvents ?? []).length;
  const hubs = profile.selected_hobbies.filter(isHub);
  const metaLine = [
    profile.organization,
    age ? `${age} yrs` : null,
    profile.location_text,
  ].filter(Boolean);

  return (
    <div className="space-y-6">
      <div className="flex items-start gap-4 sm:gap-6">
        <Avatar className="h-20 w-20 shrink-0 sm:h-24 sm:w-24">
          {profile.avatar_url ? (
            <AvatarImage src={profile.avatar_url} alt="" />
          ) : null}
          <AvatarFallback className="text-2xl font-semibold uppercase">
            {profile.username.slice(0, 2)}
          </AvatarFallback>
        </Avatar>
        <div className="min-w-0 flex-1 pt-1">
          <div className="flex items-start justify-between gap-2">
            <div className="min-w-0">
              <h1 className="truncate text-xl font-bold tracking-tight sm:text-2xl">
                {profile.full_name || `@${profile.username}`}
              </h1>
              {profile.full_name ? (
                <p className="truncate text-sm text-muted-foreground">
                  @{profile.username}
                </p>
              ) : null}
            </div>
            <Button asChild variant="outline" size="icon" className="shrink-0">
              <Link href="/profile/edit" aria-label="Edit profile">
                <Pencil className="h-4 w-4" />
              </Link>
            </Button>
          </div>
          {metaLine.length > 0 ? (
            <p className="mt-1 flex flex-wrap gap-x-2 gap-y-0.5 text-xs text-muted-foreground">
              {metaLine.map((item, index) => (
                <span key={item}>
                  {index > 0 ? <span className="mr-2">·</span> : null}
                  {item}
                </span>
              ))}
            </p>
          ) : null}
        </div>
      </div>

      {profile.bio ? (
        <p className="whitespace-pre-line text-sm leading-relaxed">
          {profile.bio}
        </p>
      ) : null}

      <div className="grid grid-cols-3 divide-x rounded-xl border py-3 text-center">
        <div>
          <p className="text-lg font-bold">{hubs.length}</p>
          <p className="text-xs text-muted-foreground">Hubs</p>
        </div>
        <div>
          <p className="text-lg font-bold">{rsvpEvents.length}</p>
          <p className="text-xs text-muted-foreground">Attending</p>
        </div>
        <div>
          <p className="text-lg font-bold">{hostedCount}</p>
          <p className="text-xs text-muted-foreground">Hosted</p>
        </div>
      </div>

      {hubs.length > 0 ? (
        <div className="flex gap-4 overflow-x-auto pb-1">
          {hubs.map((hub) => (
            <Link
              key={hub}
              href={`/hubs/${hubToSlug(hub)}`}
              className="flex shrink-0 flex-col items-center gap-1.5"
            >
              <span className="flex h-14 w-14 items-center justify-center rounded-full border-2 bg-muted text-2xl">
                {hubEmoji(hub)}
              </span>
              <span className="max-w-[4.5rem] truncate text-center text-[11px] text-muted-foreground">
                {hub}
              </span>
            </Link>
          ))}
        </div>
      ) : (
        <p className="text-sm text-muted-foreground">
          No hubs yet —{" "}
          <Link href="/profile/edit" className="underline underline-offset-2">
            pick some
          </Link>
          .
        </p>
      )}

      <Card>
        <CardHeader className="pb-1">
          <CardTitle className="text-base">
            Upcoming events you&apos;re attending
          </CardTitle>
        </CardHeader>
        <CardContent>
          <EventList
            events={rsvpEvents}
            empty="Nothing yet — join something from the home feed!"
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader className="pb-1">
          <CardTitle className="text-base">Events you created</CardTitle>
        </CardHeader>
        <CardContent>
          <EventList
            events={createdEvents ?? []}
            empty="You haven't posted an event yet."
          />
        </CardContent>
      </Card>

      <form action={signOutAction}>
        <Button type="submit" variant="outline" className="w-full">
          Sign out
        </Button>
      </form>
    </div>
  );
}
