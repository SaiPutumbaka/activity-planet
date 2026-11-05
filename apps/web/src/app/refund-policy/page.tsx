import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Refund and Cancellation Policy (draft)",
  description:
    "The draft refund and cancellation policy for coaching bookings on Activity Planet: what happens when a session is cancelled, missed or disputed.",
};

/** The version coaching_config() returns as policy_version (meta.refund_policy_version). */
const VERSION = "refund-policy 2026-12";

const ROWS: [string, string, string][] = [
  [
    "The coach declines, the request expires, or the time was just taken",
    "Nothing was charged.",
    "Nothing to settle.",
  ],
  [
    "You cancel at least 24 hours before the start",
    "Full refund, fee included.",
    "The expectation: you owe nothing.",
  ],
  [
    "You cancel less than 24 hours before the start",
    "50% refund.",
    "The expectation: half the price.",
  ],
  ["You don't come (not contested, or upheld)", "No refund.", "The expectation: the full price."],
  [
    "The coach cancels, doesn't come, or their account is closed or banned",
    "Full refund, fee included.",
    "The expectation: you owe nothing.",
  ],
  ["The coach blocks you", "Full refund.", "The booking is cancelled."],
  ["You block the coach", "As if you cancelled at that moment.", "The booking is cancelled."],
  [
    "A missed session is contested, or there's a problem with the session",
    "The refund waits for a moderator's decision (we aim for 24 hours).",
    "Moderators can cancel or mark the booking; the money is between the two of you.",
  ],
];

/**
 * Refund and Cancellation Policy, DRAFT (D-044; COACHING_DESIGN sections 3.7 and 10). Static.
 * Linked next to the acknowledgment on every booking request and from the booking page. The
 * window is stored on each booking, so a later version never changes an existing booking.
 */
export default function RefundPolicyPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <p
        role="note"
        className="rounded-card border border-border bg-surface-2 px-4 py-3 text-sm font-semibold text-text"
      >
        DRAFT: pending review by an attorney. Not yet in effect.
      </p>
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
          Refund and Cancellation Policy
        </h1>
        <p className="text-sm text-text-2">Version: {VERSION}</p>
        <p className="text-lg text-text-2">
          This policy applies to every coaching booking made on Activity Planet. The version you
          accepted is saved with your booking, so later changes never affect it.
        </p>
      </header>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">What happens when</h2>
        <ul className="flex flex-col gap-4">
          {ROWS.map(([when, paid, direct]) => (
            <li key={when} className="flex flex-col gap-1 rounded-card border border-border p-4">
              <p className="font-semibold text-text">{when}</p>
              <p className="text-text-2">
                <span className="font-medium text-text">Paid in the app:</span> {paid}
              </p>
              <p className="text-text-2">
                <span className="font-medium text-text">Paid directly to the coach:</span> {direct}
              </p>
            </li>
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3 text-text-2">
        <h2 className="text-2xl font-semibold tracking-tight text-text">When a refund arrives</h2>
        <p>
          Refunds for in-app payments are made by Stripe to the card you paid with, usually within 5
          to 10 business days.
        </p>
      </section>

      <section className="flex flex-col gap-3 text-text-2">
        <h2 className="text-2xl font-semibold tracking-tight text-text">
          Bookings paid directly to the coach
        </h2>
        <p>
          Where in-app payments aren&rsquo;t available, payment is arranged between you and the
          coach. This policy is the expectation for both of you, and Activity Planet is not a party
          to that payment. Our moderators can act on conduct, such as repeated no-shows, but not on
          money.
        </p>
      </section>

      <section className="flex flex-col gap-3 text-text-2">
        <h2 className="text-2xl font-semibold tracking-tight text-text">Raising a problem</h2>
        <p>
          Open the booking and choose &ldquo;Report a problem&rdquo;. A moderator looks at every
          report; we aim to answer within 24 hours. You can also write to support at{" "}
          <a
            href="mailto:support@activityplanet.app"
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            support@activityplanet.app
          </a>
          .
        </p>
      </section>
    </main>
  );
}
