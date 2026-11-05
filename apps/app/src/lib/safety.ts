import { queryOptions } from "@tanstack/react-query";

import { reportPlace } from "./place-contributions";
import { supabase } from "./supabase";

/**
 * Blocks, mutes and reports (migration 51; PLAN 4.6 and 4.11). Every rule lives in the database;
 * this module shapes the calls and turns error codes into sentences. Places keep their own
 * reasons and go through reportPlace (place-contributions.ts).
 *
 *   await blockUser(userId)          // { blocked, already, shared_upcoming }
 *   await muteUser(userId)
 *   await reportContent("event", id, "scam", note)
 *   useQuery(myBlocksQuery(userId))
 *   useQuery(eventBlockWarningQuery(eventId, userId))   // >0: someone you blocked is on this plan
 *   useQuery(myMutesQuery(userId))   // ids the viewer muted (mutes RLS: own rows only)
 *   attendeeName(row.profiles, row.user_id, blockedIds)   // "Blocked member" for a host's row
 */

export type ReportKind =
  | "profile"
  | "event"
  | "chapter"
  | "hub"
  | "message"
  | "coach_listing"
  | "coach_review"
  | "coach_review_reply"
  | "booking";

export const REPORT_REASONS = [
  "harassment",
  "hate",
  "sexual_content",
  "violence",
  "spam",
  "scam",
  "impersonation",
  "underage",
  "unsafe",
  "ncii",
  "child_safety",
  "other",
] as const;
/** Booking reports also take these (migration 60): a missed session or a payment problem. */
export const BOOKING_REPORT_REASONS = ["no_show", "payment"] as const;
export type ReportReason =
  (typeof REPORT_REASONS)[number] | (typeof BOOKING_REPORT_REASONS)[number];

/** Labels for the report sheet. Everyone-first wording (D-035, D-040). */
export const REPORT_REASON_LABELS: Record<ReportReason, string> = {
  harassment: "Harassment or bullying",
  hate: "Hate or discrimination",
  sexual_content: "Sexual content",
  violence: "Violence or threats",
  spam: "Spam",
  scam: "Scam or fraud",
  impersonation: "Pretending to be someone else",
  underage: "Someone under 18",
  unsafe: "Unsafe meetup or place",
  ncii: "Intimate image shared without consent",
  child_safety: "Child safety",
  other: "Something else",
  no_show: "A missed session",
  payment: "A payment problem",
};

export interface BlockResult {
  blocked: boolean;
  already: boolean;
  /** Upcoming plans both people are on; show "you're both going to N plans" when > 0. */
  shared_upcoming: number;
}

export interface ReportResult {
  id: string;
  already: boolean;
  /** True only when this report hid the item (migration 54); never the item's state. */
  hidden: boolean;
}

export interface BlockedPerson {
  user_id: string;
  handle: string;
  first_name: string;
  avatar_url: string | null;
  blocked_at: string;
}

/** The server's error code (the exception message), or "". */
export function safetyErrorCode(err: unknown): string {
  const m =
    typeof err === "object" &&
    err !== null &&
    typeof (err as { message?: unknown }).message === "string"
      ? (err as { message: string }).message.trim()
      : "";
  return /^[a-z0-9_]+$/.test(m) ? m : "";
}

const MESSAGES: Record<string, string> = {
  not_authenticated: "Sign in again to continue.",
  onboarding_required: "Finish setting up your profile first.",
  cannot_block_self: "You can't block yourself.",
  cannot_mute_self: "You can't mute yourself.",
  user_not_found: "We couldn't find that person.",
  too_many_blocks: "You've reached the block limit.",
  too_many_mutes: "You've reached the mute limit.",
  invalid_reason: "Pick a reason for the report.",
  invalid_kind: "That can't be reported.",
  target_not_found: "We couldn't find what you're reporting.",
  own_item: "You can't report your own profile, plan, chapter or message.",
  rate_limited: "You've sent a lot of reports today. Try again tomorrow.",
};

export function safetyErrorMessage(err: unknown): string {
  return MESSAGES[safetyErrorCode(err)] ?? "Something went wrong. Try again.";
}

export async function blockUser(userId: string): Promise<BlockResult> {
  const { data, error } = await supabase.rpc("block_user", { p_user: userId });
  if (error) throw error;
  return data as unknown as BlockResult;
}

export async function unblockUser(userId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc("unblock_user", { p_user: userId });
  if (error) throw error;
  return Boolean((data as { unblocked?: boolean } | null)?.unblocked);
}

export async function muteUser(userId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc("mute_user", { p_user: userId });
  if (error) throw error;
  return Boolean((data as { muted?: boolean } | null)?.muted);
}

export async function unmuteUser(userId: string): Promise<boolean> {
  const { data, error } = await supabase.rpc("unmute_user", { p_user: userId });
  if (error) throw error;
  return Boolean((data as { unmuted?: boolean } | null)?.unmuted);
}

