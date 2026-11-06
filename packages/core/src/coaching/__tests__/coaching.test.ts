import { describe, expect, it } from "vitest";

import {
  addDays,
  bookingDetailSchema,
  bookingStatusLabel,
  bookingTimeline,
  cancelRefundPreview,
  coachFee,
  coachSchema,
  coachSearchRowSchema,
  coachingErrorCode,
  coachingErrorMessage,
  edgeFunctionError,
  dateKeyIn,
  durationLabel,
  formatPrice,
  fromPriceLabel,
  groupSlotsByDay,
  isPayable,
  parsePrice,
  paymentLine,
  ratingLabel,
  refundFor,
  requestsOnlyNote,
  sessionTimeLabel,
} from "../index";

// The same fixtures as supabase/functions/stripe-checkout/fees_test.ts and
// supabase/tests/coaching_payments.sql (private.coach_fee, private.booking_refund_minor).
describe("fees mirror private.coach_fee", () => {
  it("12% with the $3 minimum", () => {
    const fixtures: [number, number][] = [
      [4000, 480],
      [2000, 300],
      [10000, 1200],
      [2500, 300],
      [2600, 312],
    ];
    for (const [price, fee] of fixtures) expect(coachFee(price, 300)).toBe(fee);
    expect(coachFee(4000, null)).toBeNull();
    expect(coachFee(-1, 300)).toBeNull();
  });
  it("payable only at twice the minimum or more", () => {
    expect(isPayable(600, 300)).toBe(true);
    expect(isPayable(599, 300)).toBe(false);
    expect(isPayable(0, 300)).toBe(false);
    expect(isPayable(4000, undefined)).toBe(false);
  });
});

describe("refunds per Refund Policy row", () => {
  const start = new Date("2027-01-10T15:00:00Z");
  const freeUntil = new Date(start.getTime() - 24 * 3600 * 1000);
  const early = new Date(freeUntil.getTime() - 60_000);
  const late = new Date(freeUntil.getTime() + 60_000);
  it("client cancels early: full; late: half", () => {
    expect(refundFor(4000, "policy", freeUntil, early)).toBe(4000);
    expect(refundFor(4000, "policy", freeUntil, late)).toBe(2000);
    expect(refundFor(4001, "policy", freeUntil, late)).toBe(2001);
  });
  it("coach side full, client no-show none", () => {
    expect(refundFor(4000, "full", freeUntil, late)).toBe(4000);
    expect(refundFor(4000, "none", freeUntil, early)).toBe(0);
    expect(refundFor(0, "full", freeUntil, early)).toBe(0);
  });
  it("preview by role and state", () => {
    const b = {
      price_minor: 4000,
      free_cancel_until: freeUntil.toISOString(),
      status: "confirmed",
    };
    expect(cancelRefundPreview(b, "client", late)).toBe(2000);
    expect(cancelRefundPreview(b, "coach", late)).toBe(4000);
    expect(cancelRefundPreview({ ...b, status: "requested" }, "client", late)).toBe(0);
  });
});

describe("prices", () => {
  it("formats any currency in its minor unit", () => {
    expect(formatPrice(4000, "usd")).toBe("$40");
    expect(formatPrice(4250, "usd")).toBe("$42.50");
    expect(formatPrice(4000, "jpy")).toBe("¥4,000");
    expect(formatPrice(3000, "eur")).toBe("€30");
    expect(formatPrice(0, "usd")).toBe("Free");
  });
  it("parses what a coach types", () => {
    expect(parsePrice("40", "usd")).toBe(4000);
    expect(parsePrice("42.5", "usd")).toBe(4250);
    expect(parsePrice("4000", "jpy")).toBe(4000);
    expect(parsePrice("1.234", "usd")).toBeNull();
    expect(parsePrice("abc", "usd")).toBeNull();
    expect(parsePrice("-5", "usd")).toBeNull();
  });
  it("from price and rating", () => {
    expect(fromPriceLabel([{ currency: "usd", price_minor: 4000 }])).toBe("From $40");
    expect(fromPriceLabel([])).toBeNull();
    expect(ratingLabel(null, 0)).toBe("New");
    expect(ratingLabel(4.75, 12)).toBe("4.8 (12)");
    expect(durationLabel(90)).toBe("1 hour 30 min");
    expect(durationLabel(45)).toBe("45 min");
  });
});

