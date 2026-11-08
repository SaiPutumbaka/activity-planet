import type { Metadata } from "next";
import { Figtree } from "next/font/google";
import Link from "next/link";
import { notFound } from "next/navigation";
import type { ReactNode, SVGProps } from "react";
import { googleCalendarUrl } from "@ap/core/calendar";
import { ticketSeller } from "@ap/core/imports";
import { DefaultCover, Mark } from "@ap/ui/brand";

import {
  appEventUrl,
  calendarEvent,
  excerpt,
  getEventShare,
  isRestricted,
  spotsLeft,
  type EventShareCard,
  type EventShareStub,
} from "@/lib/event-share";
import { LocalEventTime, LocalRelativeDay } from "@/components/local-time";
import {
  DEFAULT_TIMEZONE,
  formatEventTime,
  isHappeningNow,
  isOver,
  timeZoneLabel,
} from "@/lib/event-time";

/**
 * The public share page for one event (PLAN 4.3): works logged out, carries an OG image, Add to
 * Calendar (.ics) and Google Calendar links, and hands off to the app for everything else. A
 * campus or 21+ plan renders a stub that says only that, with its hub, and the same hand-off.
 * Re-rendered at most once a minute so the going count stays fresh without a database call per
 * visit.
 */
export const revalidate = 60;

const figtree = Figtree({ subsets: ["latin"], display: "swap" });

type Props = { params: Promise<{ id: string }> };

export async function generateMetadata({ params }: Props): Promise<Metadata> {
  const { id } = await params;
  const card = await getEventShare(id);
  if (!card) {
    return {
      title: { absolute: "Plan not found · Activity Planet" },
      description: "This plan may have been removed, or it is not public.",
      robots: { index: false, follow: false },
    };
  }
  if (isRestricted(card)) {
    return {
      title: { absolute: "A plan on Activity Planet" },
      description: `A ${card.hub_name} plan on Activity Planet. Open it in the app to see the details.`,
      robots: { index: false, follow: false },
    };
  }

  const when = formatEventTime(card.starts_at, card.ends_at, card.timezone);
  const where = card.location_hint ? ` at ${card.location_hint}` : "";
  const about = excerpt(card.description, 120);
  const description = `${when}${where}.${about ? ` ${about}` : ""}`;

  return {
    title: { absolute: `${card.title} · Activity Planet` },
    description,
    alternates: { canonical: `/e/${card.id}` },
    openGraph: {
      type: "website",
      siteName: "Activity Planet",
      title: card.title,
      description,
      url: `/e/${card.id}`,
    },
    twitter: { card: "summary_large_image", title: card.title, description },
  };
}

