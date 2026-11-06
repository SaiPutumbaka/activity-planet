/**
 * Coaching error codes (the exception message of every coaching RPC, migration 60) and what the
 * app says about them. A block reads like "not available", never as a block (design section 2).
 */

import { MAX_RADIUS_KM } from "../feed";
import { formatKmRange, viewerPrefs, type DistanceUnit } from "../locale";

/** The code of a PostgREST error, else "". */
export function coachingErrorCode(err: unknown): string {
  if (typeof err !== "object" || err === null) return "";
  const m = (err as { message?: unknown }).message;
  const raw = typeof m === "string" ? m.trim() : "";
  return /^[a-z0-9_]+$/.test(raw) ? raw : "";
}

/**
 * The error an Edge Function call should throw. supabase-js reports a non-2xx answer as
 * "Edge Function returned a non-2xx status code" and keeps the response in `context`; the
 * coaching functions answer {error: "<code>"}, so the code becomes the message (and reaches
 * coachingErrorCode). Anything else is returned as it came.
 */
export async function edgeFunctionError(error: unknown): Promise<Error> {
  const context =
    typeof error === "object" && error !== null ? (error as { context?: unknown }).context : null;
  if (
    typeof context === "object" &&
    context !== null &&
    typeof (context as { clone?: unknown }).clone === "function"
  ) {
    try {
      const body: unknown = await (context as Response).clone().json();
      const code =
        typeof body === "object" && body !== null ? (body as { error?: unknown }).error : null;
      if (typeof code === "string" && /^[a-z0-9_]+$/.test(code)) return new Error(code);
    } catch {
      /* not JSON */
    }
  }
  return error instanceof Error ? error : new Error(String(error));
}

const COPY: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  forbidden: "Your account can't do this right now.",
  photo_required: "Add a profile photo first. It helps people know who they're meeting.",
  account_too_new: "New accounts can coach and book 24 hours after they join.",
  guidelines_required: "Agree to the Community Guidelines first.",
  coach_terms_required: "Accept the current Coach Terms to publish.",
  policy_ack_required: "Read and accept the Refund and Cancellation Policy to send a request.",
  coach_profile_required: "Set up your coach profile first.",
  unknown_version: "The terms changed. Reload and try again.",
  incomplete_profile:
    "Add a headline, at least one active listing and your weekly availability (or a group session) before publishing.",
  timezone_invalid: "Pick a valid time zone.",
  invalid_text: "Some of that text can't be saved. Check the lengths and wording.",
  invalid_listing: "Check the listing details and try again.",
  invalid_shape:
    "Online group sessions aren't offered yet. Group sessions are in person, for 2 to 50 people.",
  delivery_not_offered: "Turn on that way of coaching in your coach profile first.",
  hub_not_allowed: "That hub can't be used for coaching.",
  invalid_price: "Enter a price of 0 or more and a three-letter currency code.",
  invalid_link: "Call links start with https://.",
  too_many: "You've reached the limit for this.",
  invalid_rule: "Each window needs a day and an end time after its start, on the same day.",
  invalid_range: "Pick an end time after the start (at most 31 days apart).",
  range_too_long: "Pick up to 31 days at a time.",
  not_group: "That only works for group listings.",
  not_found: "This isn't available.",
  cannot_book_self: "You can't book your own listing.",
  invalid_request: "Pick a time and try again.",
  rate_limited: "You've sent a lot of requests today. Try again tomorrow.",
  too_many_open:
    "You have several requests waiting. Wait for answers (one open request per listing, five in all).",
  slot_unavailable: "That time isn't available any more. Pick another.",
  full: "That session is full.",
  client_overlap: "You already have a booking at that time.",
  invalid_state: "That can't be done now. Refresh to see the latest.",
  slot_taken: "That time was just taken.",
  expired: "This request expired.",
  too_early: "That can be done once the session has started or ended.",
  too_late: "It's too late for that now.",
  not_completed: "Reviews open once the session is completed.",
  review_window_closed: "Reviews close 30 days after the session.",
  review_filtered: "That review can't be posted. Links and some words aren't allowed.",
  already_reviewed: "Your review can no longer be edited.",
  invalid_rating: "Pick 1 to 5 stars.",
  reply_locked: "Replies can be edited for 7 days.",
  invalid_scope: "Something went wrong. Try again.",
  invalid_cursor: "Something went wrong. Try again.",
  invalid_coordinates: "We couldn't use that location.",
  invalid_photo: "That photo couldn't be used. Upload it again.",
  image_blocked: "That photo can't be used.",
  payments_off: "In-app payments aren't available right now.",
  not_payable:
    "This booking can't be paid in the app now. The payment deadline may have passed. Refresh to see the latest.",
  not_a_coach: "Set up your coach profile first.",
  no_account: "Set up payouts first.",
  invalid_country: "Enter the two-letter code of the country you coach in.",
  stripe_error: "Stripe didn't answer. Try again in a minute.",
  listing_unavailable: "This listing isn't taking bookings right now.",
};

/**
 * What the app says about a coaching error. Copy with a distance uses the viewer's unit (the
 * browser's locale by default; packages/core/src/locale).
 */
export function coachingErrorMessage(
  err: unknown,
  unit: DistanceUnit = viewerPrefs().unit,
): string {
  const code = coachingErrorCode(err);
  if (code === "invalid_area")
    return `Pick where you coach in person (a point and a radius of ${formatKmRange(1, MAX_RADIUS_KM, unit)}), or coach online.`;
  const copy = COPY[code];
  if (copy) return copy;
  const m =
    typeof err === "object" && err && typeof (err as { message?: unknown }).message === "string"
      ? (err as { message: string }).message
      : "";
  if (/Failed to fetch|NetworkError|Load failed/i.test(m))
    return "Check your connection and try again.";
  return "Something went wrong. Try again.";
}

/** Codes that mean the viewer must fix their own profile first (photo, guidelines, age). */
export function isMemberGate(err: unknown): boolean {
  return [
    "photo_required",
    "account_too_new",
    "guidelines_required",
    "onboarding_required",
  ].includes(coachingErrorCode(err));
}
