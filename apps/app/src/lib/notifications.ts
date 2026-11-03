import { useEffect, useState } from "react";
import { queryOptions, useQuery, useQueryClient } from "@tanstack/react-query";
import type { Database } from "@ap/core/types";

import { attendanceWindowOpen } from "./attendance";
import { formatEventTime } from "./datetime";
import { supabase } from "./supabase";

/**
 * In-app notifications (PLAN.md 4.9, migration 18). The server writes every row (producers in
 * set_rsvp, cancel_event, broadcast_to_event and friends, plus the reminder job); the client
 * reads its own rows (RLS: owner select), marks them read through an RPC and edits its own
 * notification_prefs row (column grants). Email and push delivery come later (week 7); the prefs
 * already decide whether each row is queued for them.
 *
 *   useQuery(inboxQuery(userId))                 // newest 100, with hub, chapter and actor
 *   useUnreadCount(userId)                       // badge; Realtime on own rows, else 60 s polling
 *   await markNotificationsRead([id])            // or markNotificationsRead() for all
 *   groupNotifications(items, now)               // Today / Earlier
 *   notificationCopy(item)                       // { title, body }
 *   notificationLink(item)                       // where a row goes
 *   opensAttendanceSheet(item)                   // checkin_prompt rows open "Did you go?"
 *   await broadcastToEvent(eventId, body)        // "Message everyone going"
 */

export type NotificationKind = Database["public"]["Enums"]["notification_kind"];
export type NotificationPrefs = Database["public"]["Tables"]["notification_prefs"]["Row"];
type PrefsUpdate = Database["public"]["Tables"]["notification_prefs"]["Update"];

export const notificationKeys = {
  all: ["notifications"] as const,
  inbox: (userId: string) => ["notifications", "inbox", userId] as const,
  unread: (userId: string) => ["notifications", "unread", userId] as const,
  prefs: (userId: string) => ["notifications", "prefs", userId] as const,
};

/* ------------------------------------------------------------------ */
/* Payload                                                              */
/* ------------------------------------------------------------------ */

/** What the producers put in notifications.payload. Every field is optional on read. */
export interface NotificationPayload {
  title?: string;
  starts_at?: string;
  ends_at?: string;
  timezone?: string;
  location_hint?: string | null;
  status?: string;
  count?: number;
  reason?: string | null;
  occurrences?: number;
  changed?: string[];
  body?: string;
  claim_kind?: string;
  proposed_name?: string;
  hub_name?: string;
  chapter_slug?: string;
  note?: string;
}

function str(v: unknown): string | undefined {
  return typeof v === "string" && v.trim() !== "" ? v : undefined;
}

function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** Reads the jsonb payload defensively: anything of the wrong type is dropped. */
export function parsePayload(raw: unknown): NotificationPayload {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
  const r = raw as Record<string, unknown>;
  return {
    title: str(r.title),
    starts_at: str(r.starts_at),
    ends_at: str(r.ends_at),
    timezone: str(r.timezone),
    location_hint: str(r.location_hint) ?? null,
    status: str(r.status),
    count: num(r.count),
    reason: str(r.reason) ?? null,
    occurrences: num(r.occurrences),
    changed: Array.isArray(r.changed)
      ? r.changed.filter((c): c is string => typeof c === "string")
      : undefined,
    body: str(r.body),
    claim_kind: str(r.claim_kind),
    proposed_name: str(r.proposed_name),
    hub_name: str(r.hub_name),
    chapter_slug: str(r.chapter_slug),
    note: str(r.note),
  };
}

/* ------------------------------------------------------------------ */
/* Queries                                                              */
/* ------------------------------------------------------------------ */

export interface InboxItem {
  id: string;
  kind: NotificationKind;
  created_at: string;
  read_at: string | null;
  event_id: string | null;
  hub_id: string | null;
  chapter_id: string | null;
  payload: NotificationPayload;
  hub: { slug: string; name: string } | null;
  chapter: { slug: string; name: string } | null;
  actorName: string | null;
}

const INBOX_SELECT =
  "id,kind,created_at,read_at,event_id,hub_id,chapter_id,payload,hubs(slug,name),hub_chapters(slug,name),actor:profiles!notifications_actor_id_fkey(first_name)" as const;

/** The viewer's newest 100 notifications, newest first. */
export const inboxQuery = (userId: string) =>
  queryOptions({
    queryKey: notificationKeys.inbox(userId),
    queryFn: async (): Promise<InboxItem[]> => {
      const { data, error } = await supabase
        .from("notifications")
        .select(INBOX_SELECT)
        .eq("user_id", userId)
        .order("created_at", { ascending: false })
        .limit(100);
      if (error) throw error;
      return data.map((r) => ({
        id: r.id,
        kind: r.kind,
        created_at: r.created_at,
        read_at: r.read_at,
        event_id: r.event_id,
        hub_id: r.hub_id,
        chapter_id: r.chapter_id,
        payload: parsePayload(r.payload),
        hub: r.hubs ? { slug: r.hubs.slug, name: r.hubs.name } : null,
        chapter: r.hub_chapters ? { slug: r.hub_chapters.slug, name: r.hub_chapters.name } : null,
        actorName: r.actor?.first_name ?? null,
      }));
    },
    staleTime: 15_000,
  });

