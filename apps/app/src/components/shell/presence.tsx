import { useEffect } from "react";

import { touchPresence } from "@/lib/presence";

/**
 * Tells the database the member is here (last_seen_at, throttled): on entering the app and each
 * time it comes back to the foreground. Renders nothing.
 */
export function Presence() {
  useEffect(() => {
    touchPresence();
    const onVisible = () => {
      if (document.visibilityState === "visible") touchPresence();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, []);
  return null;
}
