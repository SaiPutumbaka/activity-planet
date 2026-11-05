import { Link } from "@tanstack/react-router";
import { ExternalLink } from "lucide-react";
import {
  importChips,
  listedByLine,
  locationCredit,
  notAffiliatedLine,
  removalHref,
  sourceLine,
  ticketSeller,
} from "@ap/core/imports";

import { buttonVariants } from "@/components/ui/button-variants";
import { cn } from "@/lib/cn";
import { appEventUrl, type ImportLabel } from "@/lib/imports";
import { SITE_URL } from "@/lib/site";

/**
 * What an imported listing carries instead of an RSVP (D-004, D-014, D-022, D-037): where it came
 * from, a "Register at source" link out, a "Request removal" link to the site's removal form
 * (collector Slice 2; the support email when no site URL is set), "Are you the organizer?", the source's
 * chip and "Open to the public" where the source says so, and the not-affiliated line only on
 * items from a source that belongs to an organization (the Georgia State sources). Shows from a
 * ticketing API (D-042 slice 10) link out as "Tickets on <seller>" to the seller's own event page
 * and carry the seller's credit, linking to its homepage, wherever their data appears.
 */

/** Neutral fact pills, the same look as the hub badges: they describe, they are not states. */
export function ImportedChips({
  label,
  className,
}: {
  label: ImportLabel | null | undefined;
  className?: string;
}) {
  const chips = importChips(label);
  if (chips.length === 0) return null;
  return (
    <span className={cn("flex flex-wrap gap-1.5", className)}>
      {chips.map((c) => (
        <span
          key={c}
          className="inline-flex h-7 items-center rounded-control border border-border bg-surface px-2.5 text-[13px] font-semibold text-text-2"
        >
          {c}
        </span>
      ))}
    </span>
  );
}

export function RegisterAtSource({
  url,
  sourceName,
  label = "Register at source",
  size,
  primary = false,
  className,
}: {
  url: string;
  sourceName: string;
  /** The button text ("Tickets on SeatGeek" for a ticketing source). */
  label?: string;
  size?: "lg";
  /** On the event page it is the one action, so it takes the accent; on cards it stays quiet. */
  primary?: boolean;
  className?: string;
}) {
  return (
    <a
      href={url}
      target="_blank"
      rel="noopener noreferrer"
      className={buttonVariants({ variant: primary ? "primary" : "outline", size, className })}
    >
      {label}
      <ExternalLink className="size-4" aria-hidden="true" />
      <span className="sr-only"> on {sourceName} (opens in a new tab)</span>
    </a>
  );
}

export function RequestRemovalLink({
  event,
  className,
}: {
  event: { id: string; title: string; external_url: string | null };
  className?: string;
}) {
  const href = removalHref({
    id: event.id,
    title: event.title,
    externalUrl: event.external_url,
    appUrl: appEventUrl(event.id),
    siteUrl: SITE_URL,
  });
  const web = href.startsWith("http");
  return (
    <a
      href={href}
      target={web ? "_blank" : undefined}
      rel={web ? "noopener noreferrer" : undefined}
      className={cn(
        "inline-flex min-h-11 items-center text-[13px] font-semibold text-text-2 underline underline-offset-2 hover:text-text",
        className,
      )}
    >
      Request removal
    </a>
  );
}

/** The geocoder's credit for a geocoded item (OpenStreetMap's ODbL notice, or Geoapify's). */
export function LocationCredit({
  provider,
  className,
}: {
  provider: string | null | undefined;
  className?: string;
}) {
  const credit = locationCredit(provider);
  if (!credit) return null;
  return (
    <a
      href={credit.href}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(
        "inline-flex min-h-11 items-center self-start text-[12px] font-semibold text-text-2 underline underline-offset-2 hover:text-text",
        className,
      )}
    >
      {credit.text}
      <span className="sr-only"> (opens in a new tab)</span>
    </a>
  );
}