export const unreadCountQuery = (userId: string) =>
  queryOptions({
    queryKey: notificationKeys.unread(userId),
    queryFn: async (): Promise<number> => {
      const { data, error } = await supabase.rpc("unread_notification_count");
      if (error) throw error;
      return data ?? 0;
    },
    staleTime: 15_000,
  });

/**
 * Keeps the inbox and the badge fresh. Subscribes to Realtime changes on the viewer's own rows
 * (notifications is in the supabase_realtime publication; RLS limits delivery to the owner).
 * Returns whether the channel is live; callers poll every 60 s while it is not.
 */
export function useNotificationsLive(userId: string): boolean {
  const queryClient = useQueryClient();
  const [live, setLive] = useState(false);

  useEffect(() => {
    const channel = supabase
      .channel(`notifications:${userId}:${Math.random().toString(36).slice(2)}`)
      .on(
        "postgres_changes",
        { event: "*", schema: "public", table: "notifications", filter: `user_id=eq.${userId}` },
        () => {
          void queryClient.invalidateQueries({ queryKey: notificationKeys.unread(userId) });
          void queryClient.invalidateQueries({ queryKey: notificationKeys.inbox(userId) });
        },
      )
      .subscribe((status) => setLive(status === "SUBSCRIBED"));
    return () => {
      setLive(false);
      void supabase.removeChannel(channel);
    };
  }, [queryClient, userId]);

  return live;
}

/** Fallback poll interval when Realtime is not connected. Paused while the tab is hidden. */
export const POLL_MS = 60_000;

/** The unread count for the bell, live when Realtime is up and polled every 60 s when not. */
export function useUnreadCount(userId: string): number {
  const live = useNotificationsLive(userId);
  const q = useQuery({
    ...unreadCountQuery(userId),
    refetchInterval: live ? false : POLL_MS,
    refetchIntervalInBackground: false,
  });
  return q.data ?? 0;
}

/** Marks the given notifications read, or every unread one when ids is omitted. */
export async function markNotificationsRead(ids?: string[]): Promise<number> {
  const { data, error } = await supabase.rpc("mark_notifications_read", ids ? { p_ids: ids } : {});
  if (error) throw error;
  return data ?? 0;
}

/** Badge text: nothing at 0, the number up to 9, then "9+". */
export function badgeLabel(count: number): string | null {
  if (!Number.isFinite(count) || count <= 0) return null;
  return count > 9 ? "9+" : String(Math.floor(count));
}

/* ------------------------------------------------------------------ */
/* Grouping                                                             */
/* ------------------------------------------------------------------ */

export interface NotificationGroup<T> {
  key: "today" | "earlier";
  title: string;
  items: T[];
}

function localDayKey(date: Date, timeZone?: string): string {
  return new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).format(date);
}

/**
 * Splits newest-first rows into Today (same calendar day as `now` in `timeZone`, the device's
 * when omitted) and Earlier. Empty groups are left out; order within a group is kept.
 */
export function groupNotifications<T extends { created_at: string }>(
  items: T[],
  now: Date = new Date(),
  timeZone?: string,
): NotificationGroup<T>[] {
  const today = localDayKey(now, timeZone);
  const t: T[] = [];
  const e: T[] = [];
  for (const item of items) {
    const d = new Date(item.created_at);
    if (!Number.isNaN(d.getTime()) && localDayKey(d, timeZone) === today) t.push(item);
    else e.push(item);
  }
  const groups: NotificationGroup<T>[] = [];
  if (t.length > 0) groups.push({ key: "today", title: "Today", items: t });
  if (e.length > 0) groups.push({ key: "earlier", title: "Earlier", items: e });
  return groups;
}

/** "Just now", "5m", "3h", "Yesterday", "Nov 2". */
export function shortAgo(value: string, now: Date = new Date()): string {
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return "";
  const mins = Math.floor((now.getTime() - d.getTime()) / 60_000);
  if (mins < 1) return "Just now";
  if (mins < 60) return `${mins}m`;
  const hours = Math.floor(mins / 60);
  if (hours < 24) return `${hours}h`;
  if (hours < 48) return "Yesterday";
  return new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric" }).format(d);
}

/* ------------------------------------------------------------------ */
/* Copy and links                                                       */
/* ------------------------------------------------------------------ */

