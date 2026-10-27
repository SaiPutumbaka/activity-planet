import { queryOptions } from "@tanstack/react-query";
import type { Database, Json } from "@ap/core/types";

import { isOver } from "./datetime";
import { supabase } from "./supabase";

/**
 * Events: queries, the RPC wrappers (jsonb args typed so callers get autocomplete), the error
 * map for every code the event RPCs raise, and the guidelines gate helper used by useRsvp.
 *
 *   useQuery(eventQuery(id))               // the event with hub, host, readable address + venue
 *   useQuery(eventRsvpsQuery(id))          // going / interested rows with names, for the avatar row
 *   useQuery(eventAttendeesQuery(id))      // event_attendees(): own row, or every row for the host
 *   useQuery(feedQuery(userId))            // feed_events(now - 6 h, now + 7 d) with hub, plus own RSVPs
 *   await createEvent({ hub_id, title, starts_at, ends_at, ... })
 *   eventErrorMessage(err)                 // "That event is full." for "event_full"
 */
export type EventRow = Database["public"]["Tables"]["events"]["Row"];
export type RsvpRow = Database["public"]["Tables"]["rsvps"]["Row"];
export type RsvpStatus = Database["public"]["Enums"]["rsvp_status"];
export type EventVisibility = Database["public"]["Enums"]["event_visibility"];
export type AddressVisibility = Database["public"]["Enums"]["address_visibility"];
export type EventKind = Database["public"]["Enums"]["event_kind"];

/* ------------------------------------------------------------------ */
/* RPC argument shapes (jsonb). Keys absent from the object are not sent, */
/* so `undefined` means "leave the default" and `null` means "clear".   */
/* ------------------------------------------------------------------ */

/** create_event(p_args). Starred keys in the migration header are required here. */
export type CreateEventArgs = {
  hub_id: string;
  title: string;
  starts_at: string;
  ends_at: string;
  description?: string;
  kind?: "member" | "chapter";
  chapter_id?: string | null;
  visibility?: EventVisibility;
  campus_id?: string | null;
  min_age?: 18 | 21;
  capacity?: number | null;
  waitlist_enabled?: boolean;
  min_headcount?: number | null;
  members_only?: boolean;
  is_free?: boolean;
  price_text?: string | null;
  venue_id?: string | null;
  location_text?: string;
  address_note?: string;
  address_visibility?: AddressVisibility;
  location_hint?: string;
  cover_url?: string | null;
  timezone?: string;
  external_url?: string | null;
};

/** update_event(p_event_id, p_args): a patch. kind, hub_id and chapter_id are fixed after creation. */
export type UpdateEventArgs = Partial<Omit<CreateEventArgs, "hub_id" | "kind" | "chapter_id">>;

/** create_event_series(p_args): create_event keys minus starts_at/ends_at, plus the weekly template. */
export type CreateEventSeriesArgs = Omit<CreateEventArgs, "starts_at" | "ends_at"> & {
  /** 0 = Sunday .. 6 = Saturday */
  weekday: number;
  /** "HH:MM" wall-clock time in `timezone` */
  start_time: string;
  duration_minutes: number;
  /** "YYYY-MM-DD"; defaults to today in the series timezone */
  starts_on?: string;
  ends_on?: string | null;
  max_occurrences?: number | null;
};

function asJson(args: object): Json {
  // Every value above is a JSON scalar; the cast only tells supabase-js the shape is jsonb.
  return args as Json;
}

/* ------------------------------------------------------------------ */
/* Mutations                                                           */
/* ------------------------------------------------------------------ */

export async function createEvent(args: CreateEventArgs): Promise<EventRow> {
  const { data, error } = await supabase.rpc("create_event", { p_args: asJson(args) });
  if (error) throw error;
  return data;
}

export async function updateEvent(eventId: string, patch: UpdateEventArgs): Promise<EventRow> {
  const { data, error } = await supabase.rpc("update_event", {
    p_event_id: eventId,
    p_args: asJson(patch),
  });
  if (error) throw error;
  return data;
}

export async function cancelEvent(eventId: string, reason: string): Promise<EventRow> {
  const trimmed = reason.trim();
  const { data, error } = await supabase.rpc("cancel_event", {
    p_event_id: eventId,
    ...(trimmed ? { p_reason: trimmed } : {}),
  });
  if (error) throw error;
  return data;
}

