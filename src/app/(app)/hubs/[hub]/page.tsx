import type { Metadata } from "next";
import { notFound, redirect } from "next/navigation";

import { EventCard } from "@/components/shared/event-card";
import { HubChat, type HubChatMessage } from "@/components/shared/hub-chat";
import { HubJoinToggle } from "@/components/shared/hub-join-toggle";
import { HubMapLoader } from "@/components/shared/hub-map-loader";
import {
  Tabs,
  TabsContent,
  TabsList,
  TabsTrigger,
} from "@/components/ui/tabs";
import { fetchUpcomingEvents } from "@/lib/events";
import { slugToHub } from "@/lib/hub-slug";
import { HUB_EMOJI } from "@/lib/hubs";
import { createClient } from "@/lib/supabase/server";

interface HubPageProps {
  params: Promise<{ hub: string }>;
}

export async function generateMetadata({
  params,
}: HubPageProps): Promise<Metadata> {
  const { hub: hubSlug } = await params;
  const hub = slugToHub(hubSlug);
  return { title: hub ?? "Hub" };
}

export default async function HubPage({ params }: HubPageProps) {
  const { hub: hubSlug } = await params;
  const hub = slugToHub(hubSlug);
  if (!hub) {
    notFound();
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  const { data: profile } = await supabase
    .from("profiles")
    .select("username, selected_hobbies, latitude, longitude")
    .eq("id", user.id)
    .maybeSingle();

  if (!profile) {
    redirect("/onboarding");
  }

  const isMember = profile.selected_hobbies.includes(hub);
  const userLocation =
    profile.latitude !== null && profile.longitude !== null
      ? { latitude: profile.latitude, longitude: profile.longitude }
      : null;

  const [events, messagesResult] = await Promise.all([
    fetchUpcomingEvents({
      viewerId: user.id,
      category: hub,
      near: userLocation,
    }),
    supabase
      .from("hub_messages")
      .select(
        "id, sender_id, body, created_at, profiles!hub_messages_sender_id_fkey(username)",
      )
      .eq("hub", hub)
      .order("created_at", { ascending: true })
      .limit(100),
  ]);

  // RLS returns an empty set (not an error) for non-members; safe either way.
  const initialMessages: HubChatMessage[] = (messagesResult.data ?? []).map(
    (row) => ({
      id: row.id,
      senderId: row.sender_id,
      senderUsername: row.profiles?.username ?? "unknown",
      body: row.body,
      createdAt: row.created_at,
    }),
  );

  const mapEvents = events
    .filter((event) => event.latitude !== null && event.longitude !== null)
    .map((event) => ({
      id: event.id,
      title: event.title,
      eventTimestamp: event.eventTimestamp,
      attendeeCount: event.attendeeCount,
      latitude: event.latitude as number,
      longitude: event.longitude as number,
    }));

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3">
        <div className="flex items-center gap-3">
          <span className="text-3xl" aria-hidden>
            {HUB_EMOJI[hub]}
          </span>
          <div>
            <h1 className="text-2xl font-bold tracking-tight">{hub}</h1>
            <p className="text-sm text-muted-foreground">
              {isMember ? "You're a member" : "Not joined yet"}
            </p>
          </div>
        </div>
        <HubJoinToggle hub={hub} initialIsMember={isMember} />
      </div>

      <Tabs defaultValue="events">
        <TabsList className="grid w-full grid-cols-3">
          <TabsTrigger value="events">Events</TabsTrigger>
          <TabsTrigger value="chat">Chat</TabsTrigger>
          <TabsTrigger value="map">Map</TabsTrigger>
        </TabsList>
        <TabsContent value="events" className="space-y-4 pt-4">
          {events.length === 0 ? (
            <div className="flex flex-col items-center gap-2 rounded-xl border border-dashed px-6 py-16 text-center">
              <p className="text-3xl" aria-hidden>
                {HUB_EMOJI[hub]}
              </p>
              <p className="font-medium">Nothing coming up in {hub}</p>
              <p className="text-sm text-muted-foreground">
                Be the first to post one.
              </p>
            </div>
          ) : (
            events.map((event) => <EventCard key={event.id} event={event} />)
          )}
        </TabsContent>
        <TabsContent value="chat" className="pt-4">
          <HubChat
            hub={hub}
            currentUserId={user.id}
            currentUsername={profile.username}
            initialMessages={initialMessages}
            isMember={isMember}
          />
        </TabsContent>
        <TabsContent value="map" className="pt-4">
          <HubMapLoader hub={hub} events={mapEvents} userLocation={userLocation} />
        </TabsContent>
      </Tabs>
    </div>
  );
}
