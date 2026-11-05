import { bandText, type DistanceUnit } from "../feed/distance";
import type {
  BookingStatus,
  BookingSummary,
  ListingDelivery,
  ListingFormat,
  PaymentState,
  Slot,
} from "./schemas";

/**
 * Display rules for coaching (design sections 3.6, 4 and 9.1): prices in any currency, the
 * booking and payment state labels, the slot list grouped by day in the viewer's zone with the
 * coach's time beside it, and the requests-only note. Neutral copy for everyone (D-040).
 */

/** Digits after the decimal point for a currency (JPY 0, USD 2, KWD 3). */
export function currencyDigits(currency: string): number {
  try {
    return (
      new Intl.NumberFormat("en-US", {
        style: "currency",
        currency: currency.toUpperCase(),
      }).resolvedOptions().maximumFractionDigits ?? 2
    );
  } catch {
    return 2;
  }
}

/** "$40", "$42.50", "€30", "¥4,000"; "Free" for 0. Amounts are in the minor unit. */
export function formatPrice(minor: number, currency: string, locale = "en-US"): string {
  if (minor === 0) return "Free";
  const digits = currencyDigits(currency);
  const major = minor / 10 ** digits;
  try {
    return new Intl.NumberFormat(locale, {
      style: "currency",
      currency: currency.toUpperCase(),
      minimumFractionDigits: Number.isInteger(major) ? 0 : digits,
      maximumFractionDigits: digits,
    }).format(major);
  } catch {
    return `${major.toFixed(digits)} ${currency.toUpperCase()}`;
  }
}

/** Minor units from what a coach types ("40", "42.5"), or null when it is not a price. */
export function parsePrice(text: string, currency: string): number | null {
  const t = text.trim().replace(/,/g, "");
  if (!/^\d+(\.\d+)?$/.test(t)) return null;
  const digits = currencyDigits(currency);
  const [whole, frac = ""] = t.split(".");
  if (frac.length > digits) return null;
  const minor = Number(whole) * 10 ** digits + Number((frac + "000").slice(0, digits) || "0");
  return Number.isSafeInteger(minor) && minor <= 10_000_000 ? minor : null;
}

/** "From $40" from the lowest active price per currency (the first one). */
export function fromPriceLabel(
  prices: readonly { currency: string; price_minor: number }[],
): string | null {
  const p = prices[0];
  if (!p) return null;
  return p.price_minor === 0 ? "Free sessions" : `From ${formatPrice(p.price_minor, p.currency)}`;
}

export function durationLabel(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const h = Math.floor(minutes / 60);
  const m = minutes % 60;
  const hours = h === 1 ? "1 hour" : `${h} hours`;
  return m === 0 ? hours : `${hours} ${m} min`;
}

export const DELIVERY_LABELS: Record<ListingDelivery, string> = {
  in_person: "In person",
  online: "Online",
};

export const FORMAT_LABELS: Record<ListingFormat, string> = {
  one_on_one: "One-on-one",
  group: "Group",
};

export function listingShapeLabel(l: {
  delivery: ListingDelivery;
  format: ListingFormat;
  duration_minutes: number;
  capacity?: number;
}): string {
  const fmt =
    l.format === "group" && l.capacity ? `Group, up to ${l.capacity}` : FORMAT_LABELS[l.format];
  return `${DELIVERY_LABELS[l.delivery]} · ${fmt} · ${durationLabel(l.duration_minutes)}`;
}

/** "4.8 (12)" or "New" before any review. */
export function ratingLabel(avg: number | null, count: number): string {
  if (!count || avg == null) return "New";
  return `${avg.toFixed(1)} (${count})`;
}

/**
 * The distance band search returns ("<1 mi", "online") in the viewer's unit; never a distance.
 */
export function bandLabel(band: string, unit: DistanceUnit = "mi"): string {
  if (band === "online") return "Online";
  return unit === "km" ? bandText(band, unit) : band;
}

export const BOOKING_STATUS_LABELS: Record<BookingStatus, string> = {
  requested: "Requested",
  confirmed: "Confirmed",
  declined: "Not accepted",
  expired: "Expired",
  cancelled: "Cancelled",
  completed: "Completed",
  no_show: "Missed",
};

