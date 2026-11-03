import { Link } from "@tanstack/react-router";
import { Bell } from "lucide-react";

import { buttonVariants } from "@/components/ui/button-variants";
import { cn } from "@/lib/cn";
import { badgeLabel, useUnreadCount } from "@/lib/notifications";

/** The Home top-bar bell: opens the inbox, with the unread count on a small badge. */
export function InboxBell({ userId }: { userId: string }) {
  const count = useUnreadCount(userId);
  const label = badgeLabel(count);
  return (
    <Link
      to="/inbox"
      aria-label={label ? `Inbox, ${count} unread` : "Inbox"}
      className={cn(
        buttonVariants({ variant: "secondary", size: "icon-sm" }),
        "relative rounded-full",
      )}
    >
      <Bell className="size-5" aria-hidden="true" />
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
