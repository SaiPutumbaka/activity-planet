import { supabase } from "@/lib/supabase";

/** The database throttles to one write per 15 minutes; the app asks no more often than that. */
export const PRESENCE_INTERVAL_MS = 15 * 60 * 1000;

let lastSent = 0;

/** True when enough time has passed since the last presence write this session. */
export function presenceDue(now: number, last: number): boolean {
  return last === 0 || now - last >= PRESENCE_INTERVAL_MS;
}

/**
 * Records that the member opened the app (touch_last_seen). Fire and forget: a failure never
 * reaches the screen, and the next foreground visit tries again.
 */
export function touchPresence(now: number = Date.now()): void {
  if (!presenceDue(now, lastSent)) return;
  lastSent = now;
  void supabase
    .rpc("touch_last_seen")
    .then(({ error }) => {
      if (error) lastSent = 0;
    })
    .then(undefined, () => {
      lastSent = 0;
    });
}

/** Tests only. */
export function resetPresence(): void {
  lastSent = 0;
}
