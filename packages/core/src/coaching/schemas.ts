import { z } from "zod";

/**
 * Shapes of the coaching RPC results (migration 60, docs/design/coaching/COACHING_DESIGN.md
 * section 7). The generated types call every jsonb answer `Json`; these give them their real
 * shape. Unknown extra keys are dropped; a malformed optional field falls back to null.
 */

const id = z.string().min(1);
const nstr = z
  .string()
  .nullish()
  .catch(null)
  .transform((v) => v ?? null);
const nnum = z
  .number()
  .nullish()
  .catch(null)
  .transform((v) => v ?? null);
/** Postgres numeric comes back as a number or a string. */
const nnumeric = z
  .union([z.number(), z.string()])
  .nullish()
  .catch(null)
  .transform((v) => {
    if (v == null) return null;
    const n = typeof v === "number" ? v : Number.parseFloat(v);
    return Number.isFinite(n) ? n : null;
  });

export const LISTING_DELIVERIES = ["in_person", "online"] as const;
export const listingDeliverySchema = z.enum(LISTING_DELIVERIES);
export type ListingDelivery = z.infer<typeof listingDeliverySchema>;

export const LISTING_FORMATS = ["one_on_one", "group"] as const;
export const listingFormatSchema = z.enum(LISTING_FORMATS);
export type ListingFormat = z.infer<typeof listingFormatSchema>;

export const COACH_STATUSES = ["draft", "active", "paused", "suspended"] as const;
export const coachStatusSchema = z.enum(COACH_STATUSES);
export type CoachStatus = z.infer<typeof coachStatusSchema>;

export const LISTING_STATUSES = ["active", "paused", "archived"] as const;
export const listingStatusSchema = z.enum(LISTING_STATUSES);
export type ListingStatus = z.infer<typeof listingStatusSchema>;

export const BOOKING_STATUSES = [
  "requested",
  "confirmed",
  "declined",
  "expired",
  "cancelled",
  "completed",
  "no_show",
] as const;
export const bookingStatusSchema = z.enum(BOOKING_STATUSES);
export type BookingStatus = z.infer<typeof bookingStatusSchema>;

export const PAYMENT_STATES = [
  "none",
  "off_platform",
  "due",
  "processing",
  "paid",
  "refund_pending",
  "partially_refunded",
  "refunded",
  "disputed",
  "failed",
] as const;
export const paymentStateSchema = z.enum(PAYMENT_STATES);
export type PaymentState = z.infer<typeof paymentStateSchema>;

export const paymentModeSchema = z.enum(["none", "off_platform", "stripe"]);
export type PaymentMode = z.infer<typeof paymentModeSchema>;

/* ------------------------------------------------------------------ */
/* Config                                                               */
/* ------------------------------------------------------------------ */

export const coachingConfigSchema = z.object({
  payments_enabled: z.boolean().catch(false),
  policy_version: z.string(),
  coach_terms_version: z.string(),
  fee_percent: z.number().catch(12),
  fee_minimums: z.record(z.string(), z.number()).catch({}),
});
export type CoachingConfig = z.infer<typeof coachingConfigSchema>;

/* ------------------------------------------------------------------ */
/* Coach profile (get_coach)                                            */
/* ------------------------------------------------------------------ */

export const credentialSchema = z.object({
  title: z.string(),
  issuer: z.string().catch(""),
  year: nnum,
  self_reported: z.literal(true).catch(true),
});
export type Credential = z.infer<typeof credentialSchema>;

export const coachHubSchema = z.object({
  id,
  slug: z.string(),
  name: z.string(),
  emoji: nstr,
});
export type CoachHub = z.infer<typeof coachHubSchema>;

export const publicListingSchema = z.object({
  id,
  title: z.string(),
  description: z.string().catch(""),
  delivery: listingDeliverySchema,
  format: listingFormatSchema,
  capacity: z.number().catch(1),
  duration_minutes: z.number(),
  price_minor: z.number(),
  currency: z.string(),
  min_age: z.number().catch(18),
  hub_id: nstr,
  auto_confirm: z.boolean().catch(false),
  status: listingStatusSchema.catch("active"),
  min_notice_hours: z.number().catch(12),
  max_advance_days: z.number().catch(60),
  moderation_state: nstr,
  payable: z.boolean().catch(false),
});
export type PublicListing = z.infer<typeof publicListingSchema>;

