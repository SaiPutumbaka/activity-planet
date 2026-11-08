import type { Metadata } from "next";
import Link from "next/link";

import { OPEN_DATA_CREDITS } from "@ap/core/imports";

import { APP_URL } from "@/lib/site";

export const metadata: Metadata = {
  title: "ActivityPlanetBot: our event collector",
  description:
    "What Activity Planet's event collector reads, what it never reads, how to block it, how to claim your listings and how to have them removed.",
};

/** The collector's User-Agent (packages/collector/src/net/fetcher.ts), shown so sites can match it. */
const USER_AGENT = "ActivityPlanetBot/0.1 (+https://activity-planet.vercel.app/bot)";

const link = "font-semibold text-text underline-offset-2 hover:underline";
const code =
  "block overflow-x-auto rounded-xl bg-surface-2 px-4 py-3 font-mono text-sm text-text whitespace-pre";

/**
 * The contact page the collector's User-Agent points to (D-040; COLLECTOR_COMPLETION 2.10 and
 * Slice 2): what it reads in each lane and what it never reads, in plain words, the User-Agent,
 * how to keep it out with robots.txt, how an organizer claims their listings, and the removal
 * form. Public, no sign-in.
 */
export default function BotPage() {
  return (
    <main className="mx-auto flex min-h-dvh max-w-2xl flex-col gap-10 px-4 py-16">
      <header className="flex flex-col gap-4">
        <p className="text-sm font-medium uppercase tracking-wide text-text-2">Activity Planet</p>
        <h1 className="text-4xl font-semibold tracking-tight break-words sm:text-5xl">
          ActivityPlanetBot
        </h1>
        <p className="text-lg text-text-2">
          Activity Planet helps adults find things to do near them, wherever they live. Alongside
          plans posted by members, it lists public events from local calendars. ActivityPlanetBot is
          the program that reads those calendars. If it visited your site, this page explains what
          it does and how to stop it.
        </p>
      </header>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What it reads</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>
            <strong className="text-text">Official event APIs</strong> used under their own terms,
            such as Ticketmaster and SeatGeek, and city open-data portals that publish event
            datasets.
          </li>
          <li>
            <strong className="text-text">Public calendar feeds</strong> (ICS and RSS), including
            the feed links a site lists in its page header.
          </li>
          <li>
            <strong className="text-text">Event structured data</strong> (schema.org{" "}
            <code className="font-mono text-sm">Event</code> in JSON-LD or microdata) on public
            pages, which sites add so search engines and aggregators can list their events.
          </li>
        </ul>
        <p className="text-text-2">
          From each event it keeps the facts (title, time, place, price, organizer and the link), a
          short excerpt of up to about 300 characters, and a link back to your page so people sign
          up with you. It does not copy images unless you license them to us.
        </p>
      </section>

      {OPEN_DATA_CREDITS.length > 0 ? (
        <section className="flex flex-col gap-3">
          <h2 className="text-2xl font-semibold tracking-tight">Open data we list</h2>
          <p className="text-text-2">
            Events from these open-data portals are listed under their licences. Each listing from
            them carries the same credit.
          </p>
          <ul className="flex flex-col gap-3">
            {OPEN_DATA_CREDITS.map((c) => (
              <li key={c.id} className="flex flex-col gap-1 rounded-xl bg-surface-2 px-4 py-3">
                <a href={c.portal} className={`${link} w-fit break-words`}>
                  {c.name}
                </a>
                <p className="text-text-2">{c.attribution}</p>
                <a href={c.licence.url} className={`${link} w-fit text-sm break-words`}>
                  {c.licence.name}
                </a>
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">What it never reads</h2>
        <ul className="list-disc space-y-2 pl-5 text-text-2">
          <li>Pages behind a login, and anything your robots.txt disallows.</li>
          <li>Pages marked noindex, and links marked nofollow when it looks for new calendars.</li>
          <li>
            Sites whose terms forbid automated collection: Facebook, Instagram, Threads, Meetup,
            LinkedIn, Handshake, Nextdoor, X, TikTok, and Eventbrite, Ticketmaster or SeatGeek web
            pages outside their official APIs.
          </li>
          <li>Private or internal network addresses, and anything over plain http.</li>
        </ul>
        <p className="text-text-2">
          It asks for at most one page every 2 seconds from a site (slower when your robots.txt sets
          a Crawl-delay), sends conditional requests so unchanged pages cost you almost nothing, and
          stops after a small number of pages per site per run.
        </p>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">How it identifies itself</h2>
        <p className="text-text-2">Every request carries this User-Agent:</p>
        <code className={code} tabIndex={0}>
          {USER_AGENT}
        </code>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">How to block it</h2>
        <p className="text-text-2">
          Add these lines to the robots.txt at the root of your site. The bot reads robots.txt
          before anything else and stops at the next run.
        </p>
        <code className={code} tabIndex={0}>
          {"User-agent: ActivityPlanetBot\nDisallow: /"}
        </code>
        <p className="text-text-2">
          To keep it off only part of your site, disallow just those paths. Blocking the bot stops
          new reads; to take down what is already listed, use the removal form below.
        </p>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">Are you the organizer?</h2>
        <p className="text-text-2">
          You can claim the listings that come from your website or calendar. Sign in to Activity
          Planet, open one of your events and tap <strong>Are you the organizer?</strong>. You prove
          you run the site in one of three free ways: a tag on your home page, a small file in your
          site&rsquo;s <code className="font-mono text-sm">/.well-known/</code> folder, or a DNS
          record. For a hosted calendar (Google Calendar, Outlook and the like), you paste a code
          into the calendar&rsquo;s description instead.
        </p>
        <p className="text-text-2">
          Once verified, your events say &ldquo;Listed by the organizer&rdquo;, and you can choose
          their hub, hide single events, stop the listing, or connect your own calendar feed.
          Imported listings link out to your page; they never take RSVPs on your behalf.
        </p>
        <a href={`${APP_URL}/organizer`} className={`${link} w-fit`}>
          Open your organizer page
        </a>
      </section>

      <section className="flex flex-col gap-3">
        <h2 className="text-2xl font-semibold tracking-tight">Have a listing removed</h2>
        <p className="text-text-2">
          Anyone can ask, with no account. Tell us the listing (or the whole calendar it came from)
          and a moderator takes it down, usually within 72 hours. A removed listing stays removed,
          even if another calendar lists the same event, and a removed calendar is never read again.
        </p>
        <Link
          href="/bot/remove"
          className="inline-flex w-fit items-center rounded-full bg-primary px-6 py-3 text-base font-semibold text-on-primary"
        >
          Request removal
        </Link>
      </section>
    </main>
  );
}
