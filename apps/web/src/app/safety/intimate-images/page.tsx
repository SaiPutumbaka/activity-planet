import type { Metadata } from "next";

import { RequestForm } from "./request-form";

// Placeholder until the mailbox exists (FOUNDER-TODO item 16); same address as /account/delete.
const SUPPORT_EMAIL = "support@activityplanet.app";

export const metadata: Metadata = {
  title: "Remove an intimate image",
  description:
    "Ask Activity Planet to remove an intimate image of you that was shared without your consent. No account needed; we act within 48 hours.",
};

/**
 * Public, no sign-in: the Take It Down Act request page (migration 52, TRUST-SAFETY-LEGAL
 * section 3). The form posts to /api/takedown, which files submit_takedown_request; the request
 * lands in the moderators' queue with a 48-hour timer, and removed images are hashed so copies
 * and re-uploads are refused.
 */
export default function IntimateImageRemovalPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">
          Activity Planet safety
        </p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">
          Remove an intimate image
        </h1>
        <p className="text-lg text-text-2">
          If a nude, sexual or otherwise intimate image of you is on Activity Planet and you did not
          agree to it being shared, tell us here. You do not need an account. We remove the image
          and any copies we find within 48 hours of a complete request, and we stop it being
          uploaded again.
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What happens next</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>A moderator reviews your request, usually much sooner than 48 hours.</li>
          <li>
            We remove the image wherever it appears on Activity Planet. We keep a digital
            fingerprint of it (a hash, not the image), so the same picture, or a resized or re-saved
            copy, cannot be posted again.
          </li>
          <li>
            We may email you if we cannot find the image or need more detail. We never share your
            name or email with the person who posted it.
          </li>
          <li>
            If the person shown is under 18, it is urgent: we act within hours and report it to the
            National Center for Missing &amp; Exploited Children (NCMEC).
          </li>
        </ul>
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">Your request</h2>
        <RequestForm supportEmail={SUPPORT_EMAIL} />
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">More help</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>
            If you are in danger right now, call your local emergency number (911 in the United
            States).
          </li>
          <li>
            Images on other sites: StopNCII.org (adults) and Take It Down by NCMEC
            (takeitdown.ncmec.org, for images taken before 18) help remove them from many platforms
            without you sharing the image.
          </li>
          <li>
            Support for people affected by image abuse: the Cyber Civil Rights Initiative helpline,
            844-878-2274.
          </li>
        </ul>
        <p className="text-sm text-text-3">
          We keep your name, email and signature for a year after we close your request, then delete
          them. The image fingerprints are kept so the image stays blocked.
        </p>
      </section>
    </main>
  );
}
