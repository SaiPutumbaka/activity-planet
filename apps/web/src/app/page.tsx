import type { Metadata } from "next";
import { Figtree } from "next/font/google";
import Link from "next/link";
import { Mark } from "@ap/ui/brand";

import { Apps, Footer, Hero, HowItWorks, Trust } from "@/components/landing/sections";
import { WeekNearYou } from "@/components/landing/week-near-you";
import { APP_URL } from "@/lib/site";
import { getWeekNear } from "@/lib/week";

/**
 * Landing page v2 (RECS_DESIGN section 8): the hero, a live "This week near you" (Atlanta on the
 * server, a picked city or a shared point in the browser, never an IP lookup), how it works, the
 * trust section, the apps note and the footer. No waitlist. Re-rendered at most every 10 minutes.
 */
export const revalidate = 600;

const figtree = Figtree({ subsets: ["latin"], display: "swap" });

export const metadata: Metadata = {
  title: { absolute: "Activity Planet: find your people and something to do this week" },
  description:
    "Hubs for every interest, real plans and real people, wherever you live. See what's on near you this week. For adults 18 and over.",
  alternates: { canonical: "/" },
};

export default async function LandingPage() {
  const cards = await getWeekNear(null);
  return (
    <div className={`${figtree.className} min-h-dvh bg-surface text-text`}>
      <header className="mx-auto flex w-full max-w-5xl items-center justify-between px-4 py-4 sm:px-6">
        <Link href="/" className="inline-flex items-center gap-2" aria-label="Activity Planet home">
          <Mark size={28} />
          <span className="text-[17px] font-bold tracking-[-0.01em]">Activity Planet</span>
        </Link>
        <a
          href={APP_URL}
          className="inline-flex h-10 items-center rounded-control border border-border-strong px-4 text-[15px] font-semibold hover:bg-surface-2"
        >
          Sign in
        </a>
      </header>
      <main className="mx-auto flex w-full max-w-5xl flex-col gap-14 px-4 sm:px-6">
        <Hero appUrl={APP_URL} />
        <section aria-labelledby="this-week" className="flex flex-col gap-5">
          <h2
            id="this-week"
            className="scroll-mt-6 text-[26px] leading-tight font-extrabold tracking-[-0.02em] sm:text-[30px]"
          >
            This week near you
          </h2>
          <WeekNearYou initialCards={cards} appUrl={APP_URL} />
        </section>
        <HowItWorks />
        <Trust />
        <Apps appUrl={APP_URL} />
        <Footer />
      </main>
    </div>
  );
}
