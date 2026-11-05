import type { ReactNode } from "react";
import type { Metadata } from "next";
import Link from "next/link";

// Placeholder until the mailbox exists (FOUNDER-TODO item 16); same address as /account/delete.
const SUPPORT_EMAIL = "support@activityplanet.app";

export const metadata: Metadata = {
  title: "Safety Center",
  description:
    "How to stay safe at Activity Planet plans, how blocking and reporting work, how fast we respond, and where to get help in an emergency.",
};

const SECTIONS = [
  { id: "in-person", title: "Meeting people in person" },
  { id: "blocking", title: "Blocking and muting" },
  { id: "reporting", title: "Reporting" },
  { id: "response", title: "How fast we respond" },
  { id: "images", title: "Intimate images" },
  { id: "emergencies", title: "Emergencies and urgent help" },
  { id: "rules", title: "Our rules" },
] as const;

function Section({
  id,
  title,
  children,
}: {
  id: (typeof SECTIONS)[number]["id"];
  title: string;
  children: ReactNode;
}) {
  return (
    <section id={id} aria-labelledby={`${id}-title`} className="flex scroll-mt-8 flex-col gap-3">
      <h2 id={`${id}-title`} className="text-2xl font-semibold tracking-tight">
        {title}
      </h2>
      {children}
    </section>
  );
}

function List({ children }: { children: ReactNode }) {
  return <ul className="list-disc space-y-2 pl-5 text-text-2">{children}</ul>;
}

const linkClass = "font-medium text-text underline underline-offset-2 hover:no-underline";

/**
 * Public, no sign-in: the Safety Center (PLAN 4.6 safety bullet and 4.11, TRUST-SAFETY-LEGAL
 * section 6). Written for anyone, anywhere (D-040): no school, city or country is assumed. The
 * response targets match the moderation queue (migrations 51 to 53): 24 hours for reports, 4 for
 * child safety, 48 for intimate images. Linked from the app's You tab and event pages and from
 * share pages.
 */
