/**
 * The public request to remove non-consensual intimate imagery (migration 52, Take It Down Act).
 * The same rules submit_takedown_request applies in the database, mirrored so the form on the
 * site can say what is wrong before it sends, plus the plain-language messages for every error
 * code the database or the site's /api/takedown route can return.
 *
 *   parseTakedownRequest({...}) -> { ok: true, value } | { ok: false, error: "invalid_email" }
 *   takedownRpcArgs(value)      -> the submit_takedown_request arguments
 */
import { z } from "zod";

export const TAKEDOWN_LIMITS = {
  name: 200,
  email: 254,
  locations: 4000,
  description: 2000,
  signature: 200,
} as const;

export type TakedownError =
  | "name_required"
  | "invalid_email"
  | "invalid_relationship"
  | "location_required"
  | "too_long"
  | "good_faith_required"
  | "signature_required"
  | "rate_limited"
  | "bad_request"
  | "unavailable";

export interface TakedownRequest {
  name: string;
  email: string;
  relationship: "self" | "authorized";
  locations: string;
  description: string;
  goodFaith: true;
  signature: string;
  involvesMinor: boolean;
}

const EMAIL = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

const raw = z.object({
  name: z.string().catch(""),
  email: z.string().catch(""),
  relationship: z.string().catch(""),
  locations: z.string().catch(""),
  description: z.string().catch(""),
  goodFaith: z.boolean().catch(false),
  signature: z.string().catch(""),
  involvesMinor: z.boolean().catch(false),
});

export function parseTakedownRequest(
  input: unknown,
): { ok: true; value: TakedownRequest } | { ok: false; error: TakedownError } {
  if (!input || typeof input !== "object") return { ok: false, error: "bad_request" };
  const r = raw.parse(input);
  const name = r.name.trim();
  const email = r.email.trim().toLowerCase();
  const locations = r.locations.trim();
  const description = r.description.trim();
  const signature = r.signature.trim();
  if (name.length < 2) return { ok: false, error: "name_required" };
  if (name.length > TAKEDOWN_LIMITS.name) return { ok: false, error: "too_long" };
  if (email.length > TAKEDOWN_LIMITS.email || !EMAIL.test(email)) {
    return { ok: false, error: "invalid_email" };
  }
  if (r.relationship !== "self" && r.relationship !== "authorized") {
    return { ok: false, error: "invalid_relationship" };
  }
  if (locations.length < 3) return { ok: false, error: "location_required" };
  if (
    locations.length > TAKEDOWN_LIMITS.locations ||
    description.length > TAKEDOWN_LIMITS.description
  ) {
    return { ok: false, error: "too_long" };
  }
  if (!r.goodFaith) return { ok: false, error: "good_faith_required" };
  if (signature.length < 2 || signature.length > TAKEDOWN_LIMITS.signature) {
    return { ok: false, error: "signature_required" };
  }
  return {
    ok: true,
    value: {
      name,
      email,
      relationship: r.relationship,
      locations,
      description,
      goodFaith: true,
      signature,
      involvesMinor: r.involvesMinor,
    },
  };
}

/** The submit_takedown_request arguments for a parsed request. */
export function takedownRpcArgs(v: TakedownRequest) {
  return {
    p_name: v.name,
    p_email: v.email,
    p_relationship: v.relationship,
    p_locations: v.locations,
    p_good_faith: v.goodFaith,
    p_signature: v.signature,
    p_description: v.description,
    p_involves_minor: v.involvesMinor,
  };
}

const MESSAGES: Record<TakedownError, string> = {
  name_required: "Enter your full name.",
  invalid_email: "Enter an email address we can reach you at.",
  invalid_relationship:
    "Say whether you are the person shown or are acting for them with their permission.",
  location_required:
    "Tell us where the image is: a link, a profile name or handle, or a short description.",
  too_long: "One of the fields is too long. Please shorten it.",
  good_faith_required: "Tick the statement to confirm the image was shared without consent.",
  signature_required: "Type your full name as your signature.",
  rate_limited:
    "We have already received several requests from this address today. We will reply to those; you can also email us.",
  bad_request: "Something in the form did not come through. Please try again.",
  unavailable: "We could not send your request just now. Please try again, or email us.",
};

/** Plain-language message for an error code; unknown codes read as unavailable. */
export function takedownErrorMessage(code: string): string {
  return MESSAGES[code as TakedownError] ?? MESSAGES.unavailable;
}

/** Maps a database error message (the exception text) to a known code. */
export function takedownErrorCode(message: string | null | undefined): TakedownError {
  const m = (message ?? "").trim();
  return m in MESSAGES && m !== "unavailable" ? (m as TakedownError) : "unavailable";
}
