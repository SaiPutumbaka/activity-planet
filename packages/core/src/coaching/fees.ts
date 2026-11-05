// The application fee and the Refund Policy amounts (D-026; design sections 3.7 and 9.3). The
// same rules live in SQL (private.coach_fee, private.booking_refund_minor) and in the
// stripe-checkout Edge Function (supabase/functions/stripe-checkout/fees.ts), tested on the same
// fixtures (coaching/__tests__/fees.test.ts, fees_test.ts, supabase/tests/coaching_payments.sql).
// The server decides every amount; the app uses these only to preview.

/** max(12% rounded, the currency's minimum). Null when the currency has no minimum. */
export function coachFee(
  priceMinor: number,
  minFeeMinor: number | null | undefined,
): number | null {
  if (minFeeMinor == null || !Number.isInteger(priceMinor) || priceMinor < 0) return null;
  return Math.max(Math.round((priceMinor * 12) / 100), minFeeMinor);
}

/** Payable in the app only when the fee is at most half the price (price >= twice the minimum). */
export function isPayable(priceMinor: number, minFeeMinor: number | null | undefined): boolean {
  return minFeeMinor != null && priceMinor > 0 && priceMinor >= 2 * minFeeMinor;
}

export type RefundMode = "policy" | "full" | "none";

/**
 * Refund Policy 2026-12: "policy" is a client cancellation now (full at least 24 hours before the
 * start, half after); "full" is a coach cancellation, a coach no-show or a block by the coach;
 * "none" is a client no-show.
 */
export function refundFor(
  amountMinor: number,
  mode: RefundMode,
  freeCancelUntil: Date,
  at: Date,
): number {
  if (!(amountMinor > 0) || mode === "none") return 0;
  if (mode === "full" || at.getTime() < freeCancelUntil.getTime()) return amountMinor;
  return Math.round(amountMinor * 0.5);
}

/** What a cancellation by this side would refund now (the cancel sheet's preview). */
export function cancelRefundPreview(
  b: { price_minor: number; free_cancel_until: string; status: string },
  role: "client" | "coach",
  now: Date = new Date(),
): number {
  if (b.status !== "confirmed") return 0;
  return refundFor(
    b.price_minor,
    role === "client" ? "policy" : "full",
    new Date(b.free_cancel_until),
    now,
  );
}
