import { queryOptions } from "@tanstack/react-query";

import { REPORT_REASON_LABELS, type ReportReason } from "./safety";
import { supabase } from "./supabase";

/**
 * Admin panel v1 (migration 53; PLAN 4.11, TRUST-SAFETY-LEGAL section 7). Moderators only: every
 * RPC here refuses anyone else with `forbidden`, whatever the page shows. The panel reads
 * mod_scorecard, mod_queue, mod_report_queue, mod_takedown_queue, mod_user_search and
 * mod_user_lookup, and acts through the existing RPCs (mod_moderate, mod_ban_user,
 * mod_unban_user, mod_takedown_block_image, mod_takedown_resolve). Lookups are logged by the
 * database; nothing is logged here.
 *
 *   useQuery(modQueueQuery())       // one list across every source, most urgent first
 *   dueLabel(item.minutes_left)     // "3 h 20 min left" | "Overdue by 2 h"
 *   queueItemLink(item)             // where a moderator acts on it
 */

// ---------------------------------------------------------------------------
// Queue
// ---------------------------------------------------------------------------

export const QUEUE_SOURCES = [
  "report",
  "takedown",
  "place_report",
  "place",
  "place_edit",
  "claim",
  "calendar",
] as const;
export type QueueSource = (typeof QUEUE_SOURCES)[number];

export const SOURCE_LABELS: Record<QueueSource, string> = {
  report: "Report",
  takedown: "Intimate image request",
  place_report: "Reported place",
  place: "New public place",
  place_edit: "Place correction",
  claim: "Chapter claim",
  calendar: "Calendar suggestion",
};

/** Plural labels for the scorecard rows. */
export const SOURCE_PLURALS: Record<QueueSource, string> = {
  report: "Reports",
  takedown: "Intimate image requests",
  place_report: "Reported places",
  place: "New public places",
  place_edit: "Place corrections",
  claim: "Chapter claims",
  calendar: "Calendar suggestions",
};

/** The review target behind each source, for the queue's footnote. Mirrors mod_sla_hours. */
export const SOURCE_TARGETS: Record<QueueSource, string> = {
  report: "24 hours (4 for child safety)",
  takedown: "48 hours (4 when someone may be under 18)",
  place_report: "24 hours",
  place: "72 hours",
  place_edit: "72 hours",
  claim: "72 hours",
  calendar: "7 days",
};

export interface QueueItem {
  source: QueueSource;
  id: string;
  title: string;
  detail: string;
  priority: number;
  received_at: string;
  due_at: string;
  overdue: boolean;
  minutes_left: number;
  count: number;
  can_act: boolean;
  ref: Record<string, unknown>;
}

const TARGET_KIND_LABELS: Record<string, string> = {
  profile: "Profile",
  event: "Plan",
  chapter: "Chapter",
  hub: "Hub",
};

export function targetKindLabel(kind: string): string {
  return TARGET_KIND_LABELS[kind] ?? kind;
}

export function reasonLabel(reason: string): string {
  return REPORT_REASON_LABELS[reason as ReportReason] ?? reason;
}

/** One line under the queue item's title. */
export function queueItemDetail(item: QueueItem): string {
  switch (item.source) {
    case "report": {
      const reasons = Array.isArray(item.ref.reasons)
        ? (item.ref.reasons as string[]).map(reasonLabel).join(", ")
        : "";
      const n = `${item.count} ${item.count === 1 ? "report" : "reports"}`;
      return [targetKindLabel(item.detail), n, reasons].filter(Boolean).join(" · ");
    }
    case "takedown":
      return [
        item.ref.involves_minor ? "May show someone under 18" : "Removal request",
        item.detail === "waiting" ? "waiting on the requester" : null,
      ]
        .filter(Boolean)
        .join(" · ");
    case "place_report":
      return `${item.count} ${item.count === 1 ? "report" : "reports"}`;
    case "claim":
      return item.detail === "area" ? "Area chapter" : "Organization chapter";
    case "calendar":
      return item.count > 1 ? `Suggested by ${item.count} members` : "Suggested by a member";
    default:
      return "";
  }
}