/** The ticket seller's credit, linking to its homepage (SeatGeek's and Ticketmaster's terms). */
export function SellerCredit({
  sourceKind,
  className,
}: {
  sourceKind: string | null | undefined;
  className?: string;
}) {
  const seller = ticketSeller(sourceKind);
  if (!seller) return null;
  return (
    <a
      href={seller.homeUrl}
      target="_blank"
      rel="noopener noreferrer"
      className={cn(
        "inline-flex min-h-11 items-center text-[12px] font-semibold text-text-2 underline underline-offset-2 hover:text-text",
        className,
      )}
    >
      {seller.credit}
      <span className="sr-only"> (opens {seller.name} in a new tab)</span>
    </a>
  );
}

/** The footer of an imported card on Home and in hubs. */
export function ImportedCardFooter({
  event,
  label,
}: {
  event: { id: string; title: string; external_url: string | null; source_name: string | null };
  label: ImportLabel | null | undefined;
}) {
  const source = label?.source_name ?? event.source_name ?? "the organizer";
  const line = notAffiliatedLine(label);
  const seller = ticketSeller(label?.source_kind);
  return (
    <div className="mt-1 flex flex-col gap-1">
      <p className="text-[13px] text-text-2">{listedByLine(source, label?.host_org)}</p>
      <div className="flex min-h-11 flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <RequestRemovalLink event={event} className="relative z-[2]" />
        {event.external_url ? (
          <RegisterAtSource
            url={event.external_url}
            sourceName={source}
            label={seller?.linkLabel}
            className="relative z-[2]"
          />
        ) : null}
      </div>
      <SellerCredit sourceKind={label?.source_kind} className="relative z-[2] self-start" />
      {line ? <p className="text-[12px] text-text-3">{line}</p> : null}
    </div>
  );
}

/** The source block on an imported event's page. */
export function ImportedSourceSection({
  event,
  label,
}: {
  event: { id: string; title: string; external_url: string | null; source_name: string | null };
  label: ImportLabel | null | undefined;
}) {
  const source = label?.source_name ?? event.source_name ?? "the organizer";
  const line = notAffiliatedLine(label);
  const seller = ticketSeller(label?.source_kind);
  return (
    <section className="flex flex-col gap-2 rounded-card border border-border p-4">
      <h3 className="text-[17px] font-bold tracking-[-0.01em]">
        {listedByLine(source, label?.host_org)}
      </h3>
      <p className="text-[14px] text-text-2">
        {sourceLine({ ...label, source_name: source })}{" "}
        {seller
          ? `Activity Planet doesn't sell tickets: details can change, so check them and buy on ${seller.name}.`
          : "Activity Planet isn't the organizer: details can change, so check and sign up on the source's page."}
      </p>
      {label?.approximate_location && !label.geocode_provider ? (
        <p className="text-[13px] text-text-2">
          The distance is approximate: the source doesn't give an exact spot.
        </p>
      ) : null}
      <LocationCredit provider={label?.geocode_provider} />
      {event.external_url ? (
        <RegisterAtSource
          url={event.external_url}
          sourceName={source}
          label={seller?.linkLabel}
          size="lg"
          primary
          className="mt-1"
        />
      ) : null}
      <SellerCredit sourceKind={label?.source_kind} className="self-start" />
      <p className="text-[13px] text-text-2">
        Organize this and want it taken down? <RequestRemovalLink event={event} />
      </p>
      {label?.organizer_listed ? null : (
        <p className="text-[13px] text-text-2">
          <Link
            to="/organizer/claim"
            search={{ event: event.id }}
            className="inline-flex min-h-11 items-center font-semibold text-text-2 underline underline-offset-2 hover:text-text"
          >
            Are you the organizer?
          </Link>
        </p>
      )}
      {line ? <p className="text-[12px] text-text-3">{line}</p> : null}
    </section>
  );
}

/**
 * The ticket sellers' credits under a list of shows (the "Shows and games" row, the map list):
 * the sellers of the shows listed, or both ticketing sources when the list does not know them.
 */
export function ShowsCredit({
  sourceKinds = ["ticketmaster", "seatgeek"],
  className,
}: {
  sourceKinds?: readonly (string | null | undefined)[];
  className?: string;
}) {
  const kinds = [...new Set(sourceKinds)].filter((k) => ticketSeller(k) !== null);
  if (kinds.length === 0) return null;
  return (
    <p className={cn("flex flex-wrap items-center gap-x-3", className)}>
      {kinds.map((k) => (
        <SellerCredit key={k} sourceKind={k} />
      ))}
    </p>
  );
}
