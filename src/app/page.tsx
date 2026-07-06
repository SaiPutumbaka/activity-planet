import Link from "next/link";
import {
  CalendarCheck,
  HeartHandshake,
  MessagesSquare,
  UsersRound,
} from "lucide-react";

import { Logo, LogoWordmark } from "@/components/shared/logo";
import { ThemeToggle } from "@/components/shared/theme-toggle";
import { Button } from "@/components/ui/button";
import { HUB_EMOJI } from "@/lib/hubs";
import { HUBS } from "@/types/database";

/**
 * Beta community links — drop the real URLs in when the Discord server and
 * signup form are live. `null` renders a "coming soon" note instead.
 */
const BETA_DISCORD_URL: string | null = null;
const BETA_FORM_URL: string | null = null;

const PROBLEM_STATS = [
  {
    value: "1 in 2",
    label: "U.S. adults report experiencing loneliness",
    source: "U.S. Surgeon General advisory, 2023",
  },
  {
    value: "Hours",
    label: "spent scrolling feeds that rarely lead to real plans",
    source: "Passive consumption is not connection",
  },
  {
    value: "8 hubs",
    label: "ready for your first real-world meetup today",
    source: "And more on the way",
  },
];

const FEATURES = [
  {
    icon: UsersRound,
    title: "Join hubs, find your people",
    body: "Pick the interests you actually care about — from basketball to anime — and instantly see the people and plans around them.",
  },
  {
    icon: CalendarCheck,
    title: "Plan real events, fast",
    body: "Post a pickup game, a watch party, or a study session in seconds. One tap to join, zero group-chat chaos.",
  },
  {
    icon: HeartHandshake,
    title: "Connection by design",
    body: "No infinite feeds engineered to keep you scrolling alone. Every feature points one direction: meeting up for real.",
  },
];

const STEPS = [
  {
    number: "01",
    title: "Create your profile",
    body: "Sign up in under a minute and pick the hubs that match your hobbies and interests.",
  },
  {
    number: "02",
    title: "Discover what's happening",
    body: "Browse upcoming events in your hubs — or post your own and watch people join.",
  },
  {
    number: "03",
    title: "Show up & connect",
    body: "RSVP, meet up, and turn shared interests into genuine friendships.",
  },
];

const HERO_PREVIEW_EVENTS = [
  { emoji: "🏀", title: "Pickup basketball, 5v5", meta: "Today · 6:00 PM · Rec Center", going: 9 },
  { emoji: "🎌", title: "Anime night: movie marathon", meta: "Fri · 8:00 PM · Common room", going: 14 },
  { emoji: "🎱", title: "Pool & chill — beginners welcome", meta: "Sat · 4:30 PM · Game lounge", going: 6 },
];