export const reviewSchema = z.object({
  booking_id: id,
  rating: z.number(),
  body: z.string().catch(""),
  created_at: z.string(),
  edited_at: nstr,
  author: z
    .object({
      user_id: id,
      handle: nstr,
      first_name: z.string().catch("Member"),
      avatar_url: nstr,
    })
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  reply: nstr,
  replied_at: nstr,
  moderation_state: nstr,
  reply_moderation_state: nstr,
  mine: z.boolean().catch(false),
});
export type Review = z.infer<typeof reviewSchema>;

export const reviewCursorSchema = z.object({ created_at: z.string(), booking_id: id });
export type ReviewCursor = z.infer<typeof reviewCursorSchema>;

export const reviewsPageSchema = z.object({
  items: z.array(reviewSchema).catch([]),
  next: reviewCursorSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
});
export type ReviewsPage = z.infer<typeof reviewsPageSchema>;

export const coachSchema = z.object({
  user_id: id,
  handle: z.string(),
  first_name: z.string().catch("Coach"),
  avatar_url: nstr,
  status: coachStatusSchema,
  own: z.boolean().catch(false),
  headline: z.string().catch(""),
  about: z.string().catch(""),
  timezone: z.string(),
  area_label: z.string().catch(""),
  in_person: z.boolean(),
  online: z.boolean(),
  service_radius_km: nnum,
  rating_avg: nnumeric,
  rating_count: z.number().catch(0),
  completed_count: z.number().catch(0),
  published_at: nstr,
  terms_current: z
    .boolean()
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  credentials: z.array(credentialSchema).catch([]),
  photos: z.array(z.string()).catch([]),
  hubs: z.array(coachHubSchema).catch([]),
  listings: z.array(publicListingSchema).catch([]),
  from_prices: z.array(z.object({ currency: z.string(), price_minor: z.number() })).catch([]),
  reviews: reviewsPageSchema.catch({ items: [], next: null }),
  payments_enabled: z.boolean().catch(false),
});
export type Coach = z.infer<typeof coachSchema>;

/* ------------------------------------------------------------------ */
/* Search                                                               */
/* ------------------------------------------------------------------ */

export const searchCursorSchema = z.object({
  k1: z.number(),
  k2: z.number(),
  k3: z.number(),
  k4: z.union([z.number(), z.string()]),
  k5: z.union([z.number(), z.string()]),
  id,
});
export type SearchCursor = z.infer<typeof searchCursorSchema>;

export const coachSearchRowSchema = z.object({
  user_id: id,
  handle: z.string(),
  first_name: z.string().catch("Coach"),
  avatar_url: nstr,
  headline: z.string().catch(""),
  area_label: z.string().catch(""),
  distance_band: z.string().catch("online"),
  in_person: z.boolean().catch(false),
  online: z.boolean().catch(false),
  rating_avg: nnumeric,
  rating_count: z.number().catch(0),
  completed_count: z.number().catch(0),
  from_price_minor: nnum,
  from_currency: nstr,
  hub_ids: z
    .array(z.string())
    .nullish()
    .catch([])
    .transform((v) => v ?? []),
  page_key: searchCursorSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
});
export type CoachSearchRow = z.infer<typeof coachSearchRowSchema>;

/* ------------------------------------------------------------------ */
/* Slots                                                                */
/* ------------------------------------------------------------------ */

export const slotSchema = z.object({
  starts_at: z.string(),
  ends_at: z.string(),
  seats_left: z.number().catch(1),
});
export type Slot = z.infer<typeof slotSchema>;

/* ------------------------------------------------------------------ */
/* Bookings                                                             */
/* ------------------------------------------------------------------ */

export const bookingPersonSchema = z.object({
  user_id: nstr,
  handle: nstr,
  first_name: z
    .string()
    .nullish()
    .catch(null)
    .transform((v) => v ?? "Deleted user"),
  avatar_url: nstr,
});
export type BookingPerson = z.infer<typeof bookingPersonSchema>;

