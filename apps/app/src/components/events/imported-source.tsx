import { ExternalLink } from "lucide-react";
import { importChips, listedByLine, notAffiliatedLine, removalMailto } from "@ap/core/imports";

import { buttonVariants } from "@/components/ui/button-variants";
import { cn } from "@/lib/cn";
import { appEventUrl, type ImportLabel } from "@/lib/imports";

/**
 * What an imported listing carries instead of an RSVP (D-004, D-014, D-022, D-037): where it came
 * from, a "Register at source" link out, a "Request removal" email for organizers, the source's
 * chip and "Open to the public" where the source says so, and the not-affiliated line only on
 * items from a source that belongs to an organization (the Georgia State sources).
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
  size,
  primary = false,
  className,
}: {
  url: string;
  sourceName: string;
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
      Register at source
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
  return (
    <a
      href={removalMailto({
        id: event.id,
        title: event.title,
        externalUrl: event.external_url,
        appUrl: appEventUrl(event.id),
      })}
      className={cn(
        "inline-flex min-h-11 items-center text-[13px] font-semibold text-text-2 underline underline-offset-2 hover:text-text",
        className,
      )}
    >
      Request removal
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
  return (
    <div className="mt-1 flex flex-col gap-1">
      <p className="text-[13px] text-text-2">{listedByLine(source, label?.host_org)}</p>
      <div className="flex min-h-11 flex-wrap items-center justify-between gap-x-3 gap-y-1">
        <RequestRemovalLink event={event} className="relative z-[2]" />
        {event.external_url ? (
          <RegisterAtSource
            url={event.external_url}
            sourceName={source}
            className="relative z-[2]"
          />
        ) : null}
      </div>
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
  return (
    <section className="flex flex-col gap-2 rounded-card border border-border p-4">
      <h3 className="text-[17px] font-bold tracking-[-0.01em]">
        {listedByLine(source, label?.host_org)}
      </h3>
      <p className="text-[14px] text-text-2">
        {label?.attribution || `Listed from ${source}.`} Activity Planet isn't the organizer:
        details can change, so check and sign up on the source's page.
      </p>
      {label?.approximate_location ? (
        <p className="text-[13px] text-text-2">
          The distance is approximate: the source doesn't give an exact spot.
        </p>
      ) : null}
      {event.external_url ? (
        <RegisterAtSource
          url={event.external_url}
          sourceName={source}
          size="lg"
          primary
          className="mt-1"
        />
      ) : null}
      <p className="text-[13px] text-text-2">
        Organize this and want it taken down? <RequestRemovalLink event={event} />
      </p>
      {line ? <p className="text-[12px] text-text-3">{line}</p> : null}
    </section>
  );
}