/** The state line on a booking, from the viewer's side. */
export function bookingStatusLabel(
  b: Pick<BookingSummary, "status" | "cancel_reason" | "no_show_party" | "role">,
): string {
  if (b.status === "declined" && b.cancel_reason === "slot_taken")
    return "That time was just taken";
  if (b.status === "requested")
    return b.role === "coach" ? "Waiting for you" : "Waiting for the coach";
  if (b.status === "no_show") {
    const you = b.no_show_party === b.role;
    return you
      ? "Marked as missed by you"
      : b.no_show_party === "coach"
        ? "Coach missed it"
        : "Client missed it";
  }
  return BOOKING_STATUS_LABELS[b.status];
}

export const PAYMENT_STATE_LABELS: Record<PaymentState, string> = {
  none: "No payment",
  off_platform: "Paid directly to the coach",
  due: "Payment due",
  processing: "Payment in progress",
  paid: "Paid",
  refund_pending: "Refund on its way",
  partially_refunded: "Partly refunded",
  refunded: "Refunded",
  disputed: "Payment disputed",
  failed: "Payment failed",
};

/**
 * Under every price on a booking screen while payment is arranged off the platform (design 9.1).
 * `coachName` is the coach's first name.
 */
export function requestsOnlyNote(coachName: string): string {
  return `Payment is arranged directly with ${coachName}. Activity Planet doesn't process payments for this booking. Agree on the amount and how you'll pay before you meet.`;
}

/** The payment line on a booking request sheet. */
export function paymentLine(
  l: { price_minor: number; payable: boolean },
  paymentsEnabled: boolean,
  coachName: string,
): string {
  if (l.price_minor === 0) return "This session is free.";
  if (paymentsEnabled && l.payable) return "Pay in the app after the coach confirms.";
  return requestsOnlyNote(coachName);
}

/* ------------------------------------------------------------------ */
/* Times                                                                */
/* ------------------------------------------------------------------ */

function fmt(d: Date, timeZone: string, opts: Intl.DateTimeFormatOptions): string {
  try {
    return new Intl.DateTimeFormat("en-US", { timeZone, ...opts }).format(d);
  } catch {
    return new Intl.DateTimeFormat("en-US", opts).format(d);
  }
}

/** "6:00 PM" in a zone. */
export function timeIn(iso: string, timeZone: string): string {
  return fmt(new Date(iso), timeZone, { hour: "numeric", minute: "2-digit" });
}

/** "Sat, Nov 7" in a zone. */
export function dayIn(iso: string, timeZone: string): string {
  return fmt(new Date(iso), timeZone, { weekday: "short", month: "short", day: "numeric" });
}

/** "2026-11-07" in a zone (the coach-local date coach_slots takes). */
export function dateKeyIn(d: Date, timeZone: string): string {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d);
  const get = (t: string) => parts.find((p) => p.type === t)?.value ?? "00";
  return `${get("year")}-${get("month")}-${get("day")}`;
}

/** A YYYY-MM-DD date plus n days. */
export function addDays(dateKey: string, n: number): string {
  const [y, m, d] = dateKey.split("-").map(Number) as [number, number, number];
  const t = new Date(Date.UTC(y, m - 1, d + n));
  return t.toISOString().slice(0, 10);
}

/** Short zone name ("EST", "GMT+1") for labels. */
export function zoneShort(iso: string, timeZone: string): string {
  try {
    const p = new Intl.DateTimeFormat("en-US", { timeZone, timeZoneName: "short" })
      .formatToParts(new Date(iso))
      .find((x) => x.type === "timeZoneName");
    return p?.value ?? timeZone;
  } catch {
    return timeZone;
  }
}

/** Two zones show the same wall clock at this instant. */
function sameWallClock(iso: string, a: string, b: string): boolean {
  if (a === b) return true;
  const opts: Intl.DateTimeFormatOptions = {
    year: "numeric",
    month: "numeric",
    day: "numeric",
    hour: "numeric",
    minute: "numeric",
  };
  return fmt(new Date(iso), a, opts) === fmt(new Date(iso), b, opts);
}

/**
 * "Sat, Nov 7 · 6:00 to 7:00 PM", plus "(3:00 PM for Sam)" when the coach's zone shows a
 * different time (design section 4: the viewer's zone first, the coach's labelled).
 */