/** Where a moderator acts on an item: the page that holds its actions. */
export function queueItemLink(
  item: Pick<QueueItem, "source">,
): "/admin/reports" | "/admin/takedowns" | "/admin/places" | "/admin/claims" | "/admin/calendars" {
  switch (item.source) {
    case "report":
      return "/admin/reports";
    case "takedown":
      return "/admin/takedowns";
    case "claim":
      return "/admin/claims";
    case "calendar":
      return "/admin/calendars";
    default:
      return "/admin/places";
  }
}

function hoursAndMinutes(totalMinutes: number): string {
  const m = Math.max(0, Math.round(totalMinutes));
  if (m < 60) return `${m} min`;
  const days = Math.floor(m / 1440);
  if (days >= 2) return `${days} days`;
  const h = Math.floor(m / 60);
  const rest = m % 60;
  return rest === 0 || h >= 10 ? `${h} h` : `${h} h ${rest} min`;
}

/** The SLA timer's text: "3 h 20 min left", "Due now", "Overdue by 2 h". */
export function dueLabel(minutesLeft: number): string {
  if (minutesLeft >= 1) return `${hoursAndMinutes(minutesLeft)} left`;
  if (minutesLeft > -1) return "Due now";
  return `Overdue by ${hoursAndMinutes(-minutesLeft)}`;
}

export type DueTone = "overdue" | "soon" | "ok";

/** Red when overdue, amber inside the last 4 hours. */
export function dueTone(minutesLeft: number): DueTone {
  if (minutesLeft < 0) return "overdue";
  if (minutesLeft < 240) return "soon";
  return "ok";
}

/** The moderator's own time zone, so times read the same wherever they are (D-040). */
export function viewerTimeZone(): string | undefined {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || undefined;
  } catch {
    return undefined;
  }
}

/** "Thu, Nov 5, 3:10 PM" in the viewer's zone. */
export function formatWhen(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("en-US", {
    timeZone: viewerTimeZone(),
    weekday: "short",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
  }).format(d);
}

/** Minutes until `dueAt`, for rows that carry only a due time. */
export function minutesUntil(dueAt: string, now: Date = new Date()): number {
  return Math.floor((new Date(dueAt).getTime() - now.getTime()) / 60_000);
}

// ---------------------------------------------------------------------------
// Scorecard
// ---------------------------------------------------------------------------

export interface QueueCounts {
  open: number;
  overdue: number;
  due_soon: number;
}

export interface Scorecard {
  generated_at: string;
  queues: Record<QueueSource, QueueCounts>;
  breaches_30d: Partial<Record<QueueSource, number>>;
  resolved_7d: { report: number; takedown: number };
  median_hours_30d: { report: number | null; takedown: number | null };
  actions_7d: Record<string, number>;
  people: { members: number; signups_7d: number; banned: number };
  plans: {
    human_hosted_next_7d: number;
    human_hosted_last_7d: number;
    four_plus_checked_in_last_7d: number;
  };
  chapters_active: number;
}

export function totalOpen(s: Pick<Scorecard, "queues">): QueueCounts {
  return QUEUE_SOURCES.reduce<QueueCounts>(
    (acc, k) => {
      const q = s.queues[k];
      if (!q) return acc;
      return {
        open: acc.open + q.open,
        overdue: acc.overdue + q.overdue,
        due_soon: acc.due_soon + q.due_soon,
      };
    },
    { open: 0, overdue: 0, due_soon: 0 },
  );
}

export function totalBreaches(s: Pick<Scorecard, "breaches_30d">): number {
  return Object.values(s.breaches_30d).reduce<number>((a, b) => a + (b ?? 0), 0);
}

