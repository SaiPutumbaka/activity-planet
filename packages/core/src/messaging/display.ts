import type { ChatListRow, ChatMessage, ConversationKind } from "./schemas";

/** Display helpers for chat rows and bubbles. Neutral copy for everyone (D-040). */

const KIND_LABEL: Record<ConversationKind, string> = {
  dm: "Message",
  group: "Group",
  event: "Plan chat",
  hub: "Hub chat",
  chapter: "Chapter chat",
};

export function kindLabel(kind: ConversationKind): string {
  return KIND_LABEL[kind];
}

/** A row's name: the other person (dm), the group's title, or the plan, hub or chapter. */
export function chatTitle(row: Pick<ChatListRow, "kind" | "title" | "other">): string {
  if (row.kind === "dm") return row.other?.first_name ?? "Deleted user";
  return row.title?.trim() || KIND_LABEL[row.kind];
}

/** The line under a row's name. */
export function chatPreview(row: Pick<ChatListRow, "last_message" | "request">): string {
  const m = row.last_message;
  if (!m) return row.request === "sent" ? "Request sent" : "No messages yet";
  const text = m.preview.replace(/\s+/g, " ").trim();
  return m.mine ? `You: ${text}` : text;
}

/** Unread badge text: nothing at 0, the number up to 99, then "99+". */
export function unreadLabel(n: number): string | null {
  if (!Number.isFinite(n) || n <= 0) return null;
  return n >= 99 ? "99+" : String(Math.floor(n));
}

/** What a bubble says instead of its body, or null to show the body. */
export function removedLabel(m: Pick<ChatMessage, "deleted" | "hidden" | "mine">): string | null {
  if (m.deleted === "author") return "Message deleted";
  if (m.deleted === "room_admin") return "Removed by the host";
  if (m.deleted === "moderator") return "Removed by moderators";
  if (m.hidden) return "Hidden while we review it";
  return null;
}

/** "Today", "Yesterday" or a date, for day dividers in a conversation. */
export function dayLabel(iso: string, now: Date = new Date(), timeZone?: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const key = (x: Date) =>
    new Intl.DateTimeFormat("en-CA", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
    }).format(x);
  if (key(d) === key(now)) return "Today";
  if (key(d) === key(new Date(now.getTime() - 86_400_000))) return "Yesterday";
  return new Intl.DateTimeFormat("en-US", {
    timeZone,
    weekday: "short",
    month: "short",
    day: "numeric",
    ...(d.getFullYear() !== now.getFullYear() ? { year: "numeric" } : {}),
  }).format(d);
}

/** "3:05 PM" for a bubble. */
export function timeLabel(iso: string, timeZone?: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  return new Intl.DateTimeFormat("en-US", { timeZone, hour: "numeric", minute: "2-digit" }).format(
    d,
  );
}