export default async function EventSharePage({ params }: Props) {
  const { id } = await params;
  const share = await getEventShare(id);
  if (!share) notFound();
  if (isRestricted(share)) return <RestrictedPage stub={share} />;

  const card = share;
  const now = new Date();
  const live = isHappeningNow(card.starts_at, card.ends_at, now);
  const over = isOver(card.ends_at, now);
  const left = spotsLeft(card);
  const about = excerpt(card.description, 320);

  return (
    <Frame gsu={namesGeorgiaState(card.source_name)}>
      <div className="h-[200px] bg-surface-2">
        {card.cover_url ? (
          // Covers are hotlinked from Supabase storage and external feeds; next/image would
          // need a remotePatterns allowlist per host for no gain on a cached share page.
          // eslint-disable-next-line @next/next/no-img-element
          <img src={card.cover_url} alt="" className="size-full object-cover" />
        ) : (
          <DefaultCover seed={card.id} />
        )}
      </div>

      <div className="flex flex-col gap-5 px-5 pt-4 pb-6">
        <section className="flex flex-col gap-2.5">
          <StateLine card={card} live={live} over={over} now={now} />
          <h1 className="text-[28px] leading-[1.15] font-extrabold tracking-[-0.02em] text-balance">
            {card.title}
          </h1>
          <div className="flex flex-wrap items-center gap-2">
            <span className="inline-flex min-h-9 items-center gap-1.5 rounded-control border border-border px-3 text-[14px] font-semibold">
              {card.hub.emoji ? <span aria-hidden="true">{card.hub.emoji}</span> : null}
              {card.hub.name}
            </span>
            {card.chapter ? (
              <span className="text-[13px] text-text-2">{card.chapter.name}</span>
            ) : null}
          </div>
          {card.series_id ? (
            <p className="text-[13px] text-text-2">
              One week of a weekly plan. Each week is its own RSVP.
            </p>
          ) : null}
        </section>

        <section className="flex flex-col gap-4 rounded-card border border-border p-4">
          <Row icon={ClockIcon}>
            <p className="font-semibold tabular-nums">
              <LocalEventTime
                startsAt={card.starts_at}
                endsAt={card.ends_at}
                timeZone={card.timezone}
                now={now.toISOString()}
              />
            </p>
            {card.timezone !== DEFAULT_TIMEZONE ? (
              <p className="text-[13px] text-text-2">Times in {timeZoneLabel(card.timezone)}</p>
            ) : null}
          </Row>
          <Row icon={PinIcon}>
            <p className="font-semibold">{card.location_hint || "Place shared in the app"}</p>
            {card.location_hint ? (
              <p className="text-[13px] text-text-2">Exact spot in the app once you join.</p>
            ) : null}
          </Row>
          <Row icon={UsersIcon}>
            <p className="font-semibold tabular-nums">
              {card.going_count} going
              {card.capacity !== null ? ` of ${card.capacity}` : ""}
              {left !== null && left > 0 ? ` · ${left} ${left === 1 ? "spot" : "spots"} left` : ""}
              {left === 0 ? " · Full" : ""}
            </p>
            {card.min_headcount !== null && card.going_count < card.min_headcount ? (
              <p className="text-[13px] text-text-2">
                Happens if at least {card.min_headcount} join.
              </p>
            ) : null}
          </Row>
          <Row icon={TagIcon}>
            <p className="font-semibold">{card.is_free ? "Free" : (card.price_text ?? "Paid")}</p>
          </Row>
        </section>

        {card.host ? (
          <section className="flex items-center gap-3">
            <Avatar src={card.host.avatar_url} name={card.host.first_name} />
            <div className="min-w-0">
              <p className="truncate text-[15px] font-semibold">{card.host.first_name}</p>
              <p className="truncate text-[13px] text-text-2">Hosting · @{card.host.handle}</p>
            </div>
          </section>
        ) : card.kind === "imported" ? (
          <ImportedSource card={card} />
        ) : card.source_attribution?.trim() ? (
          <p className="text-[13px] text-text-2">{card.source_attribution.trim()}</p>
        ) : card.source_name ? (
          <p className="text-[13px] text-text-2">Listed from {card.source_name}.</p>
        ) : null}

        {about ? (
          <section className="flex flex-col gap-1.5">
            <h2 className="text-[17px] font-bold tracking-[-0.01em]">About</h2>
            <p className="text-[15px] leading-[1.45] text-text">{about}</p>
          </section>
        ) : null}

        <section className="flex flex-col gap-2.5 pt-1">
          <a
            href={appEventUrl(card.id)}
            className="inline-flex min-h-12 items-center justify-center rounded-control bg-primary px-5 text-[16px] font-bold text-on-primary"
          >
            Open in Activity Planet
          </a>
          {/* No download attribute: iOS Safari then hands text/calendar to Calendar. */}
          <a
            href={`/e/${card.id}/calendar.ics`}
            className="inline-flex min-h-12 items-center justify-center rounded-control border border-border-strong px-5 text-[16px] font-semibold text-text hover:bg-surface-2"
          >
            Add to calendar
          </a>
          <a
            href={googleCalendarUrl(calendarEvent(card))}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-11 items-center justify-center text-[15px] font-semibold text-primary-text underline-offset-2 hover:underline"
          >
            Add to Google Calendar
          </a>
        </section>
      </div>
    </Frame>
  );
}

/**
 * Where an imported listing came from (D-004, D-040, D-042 slice 10), as the app's event page
 * shows it: the source's attribution (an open-data licence line, for example), the link out to
 * the source ("Tickets on <seller>" for a ticketing source), the seller's credit linking to its
 * homepage wherever the seller's data appears, and "Request removal".
 */