export interface NotificationCopy {
  title: string;
  body: string | null;
}

type CopyInput = Pick<InboxItem, "kind" | "payload" | "actorName" | "hub" | "chapter">;

function when(p: NotificationPayload, now: Date): string | null {
  if (!p.starts_at) return null;
  const t = formatEventTime(p.starts_at, p.ends_at, p.timezone, now);
  return t || null;
}

function whenWhere(p: NotificationPayload, now: Date): string | null {
  const parts = [when(p, now), p.location_hint].filter(Boolean);
  return parts.length > 0 ? parts.join(" · ") : null;
}

/** Title and one line of detail for a row. Everyone-first copy (D-035): no audience assumed. */
export function notificationCopy(item: CopyInput, now: Date = new Date()): NotificationCopy {
  const p = item.payload;
  const plan = p.title ?? "a plan";
  switch (item.kind) {
    case "rsvp_confirmed":
      return p.status === "waitlisted"
        ? { title: `You're on the waitlist for ${plan}`, body: "We'll tell you if a spot opens." }
        : { title: `You're going to ${plan}`, body: whenWhere(p, now) };
    case "attendee_joined": {
      const n = p.count ?? 1;
      const who = item.actorName ?? "Someone";
      const title =
        n <= 1
          ? `${who} joined ${plan}`
          : `${who} and ${n - 1} ${n - 1 === 1 ? "other" : "others"} joined ${plan}`;
      return { title, body: when(p, now) };
    }
    case "waitlist_promoted":
      return { title: `A spot opened. You're going to ${plan}`, body: whenWhere(p, now) };
    case "rsvp_approved":
      return { title: `You're approved for ${plan}`, body: "The address is on the plan now." };
    case "event_reminder_day":
      return { title: `Coming up: ${plan}`, body: whenWhere(p, now) };
    case "event_reminder_2h":
      return { title: `${plan} starts soon`, body: whenWhere(p, now) };
    case "event_cancelled": {
      const dates = p.occurrences && p.occurrences > 1 ? ` (${p.occurrences} dates)` : "";
      const reason =
        p.reason === "host_deleted" ? "The host closed their account." : (p.reason ?? null);
      return { title: `${plan} is cancelled${dates}`, body: reason ?? when(p, now) };
    }
    case "event_updated": {
      const time = p.changed?.includes("time") ?? false;
      const place = p.changed?.includes("place") ?? false;
      const what = time && place ? "a new time and place" : place ? "a new place" : "a new time";
      return { title: `${plan} has ${what}`, body: whenWhere(p, now) };
    }
    case "checkin_prompt":
      return { title: `Did you go to ${plan}?`, body: "Tell us, and pick who you met there." };
    case "hub_new_event": {
      const hub = item.hub?.name;
      return { title: hub ? `New in ${hub}: ${plan}` : `New plan: ${plan}`, body: when(p, now) };
    }
    case "broadcast":
      return {
        title: item.actorName ? `${item.actorName} about ${plan}` : `Message about ${plan}`,
        body: p.body ?? null,
      };
    case "chapter_claim_update": {
      const name = item.chapter?.name ?? p.proposed_name ?? "your chapter";
      if (p.status === "approved") {
        return { title: "Your chapter claim was approved", body: `You now organize ${name}.` };
      }
      return {
        title: "Your chapter claim wasn't approved",
        body: p.note ?? (p.hub_name ? `About ${name} in ${p.hub_name}.` : `About ${name}.`),
      };
    }
    default:
      return { title: "Update", body: null };
  }
}

export type NotificationLink =
  | { to: "/events/$id"; params: { id: string } }
  | { to: "/chapters/$slug"; params: { slug: string } }
  | { to: "/hubs/$slug"; params: { slug: string } };

type LinkInput = Pick<InboxItem, "kind" | "event_id" | "payload" | "hub" | "chapter">;

/** Where tapping a row goes: the plan, the chapter or the hub (for a claim). Null when nowhere. */
export function notificationLink(item: LinkInput): NotificationLink | null {
  if (item.kind === "chapter_claim_update") {
    const chapterSlug = item.chapter?.slug ?? item.payload.chapter_slug;
    if (item.payload.status === "approved" && chapterSlug) {
      return { to: "/chapters/$slug", params: { slug: chapterSlug } };
    }
    return item.hub ? { to: "/hubs/$slug", params: { slug: item.hub.slug } } : null;
  }
  if (item.event_id) return { to: "/events/$id", params: { id: item.event_id } };
  if (item.chapter) return { to: "/chapters/$slug", params: { slug: item.chapter.slug } };
  if (item.hub) return { to: "/hubs/$slug", params: { slug: item.hub.slug } };
  return null;
}

