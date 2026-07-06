import type { Metadata } from "next";
import Link from "next/link";
import { redirect } from "next/navigation";

import { EventCard } from "@/components/shared/event-card";
import { fetchUpcomingEvents } from "@/lib/events";
import { HUB_EMOJI } from "@/lib/hubs";
import { createClient } from "@/lib/supabase/server";
import { cn } from "@/lib/utils";
import { HUBS, type Hub } from "@/types/database";

export const metadata: Metadata = {
  title: "Discover",
};

function parseHub(value: string | undefined): Hub | undefined {
  return (HUBS as readonly string[]).includes(value ?? "")
    ? (value as Hub)
    : undefined;
}

interface DiscoverPageProps {
  searchParams: Promise<{ hub?: string }>;
}

export default async function DiscoverPage({
  searchParams,
}: DiscoverPageProps) {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { hub } = await searchParams;
  const activeHub = parseHub(hub);
  const events = await fetchUpcomingEvents({
    viewerId: user.id,
    category: activeHub,
  });

  return (
    <div className="space-y-4">
      <div>
        <h1 className="text-2xl font-bold tracking-tight">Discover</h1>
        <p className="text-sm text-muted-foreground">
          Browse activities by hub.
        </p>
      </div>
      <div className="flex gap-2 overflow-x-auto pb-1">
        <Link
          href="/discover"
          className={cn(
            "shrink-0 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors",
            !activeHub
              ? "border-primary bg-primary text-primary-foreground"
              : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
          )}
        >
          All
        </Link>
        {HUBS.map((h) => (
          <Link
            key={h}
            href={{ pathname: "/discover", query: { hub: h } }}
            className={cn(
              "shrink-0 rounded-full border px-3 py-1.5 text-sm font-medium transition-colors",
              activeHub === h
                ? "border-primary bg-primary text-primary-foreground"
                : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
            )}
          >
            <span aria-hidden>{HUB_EMOJI[h]}</span> {h}
          </Link>
        ))}
      </div>
      {events.length === 0 ? (
        <div className="flex flex-col items-center gap-2 rounded-xl border border-dashed px-6 py-16 text-center">
          <p className="text-3xl" aria-hidden>
            {activeHub ? HUB_EMOJI[activeHub] : "🔭"}
          </p>
          <p className="font-medium">
            {activeHub
              ? `Nothing coming up in ${activeHub}`
              : "Nothing coming up right now"}
          </p>
          <p className="text-sm text-muted-foreground">
            Check back later or start your own.
          </p>
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