function ImportedSource({ card }: { card: EventShareCard }) {
  const seller = ticketSeller(card.source_kind);
  const source = card.source_name?.trim() || seller?.name || "the organizer";
  const attribution = card.source_attribution?.trim();
  const link =
    card.external_url && /^https?:\/\//i.test(card.external_url) ? card.external_url : null;
  const quiet =
    "inline-flex min-h-11 items-center self-start text-[13px] font-semibold text-text-2 underline underline-offset-2 hover:text-text";
  return (
    <section className="flex flex-col gap-1.5">
      <p className="text-[13px] text-text-2">{attribution || `Listed from ${source}.`}</p>
      <p className="text-[13px] text-text-2">
        {seller
          ? `Activity Planet doesn't sell tickets: details can change, so check them and buy on ${seller.name}.`
          : "Activity Planet isn't the organizer: details can change, so check and sign up on the source's page."}
      </p>
      {link ? (
        <a
          href={link}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex min-h-12 items-center justify-center rounded-control border border-border-strong px-5 text-[16px] font-semibold text-text hover:bg-surface-2"
        >
          {seller?.linkLabel ?? "Register at source"}
          <span className="sr-only"> on {source} (opens in a new tab)</span>
        </a>
      ) : null}
      {seller ? (
        <a href={seller.homeUrl} target="_blank" rel="noopener noreferrer" className={quiet}>
          {seller.credit}
          <span className="sr-only"> (opens {seller.name} in a new tab)</span>
        </a>
      ) : null}
      <Link href={`/bot/remove?event=${encodeURIComponent(card.id)}`} className={quiet}>
        Request removal
      </Link>
    </section>
  );
}

/** A campus or 21+ plan: nothing about it may be shown logged out except its hub. */
function RestrictedPage({ stub }: { stub: EventShareStub }) {
  return (
    <Frame>
      <div className="h-[200px] bg-surface-2">
        <DefaultCover seed={stub.id} />
      </div>
      <div className="flex flex-col gap-5 px-5 pt-4 pb-6">
        <section className="flex flex-col gap-2.5">
          <h1 className="text-[28px] leading-[1.15] font-extrabold tracking-[-0.02em] text-balance">
            {stub.restricted === "campus" ? "A campus plan" : "A 21+ plan"}
          </h1>
          <span className="inline-flex min-h-9 items-center self-start rounded-control border border-border px-3 text-[14px] font-semibold">
            {stub.hub_name}
          </span>
          <p className="text-[15px] leading-[1.45] text-text-2">
            {stub.restricted === "campus"
              ? "This plan is open to verified members of one campus, so its details stay in the app. Open it there to see whether you can join."
              : "This plan is for people 21 and over, so its details stay in the app. Open it there to see the time, the place and who's going."}
          </p>
        </section>
        <a
          href={appEventUrl(stub.id)}
          className="inline-flex min-h-12 items-center justify-center rounded-control bg-primary px-5 text-[16px] font-bold text-on-primary"
        >
          Open in Activity Planet
        </a>
      </div>
    </Frame>
  );
}

/**
 * The GSU disclaimer belongs only on surfaces that name Georgia State (D-022, D-035): here, an
 * item listed from a Georgia State source.
 */
function namesGeorgiaState(source: string | null | undefined): boolean {
  return /georgia state|\bgsu\b/i.test(source ?? "");
}

/** The page shell: the lockup header, one card column and the legal footer. */
function Frame({ children, gsu = false }: { children: ReactNode; gsu?: boolean }) {
  return (
    <div className={`${figtree.className} min-h-dvh bg-surface text-text sm:bg-surface-2`}>
      <main className="mx-auto flex min-h-dvh w-full max-w-md flex-col sm:min-h-0 sm:py-8">
        <article className="flex flex-col bg-surface sm:overflow-hidden sm:rounded-card sm:border sm:border-border sm:shadow-card">
          <header className="flex items-center justify-between px-5 py-3.5">
            <Link href="/" className="inline-flex items-center gap-2">
              <Mark size={22} />
              <span className="text-[15px] font-bold tracking-[-0.01em]">Activity Planet</span>
            </Link>
            <span className="text-[13px] font-medium text-text-2">A plan</span>
          </header>
          {children}
        </article>

        <footer className="flex flex-col gap-2 px-5 py-6 text-[13px] text-text-2">
          {gsu ? <p>Not affiliated with or endorsed by Georgia State University.</p> : null}
          <nav className="flex flex-wrap gap-x-4 gap-y-1" aria-label="Legal">
            <a href="/terms" className="underline-offset-2 hover:underline">
              Terms
            </a>
            <a href="/privacy" className="underline-offset-2 hover:underline">
              Privacy
            </a>
            <a href="/safety" className="underline-offset-2 hover:underline">
              Safety
            </a>
            <a href="/coach-terms" className="underline-offset-2 hover:underline">
              Coach Terms
            </a>
            <a href="/refund-policy" className="underline-offset-2 hover:underline">
              Refund Policy
            </a>
          </nav>
        </footer>
      </main>
    </div>
  );
}

