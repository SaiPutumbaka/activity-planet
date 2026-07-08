import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { EventCard } from "@/components/shared/event-card";
import { Button } from "@/components/ui/button";
import { fetchUpcomingEvents } from "@/lib/events";
import { createClient } from "@/lib/supabase/server";
import { isHub } from "@/types/database";

export const metadata: Metadata = {
  title: "Home",
};

export default async function HomePage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("selected_hobbies, location_text, latitude, longitude")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) {
    redirect("/onboarding");
  }

  const hubs = profile.selected_hobbies.filter(isHub);
  const userLocation =
    profile.latitude !== null && profile.longitude !== null
      ? { latitude: profile.latitude, longitude: profile.longitude }
      : null;

  const events =
    hubs.length > 0
      ? await fetchUpcomingEvents({
          viewerId: user.id,
          categories: hubs,
          near: userLocation,
        })
      : [];

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Happening soon</h1>
        <p className="text-sm text-muted-foreground">
          {hubs.length === 0
            ? "Join a hub to start seeing events here."
            : userLocation
              ? `Upcoming activities in your hubs, nearest first${
                  profile.location_text ? ` around ${profile.location_text}` : ""
                }.`
              : "Upcoming activities across your hubs, soonest first."}
        </p>
      </div>
      {hubs.length === 0 ? (
        <div className="flex flex-col items-center gap-4 rounded-xl border border-dashed px-6 py-16 text-center">
          <p className="text-3xl" aria-hidden>
            🧭
          </p>
          <div>
            <p className="font-medium">You haven&apos;t joined any hubs yet</p>
            <p className="text-sm text-muted-foreground">
              Pick a few interests and your feed fills in.
            </p>
          </div>
          <Button asChild>
            <Link href="/profile/edit">Choose your hubs</Link>
          </Button>
        </div>
      ) : events.length === 0 ? (
        <div className="flex flex-col items-center gap-4 rounded-xl border border-dashed px-6 py-16 text-center">
          <p className="text-3xl" aria-hidden>
            🪐
          </p>
          <div>
            <p className="font-medium">No upcoming events yet</p>
            <p className="text-sm text-muted-foreground">
              Be the first to get something going.
            </p>
          </div>
          <Button asChild>
            <Link href="/create">Create an event</Link>
          </Button>
        </div>
      ) : (
        <div className="space-y-4">
          {events.map((event) => (
            <EventCard key={event.id} event={event} />
          ))}
        </div>
      )}
    </div>
  );
}
