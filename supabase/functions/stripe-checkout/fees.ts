// The application fee and the Refund Policy amounts (D-026; design sections 3.7 and 9.3). The
// same rules live in SQL (private.coach_fee, private.booking_refund_minor) and are tested on the
// same fixtures (fees_test.ts, supabase/tests/coaching_payments.sql).

/** max(12% rounded, the currency's minimum). Amounts are in the currency's minor unit. */
export function coachFee(priceMinor: number, minFeeMinor: number | null): number | null {
  if (minFeeMinor === null || !Number.isInteger(priceMinor) || priceMinor < 0) return null;
  return Math.max(Math.round((priceMinor * 12) / 100), minFeeMinor);
}

/** Payable in the app only when the fee is at most half the price (price >= twice the minimum). */
export function isPayable(priceMinor: number, minFeeMinor: number | null): boolean {
  return minFeeMinor !== null && priceMinor > 0 && priceMinor >= 2 * minFeeMinor;
}

export type RefundMode = "policy" | "full" | "none";

/**
 * Refund Policy 2026-12: "policy" is a client cancellation now (full at least 24 hours before the
 * start, half after); "full" is a coach cancellation, a coach no-show or a block by the coach;
 * "none" is a client no-show. The fee comes back in proportion (refund_application_fee).
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
