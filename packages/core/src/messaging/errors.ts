/**
 * Messaging error codes (the exception message of every chat RPC, migration 58) and what the app
 * says about them. Neutral, for everyone (D-040): a block reads exactly like a closed or deleted
 * account, and a declined request is never named.
 */

export interface ChatError {
  code: string;
  /** Seconds to wait, from the exception hint (rate_limited, slow_mode). */
  waitSeconds: number | null;
}

/** The code and hint of a PostgREST error (or a send_message `{error}` answer), else "". */
export function chatError(err: unknown): ChatError {
  if (typeof err !== "object" || err === null) return { code: "", waitSeconds: null };
  const e = err as { message?: unknown; hint?: unknown; error?: unknown };
  const raw =
    typeof e.message === "string" ? e.message.trim() : typeof e.error === "string" ? e.error : "";
  const code = /^[a-z0-9_]+$/.test(raw) ? raw : "";
  const hint = typeof e.hint === "string" ? Number.parseInt(e.hint, 10) : Number.NaN;
  return { code, waitSeconds: Number.isFinite(hint) && hint > 0 ? hint : null };
}

/** A failure to reach the server (worth retrying with the same client id), not a rule. */
export function isNetworkError(err: unknown): boolean {
  if (typeof err !== "object" || err === null) return false;
  const e = err as { message?: unknown; name?: unknown; code?: unknown; status?: unknown };
  const m = typeof e.message === "string" ? e.message : "";
  if (/Failed to fetch|NetworkError|Load failed|network|timed? ?out|ECONN|fetch failed/i.test(m))
    return true;
  if (e.name === "TypeError" && m === "") return true;
  // Gateway errors from the API: the request may not have run.
  return typeof e.status === "number" && (e.status === 0 || e.status >= 502);
}

function wait(seconds: number | null): string {
  if (!seconds) return "a moment";
  if (seconds < 60) return seconds === 1 ? "a second" : `${seconds} seconds`;
  const mins = Math.ceil(seconds / 60);
  if (mins < 60) return mins === 1 ? "a minute" : `${mins} minutes`;
  const hours = Math.ceil(mins / 60);
  return hours === 1 ? "an hour" : `${hours} hours`;
}

const COPY: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  onboarding_required: "Finish setting up your profile first.",
  photo_required: "Add a profile photo to send messages. It helps people know who they're meeting.",
  account_too_new:
    "New accounts can message people they share a plan, hub or chapter with. Message requests, links, photos and hub chats open 24 hours after you join.",
  rate_limited: "You're sending a lot. Wait {wait}, then try again.",
  slow_mode: "This hub chat has slow mode on. You can send again in {wait}.",
  request_pending: "Your request is waiting. You can send more once they accept.",
  request_cooldown: "You can't send them another request right now.",
  request_text_only: "Message requests are text only.",
  link_not_allowed:
    "Links can't be sent here. They aren't allowed in message requests, from accounts under a day old, or through link shorteners.",
  message_filtered: "This message can't be sent. It may break the Community Guidelines.",
  body_length: "Messages are 1 to 2,000 characters.",
  conversation_closed: "You can't send messages in this conversation.",
  read_only: "This chat is read-only now.",
  images_disabled: "Photos in chats are coming soon.",
  image_invalid: "That photo couldn't be sent. Try another.",
  image_blocked: "That photo can't be sent.",
  user_not_found: "We couldn't find that person.",
  cannot_message_self: "That's you.",
  chat_unavailable: "This chat isn't available.",
  forbidden: "You're not in this chat.",
  not_found: "This conversation isn't available.",
  too_many_members: "Groups are up to 50 people.",
  too_few_members: "A group needs at least two other people you share a plan, hub or chapter with.",
  invalid_title: "Give the group a name of 1 to 60 characters.",
  client_id_required: "Couldn't send that. Try again.",
};

/** One sentence for an error code; {wait} is filled from the hint. */
export function chatErrorMessage(err: unknown): string {
  const { code, waitSeconds } = chatError(err);
  const copy = COPY[code];
  if (copy) return copy.replace("{wait}", wait(waitSeconds));
  if (isNetworkError(err)) return "Couldn't reach the server. Check your connection and try again.";
  return "Something went wrong. Try again.";
}

/** The composer's line for a can_post code (conversation_info), or null when posting is open. */
export function composerNotice(canPost: string | null | undefined): string | null {
  if (!canPost) return null;
  return COPY[canPost] ?? "You can't send messages here right now.";
}

/** Codes that are about the sender's own account, with a way to fix it in the app. */
export function gateAction(code: string | null | undefined): "photo" | null {
  return code === "photo_required" ? "photo" : null;
}
