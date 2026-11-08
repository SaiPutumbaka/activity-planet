import type { Metadata } from "next";
import { LEGAL_VERSIONS } from "@ap/core/site";

export const metadata: Metadata = {
  title: "Privacy Policy (draft)",
  description:
    "The draft privacy policy for Activity Planet: what we collect, how location works, who processes it, how long we keep it, and how to delete your account.",
};

/** The version this page shows. Bump it when the text changes. */
const VERSION = LEGAL_VERSIONS.privacy;

const SUPPORT_EMAIL = "support@activityplanet.app";

const link = "font-semibold text-text underline-offset-2 hover:underline";

function Section({
  id,
  title,
  children,
}: {
  id?: string;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section id={id} className="flex scroll-mt-8 flex-col gap-3">
      <h2 className="text-2xl font-semibold tracking-tight">{title}</h2>
      <div className="flex flex-col gap-3 text-text-2">{children}</div>
    </section>
  );
}

function List({ items }: { items: [string, React.ReactNode][] }) {
  return (
    <ul className="flex flex-col gap-2">
      {items.map(([term, text]) => (
        <li key={term}>
          <strong className="text-text">{term}.</strong> {text}
        </li>
      ))}
    </ul>
  );
}

/** Who processes data for us (TRUST-SAFETY-LEGAL section 6), only services actually in use. */
const PROCESSORS: [string, React.ReactNode][] = [
  [
    "Supabase",
    "Our database, sign-in, file storage and server functions, hosted on Amazon Web Services in the United States. It holds everything described on this page. Recommendations are computed inside Supabase with its built-in text model; your data is not sent to an outside AI service.",
  ],
  [
    "Vercel",
    "Hosts this site and the web app. Like any web host it receives your IP address and the pages you request, and keeps short-lived request logs.",
  ],
  [
    "Resend",
    "Sends our emails (sign-in links when set up, verification codes and the notification emails you choose). It receives your email address and the message.",
  ],
  [
    "Google",
    "Only if you choose Sign in with Google: Google tells us your name and email address, and learns that you signed in to Activity Planet.",
  ],
  [
    "Geoapify",
    "Address and city search. When you type into a place or city search, the text you type and your IP address go to Geoapify, and to rank results near you, the rough point of your saved home. Our servers also send it the addresses of imported venues to place them on the map, with no member data.",
  ],
  [
    "OpenFreeMap",
    "Map tiles. Your device loads them directly, so OpenFreeMap receives your IP address and the area you are viewing.",
  ],
  [
    "GitHub (Pages)",
    "Hosts the public place files the map reads, one file per map area, so GitHub receives your IP address and the areas you load, never your hubs or your account.",
  ],
  [
    "OpenStreetMap (Nominatim)",
    "Our servers look up the addresses of imported venues when Geoapify isn't available. No member data is sent.",
  ],
  [
    "Ticketmaster and SeatGeek",
    "Sources of public event listings. Our servers search them by map area; they receive no member data. Following one of their links takes you to their site, under their own privacy policy.",
  ],
  [
    "Push services",
    "If you turn on notifications on a device, your browser's push service (run by Apple, Google or Mozilla, depending on the browser) delivers them and receives the notification's text.",
  ],
  [
    "Sightengine",
    "Checks photos sent in a chat before anyone sees them, for nudity, violence, hate symbols and similar content. Our servers send it the photo itself and nothing about you or the conversation; Sightengine returns scores and handles the photo under its own terms as our processor. When the check is unsure or unavailable, or a usage limit is reached (our monthly or daily allowance, or more than a few photos from one person in a day), a moderator looks at the photo instead.",
  ],
  [
    "Cloudflare Turnstile",
    "Where it is switched on, a bot check on the public request forms (intimate image removal and listing removal).",
  ],
  [
    "Eventbrite",
    "Only if you connect your own Eventbrite account to list your events: you sign in on Eventbrite, which tells us an access token for your account. We keep that token encrypted in Supabase Vault and use it to read your live events from Eventbrite's API, so Eventbrite receives it with each request. It is deleted with your account; you can also remove Activity Planet in your Eventbrite account settings.",
  ],
  [
    "Cloudflare DNS",
    "Only if you prove you own a website with a DNS record: our servers ask Cloudflare's public DNS for that record on the website's domain. No member data is sent.",
  ],
  [
    "Stripe",
    "Only when in-app payments are available: Stripe handles card payments and coach payouts, under its own privacy policy. We never see or store card numbers; we keep payment ids, amounts and dates.",
  ],
];