/**
 * The one line about the event itself: raspberry only when it is happening, grey-blue when it
 * is over or came from a feed, otherwise the day in words ("Tomorrow", "Saturday", "Thu, Nov 5").
 */
function StateLine({
  card,
  live,
  over,
  now,
}: {
  card: EventShareCard;
  live: boolean;
  over: boolean;
  now: Date;
}) {
  if (live) {
    return (
      <p className="inline-flex items-center gap-1.5 self-start rounded-control bg-live-tint px-2.5 py-1 text-[13px] font-semibold text-live">
        <span className="size-2 rounded-full bg-live-dot" aria-hidden="true" />
        Happening now
      </p>
    );
  }
  if (over) {
    return (
      <p className="inline-flex items-center self-start rounded-control bg-info-tint px-2.5 py-1 text-[13px] font-semibold text-info">
        Over
      </p>
    );
  }
  const day = (
    <LocalRelativeDay value={card.starts_at} timeZone={card.timezone} now={now.toISOString()} />
  );
  const source = card.kind === "imported" && card.source_name ? ` · From ${card.source_name}` : "";
  return (
    <p className="text-[14px] font-semibold text-text-2">
      {day}
      {source}
    </p>
  );
}

function Row({
  icon: Icon,
  children,
}: {
  icon: (props: SVGProps<SVGSVGElement>) => ReactNode;
  children: ReactNode;
}) {
  return (
    <div className="flex gap-3">
      <Icon className="mt-0.5 size-5 shrink-0 text-text-2" aria-hidden="true" />
      <div className="flex min-w-0 flex-1 flex-col gap-0.5 text-[15px]">{children}</div>
    </div>
  );
}

/** The host's photo, or the first letter of their name on the accent tint. */
function Avatar({ src, name }: { src: string | null; name: string }) {
  const initial = name.trim().slice(0, 1).toUpperCase() || "?";
  return (
    <span
      role="img"
      aria-label={name}
      className="inline-flex size-11 shrink-0 items-center justify-center overflow-hidden rounded-full bg-primary-tint text-[18px] font-bold text-primary-text select-none"
    >
      {src ? (
        // Avatars live in Supabase storage; see the cover note above.
        // eslint-disable-next-line @next/next/no-img-element
        <img src={src} alt="" width={44} height={44} className="size-full object-cover" />
      ) : (
        initial
      )}
    </span>
  );
}

function iconProps(props: SVGProps<SVGSVGElement>): SVGProps<SVGSVGElement> {
  return {
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 2,
    strokeLinecap: "round",
    strokeLinejoin: "round",
    ...props,
  };
}

function ClockIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg {...iconProps(props)}>
      <circle cx="12" cy="12" r="10" />
      <path d="M12 6v6l4 2" />
    </svg>
  );
}

function PinIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg {...iconProps(props)}>
      <path d="M20 10c0 6-8 12-8 12S4 16 4 10a8 8 0 0 1 16 0Z" />
      <circle cx="12" cy="10" r="3" />
    </svg>
  );
}

function UsersIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg {...iconProps(props)}>
      <path d="M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2" />
      <circle cx="9" cy="7" r="4" />
      <path d="M22 21v-2a4 4 0 0 0-3-3.87" />
      <path d="M16 3.13a4 4 0 0 1 0 7.75" />
    </svg>
  );
}

function TagIcon(props: SVGProps<SVGSVGElement>) {
  return (
    <svg {...iconProps(props)}>
      <path d="M20.59 13.41l-7.17 7.17a2 2 0 0 1-2.83 0L2 12V2h10l8.59 8.59a2 2 0 0 1 0 2.82Z" />
      <circle cx="7" cy="7" r="1.5" />
    </svg>
  );
}