/**
 * Whether tapping a row opens the morning-after sheet instead of the plan: a checkin_prompt
 * whose plan ended less than 7 days ago (submit_attendance's window).
 */
export function opensAttendanceSheet(
  item: Pick<InboxItem, "kind" | "event_id" | "payload">,
  now: Date = new Date(),
): boolean {
  return (
    item.kind === "checkin_prompt" &&
    Boolean(item.event_id) &&
    Boolean(item.payload.ends_at) &&
    attendanceWindowOpen({ status: "published", ends_at: item.payload.ends_at ?? "" }, now)
  );
}

/* ------------------------------------------------------------------ */
/* Preferences                                                          */
/* ------------------------------------------------------------------ */

export const notificationPrefsQuery = (userId: string) =>
  queryOptions({
    queryKey: notificationKeys.prefs(userId),
    queryFn: async (): Promise<NotificationPrefs | null> => {
      const { data, error } = await supabase
        .from("notification_prefs")
        .select("*")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

/** The columns a person may change (the column grant on notification_prefs). */
export type PrefsPatch = Pick<
  PrefsUpdate,
  | "timezone"
  | "email_enabled"
  | "push_enabled"
  | "event_reminders"
  | "event_updates"
  | "hub_activity"
  | "messages"
  | "checkin_prompts"
  | "weekly_digest"
  | "quiet_start"
  | "quiet_end"
  | "unsubscribed_all_at"
>;

export async function updateNotificationPrefs(
  userId: string,
  patch: PrefsPatch,
): Promise<NotificationPrefs> {
  const { data, error } = await supabase
    .from("notification_prefs")
    .update(patch)
    .eq("user_id", userId)
    .select("*")
    .single();
  if (error) throw error;
  return data;
}

/** "22:00:00" (Postgres time) to "22:00" for <input type="time">; "" when unset. */
export function toTimeInput(value: string | null | undefined): string {
  const m = /^(\d{2}):(\d{2})/.exec(value ?? "");
  return m ? `${m[1]}:${m[2]}` : "";
}

/** "22:00" from <input type="time"> to "22:00:00"; null when empty or malformed. */
export function fromTimeInput(value: string): string | null {
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(value.trim());
  return m ? `${m[1]}:${m[2]}:00` : null;
}

/** The device's IANA timezone, or null when the browser does not say. */
export function deviceTimeZone(): string | null {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
  } catch {
    return null;
  }
}

/* ------------------------------------------------------------------ */
/* Broadcast                                                            */
/* ------------------------------------------------------------------ */

export const BROADCAST_MAX = 500;
export const BROADCAST_DAILY_CAP = 3;

export async function broadcastToEvent(
  eventId: string,
  body: string,
): Promise<{ recipients: number }> {
  const { data, error } = await supabase.rpc("broadcast_to_event", {
    p_event_id: eventId,
    p_body: body,
  });
  if (error) throw error;
  const recipients =
    data && typeof data === "object" && !Array.isArray(data) && typeof data.recipients === "number"
      ? data.recipients
      : 0;
  return { recipients };
}

function errorCode(err: unknown): string {
  return typeof err === "object" && err && "message" in err && typeof err.message === "string"
    ? err.message.trim()
    : "";
}

const BROADCAST_MESSAGES: Record<string, string> = {
  broadcast_limit: `You've sent ${BROADCAST_DAILY_CAP} messages for this plan in the last day. Try again tomorrow.`,
  body_length: `Messages are 1 to ${BROADCAST_MAX} characters.`,
  forbidden: "Only the host or the chapter's captains can message everyone.",
  event_cancelled: "This plan is cancelled.",
  event_over: "This plan ended more than a day ago.",
  event_not_found: "This plan isn't available anymore.",
  not_authenticated: "Your session ended. Sign in again.",
};

export function broadcastErrorMessage(err: unknown): string {
  const code = errorCode(err);
  const known = BROADCAST_MESSAGES[code];
  if (known) return known;
  if (/Failed to fetch|NetworkError|Load failed/i.test(code))
    return "Couldn't reach the server. Check your connection and try again.";
  return "Couldn't send that. Try again.";
}

/** Whether broadcast_to_event accepts a message: not cancelled, and until a day after the end. */
export function broadcastOpen(
  event: { status: string; ends_at: string },
  now: Date = new Date(),
): boolean {
  if (event.status === "cancelled") return false;
  const end = new Date(event.ends_at).getTime();
  return Number.isFinite(end) && end >= now.getTime() - 24 * 60 * 60 * 1000;
}

/** Success line after a broadcast. */
export function broadcastSentMessage(recipients: number): string {
  if (recipients <= 0) return "Sent. No one else is on this plan yet.";
  return recipients === 1 ? "Sent to 1 person." : `Sent to ${recipients} people.`;
}
