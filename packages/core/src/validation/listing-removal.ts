/**
 * The public request to take an imported listing (or its whole source) off Activity Planet
 * (migration 62, submit_listing_removal; COLLECTOR_COMPLETION 2.1). The same rules the database
 * applies, mirrored so the form on the site's /bot/remove page can say what is wrong before it
 * sends, plus plain-language messages for every error code the database or the site's
 * /api/listing-removal route can return.
 *
 *   parseListingRemoval({...}) -> { ok: true, value } | { ok: false, error: "invalid_email" }
 *   listingRemovalRpcArgs(value) -> the submit_listing_removal arguments
 *   listingFromInput("https://app.example/events/<uuid>") -> { eventId: "<uuid>", url: null }
 */
import { z } from "zod";

export const LISTING_REMOVAL_LIMITS = {
  name: 200,
  email: 254,
  listing: 2000,
  reason: 2000,
} as const;

export const LISTING_RELATIONSHIPS = ["organizer", "venue", "rights_holder", "other"] as const;
export type ListingRelationship = (typeof LISTING_RELATIONSHIPS)[number];

export const LISTING_RELATIONSHIP_LABELS: Record<ListingRelationship, string> = {
  organizer: "I organize the event or run the calendar",
  venue: "I work for the venue",
  rights_holder: "I hold rights in the text or images",
  other: "Something else",
};

export type ListingRemovalError =
  | "name_required"
  | "invalid_email"
  | "invalid_relationship"
  | "invalid_scope"
  | "too_long"
  | "invalid_url"
  | "listing_required"
  | "not_imported"
  | "rate_limited"
  | "verification_failed"
  | "bad_request"
  | "unavailable";

export interface ListingRemovalRequest {
  eventId: string | null;
  url: string | null;
  scope: "item" | "source";
  name: string;
  email: string;
  relationship: ListingRelationship;
  reason: string;
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID_IN_PATH =
  /\/(?:events|e)\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(?:[/?#]|$)/i;

/** True for a canonical event id. */
export function isEventId(value: string | null | undefined): value is string {
  return typeof value === "string" && UUID.test(value.trim());
}

/**
 * What the "listing" field holds: an event id, an Activity Planet link to one (/events/<id> in
 * the app, /e/<id> on the site), or the https link of the listing or source page elsewhere.
 */
export function listingFromInput(input: string): {
  eventId: string | null;
  url: string | null;
} {
  const t = input.trim();
  if (t === "") return { eventId: null, url: null };
  if (UUID.test(t)) return { eventId: t.toLowerCase(), url: null };
  const inPath = UUID_IN_PATH.exec(t);
  if (inPath && /^https?:\/\//i.test(t)) return { eventId: inPath[1]!.toLowerCase(), url: null };
  return { eventId: null, url: t };
}

const raw = z.object({
  eventId: z.string().nullable().catch(null),
  listing: z.string().catch(""),
  scope: z.string().catch("item"),
  name: z.string().catch(""),
  email: z.string().catch(""),
  relationship: z.string().catch(""),
  reason: z.string().catch(""),
});

export function parseListingRemoval(
  input: unknown,
): { ok: true; value: ListingRemovalRequest } | { ok: false; error: ListingRemovalError } {
  if (!input || typeof input !== "object") return { ok: false, error: "bad_request" };
  const r = raw.parse(input);
  const name = r.name.trim();
  const email = r.email.trim().toLowerCase();
  const reason = r.reason.trim();
  const scope =
    r.scope === "source" ? "source" : r.scope === "item" || r.scope === "" ? "item" : null;
  if (name.length < 2) return { ok: false, error: "name_required" };
  if (name.length > LISTING_REMOVAL_LIMITS.name) return { ok: false, error: "too_long" };
  if (email.length > LISTING_REMOVAL_LIMITS.email || !EMAIL.test(email)) {
    return { ok: false, error: "invalid_email" };
  }
  if (!(LISTING_RELATIONSHIPS as readonly string[]).includes(r.relationship)) {
    return { ok: false, error: "invalid_relationship" };
  }
  if (!scope) return { ok: false, error: "invalid_scope" };
  if (reason.length > LISTING_REMOVAL_LIMITS.reason) return { ok: false, error: "too_long" };

  const fromField = listingFromInput(r.listing);
  const eventId = isEventId(r.eventId) ? r.eventId.trim().toLowerCase() : fromField.eventId;
  const url = fromField.eventId ? null : fromField.url;
  if (url !== null) {
    if (url.length > LISTING_REMOVAL_LIMITS.listing) return { ok: false, error: "too_long" };
    if (!/^https:\/\/[^\s]+$/i.test(url) || /[\s\p{Cc}]/u.test(url)) {
      return { ok: false, error: "invalid_url" };
    }
  }
  if (!eventId && !url) return { ok: false, error: "listing_required" };
  return {
    ok: true,
    value: {
      eventId,
      url,
      scope,
      name,
      email,
      relationship: r.relationship as ListingRelationship,
      reason,
    },
  };
}

/** The submit_listing_removal arguments for a parsed request (p_client_hash is the route's). */
export function listingRemovalRpcArgs(v: ListingRemovalRequest) {
  return {
    p_event: v.eventId as string,
    p_url: v.url as string,
    p_scope: v.scope,
    p_name: v.name,
    p_email: v.email,
    p_relationship: v.relationship,
    p_reason: v.reason,
  };
}

const MESSAGES: Record<ListingRemovalError, string> = {
  name_required: "Enter your name.",
  invalid_email: "Enter an email address we can reach you at.",
  invalid_relationship: "Say how you are connected to the listing.",
  invalid_scope: "Choose whether to remove this listing or everything from its source.",
  too_long: "One of the fields is too long. Please shorten it.",
  invalid_url: "Paste the full link, starting with https://.",
  listing_required:
    "Tell us which listing: paste its Activity Planet link, or the link of the page it came from.",
  not_imported:
    "That is a plan a member posted, not a listing we collected. Use Report on its page instead.",
  rate_limited:
    "We have already received several requests from you today. We will reply to those; you can also email us.",
  verification_failed:
    "We could not confirm the form was sent by a person. Reload the page and try again, or email us.",
  bad_request: "Something in the form did not come through. Please try again.",
  unavailable: "We could not send your request just now. Please try again, or email us.",
};

/** Plain-language message for an error code; unknown codes read as unavailable. */
export function listingRemovalErrorMessage(code: string): string {
  return MESSAGES[code as ListingRemovalError] ?? MESSAGES.unavailable;
}

/** Maps a database error message (the exception text) to a known code. */
export function listingRemovalErrorCode(message: string | null | undefined): ListingRemovalError {
  const m = (message ?? "").trim();
  return m in MESSAGES && m !== "unavailable" ? (m as ListingRemovalError) : "unavailable";
}
