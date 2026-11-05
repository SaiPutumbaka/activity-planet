import { useEffect, useSyncExternalStore } from "react";

/**
 * Connection state for the error screen. The service worker serves the app shell offline, but
 * every screen behind the tab bar reads the member's profile first, so without a connection the
 * route guard fails; the error screen then says so plainly and retries when the device is back.
 */
export function isOnline(): boolean {
  return typeof navigator === "undefined" || navigator.onLine !== false;
}

export function useOnline(): boolean {
  return useSyncExternalStore(
    (cb) => {
      if (typeof window === "undefined") return () => {};
      window.addEventListener("online", cb);
      window.addEventListener("offline", cb);
      return () => {
        window.removeEventListener("online", cb);
        window.removeEventListener("offline", cb);
      };
    },
    isOnline,
    () => true,
  );
}

/** Calls fn once when the device comes back online (for retrying a failed route load). */
export function useOnReconnect(fn: () => void): void {
  useEffect(() => {
    if (typeof window === "undefined") return;
    window.addEventListener("online", fn);
    return () => window.removeEventListener("online", fn);
  }, [fn]);
}

/** Thrown by route guards that need the network while the device is offline. */
export class OfflineError extends Error {
  constructor() {
    super("offline");
    this.name = "OfflineError";
  }
}

/** Network failures from fetch and supabase-js, which wrap them in plain objects. */
export function looksLikeNetworkError(error: unknown): boolean {
  if (error instanceof OfflineError) return true;
  const msg =
    error instanceof Error
      ? error.message
      : typeof error === "object" && error && "message" in error
        ? String((error as { message: unknown }).message)
        : "";
  return /failed to fetch|networkerror|network request failed|load failed|internet/i.test(msg);
}

export interface RouteErrorCopy {
  title: string;
  body: string;
  offline: boolean;
}

/** What the route error screen says: offline first, then the error's own message. */
export function routeErrorCopy(error: unknown, online: boolean): RouteErrorCopy {
  if (!online || looksLikeNetworkError(error)) {
    return {
      title: "You're offline",
      body: online
        ? "We couldn't reach Activity Planet. Check your connection and try again."
        : "Activity Planet needs a connection for this. It will try again when you're back online.",
      offline: true,
    };
  }
  return {
    title: "Something broke",
    body: error instanceof Error && error.message ? error.message : "Try again in a moment.",
    offline: false,
  };
}