/** Creates the series and returns the id of its first occurrence (null if none materialized). */
export async function createEventSeries(
  args: CreateEventSeriesArgs,
): Promise<{ seriesId: string; firstEventId: string | null }> {
  const { data, error } = await supabase.rpc("create_event_series", { p_args: asJson(args) });
  if (error) throw error;
  const first = await supabase
    .from("events")
    .select("id")
    .eq("series_id", data.id)
    .order("starts_at")
    .limit(1)
    .maybeSingle();
  if (first.error) throw first.error;
  return { seriesId: data.id, firstEventId: first.data?.id ?? null };
}

export async function setRsvp(eventId: string, status: RsvpStatus): Promise<RsvpRow | null> {
  const { data, error } = await supabase.rpc("set_rsvp", {
    p_event_id: eventId,
    p_status: status,
  });
  if (error) throw error;
  return data;
}

export async function acceptGuidelines(): Promise<string> {
  const { data, error } = await supabase.rpc("accept_guidelines");
  if (error) throw error;
  return data;
}

export async function checkIn(eventId: string): Promise<RsvpRow> {
  const { data, error } = await supabase.rpc("check_in", { p_event_id: eventId });
  if (error) throw error;
  return data;
}

export async function approveRsvp(
  eventId: string,
  userId: string,
  approved: boolean,
): Promise<RsvpRow> {
  const { data, error } = await supabase.rpc("approve_rsvp", {
    p_event_id: eventId,
    p_user_id: userId,
    p_approved: approved,
  });
  if (error) throw error;
  return data;
}

export async function removeRsvp(
  eventId: string,
  userId: string,
  reason: string,
): Promise<RsvpRow> {
  const trimmed = reason.trim();
  const { data, error } = await supabase.rpc("remove_rsvp", {
    p_event_id: eventId,
    p_user_id: userId,
    ...(trimmed ? { p_reason: trimmed } : {}),
  });
  if (error) throw error;
  return data;
}

/* ------------------------------------------------------------------ */
/* Queries                                                             */
/* ------------------------------------------------------------------ */

// `profiles` needs the FK hint: rsvps (event_id, user_id) is a junction table in PostgREST's
// eyes, so events <-> profiles has two candidate relationships and a bare `profiles(...)` answers
// HTTP 300 PGRST201. postgrest-js keeps the result key `profiles`.
const EVENT_SELECT =
  "*, hubs(id,slug,name,emoji,min_age,scope), profiles!events_host_id_fkey(id,handle,first_name,avatar_url), event_addresses(venue_id,location_text,address_note,venues(id,name,address_line1,address_line2,city,state,postal_code,is_public,place_id))" as const;

