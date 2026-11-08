import type { Metadata } from "next";
import { LEGAL_VERSIONS } from "@ap/core/site";

export const metadata: Metadata = {
  title: "Terms of Service (draft)",
  description:
    "The draft terms for using Activity Planet: who can join, plans and meeting people, what you post, imported listings, the map, safety, ending your account and the legal terms.",
};

/** The version this page shows. Bump it when the text changes. */
const VERSION = LEGAL_VERSIONS.terms;

const SUPPORT_EMAIL = "support@activityplanet.app";

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
 * Terms of Service, DRAFT (TRUST-SAFETY-LEGAL sections 6 and 12; FOUNDER-TODO item 13). Static.
 * Linked from sign-up, the You tab, the Safety Center, every share page and the footer. Not in
 * effect until an attorney has reviewed it. Every promise here is one the product keeps today;
 * a clause for something not built says so. Wording is for everyone, anywhere (D-040).
 */
export default function TermsPage() {
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
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Terms of Service</h1>
        <p className="text-sm text-text-2">Version: {VERSION}</p>
        <p className="text-lg text-text-2">
          Activity Planet helps adults find people to do things with: plans that members host,
          groups around an activity, a map of places, and coaches. These terms are the agreement
          between you and Activity Planet when you use the app or this site. Our{" "}
          <a href="/privacy" className={link}>
            Privacy Policy
          </a>{" "}
          says what we collect and why, and the{" "}
          <a href="/guidelines" className={link}>
            Community Guidelines
          </a>{" "}
          are part of these terms.
        </p>
      </header>

      <Section title="Who can use Activity Planet">
        <p>
          You must be 18 or older. Some plans and groups are for people 21 and older, and the app
          shows them only to members old enough. We ask for your date of birth when you join; an
          account we have reason to believe belongs to someone under 18 is suspended.
        </p>
        <p>
          One account per person, in your own name. Keep your sign-in details to yourself; you are
          responsible for what happens on your account. You can&rsquo;t use Activity Planet if we
          have banned you, or where the law doesn&rsquo;t allow you to.
        </p>
      </Section>

      <Section title="Plans and meeting people">
        <p>
          Plans are posted by members, not by Activity Planet. Hosts, chapter organizers and coaches
          are independent: they don&rsquo;t work for us, and we don&rsquo;t run, supervise or check
          their plans. We don&rsquo;t run background checks on anyone. A &ldquo;verified&rdquo; mark
          means only that a member confirmed an email address at an organization such as a school;
          it says nothing else about them.
        </p>
        <p>
          Sports, games, outings and meeting new people carry risks, including injury, loss of or
          damage to property, and other people&rsquo;s behaviour. You take part at your own risk and
          choose for yourself what is safe for you. Read the{" "}
          <a href="/safety" className={link}>
            Safety Center
          </a>
          : meet in public, tell a friend where you&rsquo;re going, and leave if something feels
          wrong. In an emergency, call your local emergency number first.
        </p>
        <p>
          Plans meet at public places by default. A host can keep the exact address for the people
          they approve. Hold a spot only if you mean to come, and cancel early if you can&rsquo;t.
        </p>
      </Section>

      <Section title="What you post">
        <p>
          You keep the rights to what you post: your profile, photos, plans, messages, reviews and
          the places you add. You give Activity Planet a worldwide, non-exclusive, royalty-free
          licence to host, store, copy, show and share it as needed to run the service (for example,
          to show your plan to the people it is meant for, or a share page to anyone who has its
          link), for as long as it is on Activity Planet and as described in the Privacy Policy
          after you delete it. Place facts are licensed differently; see &ldquo;Places and map
          data&rdquo; below.
        </p>
        <p>
          Post only what you have the right to post, and nothing that breaks the Community
          Guidelines or the law. We may hide, remove or limit anything that does, or anything that
          has been reported while we look at it, and we may suspend or ban accounts. We don&rsquo;t
          check everything before it appears, and we aren&rsquo;t responsible for what members post.
        </p>
      </Section>

      <Section title="Messages">
        <p>
          You can message members you share a plan, group or chapter with; a first message to anyone
          else is a request they can accept or decline. Moderators can read a message when someone
          reports it, to decide the report. Photos you send in a chat get an automatic check by our
          image-checking service before anyone sees them; when the check is unsure, unavailable or
          over its monthly allowance, a moderator looks at the photo before it is shown, even if
          nobody reported it. A photo that breaks the Community Guidelines is not delivered.
        </p>
      </Section>

      <Section title="Imported listings">
        <p>
          Some listings come from public calendars, feeds and partner services such as Ticketmaster
          and SeatGeek, not from members. We are not the organizer of those events. We show the
          facts, a short excerpt and a link to the source, which may be out of date or wrong: check
          with the organizer, and register or buy tickets at the source. Organizers can ask us to
          remove a listing from{" "}
          <a href="/bot/remove" className={link}>
            the removal page
          </a>
          .
        </p>
      </Section>

      <Section title="Places and map data">
        <p>
          The places on the Activity Planet map form a database made available under the{" "}
          <a href="https://opendatacommons.org/licenses/odbl/1-0/" className={link}>
            Open Database License 1.0 (ODbL)
          </a>
          . It includes data from OpenStreetMap, &copy; OpenStreetMap contributors, also available
          under the ODbL, and, in some areas, from Geoapify, which is built on OpenStreetMap data.
          When you add a place, or suggest a correction to one, you grant everyone a licence to the
          facts you contribute (its name, location, kind, address, opening hours and website) under
          the ODbL 1.0, and you confirm you have the right to share them. A place you keep to
          &ldquo;Only me&rdquo; is not published. Your name, account and any note you write to
          moderators are never part of a place and are not licensed. We may publish public places as
          an open download. We may edit, merge, hide or remove any place. Do not add a private home,
          a place that puts someone at risk, or anything you are not allowed to share.
        </p>
        <p>
          The map shows &ldquo;&copy; OpenStreetMap contributors&rdquo;, &ldquo;OpenMapTiles&rdquo;
          and &ldquo;OpenFreeMap&rdquo; at all times, and &ldquo;Powered by Geoapify&rdquo; while
          Geoapify places are on screen. Don&rsquo;t remove these credits from screenshots or embeds
          of the map. More on the{" "}
          <a href="/map-data" className={link}>
            map data page
          </a>
          .
        </p>
      </Section>

      <Section title="Coaching">
        <p>
          Coaches and their clients agree to the{" "}
          <a href="/coach-terms" className={link}>
            Coach Terms
          </a>{" "}
          and the{" "}
          <a href="/refund-policy" className={link}>
            Refund and Cancellation Policy
          </a>
          , both drafts too. Where in-app payments are not available, the coach and the client
          arrange payment between themselves and Activity Planet is not a party to it.
        </p>
      </Section>

      <Section title="Rules for using the service">
        <p>
          Don&rsquo;t use Activity Planet to harass, deceive or endanger anyone; to sell, advertise
          or spam; to collect other members&rsquo; information; to get around a block, a limit or a
          ban; or to break the law. Don&rsquo;t scrape, overload, probe or interfere with the
          service, and don&rsquo;t pretend to be someone else or to speak for Activity Planet.
        </p>
      </Section>

      <Section title="Copyright">
        <p>
          If you believe something on Activity Planet infringes your copyright, email{" "}
          <a href={`mailto:${SUPPORT_EMAIL}`} className={link}>
            {SUPPORT_EMAIL}
          </a>{" "}
          with the work, where it appears on Activity Planet, your contact details, a statement that
          you believe in good faith the use is not authorised, a statement that your notice is
          accurate and, under penalty of perjury, that you are the owner or authorised to act for
          them, and your physical or electronic signature. We remove infringing material and close
          the accounts of repeat infringers (three upheld copyright reports in three years). You can
          also report a post as a copyright problem in the app. For an intimate image shared without
          consent, use{" "}
          <a href="/safety/intimate-images" className={link}>
            the intimate image removal page
          </a>{" "}
          instead; it is faster.
        </p>
      </Section>

      <Section title="Not affiliated">
        <p>
          Activity Planet is independent. Unless a page says otherwise, it is not affiliated with or
          endorsed by any school, university, venue, league or event organizer named on it.
        </p>
      </Section>

      <Section title="Changes and availability">
        <p>
          Activity Planet is new and changes often. We may add, change or remove features, and the
          service may sometimes be unavailable. When we change these terms in a way that matters, we
          will update the version above and post the new text here before it takes effect. If you
          keep using Activity Planet after that, the new terms apply.
        </p>
      </Section>

      <Section title="Ending your account">
        <p>
          You can delete your account at any time from the You tab (Delete my account), or as
          described on{" "}
          <a href="/account/delete" className={link}>
            the account deletion page
          </a>
          . Deletion is immediate and can&rsquo;t be undone; the Privacy Policy lists what we keep
          afterwards and for how long. We may suspend or ban an account that breaks these terms or
          the Community Guidelines, or to protect members or the service. A banned member can appeal
          by emailing support.
        </p>
      </Section>

      <Section title="Disclaimers and liability">
        <p>
          Activity Planet is provided &ldquo;as is&rdquo; and &ldquo;as available&rdquo;. To the
          extent the law allows, we make no promises about the service, about members, hosts,
          coaches or organizers, or about any plan, place or listing, including that they are
          accurate, safe or suitable for you.
        </p>
        <p>
          To the extent the law allows, Activity Planet is not liable for indirect, incidental,
          special, consequential or punitive damages, or for anything that happens between members
          or at a plan, session or event, on or off the app. Our total liability for any claim about
          the service is limited to the greater of the amount you paid Activity Planet in the 12
          months before the claim and US$100. Some places don&rsquo;t allow some of these limits, so
          they may not all apply to you; nothing here limits rights you have under the law that
          can&rsquo;t be limited.
        </p>
        <p>
          You agree to cover Activity Planet&rsquo;s reasonable costs and losses from a claim made
          by someone else that results from what you posted, how you used the service or your
          breaking these terms.
        </p>
      </Section>

      <Section title="Governing law and disputes">
        <p>
          These terms are governed by the laws of the State of Georgia, United States, without
          regard to its conflict-of-law rules. Disputes are decided by the state or federal courts
          located in Fulton County, Georgia, unless the law where you live gives you the right to
          bring a claim in your local courts. Before going to court, email us and give us 30 days to
          try to resolve it.
        </p>
      </Section>

      <Section title="Contact">
        <p>
          Questions about these terms:{" "}
          <a href={`mailto:${SUPPORT_EMAIL}`} className={link}>
            {SUPPORT_EMAIL}
          </a>
          . To report a person or a plan, use Report in the app or the{" "}
          <a href="/safety" className={link}>
            Safety Center
          </a>
          .
        </p>
      </Section>
    </main>
  );
}
