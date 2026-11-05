import { useEffect } from "react";
import { useQuery } from "@tanstack/react-query";

import { badgeCount, setAppBadge } from "@/lib/app-badge";
import { isStandalone } from "@/lib/install";
import { unreadChatsQuery } from "@/lib/messaging";
import { unreadCountQuery } from "@/lib/notifications";

/**
 * Mirrors the Chats and inbox badges onto the installed app's icon. It reads the queries the
 * top bar already keeps fresh (no extra polling) and renders nothing.
 */
export function AppBadge({ userId }: { userId: string }) {
  const standalone = isStandalone();
  const chats = useQuery({ ...unreadChatsQuery(userId), enabled: standalone });
  const inbox = useQuery({ ...unreadCountQuery(userId), enabled: standalone });
  const count = badgeCount([chats.data?.chats, chats.data?.requests, inbox.data]);
  const ready = chats.isSuccess || inbox.isSuccess;
  useEffect(() => {
    if (standalone && ready) setAppBadge(count);
  }, [standalone, ready, count]);
  // Signing out leaves the shell: clear the icon.
  useEffect(() => () => setAppBadge(0), []);
  return null;
}