export default function SafetyCenterPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Safety Center</h1>
        <p className="text-lg text-text-2">
          Activity Planet is for doing things with people you haven&apos;t met yet: a pickup game, a
          run, a board game night. Most plans are just that. This page covers how to look after
          yourself when you meet people, the tools you have when something feels off, and what we do
          when you tell us.
        </p>
        <p
          role="note"
          className="rounded-lg border border-border bg-surface-2 p-4 text-base font-medium text-text"
        >
          In danger right now? Leave if you can and call your local emergency number: 911 in the
          United States and Canada, 112 across Europe, 999 in the UK, 000 in Australia. Activity
          Planet can&apos;t send help.
        </p>
      </header>

      <nav aria-label="On this page" className="flex flex-col gap-2">
        <p className="text-sm font-semibold text-text-2">On this page</p>
        <ul className="flex flex-wrap gap-x-4 gap-y-2 text-sm">
          {SECTIONS.map((s) => (
            <li key={s.id}>
              <a href={`#${s.id}`} className={linkClass}>
                {s.title}
              </a>
            </li>
          ))}
        </ul>
      </nav>

      <Section id="in-person" title="Meeting people in person">
        <List>
          <li>
            <strong className="text-text">Meet in public places.</strong> Parks, courts, gyms, cafes
            and community spaces are the best spots, especially the first time you meet someone. Be
            careful with plans at a private home when you don&apos;t know the host.
          </li>
          <li>
            <strong className="text-text">Tell a friend.</strong> Share the plan link with someone
            you trust: where you&apos;re going, when, and who&apos;s hosting. Let them know when
            you&apos;re home.
          </li>
          <li>
            <strong className="text-text">Look before you go.</strong> Check the host&apos;s profile
            and the plan&apos;s details. A brand-new profile with no photo or a plan with a vague
            location is worth a second look.
          </li>
          <li>
            <strong className="text-text">Get there and back your own way.</strong> Have your own
            ride home and keep your phone charged.
          </li>
          <li>
            <strong className="text-text">Keep your details to yourself.</strong> You don&apos;t
            need to share your home address, workplace or finances to join a plan. For plans that
            need the host&apos;s approval, the exact address is shared only once you&apos;re
            approved.
          </li>
          <li>
            <strong className="text-text">Know your limits.</strong> If there&apos;s alcohol, pace
            yourself and watch your drink. Plans marked 18+ or 21+ are only for people that age.
          </li>
          <li>
            <strong className="text-text">You can leave at any time.</strong> If something feels
            wrong, you don&apos;t owe anyone an explanation. Go, then tell us.
          </li>
          <li>
            <strong className="text-text">Hosting?</strong> Pick a public spot, say clearly what the
            plan is, and use host approval if you want to choose who comes. You can remove someone
            from your plan at any time.
          </li>
        </List>
      </Section>

      <Section id="blocking" title="Blocking and muting">
        <p className="text-text-2">
          Block someone from their profile. A block works both ways, and they aren&apos;t told:
        </p>
        <List>
          <li>
            Neither of you sees the other&apos;s profile, RSVPs or chapter and hub memberships.
          </li>
          <li>
            They stop showing up in your notifications and in the &quot;who did you meet&quot; list
            after a plan.
          </li>
          <li>
            If you&apos;re both going to the same plan, we let you know privately so you can decide
            whether to go. They aren&apos;t told.
          </li>
          <li>You can unblock someone from your settings later.</li>
        </List>
        <p className="text-text-2">
          Muting is quieter: you stop getting notifications about what that person does, and nothing
          else changes. They can&apos;t tell.
        </p>
      </Section>

      <Section id="reporting" title="Reporting">
        <p className="text-text-2">
          You can report a profile, a plan, a chapter, a hub or a place on the map. Choose the
          reason that fits best and add a note if it helps. Reports are private: the person you
          report never learns who reported them.
        </p>
        <List>
          <li>
            Report anything that breaks our rules: harassment, hate, threats, scams, spam,
            pretending to be someone else, sexual content, someone under 18, or an unsafe meetup or
            place.
          </li>
          <li>
            When several different people report the same profile, plan or chapter, it&apos;s hidden
            right away until a moderator reviews it.
          </li>
          <li>
            A moderator then decides: leave it, hide it, remove it, or ban the account. Moderators
            never review reports about themselves or things they posted; a second moderator does.
          </li>
          <li>
            Something happened at a plan? Report the plan or the person afterwards, even if it seems
            small. It helps us spot patterns.
          </li>
        </List>
        <p className="text-text-2">
          Can&apos;t use the app, or need to tell us more? Email{" "}
          <a href={`mailto:${SUPPORT_EMAIL}`} className={linkClass}>
            {SUPPORT_EMAIL}
          </a>
          .
        </p>
      </Section>

      <Section id="response" title="How fast we respond">
        <div className="overflow-hidden rounded-lg border border-border">
          <table className="w-full text-left text-sm">
            <caption className="sr-only">Our response targets</caption>
            <thead className="bg-surface-2 text-text-2">
              <tr>
                <th scope="col" className="px-4 py-2 font-semibold">
                  What you tell us about
                </th>
                <th scope="col" className="px-4 py-2 font-semibold">
                  Our target
                </th>
              </tr>
            </thead>
            <tbody className="divide-y divide-border">
              <tr>
                <th scope="row" className="px-4 py-3 font-medium">
                  Child safety
                </th>
                <td className="px-4 py-3 text-text-2">Within 4 hours</td>
              </tr>
              <tr>
                <th scope="row" className="px-4 py-3 font-medium">
                  Any other report
                </th>
                <td className="px-4 py-3 text-text-2">Within 24 hours</td>
              </tr>
              <tr>
                <th scope="row" className="px-4 py-3 font-medium">
                  An intimate image shared without consent
                </th>
                <td className="px-4 py-3 text-text-2">
                  Removed within 48 hours of a complete request (4 hours if the person shown may be
                  under 18)
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <p className="text-sm text-text-3">
          These are the most we aim to take; most reports are handled sooner. Our moderators track
          every one against these targets.
        </p>
      </Section>

      <Section id="images" title="Intimate images">
        <p className="text-text-2">
          If a nude, sexual or intimate image of you is on Activity Planet without your consent, ask
          us to remove it. You don&apos;t need an account, and you don&apos;t need to send us the
          image. We remove it within 48 hours and block copies from being uploaded again.
        </p>
        <p>
          <Link href="/safety/intimate-images" className={linkClass}>
            Request removal of an intimate image
          </Link>
        </p>
        <p className="text-text-2">
          For images on other sites, StopNCII.org (for adults) and Take It Down by NCMEC
          (takeitdown.ncmec.org, for images taken before 18) can help remove them from many
          platforms.
        </p>
      </Section>

      <Section id="emergencies" title="Emergencies and urgent help">
        <List>
          <li>
            <strong className="text-text">Immediate danger:</strong> call your local emergency
            number (911 in the United States and Canada, 112 across Europe, 999 in the UK, 000 in
            Australia). Then report it to us so we can act on the account or plan.
          </li>
          <li>
            <strong className="text-text">A child at risk:</strong> contact local police. In the
            United States you can also report to the NCMEC CyberTipline (report.cybertip.org or
            1-800-843-5678). We report child sexual abuse material we find to NCMEC.
          </li>
          <li>
            <strong className="text-text">Sexual assault:</strong> in the United States, the RAINN
            hotline is 800-656-4673. Elsewhere, your local emergency number or health service can
            point you to support near you.
          </li>
          <li>
            <strong className="text-text">Thinking about suicide or in crisis:</strong> in the
            United States and Canada, call or text 988. Elsewhere, findahelpline.com lists free,
            confidential lines by country.
          </li>
        </List>
      </Section>

      <Section id="rules" title="Our rules">
        <p className="text-text-2">
          Everyone on Activity Planet agrees to the Community Guidelines before joining a plan.
          Breaking them can mean content is removed or an account is banned.
        </p>
        <ul className="flex flex-wrap gap-x-5 gap-y-2">
          <li>
            <a href="/guidelines" className={linkClass}>
              Community Guidelines (draft)
            </a>
          </li>
          <li>
            <a href="/terms" className={linkClass}>
              Terms of Service
            </a>
          </li>
          <li>
            <a href="/privacy" className={linkClass}>
              Privacy Policy
            </a>
          </li>
          <li>
            <a href="/coach-terms" className={linkClass}>
              Coach Terms (draft)
            </a>
          </li>
          <li>
            <a href="/refund-policy" className={linkClass}>
              Refund and Cancellation Policy (draft)
            </a>
          </li>
          <li>
            <Link href="/account/delete" className={linkClass}>
              Delete your account
            </Link>
          </li>
        </ul>
      </Section>
    </main>
  );
}