/** What stays after an account is deleted (TRUST-SAFETY-LEGAL section 11, D-031). */
const RETENTION: [string, string, string][] = [
  [
    "A record of the deletion: your account id, a one-way hash of your sign-in email, when you asked and why (if you said)",
    "30 days",
    "So a returning account can be tied to reports about the deleted one. A moderation hold can extend it.",
  ],
  ["Your old handle", "30 days", "So nobody can take it at once and pretend to be you."],
  [
    "A placeholder profile with no personal data (shown as “Deleted user”)",
    "As long as the content it is attached to",
    "Messages and plans other people received keep an author, and a ban still holds.",
  ],
  [
    "Past plans you hosted (title, description, time and rough area; never the exact address)",
    "As long as the plans are kept",
    "They are part of the history of the people who went. They show under “Deleted user”. Future plans you hosted are cancelled.",
  ],
  [
    "Messages you sent to others",
    "Until the conversation is deleted or expires (plan chats 90 days after the plan)",
    "They are part of the other people's history. They show under “Deleted user”.",
  ],
  [
    "Reports and moderation records",
    "As long as needed for safety",
    "Legal duties and safety. Reports you filed lose your name.",
  ],
  [
    "Copies of reported messages (with a few messages around them)",
    "90 days after the report is closed; one year for child-safety, intimate-image and underage reports",
    "So moderators can review the report and any appeal.",
  ],
  [
    "Your photos, when a child-safety or intimate-image report or removal request about your account was made in the year before you delete it",
    "One year, in private storage only moderators can open",
    "The law requires us to keep evidence of possible child sexual abuse material for a year (and to report it), and to handle intimate-image removal requests. Nothing else is kept.",
  ],
  [
    "Fingerprints (hashes) of images that were blocked for abuse",
    "While the block applies",
    "So the same image can't be uploaded again. Your other image fingerprints are deleted.",
  ],
  [
    "Booking and payment records (times, amounts, payment ids; never card data)",
    "Not deleted automatically",
    "Tax and accounting records. They show under “Deleted user”.",
  ],
  [
    "Public places you added that moderators reviewed",
    "While the place is on the map",
    "They are part of the open map data, without your name.",
  ],
];

/**
 * Privacy Policy, DRAFT (TRUST-SAFETY-LEGAL sections 6, 8, 11 and 12; D-031 retention;
 * FOUNDER-TODO item 13). Static. Linked from sign-up, the You tab, the Safety Center, every share
 * page and the footer. Not in effect until an attorney has reviewed it. Lists only data the
 * schema stores and processors the code uses; if either changes, this page changes with it.
 * Wording is for everyone, anywhere (D-040).
 */