describe("requests-only copy", () => {
  it("names the coach and never mentions a place or school", () => {
    const n = requestsOnlyNote("Sam");
    expect(n).toContain("arranged directly with Sam");
    expect(n).not.toMatch(/student|campus|atlanta/i);
  });
  it("payment line by mode", () => {
    expect(paymentLine({ price_minor: 0, payable: false }, true, "Sam")).toBe(
      "This session is free.",
    );
    expect(paymentLine({ price_minor: 4000, payable: true }, true, "Sam")).toMatch(
      /after the coach confirms/,
    );
    expect(paymentLine({ price_minor: 4000, payable: true }, false, "Sam")).toBe(
      requestsOnlyNote("Sam"),
    );
    expect(paymentLine({ price_minor: 4000, payable: false }, true, "Sam")).toBe(
      requestsOnlyNote("Sam"),
    );
  });
});

describe("slots in the viewer's zone", () => {
  const slots = [
    { starts_at: "2026-11-07T23:00:00Z", ends_at: "2026-11-08T00:00:00Z", seats_left: 1 },
    { starts_at: "2026-11-07T15:00:00Z", ends_at: "2026-11-07T16:00:00Z", seats_left: 1 },
  ];
  it("groups by viewer day with the coach's time when it differs", () => {
    const days = groupSlotsByDay(slots, "Europe/Berlin", "America/New_York", "Sam");
    expect(days.map((d) => d.key)).toEqual(["2026-11-07", "2026-11-08"]);
    expect(days[0]!.slots[0]!.label).toBe("4:00 PM");
    expect(days[0]!.slots[0]!.coachLabel).toBe("10:00 AM for Sam");
    expect(days[1]!.slots[0]!.label).toBe("12:00 AM");
    expect(days[1]!.slots[0]!.coachLabel).toBe("Sat, Nov 7, 6:00 PM for Sam");
  });
  it("no coach label in the same zone", () => {
    const days = groupSlotsByDay(slots, "America/New_York", "America/New_York", "Sam");
    expect(days).toHaveLength(1);
    expect(days[0]!.slots.every((s) => s.coachLabel === null)).toBe(true);
  });
  it("session label names the coach's time only when it differs", () => {
    const s = slots[1]!;
    expect(sessionTimeLabel(s.starts_at, s.ends_at, "America/New_York", "America/New_York")).toBe(
      "Sat, Nov 7 · 10:00 AM to 11:00 AM",
    );
    expect(
      sessionTimeLabel(s.starts_at, s.ends_at, "Europe/Berlin", "America/New_York", "Sam"),
    ).toBe("Sat, Nov 7 · 4:00 PM to 5:00 PM (Sat, Nov 7, 10:00 AM for Sam)");
  });
  it("date keys", () => {
    expect(dateKeyIn(new Date("2026-11-07T23:30:00Z"), "Asia/Tokyo")).toBe("2026-11-08");
    expect(addDays("2026-12-31", 1)).toBe("2027-01-01");
  });
});

const BOOKING = {
  id: "b1",
  role: "client",
  listing_id: "l1",
  status: "confirmed",
  title: "Tennis, one hour",
  delivery: "in_person",
  format: "one_on_one",
  starts_at: "2026-11-07T15:00:00Z",
  ends_at: "2026-11-07T16:00:00Z",
  price_minor: 4000,
  currency: "usd",
  payment_mode: "off_platform",
  payment_state: "off_platform",
  pay_by: null,
  other: { user_id: "u2", handle: "sam", first_name: "Sam", avatar_url: null },
  coach_timezone: "America/New_York",
  requested_at: "2026-11-05T10:00:00Z",
  expires_at: "2026-11-07T10:00:00Z",
  confirmed_at: "2026-11-05T11:00:00Z",
  declined_at: null,
  expired_at: null,
  paid_at: null,
  cancelled_at: null,
  cancelled_by: null,
  cancel_reason: null,
  completed_at: null,
  no_show_at: null,
  no_show_party: null,
  no_show_contested_at: null,
  free_cancel_until: "2026-11-06T15:00:00Z",
  policy_version: "2026-12",
};

