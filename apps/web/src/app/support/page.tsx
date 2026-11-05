import type { Metadata } from "next";
import Link from "next/link";

// Placeholder until the mailbox exists (FOUNDER-TODO item 16); same address as /account/delete.
const SUPPORT_EMAIL = "support@activityplanet.app";

export const metadata: Metadata = {
  title: "Help",
  description:
    "How to get help with Activity Planet: write to support, report a problem, stay safe at plans, and delete your account.",
};

const LINKS: {
  href: "/safety" | "/guidelines" | "/account/delete" | "/refund-policy";
  title: string;
  body: string;
}[] = [
  {
    href: "/safety",
    title: "Safety Center",
    body: "Meeting people in person, blocking and reporting, and where to get urgent help.",
  },
  {
    href: "/guidelines",
    title: "Community Guidelines",
    body: "The five rules everyone agrees to before joining a plan.",
  },
  {
    href: "/refund-policy",
    title: "Refund and Cancellation Policy",
    body: "What happens when a coaching session is cancelled, missed or disputed.",
  },
  {
    href: "/account/delete",
    title: "Delete your account",
    body: "How to delete your account and what is removed.",
  },
];

/**
 * Help (the "Help" link in the app's sign-in and sign-up footer, apps/app routes/auth.tsx).
 * Static: the support address and the site pages that answer the common questions.
 */
export default function SupportPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Help</h1>
        <p className="text-lg text-text-2">
          Write to{" "}
          <a
            href={`mailto:${SUPPORT_EMAIL}`}
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            {SUPPORT_EMAIL}
          </a>{" "}
          and a person reads it. To report a person, plan, message or place, use Report in its menu
          in the app; a moderator looks at every report.
        </p>
      </header>

      <section className="flex flex-col gap-4">
        <h2 className="text-2xl font-semibold tracking-tight">More answers</h2>
        <ul className="flex flex-col gap-4">
          {LINKS.map(({ href, title, body }) => (
            <li key={href} className="flex flex-col gap-1">
              <Link
                href={href}
                className="font-semibold text-text underline-offset-2 hover:underline"
              >
                {title}
              </Link>
              <p className="text-text-2">{body}</p>
            </li>
          ))}
        </ul>
      </section>

      <p className="text-text-2">In an emergency, call your local emergency number first.</p>
    </main>
  );
}
