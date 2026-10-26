import { isHappeningNow, isOver } from "@/lib/datetime";
import type { RsvpStatus } from "@/lib/events";

/**
 * Board rule: states have a word and a hue. Green only means you're in, raspberry only means it is
 * happening, amber is capacity, red is the end of something, grey-blue is "came from" a source.
 */
export type StateTone = "going" | "live" | "warning" | "danger" | "info";

export interface EventState {
  tone: StateTone;
  label: string;
}

interface EventLike {
  status: "published" | "cancelled";
  starts_at: string;
  ends_at: string;
  capacity: number | null;
  going_count: number;
  kind: "member" | "chapter" | "imported";
  source_name: string | null;
}

/** Seats left, or null when the plan has no capacity. */
export function spotsLeft(e: { capacity: number | null; going_count: number }): number | null {
  return e.capacity === null ? null : Math.max(0, e.capacity - e.going_count);
}

export function isFull(e: { capacity: number | null; going_count: number }): boolean {
  return spotsLeft(e) === 0;
}

/** The one chip an event card or page shows about the event itself (not about the viewer). */
export function eventState(e: EventLike, now: Date = new Date()): EventState | null {
  if (e.status === "cancelled") return { tone: "danger", label: "Cancelled" };
  if (isOver(e.ends_at, now)) return { tone: "info", label: "Over" };
  if (isHappeningNow(e.starts_at, e.ends_at, now)) return { tone: "live", label: "Happening now" };
  if (e.kind === "imported") {
    return { tone: "info", label: e.source_name ? `From ${e.source_name}` : "Imported" };
  }
  const left = spotsLeft(e);
  if (left !== null) {
    if (left === 0) return { tone: "warning", label: "Full" };
    if (left <= 5)
      return { tone: "warning", label: `${left} ${left === 1 ? "spot" : "spots"} left` };
  }
  return null;
}

/** The viewer's own state, shown next to (never instead of) the event state. */
export function rsvpState(
  status: RsvpStatus | null | undefined,
  waitlistPosition?: number | null,
): EventState | null {
  switch (status) {
    case "going":
      return { tone: "going", label: "You're in" };
    case "waitlisted":
      return {
        tone: "warning",
        label: waitlistPosition ? `On the waitlist · #${waitlistPosition}` : "On the waitlist",
      };
    case "interested":
      return { tone: "info", label: "Interested" };
    default:
      return null;
  }
}

/** check_in accepts from an hour before the start until six hours after the end. */
export function inCheckInWindow(
  e: { starts_at: string; ends_at: string },
  now: Date = new Date(),
): boolean {
  const t = now.getTime();
  return (
    t >= new Date(e.starts_at).getTime() - 3_600_000 &&
    t <= new Date(e.ends_at).getTime() + 6 * 3_600_000
  );
}

/** Whether a Going tap can still do something (the RPC decides for real). */
export function canRsvp(e: EventLike, now: Date = new Date()): boolean {
  return e.status === "published" && !isOver(e.ends_at, now) && e.kind !== "imported";
}