/** Report a profile, plan, chapter, hub or chat message (migration 58). Notes are trimmed to 1000 characters by the server. */
export async function reportContent(
  kind: ReportKind,
  id: string,
  reason: ReportReason,
  note?: string,
): Promise<ReportResult> {
  const trimmed = note?.trim();
  const { data, error } = await supabase.rpc("report_content", {
    p_kind: kind,
    p_id: id,
    p_reason: reason,
    ...(trimmed ? { p_note: trimmed } : {}),
  });
  if (error) throw error;
  return data as unknown as ReportResult;
}

export { reportPlace };

export const safetyKeys = {
  blocks: (userId: string) => ["safety", "blocks", userId] as const,
  warning: (eventId: string, userId: string) => ["safety", "warning", eventId, userId] as const,
  mutes: (userId: string) => ["safety", "mutes", userId] as const,
};

export const myBlocksQuery = (userId: string) =>
  queryOptions({
    queryKey: safetyKeys.blocks(userId),
    queryFn: async (): Promise<BlockedPerson[]> => {
      const { data, error } = await supabase.rpc("my_blocks");
      if (error) throw error;
      return (data ?? []) as BlockedPerson[];
    },
    staleTime: 60_000,
  });

export const eventBlockWarningQuery = (eventId: string, userId: string) =>
  queryOptions({
    queryKey: safetyKeys.warning(eventId, userId),
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc("event_block_warning", { p_event: eventId });
      if (error) throw error;
      return data ?? 0;
    },
    staleTime: 30_000,
  });

/** "Someone you blocked is going" line for the plan page, or null. */
export function blockWarningText(count: number): string | null {
  if (count <= 0) return null;
  return count === 1
    ? "Someone you blocked is on this plan. You won't see each other's RSVPs."
    : `${count} people you blocked are on this plan. You won't see each other's RSVPs.`;
}

export const myMutesQuery = (userId: string) =>
  queryOptions({
    queryKey: safetyKeys.mutes(userId),
    queryFn: async (): Promise<string[]> => {
      const { data, error } = await supabase
        .from("mutes")
        .select("muted_id")
        .eq("muter_id", userId);
      if (error) throw error;
      return (data ?? []).map((r) => r.muted_id);
    },
    staleTime: 60_000,
  });

/** The user ids in a block list, for lookups on attendee rows. */
export function blockedIdSet(list: readonly Pick<BlockedPerson, "user_id">[] | undefined) {
  return new Set((list ?? []).map((b) => b.user_id));
}

/**
 * The name on an attendee row. Profiles RLS hides people across a block, so a host's row for
 * someone they blocked comes back without a profile: say "Blocked member", not "Deleted user".
 */
export function attendeeName(
  profile: { first_name: string } | null | undefined,
  userId: string,
  blockedIds: ReadonlySet<string>,
): string {
  if (profile?.first_name) return profile.first_name;
  return blockedIds.has(userId) ? "Blocked member" : "Deleted user";
}

/** What a report is about, for titles and buttons ("Report this plan"). */
export const REPORT_SUBJECTS: Record<ReportKind, string> = {
  profile: "this profile",
  event: "this plan",
  chapter: "this chapter",
  hub: "this hub",
  message: "this message",
  coach_listing: "this listing",
  coach_review: "this review",
  coach_review_reply: "this reply",
  booking: "a problem with this booking",
};

export function reportTitle(kind: ReportKind, name?: string | null): string {
  if (kind === "profile" && name) return `Report ${name}`;
  return `Report ${REPORT_SUBJECTS[kind]}`;
}

/** The toast after report_content. Never says whether the item is hidden unless this report hid it. */
export function reportSentText(result: Pick<ReportResult, "already" | "hidden">): string {
  if (result.already) return "You already reported this. A moderator will look at it.";
  if (result.hidden) return "Thanks. It's hidden until a moderator looks at it.";
  return "Thanks. A moderator will look at it.";
}

/** The toast after block_user, with the shared-plans heads-up when there are any. */
export function blockedText(name: string, result: Pick<BlockResult, "shared_upcoming">): string {
  const n = result.shared_upcoming;
  if (n <= 0) return `You blocked ${name}.`;
  return n === 1
    ? `You blocked ${name}. You're both on 1 upcoming plan; they aren't told.`
    : `You blocked ${name}. You're both on ${n} upcoming plans; they aren't told.`;
}

/** "Blocked Nov 5, 2026" under a name in the Blocked accounts list. */
export function blockedOnText(iso: string, timeZone?: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "Blocked";
  const day = new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "numeric",
    year: "numeric",
    ...(timeZone ? { timeZone } : {}),
  }).format(d);
  return `Blocked ${day}`;
}
