import { assertEquals } from "jsr:@std/assert@1.0.19";
import { coachFee, isPayable, refundFor } from "./fees.ts";

// The same fixtures as supabase/tests/coaching_payments.sql (private.coach_fee, booking_refund_minor).
Deno.test("fee: 12% with the $3 minimum", () => {
  const fixtures: [number, number][] = [
    [4000, 480],
    [2000, 300],
    [10000, 1200],
    [2500, 300],
    [2600, 312],
  ];
  for (const [price, fee] of fixtures) assertEquals(coachFee(price, 300), fee, `price ${price}`);
  assertEquals(coachFee(4000, null), null);
  assertEquals(coachFee(-1, 300), null);
});

Deno.test("payable only at twice the minimum or more", () => {
  assertEquals(isPayable(600, 300), true);
  assertEquals(isPayable(599, 300), false);
  assertEquals(isPayable(500, 300), false);
  assertEquals(isPayable(4000, null), false);
  assertEquals(isPayable(0, 300), false);
});

Deno.test("refunds per Refund Policy row", () => {
  const start = new Date("2027-01-10T15:00:00Z");
  const freeUntil = new Date(start.getTime() - 24 * 3600 * 1000);
  const early = new Date(freeUntil.getTime() - 60_000);
  const late = new Date(freeUntil.getTime() + 60_000);
  // Client cancels 24 hours or more before: full.
  assertEquals(refundFor(4000, "policy", freeUntil, early), 4000);
  // Client cancels inside 24 hours: half (rounded like SQL).
  assertEquals(refundFor(4000, "policy", freeUntil, late), 2000);
  assertEquals(refundFor(4001, "policy", freeUntil, late), 2001);
  // Coach cancels, coach no-show, coach banned or deleted, block by the coach: full.
  assertEquals(refundFor(4000, "full", freeUntil, late), 4000);
  // Client no-show: none.
  assertEquals(refundFor(4000, "none", freeUntil, early), 0);
  assertEquals(refundFor(0, "full", freeUntil, early), 0);
});