export const bookingSummarySchema = z.object({
  id,
  role: z.enum(["client", "coach"]),
  listing_id: nstr,
  status: bookingStatusSchema,
  title: z.string(),
  delivery: listingDeliverySchema,
  format: listingFormatSchema,
  starts_at: z.string(),
  ends_at: z.string(),
  price_minor: z.number(),
  currency: z.string(),
  payment_mode: paymentModeSchema,
  payment_state: paymentStateSchema,
  pay_by: nstr,
  other: bookingPersonSchema,
  coach_timezone: nstr,
  requested_at: z.string(),
  expires_at: nstr,
  confirmed_at: nstr,
  declined_at: nstr,
  expired_at: nstr,
  paid_at: nstr,
  cancelled_at: nstr,
  cancelled_by: nstr,
  cancel_reason: nstr,
  completed_at: nstr,
  no_show_at: nstr,
  no_show_party: nstr,
  no_show_contested_at: nstr,
  free_cancel_until: z.string(),
  policy_version: z.string().catch(""),
});
export type BookingSummary = z.infer<typeof bookingSummarySchema>;

const flag = z
  .boolean()
  .nullish()
  .catch(false)
  .transform((v) => v ?? false);

export const bookingDetailSchema = bookingSummarySchema.extend({
  client_note: z.string().catch(""),
  fee_minor: nnum,
  refunded_minor: z.number().catch(0),
  refund_if_cancelled_now: nnum,
  meeting_note: nstr,
  online_link: nstr,
  review: reviewSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  can_confirm: flag,
  can_decline: flag,
  can_cancel: flag,
  can_complete: flag,
  can_mark_no_show: flag,
  can_report_no_show: flag,
  can_contest: flag,
  can_review: flag,
  can_set_meeting: flag,
  can_pay: flag,
  can_message: flag,
});
export type BookingDetail = z.infer<typeof bookingDetailSchema>;

export const bookingCursorSchema = z.object({ starts_at: z.string(), id });
export type BookingCursor = z.infer<typeof bookingCursorSchema>;

export const bookingsPageSchema = z.object({
  items: z.array(bookingSummarySchema).catch([]),
  next: bookingCursorSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
});
export type BookingsPage = z.infer<typeof bookingsPageSchema>;

export const requestBookingResultSchema = z.object({
  id,
  status: bookingStatusSchema,
  payment_mode: paymentModeSchema,
  duplicate: z.boolean().catch(false),
});
export type RequestBookingResult = z.infer<typeof requestBookingResultSchema>;

export const cancelResultSchema = z.object({
  id,
  status: bookingStatusSchema,
  refund_minor: z.number().catch(0),
  currency: z.string().catch("usd"),
});
export type CancelResult = z.infer<typeof cancelResultSchema>;

export const payoutStatusSchema = z.object({
  payments_enabled: z.boolean().catch(false),
  state: z.enum(["none", "onboarding", "restricted", "active"]).catch("none"),
  requirements_due: z.number().catch(0),
  default_currency: nstr,
  country: nstr,
});
export type PayoutStatus = z.infer<typeof payoutStatusSchema>;

/* ------------------------------------------------------------------ */
/* The coach's own rows (owner RLS)                                     */
/* ------------------------------------------------------------------ */

export interface OwnListing {
  id: string;
  hub_id: string | null;
  title: string;
  description: string;
  delivery: ListingDelivery;
  format: ListingFormat;
  capacity: number;
  duration_minutes: number;
  price_minor: number;
  currency: string;
  buffer_minutes: number;
  min_notice_hours: number;
  max_advance_days: number;
  slot_step_minutes: number;
  auto_confirm: boolean;
  min_age: number;
  status: ListingStatus;
  moderation_state: string | null;
  meeting_note: string;
  online_link: string | null;
}

export interface AvailabilityRule {
  weekday: number;
  start: string;
  end: string;
  listing_id: string | null;
}

export interface AvailabilityException {
  id: string;
  kind: "unavailable" | "available";
  starts_at: string;
  ends_at: string;
  note: string;
}

/** Rows of a list, dropping any that do not parse. */
export function parseRowsOf<T>(schema: z.ZodType<T>, data: unknown): T[] {
  if (!Array.isArray(data)) return [];
  const out: T[] = [];
  for (const row of data) {
    const p = schema.safeParse(row);
    if (p.success) out.push(p.data);
  }
  return out;
}
