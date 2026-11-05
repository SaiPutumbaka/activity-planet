/**
 * The installed app's icon badge (RECS_DESIGN 9.4): unread chats plus unread notifications,
 * cleared at 0. Feature-detected; a no-op in a browser tab and wherever the Badging API is absent.
 */
type BadgeNavigator = Navigator & {
  setAppBadge?: (n?: number) => Promise<void>;
  clearAppBadge?: () => Promise<void>;
};

export function badgeCount(parts: readonly (number | null | undefined)[]): number {
  let n = 0;
  for (const p of parts) if (typeof p === "number" && Number.isFinite(p) && p > 0) n += p;
  return Math.min(Math.floor(n), 999);
}

export function setAppBadge(count: number): void {
  if (typeof navigator === "undefined") return;
  const nav = navigator as BadgeNavigator;
  try {
    if (count > 0) void nav.setAppBadge?.(count)?.catch(() => undefined);
    else void nav.clearAppBadge?.()?.catch(() => undefined);
  } catch {
    /* not allowed here */
  }
}