describe("schemas", () => {
  it("parses get_booking with flags, defaulting missing ones to false", () => {
    const b = bookingDetailSchema.parse({ ...BOOKING, client_note: "", can_cancel: true });
    expect(b.can_cancel).toBe(true);
    expect(b.can_pay).toBe(false);
    expect(b.review).toBeNull();
  });
  it("a deleted other person reads as Deleted user", () => {
    const b = bookingDetailSchema.parse({ ...BOOKING, other: { user_id: null, first_name: null } });
    expect(b.other.first_name).toBe("Deleted user");
  });
  it("parses search rows with numeric strings", () => {
    const r = coachSearchRowSchema.parse({
      user_id: "u",
      handle: "sam",
      first_name: "Sam",
      headline: "Tennis",
      distance_band: "1-5 mi",
      rating_avg: "4.50",
      rating_count: 3,
      hub_ids: null,
    });
    expect(r.rating_avg).toBe(4.5);
    expect(r.hub_ids).toEqual([]);
  });
  it("credentials are always self-reported", () => {
    const c = coachSchema.parse({
      user_id: "u",
      handle: "sam",
      first_name: "Sam",
      status: "active",
      timezone: "UTC",
      in_person: true,
      online: false,
      credentials: [{ title: "USPTA", issuer: "", year: 2020, self_reported: false }],
    });
    expect(c.credentials[0]!.self_reported).toBe(true);
    expect(c.listings).toEqual([]);
  });
});

describe("labels and errors", () => {
  it("state labels from each side", () => {
    expect(bookingStatusLabel({ ...BOOKING, role: "coach", status: "requested" } as never)).toBe(
      "Waiting for you",
    );
    expect(
      bookingStatusLabel({ ...BOOKING, status: "declined", cancel_reason: "slot_taken" } as never),
    ).toBe("That time was just taken");
  });
  it("timeline in time order", () => {
    const t = bookingTimeline({ ...BOOKING, completed_at: "2026-11-07T17:00:00Z" } as never);
    expect(t.map((x) => x.key)).toEqual(["requested", "confirmed", "completed"]);
  });
  it("error codes to copy", () => {
    expect(coachingErrorCode({ message: "slot_unavailable" })).toBe("slot_unavailable");
    expect(coachingErrorCode({ message: "duplicate key value" })).toBe("");
    expect(coachingErrorMessage({ message: "invalid_shape" })).toMatch(/Online group/);
    expect(coachingErrorMessage({ message: "invalid_area" }, "km")).toMatch(/1 to 50 km/);
    expect(coachingErrorMessage({ message: "invalid_area" }, "mi")).toMatch(/1 to 31 mi/);
    expect(coachingErrorMessage({ message: "whatever_else" })).toBe(
      "Something went wrong. Try again.",
    );
  });
  it("Edge Function refusals carry their code (review: the raw invoke error hid it)", async () => {
    // supabase-js FunctionsHttpError: a generic message, the response in context.
    const httpError = (status: number, body: string) =>
      Object.assign(new Error("Edge Function returned a non-2xx status code"), {
        context: new Response(body, { status, headers: { "Content-Type": "application/json" } }),
      });
    for (const code of [
      "payments_off",
      "not_payable",
      "coach_terms_required",
      "not_a_coach",
      "no_account",
    ]) {
      const err = await edgeFunctionError(
        httpError(code === "payments_off" ? 503 : 409, JSON.stringify({ error: code })),
      );
      expect(coachingErrorCode(err)).toBe(code);
      expect(coachingErrorMessage(err)).not.toBe("Something went wrong. Try again.");
    }
    const notJson = await edgeFunctionError(httpError(500, "oops"));
    expect(coachingErrorCode(notJson)).toBe("");
    const network = new Error("Failed to fetch");
    expect(await edgeFunctionError(network)).toBe(network);
    expect(coachingErrorMessage({ message: "listing_unavailable" })).toMatch(
      /isn't taking bookings/,
    );
  });
});

describe("times follow the viewer's locale", () => {
  it("12-hour and month first in en-US, 24-hour and day first in de-DE", async () => {
    const { clockLabel, dayIn, timeIn } = await import("../display");
    const { localePrefs } = await import("../../locale/index");
    const de = localePrefs("de-DE");
    const us = localePrefs("en-US");
    const iso = "2026-11-07T23:00:00Z";
    expect(clockLabel("18:05", us)).toBe("6:05 PM");
    expect(clockLabel("18:05", de)).toBe("18:05");
    expect(timeIn(iso, "America/New_York", us)).toBe("6:00 PM");
    expect(timeIn(iso, "Europe/Berlin", de)).toBe("00:00");
    expect(dayIn(iso, "America/New_York", us)).toBe("Sat, Nov 7");
    expect(dayIn(iso, "Europe/Berlin", de)).toBe("Sun 8 Nov");
  });
});
