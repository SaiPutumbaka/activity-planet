import { Link } from "@tanstack/react-router";
import { BellOff, Lock, Users } from "lucide-react";
import {
  chatPreview,
  chatTitle,
  kindLabel,
  unreadLabel,
  type ChatListRow,
} from "@ap/core/messaging";

import { Avatar } from "@/components/ui/avatar";
import { cn } from "@/lib/cn";
import { shortAgo } from "@/lib/notifications";

/** The round picture of a row: the other person, or the room's emoji or initial. */
export function ChatAvatar({ row, size = 48 }: { row: ChatListRow; size?: number }) {
  if (row.kind === "dm") {
    return (
      <Avatar
        src={row.other?.avatar_url}
        name={row.other?.first_name ?? "Deleted user"}
        size={size}
      />
    );
  }
  const emoji = row.kind === "hub" ? row.context?.emoji : null;
  return (
    <span
      aria-hidden="true"
      className="inline-flex shrink-0 items-center justify-center rounded-full bg-surface-2 text-text-2"
      style={{ width: size, height: size, fontSize: Math.round(size * 0.45) }}
    >
      {emoji ? emoji : <Users className="size-5" />}
    </span>
  );
}

/** One conversation in the Chats list: picture, name, preview, time and the unread count. */
export function ChatRow({ row, now }: { row: ChatListRow; now: Date }) {
  const title = chatTitle(row);
  const unread = row.muted ? null : unreadLabel(row.unread);
  const at = row.last_message?.at ?? row.activity_at;
  return (
    <li>
      <Link
        to="/chats/$id"
        params={{ id: row.conversation_id }}
        className="flex min-h-16 items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-2"
        aria-label={`${title}${row.unread > 0 ? `, ${row.unread} unread` : ""}${row.muted ? ", muted" : ""}`}
      >
        <ChatAvatar row={row} />
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1.5">
            <span
              className={cn("truncate text-[16px]", row.unread > 0 ? "font-bold" : "font-semibold")}
            >
              {title}
            </span>
            {row.muted ? (
              <BellOff className="size-3.5 shrink-0 text-text-3" aria-hidden="true" />
            ) : null}
            {row.closed ? (
              <Lock className="size-3.5 shrink-0 text-text-3" aria-hidden="true" />
            ) : null}
          </span>
          <span className="block truncate text-[14px] text-text-2">
            {row.kind !== "dm" && row.kind !== "group" ? `${kindLabel(row.kind)} · ` : ""}
            {chatPreview(row)}
          </span>
        </span>
        <span className="flex shrink-0 flex-col items-end gap-1">
          <span className="text-[12px] text-text-3 tabular">{shortAgo(at, now)}</span>
          {unread ? (
            <span className="flex h-5 min-w-5 items-center justify-center rounded-full bg-primary px-1.5 text-[12px] font-bold text-on-primary tabular">
              {unread}
            </span>
          ) : null}
        </span>
      </Link>
    </li>
  );
}