/** One event with its hub, host and (when RLS lets the viewer see it) the exact address. Null when unreadable. */
export const eventQuery = (eventId: string) =>
  queryOptions({
    queryKey: ["events", eventId] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("events")
        .select(EVENT_SELECT)
        .eq("id", eventId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

/** The resolved data of a queryOptions object (its queryFn is optional in the type). */
type QueryData<T extends { queryFn?: (...args: never[]) => unknown }> = Awaited<
  ReturnType<NonNullable<T["queryFn"]>>
>;

export type EventDetail = NonNullable<QueryData<ReturnType<typeof eventQuery>>>;

/** Live RSVP rows (going, interested, waitlisted) with names, for the avatar row and counts. */
export const eventRsvpsQuery = (eventId: string) =>
  queryOptions({
    queryKey: ["events", eventId, "rsvps"] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("rsvps")
        .select(
          "user_id,status,created_at,profiles!rsvps_user_id_fkey(handle,first_name,avatar_url)",
        )
        .eq("event_id", eventId)
        .neq("status", "cancelled")
        .order("created_at");
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

export type EventRsvp = QueryData<ReturnType<typeof eventRsvpsQuery>>[number];

/**
 * event_attendees(): the viewer's own row with the columns clients cannot select (waitlist
 * position, approval, check-in), and for the host, captains and moderators every live row.
 */
export const eventAttendeesQuery = (eventId: string) =>
  queryOptions({
    queryKey: ["events", eventId, "attendees"] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .rpc("event_attendees", { p_event_id: eventId })
        .select("*, profiles!rsvps_user_id_fkey(handle,first_name,avatar_url)");
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

export type Attendee = QueryData<ReturnType<typeof eventAttendeesQuery>>[number];

const FEED_SELECT =
  "id,title,cover_url,starts_at,ends_at,timezone,status,kind,capacity,waitlist_enabled,going_count,interested_count,location_hint,min_age,is_free,price_text,source_name,hub_id,host_id,series_id,hubs(id,slug,name,emoji)" as const;

/**
 * This week: published events in the viewer's hubs or verified campus, from six hours ago (so a
 * plan that is happening now still shows) to seven days out, minus anything already over.
 * Each event carries `rsvps`: the viewer's own row as `[{ status }]`, or `[]`. That comes from a
 * second request on the rsvps table, because a filter on an embedded resource is not supported
 * on an /rpc call: PostgREST pulls the filter column from the function result, events has no
 * user_id, and `rsvps(status)&rsvps.user_id=eq.` on feed_events is an HTTP 400.
 */
export const feedQuery = (userId: string) =>
  queryOptions({
    queryKey: ["feed", "this-week", userId] as const,
    queryFn: async () => {
      const now = new Date();
      const from = new Date(now.getTime() - 6 * 3_600_000).toISOString();
      const to = new Date(now.getTime() + 7 * 86_400_000).toISOString();
      const { data, error } = await supabase
        .rpc("feed_events", { p_from: from, p_to: to, p_limit: 100 })
        .select(FEED_SELECT);
      if (error) throw error;
      const events = data.filter((e) => !isOver(e.ends_at, now));
      if (events.length === 0) return [];
      const own = await supabase
        .from("rsvps")
        .select("event_id,status")
        .eq("user_id", userId)
        .in(
          "event_id",
          events.map((e) => e.id),
        );
      if (own.error) throw own.error;
      const byEvent = new Map(own.data.map((r) => [r.event_id, r.status]));
      return events.map((e) => {
        const status = byEvent.get(e.id);
        const rsvps: { status: RsvpStatus }[] = status ? [{ status }] : [];
        return { ...e, rsvps };
      });
    },
    staleTime: 60_000,
  });

export type FeedEvent = QueryData<ReturnType<typeof feedQuery>>[number];

/** The hubs the viewer can post in, with the fields the form needs (21+ hubs force the flag). */
export const myPostableHubsQuery = (userId: string) =>
  queryOptions({
    queryKey: ["my-hubs", userId, "postable"] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("hub_members")
        .select("hub_id,hubs(id,slug,name,emoji,min_age,scope,is_active)")
        .eq("user_id", userId)
        .order("joined_at");
      if (error) throw error;
      return data.flatMap((m) => (m.hubs && m.hubs.is_active ? [m.hubs] : []));
    },
    staleTime: 60_000,
  });

export type PostableHub = QueryData<ReturnType<typeof myPostableHubsQuery>>[number];

/* ------------------------------------------------------------------ */
/* Errors                                                              */
/* ------------------------------------------------------------------ */

/** The snake_case code (or constraint name) an event RPC raised; "" when the error has no message. */
export function eventErrorCode(err: unknown): string {
  const message =
    typeof err === "object" && err && "message" in err && typeof err.message === "string"
      ? err.message
      : err instanceof Error
        ? err.message
        : "";
  return message.trim();
}

export function isGuidelinesRequired(err: unknown): boolean {
  return eventErrorCode(err) === "guidelines_required";
}

const MESSAGES: Record<string, string> = {
  // session / account
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  profile_missing: "Your profile is missing. Sign in again.",
  forbidden: "Only the host can do that.",
  // posting
  title_required: "Give the plan a title.",
  title_length: "Titles are 3 to 120 characters.",
  description_too_long: "Descriptions are up to 2,000 characters.",
  invalid_time_range: "The end has to come after the start.",
  duration_too_long: "A plan can last up to three days.",
  starts_in_past: "Pick a start time in the future.",
  timezone_invalid: "That timezone isn't recognized.",
  min_headcount_above_capacity: "The minimum headcount can't be above the capacity.",
  capacity_below_going: "More people are already going than that capacity allows.",
  kind_not_allowed: "That kind of plan can't be posted from the app.",
  hub_not_found: "That hub doesn't exist anymore.",
  hub_inactive: "That hub is closed.",
  min_age_invalid: "Plans are 18+ or 21+.",
  hub_min_age: "Plans in this hub are 21+.",
  campus_min_age: "21+ plans can't be posted in the campus space.",
  age_restricted: "This plan is for people older than you.",
  invalid_chapter: "That chapter doesn't match the hub.",
  not_hub_member: "This plan is for hub members. Join the hub first.",
  chapter_not_found: "That chapter doesn't exist.",
  chapter_mismatch: "That chapter belongs to another hub or campus.",
  not_chapter_captain: "Only chapter captains can post as the chapter.",
  campus_required: "Pick a campus for a campus-only plan.",
  campus_not_found: "That campus doesn't exist.",
  not_campus_member: "Verify your campus email to post or RSVP in the campus space.",
  venue_not_found: "That place isn't available. Pick another one.",
  private_venue_requires_approval:
    "That place is a private address. Share it only with people you approve.",
  location_required: "Pick a place or describe where to meet.",
  too_many_events: "That's a lot of plans. You can post up to 10 an hour and 30 a day.",
  too_many_series: "You can start up to three weekly series a day.",
  weekday_invalid: "Pick a day of the week.",
  start_time_required: "Pick a start time.",
  duration_invalid: "Pick a length between 15 minutes and a day.",
  invalid_date_range: "The series has to end after it starts.",
  immutable_field: "That part of a plan can't be changed after posting.",
  event_not_found: "That plan doesn't exist, or you can't see it.",
  series_not_found: "That weekly series doesn't exist.",
  // RSVP
  invalid_status: "That RSVP isn't valid.",
  guidelines_required: "Accept the community guidelines first.",
  photo_required: "Add a profile photo first.",
  removed_by_host: "The host removed you from this plan.",
  event_cancelled: "This plan was cancelled.",
  event_over: "This plan is over.",
  event_full: "This plan is full.",
  not_chapter_member: "This plan is for chapter members.",
  check_in_window: "Check in from an hour before the start until six hours after the end.",
  not_going: "Only people who are going can do that.",
  rsvp_not_found: "That person isn't on the list.",
  cannot_remove_host: "The host can't be removed.",
  // venues
  name_required: "Give the place a name.",
  name_length: "Place names are up to 120 characters.",
  country_invalid: "Use a two-letter country code.",
  invalid_coordinates: "That location couldn't be placed on the map.",
  too_many_venues: "You've added a lot of places today. Try again tomorrow.",
  // table constraints that can slip past the explicit checks
  events_cover_url_format: "Cover images need an https link.",
  events_external_url_format: "Links need to start with https://.",
  events_price_text_length: "Keep the price under 40 characters.",
  events_location_hint_length: "Keep the location hint under 120 characters.",
  event_addresses_location_text_length: "Keep the meeting spot under 200 characters.",
  event_addresses_address_note_length: "Keep the address note under 200 characters.",
  event_series_price_text_length: "Keep the price under 40 characters.",
  event_series_location_text_length: "Keep the meeting spot under 200 characters.",
  event_series_max_occurrences_range: "A series runs for 1 to 104 weeks.",
  venues_address_line1_length: "Keep the address under 200 characters.",
  venues_city_length: "Keep the city under 80 characters.",
  venues_postal_code_length: "Keep the postal code under 20 characters.",
};

/** A sentence for any error an event, RSVP or venue RPC raises. */
export function eventErrorMessage(err: unknown): string {
  const code = eventErrorCode(err);
  const known = MESSAGES[code];
  if (known) return known;
  if (/invalid input syntax|22P02/.test(code))
    return "Something in the form isn't valid. Check it and try again.";
  if (/Failed to fetch|NetworkError|Load failed/i.test(code))
    return "Couldn't reach the server. Check your connection and try again.";
  if (/^[a-z0-9_]+$/.test(code)) return `Couldn't do that (${code.replace(/_/g, " ")}).`;
  return code || "Something went wrong. Try again.";
}

/** The form field an error belongs to, when it is about one field; otherwise null (show it at the top). */
export function fieldForEventError(code: string): EventFormField | null {
  switch (code) {
    case "title_required":
    case "title_length":
      return "title";
    case "description_too_long":
      return "description";
    case "invalid_time_range":
    case "duration_too_long":
    case "starts_in_past":
    case "weekday_invalid":
    case "start_time_required":
    case "duration_invalid":
    case "invalid_date_range":
      return "startsAt";
    case "min_headcount_above_capacity":
      return "minHeadcount";
    case "capacity_below_going":
      return "capacity";
    case "hub_not_found":
    case "hub_inactive":
    case "not_hub_member":
      return "hubId";
    case "hub_min_age":
    case "campus_min_age":
    case "min_age_invalid":
      return "is21";
    case "campus_required":
    case "campus_not_found":
    case "not_campus_member":
      return "campusOnly";
    case "venue_not_found":
    case "private_venue_requires_approval":
    case "location_required":
    case "event_addresses_location_text_length":
    case "event_series_location_text_length":
      return "locationText";
    case "events_price_text_length":
    case "event_series_price_text_length":
      return "priceText";
    case "events_external_url_format":
      return "externalUrl";
    default:
      return null;
  }
}

/** Field names of the post/edit form (components/events/event-form-schema.ts). */
export type EventFormField =
  | "hubId"
  | "title"
  | "description"
  | "startsAt"
  | "minHeadcount"
  | "capacity"
  | "is21"
  | "campusOnly"
  | "locationText"
  | "priceText"
  | "externalUrl";
