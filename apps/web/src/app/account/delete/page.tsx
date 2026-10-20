import type { Metadata } from "next";

const APP_URL = process.env.NEXT_PUBLIC_APP_URL ?? "https://app.activityplanet.app";
// Placeholder until the mailbox exists (FOUNDER-TODO item 16); the Privacy Policy must name the same address.
const SUPPORT_EMAIL = "support@activityplanet.app";

export const metadata: Metadata = {
  title: "Delete your account",
  description:
    "How to delete your Activity Planet account, what is removed right away, and what is kept for how long.",
};

/**
 * Public, reachable without the app or a sign-in: Google Play requires a web URL for account
 * deletion and Apple 5.1.1(v) requires the in-app path this page points to.
 */
export default function DeleteAccountPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Delete your account</h1>
        <p className="text-lg text-text-2">
          Deleting your account is immediate and cannot be undone. You can do it yourself in the app
          in under a minute, or email us if you can no longer sign in.
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">In the app</h2>
        <ol className="list-decimal space-y-2 pl-5 text-text-2">
          <li>Open Activity Planet and go to the You tab.</li>
          <li>Tap Delete my account at the bottom.</li>
          <li>
            Type <strong className="text-text">delete</strong> to confirm.
          </li>
        </ol>
        <a
          href={`${APP_URL}/you/delete`}
          className="inline-flex w-fit items-center rounded-full bg-primary px-5 py-3 text-base font-semibold text-on-primary"
        >
          Open the deletion screen
        </a>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">If you cannot sign in</h2>
        <p className="text-text-2">
          Email{" "}
          <a
            href={`mailto:${SUPPORT_EMAIL}?subject=Delete%20my%20account`}
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            {SUPPORT_EMAIL}
          </a>{" "}
          from the address on your account with the subject &ldquo;Delete my account&rdquo;. We
          reply to that same address to confirm it is you, delete the account, and confirm by email.
          This takes at most 30 days, usually a day or two.
        </p>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What is deleted right away</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>Your name, handle, photo, bio and campus.</li>
          <li>Your date of birth, email address and location.</li>
          <li>The hubs you joined, your notification settings and push registrations.</li>
          <li>Your sign-in. The email address can be used for a new account straight away.</li>
        </ul>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What is kept, and for how long</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>
            A deletion record (your account ID, a one-way hash of your email, the time and any
            reason you gave) for 30 days, so moderators can act on reports about the account.
          </li>
          <li>Your old handle is held for 30 days before anyone else can take it.</li>
          <li>
            Anything other people received from you, such as messages, stays with them with
            &ldquo;Deleted user&rdquo; as the sender.
          </li>
          <li>
            If you ever paid for something through Activity Planet, the payment record stays as long
            as tax law requires.
          </li>
        </ul>
        <p className="text-text-2">Nothing else is kept.</p>
      </section>

      <p className="text-sm text-text-2">
        Not affiliated with or endorsed by Georgia State University.
      </p>
    </main>
  );
}
