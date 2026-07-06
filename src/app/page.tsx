import Link from "next/link";
import {
  CalendarCheck,
  HeartHandshake,
  MessagesSquare,
  Rocket,
  Sparkles,
  UsersRound,
} from "lucide-react";

import { Logo, LogoWordmark } from "@/components/shared/logo";
import { ThemeToggle } from "@/components/shared/theme-toggle";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { HUB_EMOJI } from "@/lib/hubs";
import { HUBS } from "@/types/database";

/**
 * Beta community links — drop the real URLs in when the Discord server and
 * signup form are live. `null` renders a "coming soon" chip instead.
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
    source: "Passive consumption ≠ connection",
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

function HubChip({ hub }: { hub: (typeof HUBS)[number] }) {
  return (
    <span className="inline-flex shrink-0 items-center gap-2 rounded-full border bg-card px-4 py-2 text-sm font-medium shadow-sm">
      <span aria-hidden>{HUB_EMOJI[hub]}</span>
      {hub}
    </span>
  );
}

export default function LandingPage() {
  return (
    <div className="relative overflow-x-clip">
      {/* ---------- Backdrop decorations ---------- */}
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-[52rem] bg-grid bg-grid-fade" />
      <div className="pointer-events-none absolute -top-40 left-1/2 -z-10 h-[30rem] w-[46rem] -translate-x-1/2 rounded-full bg-violet-600/25 blur-[120px]" />
      <div className="pointer-events-none absolute right-[-10rem] top-64 -z-10 h-80 w-80 rounded-full bg-fuchsia-600/20 blur-[110px]" />
      <div className="pointer-events-none absolute left-[-8rem] top-[38rem] -z-10 h-72 w-72 rounded-full bg-cyan-500/15 blur-[100px]" />

      {/* ---------- Nav ---------- */}
      <header className="sticky top-0 z-50 border-b border-border/60 bg-background/80 backdrop-blur">
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
            <Button asChild className="bg-cta text-white hover:opacity-90">
              <Link href="/signup">Get started</Link>
            </Button>
          </div>
        </div>
      </header>

      <main>
        {/* ---------- Hero ---------- */}
        <section className="mx-auto flex max-w-6xl flex-col items-center px-4 pb-20 pt-16 text-center sm:pt-24">
          <Badge
            variant="secondary"
            className="animate-fade-up gap-1.5 rounded-full px-4 py-1.5 text-sm"
          >
            <Rocket className="h-3.5 w-3.5" aria-hidden />
            Now in open beta — founding testers wanted
          </Badge>
          <h1 className="animate-fade-up delay-100 mt-6 max-w-3xl text-balance text-4xl font-bold leading-tight tracking-tight sm:text-6xl">
            Find your people,{" "}
            <span className="text-gradient">not just followers.</span>
          </h1>
          <p className="animate-fade-up delay-200 mt-6 max-w-2xl text-balance text-lg text-muted-foreground">
            Activity Planet is a social network built for the real world —
            connecting you with people who share your hobbies and interests,
            so plans actually happen and loneliness doesn&apos;t stand a
            chance.
          </p>
          <div className="animate-fade-up delay-300 mt-8 flex flex-col gap-3 sm:flex-row">
            <Button
              asChild
              size="lg"
              className="glow-primary bg-cta text-base text-white hover:opacity-90"
            >
              <Link href="/signup">
                <Sparkles className="h-4 w-4" aria-hidden />
                Get started — it&apos;s free
              </Link>
            </Button>
            <Button asChild size="lg" variant="outline" className="text-base">
              <a href="#how-it-works">See how it works</a>
            </Button>
          </div>

          {/* App preview mock */}
          <div className="relative mt-16">
            <div className="pointer-events-none absolute -inset-8 -z-10 rounded-[3rem] bg-gradient-to-r from-violet-600/30 via-fuchsia-600/20 to-cyan-500/25 blur-2xl" />
            <div className="animate-float w-[19rem] rotate-1 rounded-[2rem] border border-border/80 bg-card p-3 shadow-2xl sm:w-[21rem]">
              <div className="rounded-[1.4rem] border bg-background p-4 text-left">
                <div className="flex items-center justify-between">
                  <LogoWordmark className="text-sm" markClassName="h-5 w-5" />
                  <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-secondary-foreground">
                    Beta
                  </span>
                </div>
                <p className="mt-3 text-sm font-semibold">Happening soon</p>
                <div className="mt-2 space-y-2">
                  {HERO_PREVIEW_EVENTS.map((event) => (
                    <div
                      key={event.title}
                      className="rounded-xl border bg-card p-3"
                    >
                      <p className="flex items-center gap-2 text-sm font-medium leading-tight">
                        <span aria-hidden>{event.emoji}</span>
                        {event.title}
                      </p>
                      <div className="mt-1.5 flex items-center justify-between">
                        <p className="text-xs text-muted-foreground">
                          {event.meta}
                        </p>
                        <span className="rounded-full bg-cta px-2.5 py-1 text-[10px] font-semibold text-white">
                          Join · {event.going}
                        </span>
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            </div>
            <span
              className="animate-float-slow absolute -left-14 top-10 hidden rounded-full border bg-card px-3 py-1.5 text-sm shadow-lg sm:block"
              aria-hidden
            >
              🏓 Ping Pong
            </span>
            <span
              className="animate-float absolute -right-16 top-1/3 hidden rounded-full border bg-card px-3 py-1.5 text-sm shadow-lg sm:block"
              aria-hidden
            >
              🎬 Movies
            </span>
            <span
              className="animate-float-slow absolute -right-10 bottom-8 hidden rounded-full border bg-card px-3 py-1.5 text-sm shadow-lg sm:block"
              aria-hidden
            >
              🥎 Pickleball
            </span>
          </div>
        </section>

        {/* ---------- Problem / mission ---------- */}
        <section id="mission" className="border-t bg-muted/40 py-20">
          <div className="mx-auto max-w-6xl px-4">
            <div className="mx-auto max-w-2xl text-center">
              <p className="text-sm font-semibold uppercase tracking-widest text-primary">
                Why we exist
              </p>
              <h2 className="mt-3 text-balance text-3xl font-bold tracking-tight sm:text-4xl">
                Social media made us reachable.
                <br />
                <span className="text-gradient">Not less alone.</span>
              </h2>
              <p className="mt-4 text-muted-foreground">
                America is living through a loneliness epidemic. Existing
                platforms let you post into the void — but offer few genuine
                ways to actually connect. Activity Planet exists to turn
                shared interests into shared plans, and shared plans into real
                community.
              </p>
            </div>
            <div className="mt-12 grid gap-4 sm:grid-cols-3">
              {PROBLEM_STATS.map((stat) => (
                <div
                  key={stat.label}
                  className="rounded-2xl border bg-card p-6 text-center shadow-sm"
                >
                  <p className="text-gradient text-4xl font-bold">
                    {stat.value}
                  </p>
                  <p className="mt-2 font-medium">{stat.label}</p>
                  <p className="mt-1 text-xs text-muted-foreground">
                    {stat.source}
                  </p>
                </div>
              ))}
            </div>
            <div className="mt-12 grid gap-4 md:grid-cols-3">
              {FEATURES.map(({ icon: Icon, title, body }) => (
                <div
                  key={title}
                  className="group rounded-2xl border bg-card p-6 shadow-sm transition-all hover:-translate-y-1 hover:border-primary/40 hover:shadow-lg"
                >
                  <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-cta text-white">
                    <Icon className="h-5 w-5" aria-hidden />
                  </div>
                  <h3 className="mt-4 text-lg font-semibold">{title}</h3>
                  <p className="mt-2 text-sm text-muted-foreground">{body}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ---------- Hub marquee ---------- */}
        <section className="border-t py-14">
          <p className="text-center text-sm font-semibold uppercase tracking-widest text-primary">
            Launch hubs
          </p>
          <h2 className="mt-3 text-center text-2xl font-bold tracking-tight sm:text-3xl">
            Whatever you&apos;re into, there&apos;s a hub for it
          </h2>
          <div className="relative mt-8 overflow-hidden">
            <div className="pointer-events-none absolute inset-y-0 left-0 z-10 w-20 bg-gradient-to-r from-background to-transparent" />
            <div className="pointer-events-none absolute inset-y-0 right-0 z-10 w-20 bg-gradient-to-l from-background to-transparent" />
            <div className="animate-marquee flex w-max gap-3">
              {HUBS.map((hub) => (
                <HubChip key={hub} hub={hub} />
              ))}
              <div className="flex gap-3" aria-hidden>
                {HUBS.map((hub) => (
                  <HubChip key={`dup-${hub}`} hub={hub} />
                ))}
              </div>
            </div>
          </div>
        </section>

        {/* ---------- How it works ---------- */}
        <section id="how-it-works" className="border-t bg-muted/40 py-20">
          <div className="mx-auto max-w-6xl px-4">
            <p className="text-center text-sm font-semibold uppercase tracking-widest text-primary">
              How it works
            </p>
            <h2 className="mt-3 text-center text-3xl font-bold tracking-tight sm:text-4xl">
              From stranger to <span className="text-gradient">crew</span> in
              three steps
            </h2>
            <div className="mt-12 grid gap-4 md:grid-cols-3">
              {STEPS.map((step) => (
                <div
                  key={step.number}
                  className="relative overflow-hidden rounded-2xl border bg-card p-6 shadow-sm"
                >
                  <span className="text-gradient text-5xl font-bold opacity-80">
                    {step.number}
                  </span>
                  <h3 className="mt-4 text-lg font-semibold">{step.title}</h3>
                  <p className="mt-2 text-sm text-muted-foreground">
                    {step.body}
                  </p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* ---------- Beta community CTA ---------- */}
        <section id="beta" className="py-20">
          <div className="mx-auto max-w-4xl px-4">
            <div className="relative overflow-hidden rounded-3xl border border-primary/30 bg-card p-8 text-center shadow-xl sm:p-12">
              <div className="pointer-events-none absolute -top-24 left-1/2 h-56 w-[30rem] -translate-x-1/2 rounded-full bg-violet-600/20 blur-3xl" />
              <Logo className="mx-auto h-14 w-14" />
              <h2 className="mt-6 text-balance text-3xl font-bold tracking-tight sm:text-4xl">
                Become a <span className="text-gradient">founding tester</span>
              </h2>
              <p className="mx-auto mt-4 max-w-xl text-balance text-muted-foreground">
                We&apos;re building Activity Planet in the open, and beta
                testers shape everything — features, hubs, and what genuine
                connection online should feel like. Join now and leave your
                fingerprints on the planet.
              </p>
              <div className="mt-8 flex flex-col items-center justify-center gap-3 sm:flex-row">
                <Button
                  asChild
                  size="lg"
                  className="glow-primary bg-cta text-base text-white hover:opacity-90"
                >
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