export default function PrivacyPage() {
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
        <h1 className="text-4xl font-semibold tracking-tight sm:text-5xl">Privacy Policy</h1>
        <p className="text-sm text-text-2">Version: {VERSION}</p>
        <p className="text-lg text-text-2">
          This is what Activity Planet collects, why, who else handles it, how long we keep it, and
          what you can do about it. We don&rsquo;t sell your data, we don&rsquo;t show ads, and we
          don&rsquo;t use analytics or tracking tools in the app or on this site.
        </p>
      </header>

      <Section title="What we collect">
        <List
          items={[
            [
              "Your account",
              "Your email address, a password if you set one (stored by our sign-in provider as a hash), or your Google sign-in if you use it.",
            ],
            [
              "Your profile",
              "Your first name, handle, photo, short bio and the activities and groups you join. Other members can see these. Your date of birth is private: we use it to check you are 18 or older and to show 21+ plans only to members who are 21 or older.",
            ],
            [
              "A school or work email, if you verify one",
              "The address and the one-time code we send to it, to show a verified mark for that organization.",
            ],
            [
              "What you do in the app",
              "Plans you host or join, RSVPs and check-ins, who you said you met, chapters you organize, reviews, places you add or correct, reports you file, people you block or mute, and your notification settings.",
            ],
            [
              "Messages",
              "The messages you send and receive and when you read them. A deleted message's text is kept 30 days for safety reviews, then removed.",
            ],
            [
              "Chat photos",
              "Photos you send in a chat are stored privately, for the people in that conversation only. Each one is fingerprinted (a hash, to block images removed for abuse) and checked before it is shown: automatically by Sightengine, or, when that check is unsure or unavailable or a usage limit is reached (our monthly or daily allowance, or more than a few photos from one person in a day), by a moderator first, even if nobody reported it. A photo is deleted when its message is deleted, when the conversation expires, or with your account. If a photo is reported, a copy is kept as evidence for the report (see the table below).",
            ],
            [
              "Your agreement",
              "Which version of the Terms of Service and of this policy you accepted, and when.",
            ],
            [
              "Coaching",
              "If you coach: your coach profile, listings, credentials (shown as self-reported), photos, availability and the rough point and radius you coach in. If you book: your bookings, times, notes and the reviews you write.",
            ],
            [
              "Organizer tools",
              "If you claim an organization's event listings: the website or calendar you claimed, how you proved it, the check results and dates. If you connect an Eventbrite account: an access token for it, kept encrypted, and the events it lists. Moderators can see your claims, never the token.",
            ],
            [
              "Devices",
              "If you turn on notifications, the push address your browser gives us for that device. We also keep the time zone your device reports and when you last opened the app.",
            ],
            [
              "Recommendations",
              "A summary of the activities you engage with, kept as numbers, used to suggest plans, groups, people and coaches. In the You tab you can turn off personalized suggestions (they then use only distance and time) and people suggestions (you are then never suggested to anyone). Items you mark “Not interested” are kept 180 days.",
            ],
          ]}
        />
      </Section>

      <Section id="location" title="Location">
        <p>
          We ask for your device&rsquo;s location only when you tap &ldquo;Use my location&rdquo;,
          and never in the background. It is rounded to about 1 km on your device. On Home it is
          used for that visit only and not stored. When you are choosing your home area (when you
          sign up or change it), the rounded point becomes your saved home area. We keep a home area
          as a point rounded to about 1 km and a label; it is private to you and never shown on your
          profile. Other members see distances only as bands (&ldquo;1 to 5 mi&rdquo;), never your
          location.
        </p>
        <p>
          Plan addresses are kept with the plan. A host can keep the exact address to the people
          they approve; until then others see only a rough area.
        </p>
      </Section>

      <Section title="Map">
        <p>
          When you use the map, your device loads map tiles directly from OpenFreeMap, which
          receives your IP address and the area you are viewing, and place files from GitHub Pages
          in the same way. We do not log which areas or places you look at. If you add a place, we
          keep who added it so you can edit or delete your own pin and so moderators can act on
          abuse; that link is never shown to other members, never published, and is removed when you
          delete your account (private and pending places are deleted; reviewed public places stay
          without your name). Place reports and corrections are kept with the reason and the change,
          and lose your name when you delete your account. To decide which areas of the map to keep,
          we look at whether any active member&rsquo;s saved home area falls in a roughly 50 km
          square; we store only the day this was last true for that square, never who.
        </p>
      </Section>

      <Section id="device" title="On your device">
        <p>
          The app keeps a few things in your browser&rsquo;s storage so it works: your sign-in
          session (so you stay signed in), your theme, the last map view, whether you dismissed a
          prompt or said no to location, and, for the open tab only, your rounded location if you
          tapped &ldquo;Use my location&rdquo;. It also keeps an offline copy of the app itself so
          it opens on a poor connection, and, if you turn notifications on, a push subscription your
          browser manages. None of this is used for tracking or advertising, and there are no
          analytics or third-party cookies. Signing out removes your session; clearing the
          site&rsquo;s data in your browser removes the rest. This site uses no cookies except the
          bot check on the request forms.
        </p>
      </Section>

      <Section title="Imported listings">
        <p>
          Some plans are imported from public calendars and from Ticketmaster and SeatGeek. Their
          cover pictures may be loaded directly from the source&rsquo;s own servers (for example
          Ticketmaster&rsquo;s or SeatGeek&rsquo;s image hosts, or the organizer&rsquo;s website),
          so that server receives your IP address when you see the picture. Following a listing link
          takes you to the source under its own privacy policy.
        </p>
      </Section>

      <Section title="How we use it">
        <p>
          To run Activity Planet: show you plans, people and places near you, deliver messages and
          notifications, handle bookings, and keep the service working. To keep people safe: enforce
          the age limit, act on reports, block known abusive images, and stop spam and abuse with
          rate limits. We don&rsquo;t sell personal data or share it for advertising.
        </p>
        <p>
          Profile photos and covers are checked against a list of images that were removed for
          abuse, using fingerprints of the image (hashes), not face recognition. We never use photos
          for face recognition.
        </p>
      </Section>

      <Section title="Who can see what">
        <p>
          Members see your public profile, the plans you host, and, depending on the plan, that you
          are going. Someone you block can&rsquo;t see your profile, your RSVPs or your messages,
          and you can&rsquo;t see theirs. A plan&rsquo;s share page shows its title, description,
          time, rough area, group, going count and the host&rsquo;s first name, handle and photo to
          anyone with the link; never the exact address or the list of who is going.
        </p>
        <p>
          Moderators can see what is needed to act on a report, including a reported message, and a
          minimal account record (never your email, date of birth, location, blocks or other
          messages). Every account record a moderator opens is logged and the log is kept a year.
        </p>
      </Section>

      <Section title="Who processes it for us">
        <p>
          These services handle data on our behalf, or receive some directly from your device when
          you use a feature:
        </p>
        <List items={PROCESSORS} />
      </Section>

      <Section title="How long we keep it">
        <p>
          While your account is open we keep your data so the service works. Some things expire on
          their own: read notifications after 90 days, plan chats 90 days after the plan, the text
          of deleted messages after 30 days.
        </p>
        <p>
          When you delete your account, your profile details, photo, private details, memberships,
          devices, verified emails, organizer claims, your Eventbrite connection and roles are
          removed at once, calendars you connected stop, and your sign-in is closed. What we keep
          afterwards:
        </p>
        <div
          className="overflow-x-auto"
          tabIndex={0}
          role="region"
          aria-label="What is kept after an account is deleted"
        >
          <table className="w-full min-w-[32rem] border-collapse text-left text-sm">
            <caption className="sr-only">What is kept after an account is deleted</caption>
            <thead>
              <tr className="border-b border-border text-text">
                <th scope="col" className="py-2 pr-3 font-semibold">
                  What
                </th>
                <th scope="col" className="py-2 pr-3 font-semibold">
                  For how long
                </th>
                <th scope="col" className="py-2 font-semibold">
                  Why
                </th>
              </tr>
            </thead>
            <tbody>
              {RETENTION.map(([what, how, why]) => (
                <tr key={what} className="border-b border-border align-top">
                  <td className="py-2 pr-3">{what}</td>
                  <td className="py-2 pr-3">{how}</td>
                  <td className="py-2">{why}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section title="Your choices and rights">
        <p>
          You can change your profile, notification settings and suggestions in the app at any time.
          You can delete your account in the app (You, Delete my account), or by email as described
          on{" "}
          <a href="/account/delete" className={link}>
            the account deletion page
          </a>
          ; deletion is immediate, with no waiting period. You can download a copy of your data in
          the app (You, Download my data), as a file you can take to another service. For a
          correction, or anything else about your data, email{" "}
          <a href={`mailto:${SUPPORT_EMAIL}`} className={link}>
            {SUPPORT_EMAIL}
          </a>{" "}
          from the address on your account. Depending on where you live, you may have further
          rights, such as to object to some uses or to complain to your local data protection
          authority.
        </p>
      </Section>

      <Section title="Adults only">
        <p>
          Activity Planet is for people 18 and older. We don&rsquo;t knowingly collect data from
          anyone younger. If you believe someone under 18 is using it, report the account in the app
          or email us.
        </p>
      </Section>

      <Section title="Security and breaches">
        <p>
          Data is encrypted in transit, and access to it is limited by row-level rules in the
          database, so each person reads only what they are allowed to. No system is perfectly
          secure. If a breach affects your personal data, we will tell you, and the authorities, as
          the law where you live requires.
        </p>
      </Section>

      <Section title="Where data is processed">
        <p>
          Activity Planet is run from the United States and our main data store is there. If you use
          it from elsewhere, your data is transferred to and processed in the United States.
        </p>
      </Section>

      <Section title="Changes">
        <p>
          When this policy changes, we update the version above and post the new text here before it
          takes effect.
        </p>
      </Section>

      <Section title="Contact">
        <p>
          <a href={`mailto:${SUPPORT_EMAIL}`} className={link}>
            {SUPPORT_EMAIL}
          </a>
          . Safety concerns: the{" "}
          <a href="/safety" className={link}>
            Safety Center
          </a>
          .
        </p>
      </Section>
    </main>
  );
}
