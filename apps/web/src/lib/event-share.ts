import { cache } from "react";
import { z } from "zod";
import type { CalendarEvent } from "@ap/core/calendar";

import { APP_URL, siteUrl } from "./site";
import { createAnonServerClient } from "./supabase-server";

/**
 * The public event card behind /e/[id], its OG image and its .ics file. Everything comes from
 * public.event_share_card(uuid): the card for published, public, 18+ events (members-only ones
 * included; joining is what needs the membership), a stub for published campus or 21+ events,
 * and null for anything else or when the host's account is not active. Never the address or the
 * attendee list.
 */
const shareCardSchema = z.object({
  id: z.string(),
  kind: z.enum(["member", "chapter", "imported"]),
  title: z.string(),
  description: z.string().nullable(),
  cover_url: z.string().nullable(),
  starts_at: z.string(),
  ends_at: z.string(),
  timezone: z.string(),
  min_age: z.number(),
  capacity: z.number().nullable(),
  min_headcount: z.number().nullable(),
  is_free: z.boolean(),
  price_text: z.string().nullable(),
  location_hint: z.string().nullable(),
  going_count: z.number(),
  interested_count: z.number(),
  external_url: z.string().nullable(),
  source_name: z.string().nullable(),
  /** Migration 74: the listing source's attribution (open-data licence lines); older servers omit it. */
  source_attribution: z.string().nullable().optional(),
  series_id: z.string().nullable(),
  hub: z.object({
    id: z.string(),
    slug: z.string(),
    name: z.string(),
    emoji: z.string().nullable(),
  }),
  chapter: z.object({ id: z.string(), slug: z.string(), name: z.string() }).nullable(),
  host: z
    .object({ handle: z.string(), first_name: z.string(), avatar_url: z.string().nullable() })
    .nullable(),
});

/** A campus or 21+ plan: only that it exists, why it is closed, and its hub. */
const restrictedStubSchema = z.object({
  id: z.string(),
  restricted: z.enum(["campus", "age"]),
  hub_name: z.string(),
});

const shareResultSchema = z.union([restrictedStubSchema, shareCardSchema]);

export type EventShareCard = z.infer<typeof shareCardSchema>;
export type EventShareStub = z.infer<typeof restrictedStubSchema>;
export type EventShareResult = z.infer<typeof shareResultSchema>;

export function isRestricted(result: EventShareResult): result is EventShareStub {
  return "restricted" in result;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID.test(value);
}

/**
 * The card or the stub, or null when there is nothing to show (unknown id, not a uuid,
 * cancelled, host not active). Wrapped in React's cache so generateMetadata, the page and the OG
 * image share one database call per request. A database error throws, so an outage is a 500,
 * not a 404.
 */
export const getEventShare = cache(async (id: string): Promise<EventShareResult | null> => {
  if (!isUuid(id)) return null;
  const supabase = createAnonServerClient();
  const { data, error } = await supabase.rpc("event_share_card", { p_event_id: id });
  if (error) throw new Error(`event_share_card failed: ${error.message}`);
  if (data === null || data === undefined) return null;
  const parsed = shareResultSchema.safeParse(data);
  if (!parsed.success) {
    console.error("event_share_card returned an unexpected shape", parsed.error.issues);
    return null;
  }
  return parsed.data;
});

/** The full card only: the .ics route and anything that needs times and places. */
export async function getEventShareCard(id: string): Promise<EventShareCard | null> {
  const result = await getEventShare(id);
  return result && !isRestricted(result) ? result : null;
}

export function appEventUrl(id: string): string {
  return `${APP_URL}/events/${id}`;
}

export function shareUrl(id: string): string {
  return `${siteUrl()}/e/${id}`;
}

/**
 * The card as a calendar entry for the .ics file and the Google Calendar link. LOCATION is the
 * coarse location hint only, never the address (D-027).
 */
export function calendarEvent(card: EventShareCard): CalendarEvent {
  const url = shareUrl(card.id);
  const about = excerpt(card.description, 600);
  return {
    id: card.id,
    title: card.title,
    startsAt: card.starts_at,
    endsAt: card.ends_at,
    location: card.location_hint,
    description: [about, `Open in Activity Planet: ${url}`].filter(Boolean).join("\n\n"),
    url,
  };
}

/** Seats left, or null when the plan has no capacity. */
export function spotsLeft(card: Pick<EventShareCard, "capacity" | "going_count">): number | null {
  return card.capacity === null ? null : Math.max(0, card.capacity - card.going_count);
}

/** Whitespace-collapsed, cut at a word boundary, with an ellipsis when something was dropped. */
export function excerpt(text: string | null, max = 300): string | null {
  if (!text) return null;
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return null;
  if (clean.length <= max) return clean;
  const head = clean.slice(0, max + 1);
  const space = head.lastIndexOf(" ");
  const cut = space > max * 0.6 ? head.slice(0, space) : head.slice(0, max);
  return `${cut.replace(/[\s,;:.\-–—]+$/, "")}…`;
}
