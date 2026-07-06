import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { EventCard } from "@/components/shared/event-card";
import { Button } from "@/components/ui/button";
import { fetchUpcomingEvents } from "@/lib/events";
import { createClient } from "@/lib/supabase/server";

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

  const events = await fetchUpcomingEvents({ viewerId: user.id });

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Happening soon</h1>
        <p className="text-sm text-muted-foreground">
          Upcoming activities across every hub.
        </p>
      </div>
      {events.length === 0 ? (
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
