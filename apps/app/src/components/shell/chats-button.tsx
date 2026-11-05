import { Link } from "@tanstack/react-router";
import { MessageCircle } from "lucide-react";

import { buttonVariants } from "@/components/ui/button-variants";
import { cn } from "@/lib/cn";
import { useUnreadChats } from "@/lib/messaging";
import { badgeLabel } from "@/lib/notifications";

/**
 * Chats, beside the inbox bell in the top bar of every top-level tab (Map keeps its tab-bar
 * slot, design 14.1). The badge counts chats with unread messages plus pending requests.
 */
export function ChatsButton({ userId }: { userId: string }) {
  const { chats, requests } = useUnreadChats(userId);
  const count = chats + requests;
  const label = badgeLabel(count);
  return (
    <Link
      to="/chats"
      aria-label={label ? `Chats, ${count} unread` : "Chats"}
      className={cn(
        buttonVariants({ variant: "secondary", size: "icon-sm" }),
        "relative rounded-full",
      )}
    >
      <MessageCircle className="size-5" aria-hidden="true" />
      {label ? (
        <span
          aria-hidden="true"
          className="absolute -top-1 -right-1 flex h-[18px] min-w-[18px] items-center justify-center rounded-full bg-primary px-1 text-[11px] leading-none font-bold text-on-primary tabular ring-2 ring-surface"
        >
          {label}
        </span>
      ) : null}
    </Link>
  );
}