export default function LandingPage() {
  return (
    <div className="overflow-x-clip">
      {/* ---------- Nav ---------- */}
      <header className="sticky top-0 z-50 border-b bg-background/90 backdrop-blur">
        <div className="mx-auto flex max-w-6xl items-center justify-between px-4 py-3">
          <Link href="/" aria-label="Activity Planet home">
            <LogoWordmark className="text-lg" />
          </Link>
          <nav className="hidden items-center gap-6 text-sm font-medium text-muted-foreground md:flex">
            <a href="#mission" className="transition-colors hover:text-foreground">
              Mission
            </a>
            <a href="#how-it-works" className="transition-colors hover:text-foreground">
              How it works
            </a>
            <a href="#beta" className="transition-colors hover:text-foreground">
              Beta program
            </a>
          </nav>
          <div className="flex items-center gap-2">
            <ThemeToggle />
            <Button asChild variant="ghost" className="hidden sm:inline-flex">
              <Link href="/login">Log in</Link>
            </Button>
            <Button asChild>
              <Link href="/signup">Get started</Link>
            </Button>
          </div>
        </div>
      </header>

      <main>
        {/* ---------- Hero ---------- */}
        <section className="mx-auto grid max-w-6xl items-center gap-12 px-4 pb-20 pt-16 sm:pt-24 lg:grid-cols-[1.1fr_0.9fr]">
          <div className="animate-fade-up">
            <p className="inline-flex items-center gap-2 rounded-full border px-3 py-1 text-xs font-medium uppercase tracking-widest text-muted-foreground">
              <span className="h-1.5 w-1.5 rounded-full bg-primary" aria-hidden />
              Now in open beta
            </p>
            <h1 className="mt-6 max-w-xl text-balance font-display text-4xl font-semibold leading-[1.1] tracking-tight sm:text-6xl">
              Find your people,{" "}
              <span className="italic text-primary">not just followers.</span>
            </h1>
            <p className="mt-6 max-w-xl text-balance text-lg text-muted-foreground">
              Activity Planet is a social network built for the real world —
              connecting you with people who share your hobbies and interests,
              so plans actually happen and loneliness doesn&apos;t stand a
              chance.
            </p>
            <div className="mt-8 flex flex-col gap-3 sm:flex-row">
              <Button asChild size="lg" className="text-base">
                <Link href="/signup">Get started — it&apos;s free</Link>
              </Button>
              <Button asChild size="lg" variant="outline" className="text-base">
                <a href="#how-it-works">See how it works</a>
              </Button>
            </div>
            <p className="mt-8 text-sm text-muted-foreground">
              Eight launch hubs, from pickup basketball to anime nights.
            </p>
          </div>

          {/* App preview */}
          <div className="animate-fade-up delay-200 mx-auto w-full max-w-sm">
            <div className="rounded-xl border bg-card p-3 shadow-lg">
              <div className="rounded-lg border bg-background p-4">
                <div className="flex items-center justify-between">
                  <LogoWordmark className="text-sm" markClassName="h-5 w-5" />
                  <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-secondary-foreground">
                    Beta
                  </span>
                </div>
                <p className="mt-4 text-sm font-semibold">Happening soon</p>
                <div className="mt-2 space-y-2">
                  {HERO_PREVIEW_EVENTS.map((event) => (
                    <div key={event.title} className="rounded-lg border bg-card p-3">
                      <p className="flex items-center gap-2 text-sm font-medium leading-tight">
                        <span aria-hidden>{event.emoji}</span>
                        {event.title}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between">
                        <p className="text-xs text-muted-foreground">{event.meta}</p>
                        <span className="rounded-full bg-primary px-2.5 py-1 text-[10px] font-semibold text-primary-foreground">
                          Join · {event.going}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* ---------- Stats band ---------- */}
        <section className="border-y bg-card">
          <div className="mx-auto grid max-w-6xl divide-y px-4 sm:grid-cols-3 sm:divide-x sm:divide-y-0">
            {PROBLEM_STATS.map((stat) => (
              <div key={stat.label} className="px-2 py-8 text-center sm:px-6">
                <p className="font-display text-4xl font-semibold text-primary">
                  {stat.value}
                </p>
                <p className="mt-2 font-medium">{stat.label}</p>
                <p className="mt-1 text-xs text-muted-foreground">{stat.source}</p>
              </div>
            ))}
          </div>
        </section>

        {/* ---------- Problem / mission ---------- */}
        <section id="mission" className="py-20">
          <div className="mx-auto max-w-6xl px-4">
            <div className="grid gap-8 lg:grid-cols-2 lg:gap-16">
              <div>
                <p className="text-sm font-semibold uppercase tracking-widest text-primary">
                  Why we exist
                </p>
                <h2 className="mt-3 text-balance font-display text-3xl font-semibold tracking-tight sm:text-4xl">
                  Social media made us reachable.{" "}
                  <span className="italic text-primary">Not less alone.</span>
                </h2>
              </div>
              <p className="self-end text-muted-foreground">
                America is living through a loneliness epidemic. Existing
                platforms let you post into the void — but offer few genuine
                ways to actually connect. Activity Planet exists to turn shared
                interests into shared plans, and shared plans into real
                community.
              </p>
            </div>
            <div className="mt-14 grid gap-4 md:grid-cols-3">
              {FEATURES.map(({ icon: Icon, title, body }) => (
                <div
                  key={title}
                  className="rounded-lg border bg-card p-6 transition-shadow hover:shadow-md"
                >
                  <div className="flex h-10 w-10 items-center justify-center rounded-md bg-secondary text-primary">
                    <Icon className="h-5 w-5" aria-hidden />
                  </div>
                  <h3 className="mt-4 text-lg font-semibold">{title}</h3>
                  <p className="mt-2 text-sm text-muted-foreground">{body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ---------- Launch hubs ---------- */}
        <section className="border-t bg-card py-16">
          <div className="mx-auto max-w-4xl px-4 text-center">
            <p className="text-sm font-semibold uppercase tracking-widest text-primary">
              Launch hubs
            </p>
            <h2 className="mt-3 font-display text-2xl font-semibold tracking-tight sm:text-3xl">
              Whatever you&apos;re into, there&apos;s a hub for it
            </h2>
            <div className="mt-8 flex flex-wrap justify-center gap-3">
              {HUBS.map((hub) => (
                <span
                  key={hub}
                  className="inline-flex items-center gap-2 rounded-full border bg-background px-4 py-2 text-sm font-medium"
                >
                  <span aria-hidden>{HUB_EMOJI[hub]}</span>
                  {hub}
                </span>
              ))}
            </div>
          </div>
        </section>

        {/* ---------- How it works ---------- */}
        <section id="how-it-works" className="border-t py-20">
          <div className="mx-auto max-w-6xl px-4">
            <p className="text-sm font-semibold uppercase tracking-widest text-primary">
              How it works
            </p>
            <h2 className="mt-3 max-w-xl text-balance font-display text-3xl font-semibold tracking-tight sm:text-4xl">
              From stranger to crew in three steps
            </h2>
            <div className="mt-12 grid gap-10 md:grid-cols-3 md:gap-6">
              {STEPS.map((step) => (
                <div key={step.number} className="border-t pt-6">
                  <span className="font-mono text-sm font-medium text-primary">
                    {step.number}
                  </span>
                  <h3 className="mt-3 text-lg font-semibold">{step.title}</h3>
                  <p className="mt-2 text-sm text-muted-foreground">{step.body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ---------- Beta community CTA ---------- */}
        <section id="beta" className="border-t bg-card py-20">
          <div className="mx-auto max-w-3xl px-4 text-center">
            <Logo className="mx-auto h-12 w-12" />
            <h2 className="mt-6 text-balance font-display text-3xl font-semibold tracking-tight sm:text-4xl">
              Become a <span className="italic text-primary">founding tester</span>
            </h2>
            <p className="mx-auto mt-4 max-w-xl text-balance text-muted-foreground">
              We&apos;re building Activity Planet in the open, and beta testers
              shape everything — features, hubs, and what genuine connection
              online should feel like. Join now and leave your fingerprints on
              the planet.
            </p>
            <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
              <Button asChild size="lg" className="text-base">
                <Link href="/signup">Start exploring the beta</Link>
              </Button>
              {BETA_DISCORD_URL ? (
                <Button asChild size="lg" variant="outline" className="text-base">
                  <a href={BETA_DISCORD_URL} target="_blank" rel="noreferrer">
                    <MessagesSquare className="h-4 w-4" aria-hidden />
                    Join the Discord
                  </a>
                </Button>
              ) : (
                <span className="inline-flex items-center gap-2 rounded-full border border-dashed px-4 py-2 text-sm text-muted-foreground">
                  <MessagesSquare className="h-4 w-4" aria-hidden />
                  Discord community — coming soon
                </span>
              )}
              {BETA_FORM_URL ? (
                <Button asChild size="lg" variant="outline" className="text-base">
                  <a href={BETA_FORM_URL} target="_blank" rel="noreferrer">
                    Beta tester signup
                  </a>
                </Button>
              ) : null}
            </div>
          </div>
        </section>
      </main>

      {/* ---------- Footer ---------- */}
      <footer className="border-t py-10">
        <div className="mx-auto flex max-w-6xl flex-col items-center gap-4 px-4 text-center sm:flex-row sm:justify-between sm:text-left">
          <LogoWordmark className="text-base" markClassName="h-6 w-6" />
          <p className="text-sm text-muted-foreground">
            Built to solve loneliness with genuine connection. ©{" "}
            {new Date().getFullYear()} Activity Planet.
          </p>
          <div className="flex gap-4 text-sm text-muted-foreground">
            <Link href="/login" className="transition-colors hover:text-foreground">
              Log in
            </Link>
            <Link href="/signup" className="transition-colors hover:text-foreground">
              Sign up
            </Link>
          </div>
        </div>
      </footer>
    </div>
  );
}
