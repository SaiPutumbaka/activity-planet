import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { Check, Copy } from "lucide-react";
import { toast } from "sonner";
import {
  claimMethodInfo,
  claimStatusLabel,
  failureText,
  organizerErrorMessage,
  proofCopies,
  type OrganizerClaim,
} from "@ap/core/organizer";

import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { formatWhen } from "@/lib/admin";
import { cn } from "@/lib/cn";
import { checkClaim, organizerKeys, type CheckOutcome } from "@/lib/organizer";

/** A value to paste somewhere else, with a Copy button. Wraps instead of scrolling sideways. */
export function CopyValue({ label, value }: { label: string; value: string }) {
  const [copied, setCopied] = useState(false);
  return (
    <div className="flex flex-col gap-1">
      <p className="text-[13px] font-semibold text-text-2">{label}</p>
      <div className="flex items-start gap-2 rounded-tile bg-surface-2 p-2">
        <code className="min-w-0 flex-1 px-1 py-1.5 font-mono text-[13px] break-all">{value}</code>
        <Button
          size="sm"
          variant="outline"
          aria-label={`Copy ${label.toLowerCase()}`}
          onClick={() => {
            void navigator.clipboard
              ?.writeText(value)
              .then(() => {
                setCopied(true);
                window.setTimeout(() => setCopied(false), 2000);
              })
              .catch(() => toast.error("Couldn't copy. Select the text and copy it instead."));
          }}
        >
          {copied ? (
            <Check className="size-4" aria-hidden="true" />
          ) : (
            <Copy className="size-4" aria-hidden="true" />
          )}
          {copied ? "Copied" : "Copy"}
        </Button>
      </div>
    </div>
  );
}

const CHECK_TEXT: Record<CheckOutcome, string> = {
  verified: "Verified. Your listings now say they're from the organizer.",
  queued: "We'll check within 30 minutes. This page updates when it's done.",
  not_yet: "We didn't find the record yet. DNS changes can take up to an hour; try again later.",
  resolver_error: "The DNS lookup didn't answer. Try again in a minute.",
  closed: "This claim is no longer waiting for proof.",
};

const STATUS_TONE: Record<OrganizerClaim["status"], string> = {
  pending: "bg-warning-tint text-warning",
  verified: "bg-going-tint text-text",
  failed: "bg-surface-2 text-text-2",
  revoked: "bg-surface-2 text-text-2",
};

/** One claim: what it is for, its state, the proof to put in place and "Check now". */
export function ClaimCard({ claim }: { claim: OrganizerClaim }) {
  const queryClient = useQueryClient();
  const check = useMutation({
    mutationFn: () => checkClaim(claim),
    onSuccess: (outcome) => {
      void queryClient.invalidateQueries({ queryKey: organizerKeys.all });
      if (outcome === "verified") toast.success(CHECK_TEXT.verified);
      else toast(CHECK_TEXT[outcome]);
    },
    onError: (err) => toast.error(organizerErrorMessage(err)),
  });
  const info = claimMethodInfo(claim.method);
  const copies = proofCopies(claim);
  const failure = claim.status === "verified" ? null : failureText(claim.failure);
  const sources = [
    ...(claim.source ? [{ id: claim.source.id, name: claim.source.name, extra: "" }] : []),
    ...claim.connected.map((c) => ({
      id: c.id,
      name: c.name,
      extra: c.stopped ? "stopped" : c.enabled ? "listing" : "waiting for its first read",
    })),
  ];

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <p className="text-[13px] text-text-2">{info.label}</p>
          <h3 className="text-[17px] font-bold break-words">{claim.source?.name ?? claim.host}</h3>
          <p className="text-[13px] break-all text-text-2">{claim.host}</p>
        </div>
        <span
          className={cn(
            "inline-flex h-6 shrink-0 items-center rounded-full px-2.5 text-[12px] font-semibold whitespace-nowrap",
            STATUS_TONE[claim.status],
          )}
        >
          {claimStatusLabel(claim)}
        </span>
      </header>

      {claim.status === "pending" ? (
        <>
          <p className="text-[14px] text-text-2">{info.summary}</p>
          {copies.map((c) => (
            <CopyValue key={c.label} label={c.label} value={c.value} />
          ))}
          {claim.method === "feed" && claim.feed_url ? (
            <p className="text-[13px] break-all text-text-2">Calendar: {claim.feed_url}</p>
          ) : null}
          <p className="text-[13px] text-text-2">
            {claim.last_checked_at
              ? `Last checked ${formatWhen(claim.last_checked_at)} · ${claim.attempts} of 10 checks`
              : "Not checked yet. Claims run out after 7 days or 10 checks."}
          </p>
        </>
      ) : null}

      {failure ? <p className="text-[14px] text-text-2">{failure}</p> : null}

      {sources.length > 0 && (claim.status === "verified" || claim.connected.length > 0) ? (
        <ul className="flex flex-col gap-2">
          {sources.map((s) => (
            <li key={s.id}>
              <Link
                to="/organizer/sources/$id"
                params={{ id: s.id }}
                className="flex min-h-11 items-center justify-between gap-3 rounded-tile bg-surface-2 px-3 py-2 text-[14px]"
              >
                <span className="min-w-0 font-semibold break-words">{s.name}</span>
                <span className="shrink-0 text-text-2">{s.extra || "Manage"}</span>
              </Link>
            </li>
          ))}
        </ul>
      ) : null}

      {claim.status === "pending" ? (
        <div className="flex flex-wrap justify-end gap-2">
          <Button size="sm" loading={check.isPending} onClick={() => check.mutate()}>
            Check now
          </Button>
        </div>
      ) : claim.status === "verified" && claim.method !== "feed" && claim.connected.length < 3 ? (
        <div className="flex flex-wrap justify-end gap-2">
          <Link
            to="/organizer/claim"
            search={{ connect: claim.claim_id }}
            className={buttonVariants({ size: "sm", variant: "secondary" })}
          >
            Connect a calendar
          </Link>
        </div>
      ) : null}
    </article>
  );
}
