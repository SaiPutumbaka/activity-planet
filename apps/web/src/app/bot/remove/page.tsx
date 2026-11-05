import type { Metadata } from "next";
import Link from "next/link";
import { isEventId } from "@ap/core/validation";

import { RequestForm } from "./request-form";

// Placeholder until the mailbox exists (FOUNDER-TODO item 16); same address as /account/delete.
const SUPPORT_EMAIL = "support@activityplanet.app";

export const metadata: Metadata = {
  title: "Remove a listing",
  description:
    "Ask Activity Planet to take down an event listing we collected from a public calendar, or everything from that calendar. No account needed.",
};

/**
 * Public, no sign-in: the listing removal request (migration 62, COLLECTOR_COMPLETION 2.1). The
 * form posts to /api/listing-removal, which files submit_listing_removal with the service role
 * after its Turnstile check; the request lands in the moderators' queue with a 72-hour timer.
 * "Request removal" on every imported item links here with ?event=<id>.
 */
export default async function ListingRemovalPage({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const params = await searchParams;
  const raw = Array.isArray(params.event) ? params.event[0] : params.event;
  const eventId = isEventId(raw) ? raw.toLowerCase() : null;
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">
          <Link href="/bot" className="underline-offset-2 hover:underline">
            ActivityPlanetBot
          </Link>
        </p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Remove a listing</h1>
        <p className="text-lg text-text-2">
          Activity Planet lists public events from local calendars, with a link back to the source.
          If you organize an event, run the venue or hold rights in what we show and want it taken
          down, tell us here. You do not need an account.
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What happens next</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>A moderator reviews your request, usually within 72 hours.</li>
          <li>
            <strong className="text-text">This listing:</strong> the event comes down and stays
            down, even if another calendar lists it too.
          </li>
          <li>
            <strong className="text-text">Everything from the source:</strong> every event from that
            calendar comes down and we stop reading it. For your own website, we stop reading the
            whole site.
          </li>
          <li>
            If you run the calendar and would rather keep it listed under your control, you can{" "}
            <Link
              href="/bot"
              className="font-semibold text-text underline-offset-2 hover:underline"
            >
              claim it instead
            </Link>
            .
          </li>
          <li>
            A plan a member posted is not a collected listing; use Report on its page in the app.
          </li>
        </ul>
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">Your request</h2>
        <RequestForm supportEmail={SUPPORT_EMAIL} eventId={eventId} />
      </section>

      <p className="text-sm text-text-3">
        We keep your name, email and reason for a year after we close your request, then delete
        them. The reference, the dates and the outcome stay.
      </p>
    </main>
  );
}