export function sessionTimeLabel(
  startsAt: string,
  endsAt: string,
  viewerZone: string,
  coachZone?: string | null,
  coachName?: string | null,
): string {
  const base = `${dayIn(startsAt, viewerZone)} · ${timeIn(startsAt, viewerZone)} to ${timeIn(endsAt, viewerZone)}`;
  if (!coachZone || sameWallClock(startsAt, viewerZone, coachZone)) return base;
  const who = coachName ? `for ${coachName}` : "coach's time";
  return `${base} (${dayIn(startsAt, coachZone)}, ${timeIn(startsAt, coachZone)} ${who})`;
}

export interface SlotChoice extends Slot {
  /** "6:00 PM" in the viewer's zone. */
  label: string;
  /** "3:00 PM for Sam" when the coach's zone differs, else null. */
  coachLabel: string | null;
}

export interface SlotDay {
  /** YYYY-MM-DD in the viewer's zone. */
  key: string;
  /** "Sat, Nov 7". */
  label: string;
  slots: SlotChoice[];
}

/** Slots grouped by day in the viewer's zone, in time order, with the coach-zone label. */
export function groupSlotsByDay(
  slots: readonly Slot[],
  viewerZone: string,
  coachZone: string,
  coachName: string,
): SlotDay[] {
  const days = new Map<string, SlotDay>();
  const sorted = [...slots].sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at));
  for (const s of sorted) {
    const key = dateKeyIn(new Date(s.starts_at), viewerZone);
    let day = days.get(key);
    if (!day) {
      day = { key, label: dayIn(s.starts_at, viewerZone), slots: [] };
      days.set(key, day);
    }
    const differs = !sameWallClock(s.starts_at, viewerZone, coachZone);
    day.slots.push({
      ...s,
      label: timeIn(s.starts_at, viewerZone),
      coachLabel: differs
        ? `${dateKeyIn(new Date(s.starts_at), coachZone) !== key ? `${dayIn(s.starts_at, coachZone)}, ` : ""}${timeIn(s.starts_at, coachZone)} for ${coachName}`
        : null,
    });
  }
  return [...days.values()];
}

/** The steps a booking went through, with their times, for the booking page timeline. */
export function bookingTimeline(
  b: Pick<
    BookingSummary,
    | "requested_at"
    | "confirmed_at"
    | "declined_at"
    | "expired_at"
    | "paid_at"
    | "cancelled_at"
    | "cancelled_by"
    | "completed_at"
    | "no_show_at"
    | "no_show_contested_at"
    | "cancel_reason"
  >,
): { key: string; label: string; at: string }[] {
  const rows: { key: string; label: string; at: string | null }[] = [
    { key: "requested", label: "Requested", at: b.requested_at },
    { key: "confirmed", label: "Confirmed", at: b.confirmed_at },
    {
      key: "declined",
      label: b.cancel_reason === "slot_taken" ? "That time was just taken" : "Not accepted",
      at: b.declined_at,
    },
    { key: "expired", label: "Expired without an answer", at: b.expired_at },
    { key: "paid", label: "Paid", at: b.paid_at },
    {
      key: "cancelled",
      label:
        b.cancelled_by === "client"
          ? "Cancelled by the client"
          : b.cancelled_by === "coach"
            ? "Cancelled by the coach"
            : "Cancelled",
      at: b.cancelled_at,
    },
    { key: "completed", label: "Completed", at: b.completed_at },
    { key: "no_show", label: "Marked as missed", at: b.no_show_at },
    { key: "contested", label: "Missed session contested", at: b.no_show_contested_at },
  ];
  return rows
    .filter((r): r is { key: string; label: string; at: string } => Boolean(r.at))
    .sort((x, y) => Date.parse(x.at) - Date.parse(y.at));
}

export const WEEKDAYS = [
  { value: 1, label: "Monday", short: "Mon" },
  { value: 2, label: "Tuesday", short: "Tue" },
  { value: 3, label: "Wednesday", short: "Wed" },
  { value: 4, label: "Thursday", short: "Thu" },
  { value: 5, label: "Friday", short: "Fri" },
  { value: 6, label: "Saturday", short: "Sat" },
  { value: 7, label: "Sunday", short: "Sun" },
] as const;

/** "18:00" or "18:00:00" to "6:00 PM". */
export function clockLabel(hhmm: string): string {
  const [h = 0, m = 0] = hhmm.split(":").map(Number);
  const ampm = h >= 12 ? "PM" : "AM";
  const h12 = h % 12 === 0 ? 12 : h % 12;
  return `${h12}:${String(m).padStart(2, "0")} ${ampm}`;
}
