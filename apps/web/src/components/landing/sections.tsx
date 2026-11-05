import Link from "next/link";
import type { ReactNode } from "react";
import { DefaultCover, Mark } from "@ap/ui/brand";

/** Section heading with an id the page can link to. */
function Heading({ id, children }: { id: string; children: ReactNode }) {
  return (
    <h2
      id={id}
      className="text-[26px] leading-tight font-extrabold tracking-[-0.02em] text-text sm:text-[30px]"
    >
      {children}
    </h2>
  );
}

export function Hero({ appUrl }: { appUrl: string }) {
  return (
    <section aria-labelledby="hero-title" className="flex flex-col gap-6 pt-6 sm:pt-10">
      <div className="flex flex-col gap-4">
        <h1
          id="hero-title"
          className="text-[36px] leading-[1.08] font-extrabold tracking-[-0.03em] text-balance text-text sm:text-[52px]"
        >
          Find your people and something to do with them this week.
        </h1>
        <p className="max-w-2xl text-[18px] leading-relaxed text-text-2">
          Hubs for every interest, real plans and real people, wherever you live. Tell it where you
          are and it shows what&apos;s happening around you first: plans posted by people near you,
          plus public events from local calendars.
        </p>
      </div>
      <div className="flex flex-wrap gap-3">
        <a
          href={appUrl}
          className="inline-flex h-12 items-center rounded-control bg-primary px-6 text-[16px] font-semibold text-on-primary hover:brightness-[1.03] focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-link"
        >
          Open the app
        </a>
        <a
          href="#this-week"
          className="inline-flex h-12 items-center rounded-control border border-border-strong bg-surface px-6 text-[16px] font-semibold text-text hover:bg-surface-2 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-link"
        >
          See what&apos;s on this week
        </a>
      </div>
      {/* The brand scene, drawn inline: no image request on the critical path. */}
      <div className="h-[140px] overflow-hidden rounded-card sm:h-[200px]">
        <DefaultCover seed="landing" />
      </div>
    </section>
  );
}

const STEPS = [
  {
    title: "Join hubs for what you're into",
    body: "Running, board games, climbing, language swaps, hundreds more. Pick a few to start.",
  },
  {
    title: "See plans near you",
    body: "Plans people post near you and public events from local calendars, in one place.",
  },
  {
    title: "Show up and meet people",
    body: "Tap Going, meet in a public place and keep in touch with the people you click with.",
  },
] as const;

export function HowItWorks() {
  return (
    <section aria-labelledby="how-it-works" className="flex flex-col gap-5">
      <Heading id="how-it-works">How it works</Heading>
      <ol className="grid grid-cols-1 gap-3 sm:grid-cols-3">
        {STEPS.map((s, i) => (
          <li
            key={s.title}
            className="flex flex-col gap-2 rounded-card border border-border bg-surface p-5"
          >
            <span
              aria-hidden="true"
              className="flex size-8 items-center justify-center rounded-full bg-primary-tint text-[15px] font-bold text-primary-text"
            >
              {i + 1}
            </span>
            <h3 className="text-[17px] font-bold text-text">{s.title}</h3>
            <p className="text-[15px] text-text-2">{s.body}</p>
          </li>
        ))}
      </ol>
    </section>
  );
}

const TRUST = [
  "Adults 18 and over only.",
  "Distance is shown in bands, never your address.",
  "Report and block on every profile, plan and chat.",
  "Moderators review reports within 24 hours.",
  "Meet in public places, and tell a friend where you're going.",
  "You can delete your account in the app at any time.",
] as const;

export function Trust() {
  return (
    <section
      aria-labelledby="trust"
      className="flex flex-col gap-5 rounded-card bg-surface-2 p-5 sm:p-8"
    >
      <Heading id="trust">Built for meeting people safely</Heading>
      <ul className="grid grid-cols-1 gap-x-6 gap-y-3 sm:grid-cols-2">
        {TRUST.map((t) => (
          <li key={t} className="flex gap-2.5 text-[15px] text-text">
            <CheckIcon />
            <span>{t}</span>
          </li>
        ))}
      </ul>
      <nav aria-label="Safety links" className="flex flex-wrap gap-x-5 gap-y-2 text-[15px]">
        <Link href="/safety" className="font-semibold text-link underline-offset-2 hover:underline">
          Safety Center
        </Link>
        <Link
          href="/safety/intimate-images"
          className="font-semibold text-link underline-offset-2 hover:underline"
        >
          Intimate image removal
        </Link>
        <Link
          href="/account/delete"
          className="font-semibold text-link underline-offset-2 hover:underline"
        >
          Delete your account
        </Link>
      </nav>
    </section>
  );
}

/**
 * The apps aren't in the stores yet, so there is no store badge artwork and no store link (both
 * companies' badge rules cover available apps only): two plain "Coming soon" pills.
 */
export function Apps({ appUrl }: { appUrl: string }) {
  return (
    <section aria-labelledby="apps" className="flex flex-col gap-4">
      <Heading id="apps">On your phone</Heading>
      <p className="max-w-2xl text-[16px] text-text-2">
        iPhone and Android apps are coming soon. Activity Planet works in your browser today, and
        you can add it to your home screen.
      </p>
      <ul className="flex flex-wrap gap-2" aria-label="Apps">
        <li className="inline-flex h-10 items-center rounded-control border border-border-strong px-4 text-[15px] font-semibold text-text">
          iPhone: coming soon
        </li>
        <li className="inline-flex h-10 items-center rounded-control border border-border-strong px-4 text-[15px] font-semibold text-text">
          Android: coming soon
        </li>
      </ul>
      <a
        href={appUrl}
        className="w-fit text-[15px] font-semibold text-link underline-offset-2 hover:underline"
      >
        Open it in your browser
      </a>
    </section>
  );
}

export function Footer() {
  return (
    <footer className="flex flex-col gap-4 border-t border-border pt-6 pb-10 text-[14px] text-text-2">
      <div className="flex items-center gap-2 text-text">
        <Mark size={22} />
        <span className="text-[15px] font-bold">Activity Planet</span>
      </div>
      <nav aria-label="Site" className="flex flex-wrap gap-x-5 gap-y-2">
        <Link href="/safety" className="underline-offset-2 hover:underline">
          Safety
        </Link>
        <Link href="/terms" className="underline-offset-2 hover:underline">
          Terms
        </Link>
        <Link href="/privacy" className="underline-offset-2 hover:underline">
          Privacy
        </Link>
        <Link href="/coach-terms" className="underline-offset-2 hover:underline">
          Coach terms
        </Link>
        <Link href="/refund-policy" className="underline-offset-2 hover:underline">
          Refund policy
        </Link>
        <Link href="/map-data" className="underline-offset-2 hover:underline">
          Map data
        </Link>
        <Link href="/account/delete" className="underline-offset-2 hover:underline">
          Delete account
        </Link>
      </nav>
      <p>For adults 18 and over, anywhere.</p>
    </footer>
  );
}

function CheckIcon() {
  return (
    <svg
      viewBox="0 0 20 20"
      width="20"
      height="20"
      aria-hidden="true"
      className="mt-0.5 shrink-0 text-going"
    >
      <path
        d="M5 10.5l3 3 7-7"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
