import { distanceMiles, type Coordinates } from "@/lib/geo";
import { createClient } from "@/lib/supabase/server";
import type { Hub } from "@/types/database";
import type { FeedEvent } from "@/types/events";

// profiles must be disambiguated: events links to profiles both directly
// (creator_id) and many-to-many through rsvps, so PostgREST needs the FK name.
const EVENT_SELECT =
  "id, title, description, category, location, latitude, longitude, event_timestamp, creator_id, profiles!events_creator_id_fkey(username), rsvps(user_id)";

interface FetchUpcomingEventsOptions {
  viewerId: string;
  /** Filter to a single hub (used by hub pages). */
  category?: Hub;
  /** Filter to a set of hubs (used by Home to scope the feed to your hubs). */
  categories?: Hub[];
  /** When provided, results are sorted nearest-first instead of soonest-first. */
  near?: Coordinates | null;
}

/**
 * Upcoming events with creator handle and RSVP state for the viewer, mapped
 * to a serializable shape for client components. Ordered soonest-first by
 * default, or nearest-first when `near` is given (events without
 * coordinates sort after ones that have them, in their original order).
 */
export async function fetchUpcomingEvents({
  viewerId,
  category,
  categories,
  near,
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
  } else if (categories && categories.length > 0) {
    query = query.in("category", categories);
  }

  const { data, error } = await query;
  if (error) {
    console.error("fetchUpcomingEvents failed:", error.message);
    return [];
  }

  const events: FeedEvent[] = (data ?? []).map((event) => ({
    id: event.id,
    title: event.title,
    description: event.description,
    category: event.category,
    location: event.location,
    latitude: event.latitude,
    longitude: event.longitude,
    eventTimestamp: event.event_timestamp,
    creatorUsername: event.profiles?.username ?? "unknown",
    attendeeCount: event.rsvps.length,
    joined: event.rsvps.some((rsvp) => rsvp.user_id === viewerId),
    isMine: event.creator_id === viewerId,
  }));

  if (!near) {
    return events;
  }

  return [...events].sort((a, b) => {
    const aHasCoords = a.latitude !== null && a.longitude !== null;
    const bHasCoords = b.latitude !== null && b.longitude !== null;
    if (aHasCoords && bHasCoords) {
      const distanceA = distanceMiles(near, {
        latitude: a.latitude as number,
        longitude: a.longitude as number,
      });
      const distanceB = distanceMiles(near, {
        latitude: b.latitude as number,
        longitude: b.longitude as number,
      });
      return distanceA - distanceB;
    }
    if (aHasCoords) {
      return -1;
    }
    if (bHasCoords) {
      return 1;
    }
    return 0;
  });
}
