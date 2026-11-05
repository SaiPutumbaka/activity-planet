"use client";

import Script from "next/script";
import { useState, type FormEvent } from "react";
import {
  LISTING_RELATIONSHIPS,
  LISTING_RELATIONSHIP_LABELS,
  LISTING_REMOVAL_LIMITS,
  listingRemovalErrorMessage,
  parseListingRemoval,
} from "@ap/core/validation";

/** Cloudflare Turnstile: shown when the site key is configured; the route checks it. */
const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? "";

declare global {
  interface Window {
    turnstile?: { reset: (widget?: string) => void };
  }
}

const field =
  "w-full min-w-0 rounded-xl border border-border bg-surface px-4 py-3 text-base text-text placeholder:text-text-3 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary";

/**
 * The listing removal form (modelled on the intimate-image request form): checked here for quick
 * feedback, then again by the route and the database. Prefilled with the event from ?event=.
 */
export function RequestForm({
  supportEmail,
  eventId,
}: {
  supportEmail: string;
  eventId: string | null;
}) {
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [reference, setReference] = useState<string | null>(null);
  const [useEvent, setUseEvent] = useState(eventId !== null);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const input = {
      eventId: useEvent ? eventId : null,
      listing: String(f.get("listing") ?? ""),
      scope: String(f.get("scope") ?? "item"),
      name: String(f.get("name") ?? ""),
      email: String(f.get("email") ?? ""),
      relationship: String(f.get("relationship") ?? ""),
      reason: String(f.get("reason") ?? ""),
    };
    const checked = parseListingRemoval(input);
    if (!checked.ok) {
      setError(listingRemovalErrorMessage(checked.error));
      return;
    }
    setError(null);
    setSending(true);
    try {
      const res = await fetch("/api/listing-removal", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...input,
          turnstileToken: String(f.get("cf-turnstile-response") ?? ""),
        }),
      });
      const body = (await res.json().catch(() => ({}))) as { reference?: string; error?: string };
      if (!res.ok || !body.reference) {
        setError(listingRemovalErrorMessage(body.error ?? "unavailable"));
        window.turnstile?.reset();
        return;
      }
      setReference(body.reference);
    } catch {
      setError(listingRemovalErrorMessage("unavailable"));
    } finally {
      setSending(false);
    }
  }

  if (reference) {
    return (
      <div role="status" className="flex flex-col gap-3 rounded-2xl bg-going-tint p-6">
        <h2 className="text-2xl font-semibold tracking-tight">We have your request</h2>
        <p className="text-text-2">
          Your reference is <strong className="font-mono text-text">{reference}</strong>. Keep it;
          quote it if you write to us.
        </p>
        <p className="text-text-2">
          A moderator reviews it, usually within 72 hours. We write to the email address you gave if
          we need anything else.
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} noValidate className="flex flex-col gap-6">
      {eventId && useEvent ? (
        <div className="flex flex-col gap-2 rounded-xl bg-surface-2 p-4">
          <p className="font-semibold">The listing</p>
          <p className="text-text-2">
            The event you opened this form from. Reference{" "}
            <span className="font-mono text-sm break-all text-text">{eventId}</span>
          </p>
          <button
            type="button"
            onClick={() => setUseEvent(false)}
            className="w-fit text-sm font-semibold text-text underline underline-offset-2"
          >
            A different listing
          </button>
        </div>
      ) : (
        <div className="flex flex-col gap-2">
          <label htmlFor="listing" className="font-semibold">
            Which listing?
          </label>
          <input
            id="listing"
            name="listing"
            type="url"
            inputMode="url"
            autoComplete="off"
            required
            maxLength={LISTING_REMOVAL_LIMITS.listing}
            placeholder="https://"
            className={field}
            aria-describedby="listing-help"
          />
          <p id="listing-help" className="text-sm text-text-2">
            Paste the Activity Planet link of the event, or the link of your page or calendar it
            came from.
          </p>
        </div>
      )}

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 font-semibold">What should we remove?</legend>
        <label className="flex items-start gap-3">
          <input
            type="radio"
            name="scope"
            value="item"
            defaultChecked
            className="mt-1 size-4 shrink-0"
          />
          <span>Only this listing.</span>
        </label>
        <label className="flex items-start gap-3">
          <input type="radio" name="scope" value="source" className="mt-1 size-4 shrink-0" />
          <span>Everything from the same calendar or site, and stop reading it.</span>
        </label>
      </fieldset>

      <div className="flex flex-col gap-2">
        <label htmlFor="name" className="font-semibold">
          Your name
        </label>
        <input
          id="name"
          name="name"
          autoComplete="name"
          required
          maxLength={LISTING_REMOVAL_LIMITS.name}
          className={field}
        />
      </div>

      <div className="flex flex-col gap-2">
        <label htmlFor="email" className="font-semibold">
          Email address we can reach you at
        </label>
        <input
          id="email"
          name="email"
          type="email"
          autoComplete="email"
          required
          maxLength={LISTING_REMOVAL_LIMITS.email}
          className={field}
        />
        <p className="text-sm text-text-2">You do not need an Activity Planet account.</p>
      </div>

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 font-semibold">How are you connected to it?</legend>
        {LISTING_RELATIONSHIPS.map((r, i) => (
          <label key={r} className="flex items-start gap-3">
            <input
              type="radio"
              name="relationship"
              value={r}
              required={i === 0}
              className="mt-1 size-4 shrink-0"
            />
            <span>{LISTING_RELATIONSHIP_LABELS[r]}</span>
          </label>
        ))}
      </fieldset>

      <div className="flex flex-col gap-2">
        <label htmlFor="reason" className="font-semibold">
          Anything else that helps us (optional)
        </label>
        <textarea
          id="reason"
          name="reason"
          rows={3}
          maxLength={LISTING_REMOVAL_LIMITS.reason}
          className={field}
        />
      </div>

      {TURNSTILE_SITE_KEY ? (
        <>
          <Script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer />
          <div className="cf-turnstile" data-sitekey={TURNSTILE_SITE_KEY} />
        </>
      ) : null}

      {error ? (
        <p role="alert" className="rounded-xl bg-danger-tint p-4 text-text">
          {error}
        </p>
      ) : null}

      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <button
          type="submit"
          disabled={sending}
          className="inline-flex w-fit items-center rounded-full bg-primary px-6 py-3 text-base font-semibold text-on-primary disabled:opacity-60"
        >
          {sending ? "Sending..." : "Send removal request"}
        </button>
        <p className="text-sm text-text-2">
          Trouble with the form? Email{" "}
          <a
            href={`mailto:${supportEmail}?subject=Listing%20removal`}
            className="font-semibold break-all text-text underline-offset-2 hover:underline"
          >
            {supportEmail}
          </a>
          .
        </p>
      </div>
    </form>
  );
}
