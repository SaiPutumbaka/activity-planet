import { cache } from "react";
import { z } from "zod";

import { createAnonServerClient } from "./supabase-server";

/**
 * The public event card behind /e/[id], its OG image and its .ics file. Everything comes from
 * public.event_share_card(uuid), which returns the card for published, public, 18+ events and
 * null for anything else, and never the address or the attendee list.
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

export type EventShareCard = z.infer<typeof shareCardSchema>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export function isUuid(value: string): boolean {
  return UUID.test(value);
}

/**
 * The card, or null when there is nothing public to show (unknown id, not a uuid, cancelled,
 * members-only, campus-only, 21+). Wrapped in React's cache so generateMetadata and the page
 * share one database call per request. A database error throws, so an outage is a 500, not a 404.
 */
export const getEventShareCard = cache(async (id: string): Promise<EventShareCard | null> => {
  if (!isUuid(id)) return null;
  const supabase = createAnonServerClient();
  const { data, error } = await supabase.rpc("event_share_card", { p_event_id: id });
  if (error) throw new Error(`event_share_card failed: ${error.message}`);
  if (data === null || data === undefined) return null;
  const parsed = shareCardSchema.safeParse(data);
  if (!parsed.success) {
    console.error("event_share_card returned an unexpected shape", parsed.error.issues);
    return null;
  }
  return parsed.data;
});

/** Where the product app is served; the primary call to action deep-links into it. */
export const APP_URL = (process.env.NEXT_PUBLIC_APP_URL ?? "http://localhost:3001").replace(
  /\/$/,
  "",
);

/** This site's origin, for absolute share and calendar URLs. */
export function siteUrl(): string {
  const explicit = process.env.NEXT_PUBLIC_SITE_URL;
  if (explicit) return explicit.replace(/\/$/, "");
  const vercel = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  if (vercel) return `https://${vercel}`;
  return "http://localhost:3000";
}

export function appEventUrl(id: string): string {
  return `${APP_URL}/events/${id}`;
}

export function shareUrl(id: string): string {
  return `${siteUrl()}/e/${id}`;
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
