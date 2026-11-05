import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Coach Terms (draft)",
  description:
    "The draft terms for coaches on Activity Planet: who can coach, listings, cancellations, the platform fee, payouts, taxes and conduct.",
};

/** The version coaching_config() returns as coach_terms_version (meta.coach_terms_version). */
const VERSION = "coach-terms 2026-12";

const link = "font-semibold text-text underline-offset-2 hover:underline";

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-3">
      <h2 className="text-2xl font-semibold tracking-tight">{title}</h2>
      <div className="flex flex-col gap-3 text-text-2">{children}</div>
    </section>
  );
}

/**
 * Coach Terms, DRAFT (D-044; COACHING_DESIGN section 10; TRUST-SAFETY-LEGAL 5). Static. Linked
 * from the coach setup screen (the accept checkbox), the payouts screen and the site footer. Not
 * in effect until an attorney has reviewed it. Wording is for everyone, anywhere (D-040).
 */
export default function CoachTermsPage() {
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
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Coach Terms</h1>
        <p className="text-sm text-text-2">Version: {VERSION}</p>
        <p className="text-lg text-text-2">
          These terms apply when you offer coaching, lessons or sessions on Activity Planet. They
          add to our Terms of Service and Community Guidelines.
        </p>
      </header>

      <Section title="Who can coach">
        <p>
          You must be 18 or older and legally allowed to do paid work where you coach. In the United
          States that means you are authorized to work; some visa holders, such as many student visa
          holders, generally may not take paid work. Check the rules that apply to you before you
          accept money for a session.
        </p>
      </Section>

      <Section title="You are an independent provider">
        <p>
          You run your own coaching. Activity Planet is a facilitator: we help people find you, book
          a time and message you. We are not your employer and we are not a party to the coaching
          itself.
        </p>
      </Section>

      <Section title="Your listings and credentials">
        <p>
          Describe your sessions, prices and experience accurately. Credentials you add are shown as
          self-reported: we don&rsquo;t verify them, and you are responsible for what you claim.
        </p>
      </Section>

      <Section title="Places and safety">
        <p>
          Meet in public places. If you coach at a venue, getting its permission is your
          responsibility. The Community Guidelines apply at sessions too, not only in the app.
          Session addresses and call links are shared only with confirmed clients.
        </p>
      </Section>

      <Section title="What can be offered">
        <p>
          In-person one-on-one, in-person group and online one-on-one sessions can be listed. Online
          group sessions are not offered at launch, because app stores treat them as digital
          products that must be sold through in-app purchase.
        </p>
      </Section>

      <Section title="Cancellations and no-shows">
        <p>
          Every booking follows the{" "}
          <a href="/refund-policy" className={link}>
            Refund and Cancellation Policy
          </a>
          . You can&rsquo;t set your own window yet. If you cancel, your client gets a full refund.
          Repeated late cancellations are reviewed by our moderators.
        </p>
        <p>
          You can mark a client as absent from 15 minutes after the start; a client can report that
          you didn&rsquo;t come. Either side can contest within 48 hours. Moderators decide
          contested cases, and you can appeal to support.
        </p>
      </Section>

      <Section title="Payments">
        <p>
          <strong className="text-text">Requests only.</strong> Where in-app payments aren&rsquo;t
          available, clients book through the app and you arrange payment directly with them.
          Activity Planet is not a party to that payment.
        </p>
        <p>
          <strong className="text-text">In-app payments.</strong> Where they are available, clients
          pay after you confirm, through Stripe. The platform fee is 12% of the price, at least $3
          in USD (minimums in other currencies as they open). Activity Planet pays the card
          processing out of that fee. When a refund is made, the fee is refunded in proportion.
          Payouts are made by Stripe under the{" "}
          <a href="https://stripe.com/connect-account/legal" className={link}>
            Stripe Connected Account Agreement
          </a>
          , which is part of these terms when you use in-app payments.
        </p>
        <p>
          Chargebacks and refunds are taken back from your Stripe balance. Repeated disputes can
          lead to suspension.
        </p>
      </Section>

      <Section title="Taxes">
        <p>You are responsible for any taxes on what you earn from coaching.</p>
      </Section>

      <Section title="Reviews">
        <p>
          Clients can review a completed session. You can post one reply to each review. Reviews and
          replies follow the Community Guidelines and can be reported.
        </p>
      </Section>

      <Section title="Ending">
        <p>
          You can pause or close your coach profile at any time; open bookings are cancelled with
          full refunds to your clients. We can suspend a coach profile that breaks these terms or
          the Community Guidelines.
        </p>
      </Section>

      <Section title="Governing law">
        <p>The governing law and dispute terms are those in our Terms of Service.</p>
      </Section>
    </main>
  );
}