const ACTION_LABELS: Record<string, string> = {
  auto_hide: "Hidden after reports",
  dismiss: "Reports dismissed",
  hide: "Hidden",
  remove: "Removed",
  restore: "Restored",
  ban: "Banned",
  unban: "Unbanned",
  grant_moderator: "Moderator added",
  revoke_moderator: "Moderator removed",
  image_block: "Image blocked",
  ncii_remove: "Image request completed",
  ncii_reject: "Image request rejected",
  ncii_update: "Image request updated",
};

export function actionLabel(action: string): string {
  return ACTION_LABELS[action] ?? action;
}

/** "1.5 h" or "None yet". */
export function formatHours(h: number | null | undefined): string {
  if (h === null || h === undefined) return "None yet";
  return `${Number.isInteger(h) ? h : h.toFixed(1)} h`;
}

// ---------------------------------------------------------------------------
// Reports (mod_report_queue, mod_moderate)
// ---------------------------------------------------------------------------

export interface ReportGroup {
  kind: "profile" | "event" | "chapter" | "hub";
  target_id: string;
  priority: number;
  due_at: string;
  overdue: boolean;
  first_reported_at: string;
  report_count: number;
  reporter_count: number;
  reasons: Record<string, number>;
  notes: string[];
  label: string | null;
  state: "hidden" | "removed" | null;
  target_user: { id: string; handle: string; first_name: string; status: string } | null;
  can_act: boolean;
}

export type ModerateAction = "dismiss" | "hide" | "remove" | "restore";

export const MODERATE_ACTIONS: { action: ModerateAction; label: string }[] = [
  { action: "dismiss", label: "Dismiss" },
  { action: "hide", label: "Hide" },
  { action: "remove", label: "Remove" },
];

/** What "Remove" does to each kind, shown before a moderator confirms. */
export function removeExplainer(kind: ReportGroup["kind"]): string {
  switch (kind) {
    case "profile":
      return "Clears their photo and bio. The account stays; ban it from Users if needed.";
    case "event":
      return "Takes the plan down. If it hasn't started, it's cancelled and attendees are told our moderators removed it.";
    case "chapter":
      return "Takes the chapter down. It stays in the log and can be restored.";
    case "hub":
      return "Takes the hub down. It stays in the log and can be restored.";
  }
}

// ---------------------------------------------------------------------------
// Takedowns (mod_takedown_queue, mod_takedown_block_image, mod_takedown_resolve)
// ---------------------------------------------------------------------------

export interface TakedownItem {
  id: string;
  reference: string;
  status: "open" | "waiting" | "removed" | "rejected";
  priority: number;
  received_at: string;
  due_at: string;
  overdue: boolean;
  minutes_left: number | null;
  involves_minor: boolean;
  requester: { name: string; email: string; relationship: "self" | "authorized" };
  signature: string;
  locations: string;
  description: string;
  images_blocked: number;
  images: { id: string; bucket: string; path: string; status: string; deleted: boolean }[];
  target_user: { id: string; handle: string; first_name: string; status: string } | null;
  resolution_note: string;
  resolved_at: string | null;
  can_act: boolean;
}

export type TakedownAction = "removed" | "rejected" | "waiting" | "reopen";

export const TAKEDOWN_STATE_LABELS: Record<string, string> = {
  blocked: "Blocked. The image and its stored copies are gone.",
  hashing: "Removed. Checking it for copies now.",
  removed: "Removed. It couldn't be read, so there's nothing to match copies against.",
};

// ---------------------------------------------------------------------------
// Users (mod_user_search, mod_user_lookup, mod_ban_user, mod_unban_user)
// ---------------------------------------------------------------------------

export interface UserSearchRow {
  id: string;
  handle: string;
  first_name: string;
  avatar_url: string | null;
  status: string;
  joined_at: string;
}

