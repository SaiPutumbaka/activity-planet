import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Community Guidelines (draft)",
  description:
    "The rules everyone on Activity Planet agrees to before joining a plan: be real, show up, respect people and places, no harassment, adults only.",
};

/** The version this page shows; the five rules match the app's guidelines sheet. */
const VERSION = "guidelines 2026-11";

/** The five rules members accept at their first RSVP (apps/app guidelines-sheet.tsx). */
const RULES: [string, string][] = [
  ["Be real", "Your name, your face, your plans. No fake accounts."],
  ["Show up, or cancel early", "A spot you hold is a spot someone else wanted."],
  ["Respect the host and the space", "Their rules, their room. Leave it as you found it."],
  ["No harassment", "No threats, slurs or unwanted contact. Report it and we act."],
  ["18+ only", "Everyone here is an adult. Some plans are 21+."],
];

const MORE: [string, string][] = [
  [
    "Hate",
    "No attacks on people for their race, ethnicity, national origin, religion, caste, sexual orientation, sex, gender identity, disability or serious illness.",
  ],
  [
    "Sexual content and solicitation",
    "No sexual images, sexual messages to people who did not ask for them, or offers of sex for money. Never share an intimate image of someone without their consent.",
  ],
  [
    "Children",
    "Activity Planet is for adults. Any content that sexualises a minor is removed, the account is banned and we report it to the National Center for Missing & Exploited Children.",
  ],
  [
    "Meet in public",
    "Plans meet at public places. A private address is shared only with the people the host approves.",
  ],
  [
    "Alcohol",
    "Plans built around drinking are marked 21+ and only adults of that age can join them.",
  ],
  [
    "Selling and spam",
    "No repeated promotion, chain messages or links to get people off the app. Coaches offer sessions through their coach page, under the Coach Terms.",
  ],
  [
    "At the plan, too",
    "These rules apply to how you treat people at a plan, not only to what you post here.",
  ],
];

/**
 * Community Guidelines, DRAFT (TRUST-SAFETY-LEGAL section 6). Static. Linked from the app's
 * guidelines sheet (accepted at the first RSVP), the Safety Center and the Help page.
 */
export default function GuidelinesPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <p
        role="note"
        className="rounded-card border border-border bg-surface-2 px-4 py-3 text-sm font-semibold text-text"
      >
        DRAFT: pending review by an attorney.
      </p>
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Community Guidelines</h1>
        <p className="text-sm text-text-2">Version: {VERSION}</p>
        <p className="text-lg text-text-2">
          Everyone agrees to these before joining their first plan. They keep the people you meet
          here real and safe.
        </p>
      </header>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">The five rules</h2>
        <ol className="flex flex-col gap-4">
          {RULES.map(([title, body], i) => (
            <li key={title} className="flex gap-3 rounded-card border border-border p-4">
              <span className="font-semibold text-text-2 tabular-nums">{i + 1}.</span>
              <span className="flex flex-col gap-1">
                <span className="font-semibold text-text">{title}</span>
                <span className="text-text-2">{body}</span>
              </span>
            </li>
          ))}
        </ol>
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">What they cover</h2>
        <ul className="flex flex-col gap-4">
          {MORE.map(([title, body]) => (
            <li key={title} className="flex flex-col gap-1">
              <p className="font-semibold text-text">{title}</p>
              <p className="text-text-2">{body}</p>
            </li>
          ))}
        </ul>
      </section>

      <section className="flex flex-col gap-3 text-text-2">
        <h2 className="text-2xl font-semibold tracking-tight text-text">
          What happens when someone breaks them
        </h2>
        <p>
          Report a person, plan, message or place from its menu. A moderator looks at every report;
          we aim to act within 24 hours. Depending on what happened we remove the content, warn the
          account, limit it for a while or ban it. Reporting is private: the person is never told
          who reported them.
        </p>
        <p>
          If you think we got it wrong, reply to the notice or write to{" "}
          <a
            href="mailto:support@activityplanet.app"
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            support@activityplanet.app
          </a>{" "}
          and a different moderator takes another look.
        </p>
        <p>
          More on staying safe, and how to block or report, is in the{" "}
          <Link
            href="/safety"
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            Safety Center
          </Link>
          .
        </p>
      </section>
    </main>
  );
}
