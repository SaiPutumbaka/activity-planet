import { createClient } from "@/lib/supabase/server";
import type { Hub } from "@/types/database";
import type { FeedEvent } from "@/types/events";

// profiles must be disambiguated: events links to profiles both directly
// (creator_id) and many-to-many through rsvps, so PostgREST needs the FK name.
const EVENT_SELECT =
  "id, title, description, category, location, event_timestamp, creator_id, profiles!events_creator_id_fkey(username), rsvps(user_id)";

interface FetchUpcomingEventsOptions {
  viewerId: string;
  category?: Hub;
}

/**
 * Upcoming events (soonest first) with creator handle and RSVP state for the
 * viewer, mapped to a serializable shape for client components.
 */
export async function fetchUpcomingEvents({
  viewerId,
  category,
}: FetchUpcomingEventsOptions): Promise<FeedEvent[]> {
  const supabase = await createClient();

  let query = supabase
    .from("events")
    .select(EVENT_SELECT)
    .gte("event_timestamp", new Date().toISOString())
    .order("event_timestamp", { ascending: true })
    .limit(50);

  if (category) {
    query = query.eq("category", category);
  }

  const { data, error } = await query;
  if (error) {
    console.error("fetchUpcomingEvents failed:", error.message);
    return [];
  }

  return (data ?? []).map((event) => ({
    id: event.id,
    title: event.title,
    description: event.description,
    category: event.category,
    location: event.location,
    eventTimestamp: event.event_timestamp,
    creatorUsername: event.profiles?.username ?? "unknown",
    attendeeCount: event.rsvps.length,
    joined: event.rsvps.some((rsvp) => rsvp.user_id === viewerId),
    isMine: event.creator_id === viewerId,
  }));
}