export interface UserRecord {
  id: string;
  handle: string;
  first_name: string;
  avatar_url: string | null;
  bio: string;
  status: "active" | "suspended" | "banned" | "deleted";
  moderation_state: "hidden" | "removed" | null;
  joined_at: string;
  account_days: number;
  onboarded: boolean;
  roles: string[];
  counts: {
    open_reports: number;
    reports_total: number;
    reports_filed_30d: number;
    hosted_total: number;
    hosted_upcoming: number;
    rsvps_upcoming: number;
    chapters_running: number;
    takedowns_about: number;
  };
  actions: {
    action: string;
    kind: string;
    note: string | null;
    created_at: string;
    by_me: boolean;
    automatic: boolean;
  }[];
  is_self: boolean;
  can_ban: boolean;
  can_unban: boolean;
}

export const STATUS_LABELS: Record<string, string> = {
  active: "Active",
  suspended: "Suspended",
  banned: "Banned",
  deleted: "Deleted",
};

/** Ban and unban reasons go in the moderation log; short ones say nothing to the next moderator. */
export const MIN_REASON_LENGTH = 10;
export const MAX_REASON_LENGTH = 500;

export function reasonError(reason: string): string | null {
  const r = reason.trim();
  if (r.length < MIN_REASON_LENGTH) return `Write at least ${MIN_REASON_LENGTH} characters.`;
  if (r.length > MAX_REASON_LENGTH) return `Keep it under ${MAX_REASON_LENGTH} characters.`;
  return null;
}

/** What the search box accepts: a handle (2+ characters), an account email, or a user id. */
export function searchQueryKind(q: string): "id" | "email" | "handle" | null {
  const t = q.trim();
  if (/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(t)) return "id";
  if (t.indexOf("@") > 0) return t.length <= 254 ? "email" : null;
  const h = t.replace(/^@+/, "");
  return /^[a-zA-Z0-9_]{2,24}$/.test(h) ? "handle" : null;
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

const MESSAGES: Record<string, string> = {
  not_authenticated: "Sign in again to continue.",
  forbidden: "Only moderators can do that.",
  own_item: "This one involves you. Another moderator handles it.",
  item_not_pending: "Someone already handled this.",
  target_not_found: "It's gone already.",
  user_not_found: "We couldn't find that account.",
  cannot_ban_admin: "Admins can't be banned.",
  invalid_query: "Type a handle (2 or more characters), an account email or a user id.",
  rate_limited: "That's 200 searches today. Searching opens again tomorrow.",
  invalid_image_url: "Paste the image's full Activity Planet link.",
  request_closed: "This request is already closed.",
  request_open: "This request is still open.",
  note_required: "Add a note for the log first.",
  not_found: "We couldn't find that request.",
  invalid_action: "That action isn't available.",
};

export function adminErrorCode(err: unknown): string {
  const m =
    typeof err === "object" &&
    err !== null &&
    typeof (err as { message?: unknown }).message === "string"
      ? (err as { message: string }).message.trim()
      : "";
  return /^[a-z0-9_]+$/.test(m) ? m : "";
}

export function adminErrorMessage(err: unknown): string {
  return MESSAGES[adminErrorCode(err)] ?? "Something went wrong. Try again.";
}

// ---------------------------------------------------------------------------
// Queries and calls
// ---------------------------------------------------------------------------

export const adminKeys = {
  all: ["admin"] as const,
  scorecard: ["admin", "scorecard"] as const,
  queue: ["admin", "queue"] as const,
  reports: ["admin", "reports"] as const,
  takedowns: (closed: boolean) => ["admin", "takedowns", closed] as const,
  search: (q: string) => ["admin", "user-search", q] as const,
  user: (id: string) => ["admin", "user", id] as const,
  isAdmin: (userId: string) => ["admin", "is-admin", userId] as const,
};

export const scorecardQuery = () =>
  queryOptions({
    queryKey: adminKeys.scorecard,
    queryFn: async (): Promise<Scorecard> => {
      const { data, error } = await supabase.rpc("mod_scorecard");
      if (error) throw error;
      return data as unknown as Scorecard;
    },
    staleTime: 30_000,
    refetchInterval: 60_000,
  });

export const modQueueQuery = () =>
  queryOptions({
    queryKey: adminKeys.queue,
    queryFn: async (): Promise<QueueItem[]> => {
      const { data, error } = await supabase.rpc("mod_queue", { p_limit: 200 });
      if (error) throw error;
      return (data ?? []) as unknown as QueueItem[];
    },
    staleTime: 15_000,
    refetchInterval: 60_000,
  });

export const reportQueueQuery = () =>
  queryOptions({
    queryKey: adminKeys.reports,
    queryFn: async (): Promise<ReportGroup[]> => {
      const { data, error } = await supabase.rpc("mod_report_queue", { p_limit: 200 });
      if (error) throw error;
      return (data ?? []) as unknown as ReportGroup[];
    },
    staleTime: 15_000,
  });

export const takedownQueueQuery = (closed: boolean) =>
  queryOptions({
    queryKey: adminKeys.takedowns(closed),
    queryFn: async (): Promise<TakedownItem[]> => {
      const { data, error } = await supabase.rpc("mod_takedown_queue", {
        p_limit: 100,
        p_closed: closed,
      });
      if (error) throw error;
      return (data ?? []) as unknown as TakedownItem[];
    },
    staleTime: 15_000,
  });

/** Every search is logged by the database, so it runs on submit, never per keystroke. */
export const userSearchQuery = (q: string) =>
  queryOptions({
    queryKey: adminKeys.search(q),
    queryFn: async (): Promise<UserSearchRow[]> => {
      const { data, error } = await supabase.rpc("mod_user_search", { p_query: q });
      if (error) throw error;
      return (data ?? []) as unknown as UserSearchRow[];
    },
    enabled: q !== "",
    staleTime: 5 * 60_000,
    retry: false,
  });

export const userRecordQuery = (userId: string | null) =>
  queryOptions({
    queryKey: adminKeys.user(userId ?? ""),
    queryFn: async (): Promise<UserRecord> => {
      const { data, error } = await supabase.rpc("mod_user_lookup", { p_user: userId! });
      if (error) throw error;
      return data as unknown as UserRecord;
    },
    enabled: Boolean(userId),
    staleTime: 5 * 60_000,
    retry: false,
  });

export async function moderate(
  kind: ReportGroup["kind"],
  id: string,
  action: ModerateAction,
  note?: string,
): Promise<void> {
  const { error } = await supabase.rpc("mod_moderate", {
    p_kind: kind,
    p_id: id,
    p_action: action,
    ...(note?.trim() ? { p_note: note.trim() } : {}),
  });
  if (error) throw error;
}

export async function banUser(userId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc("mod_ban_user", { p_user: userId, p_note: reason.trim() });
  if (error) throw error;
}

export async function unbanUser(userId: string, reason: string): Promise<void> {
  const { error } = await supabase.rpc("mod_unban_user", {
    p_user: userId,
    p_note: reason.trim(),
  });
  if (error) throw error;
}

export async function blockTakedownImage(requestId: string, url: string): Promise<string> {
  const { data, error } = await supabase.rpc("mod_takedown_block_image", {
    p_request: requestId,
    p_image_url: url.trim(),
  });
  if (error) throw error;
  return String((data as { state?: unknown } | null)?.state ?? "");
}

export async function resolveTakedown(
  requestId: string,
  action: TakedownAction,
  note?: string,
): Promise<void> {
  const { error } = await supabase.rpc("mod_takedown_resolve", {
    p_request: requestId,
    p_action: action,
    ...(note?.trim() ? { p_note: note.trim() } : {}),
  });
  if (error) throw error;
}
