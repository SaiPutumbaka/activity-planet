"use client";

import Script from "next/script";
import { useState, type FormEvent } from "react";
import { parseTakedownRequest, takedownErrorMessage, TAKEDOWN_LIMITS } from "@ap/core/validation";

type Sent = { reference: string; dueAt: string | null };

/** Cloudflare Turnstile (migration 54): shown when the site key is configured; the route checks it. */
const TURNSTILE_SITE_KEY = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY ?? "";

declare global {
  interface Window {
    turnstile?: { reset: (widget?: string) => void };
  }
}

const field =
  "w-full rounded-xl border border-border bg-surface px-4 py-3 text-base text-text placeholder:text-text-3 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary";

/** The request form: checked here for quick feedback, then again by the database. */
export function RequestForm({ supportEmail }: { supportEmail: string }) {
  const [error, setError] = useState<string | null>(null);
  const [sending, setSending] = useState(false);
  const [sent, setSent] = useState<Sent | null>(null);

  async function onSubmit(e: FormEvent<HTMLFormElement>) {
    e.preventDefault();
    const f = new FormData(e.currentTarget);
    const input = {
      name: String(f.get("name") ?? ""),
      email: String(f.get("email") ?? ""),
      relationship: String(f.get("relationship") ?? ""),
      locations: String(f.get("locations") ?? ""),
      description: String(f.get("description") ?? ""),
      goodFaith: f.get("goodFaith") === "on",
      signature: String(f.get("signature") ?? ""),
      involvesMinor: f.get("involvesMinor") === "on",
    };
    const checked = parseTakedownRequest(input);
    if (!checked.ok) {
      setError(takedownErrorMessage(checked.error));
      return;
    }
    setError(null);
    setSending(true);
    try {
      const res = await fetch("/api/takedown", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          ...checked.value,
          turnstileToken: String(f.get("cf-turnstile-response") ?? ""),
        }),
      });
      const body = (await res.json().catch(() => ({}))) as {
        reference?: string;
        due_at?: string | null;
        error?: string;
      };
      if (!res.ok || !body.reference) {
        setError(takedownErrorMessage(body.error ?? "unavailable"));
        window.turnstile?.reset();
        return;
      }
      setSent({ reference: body.reference, dueAt: body.due_at ?? null });
    } catch {
      setError(takedownErrorMessage("unavailable"));
    } finally {
      setSending(false);
    }
  }

  if (sent) {
    const due = sent.dueAt ? new Date(sent.dueAt) : null;
    return (
      <div role="status" className="flex flex-col gap-3 rounded-2xl bg-going-tint p-6">
        <h2 className="text-2xl font-semibold tracking-tight">We have your request</h2>
        <p className="text-text-2">
          Your reference is <strong className="font-mono text-text">{sent.reference}</strong>. Keep
          it; quote it if you write to us.
        </p>
        <p className="text-text-2">
          A moderator reviews it and removes the image and any copies we find
          {due ? (
            <>
              {" "}
              by{" "}
              <strong className="text-text">
                {due.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })}
              </strong>
            </>
          ) : (
            " within 48 hours"
          )}
          . We write to the email address you gave if we need anything else, and to tell you what we
          did.
        </p>
      </div>
    );
  }

  return (
    <form onSubmit={onSubmit} noValidate className="flex flex-col gap-6">
      <div className="flex flex-col gap-2">
        <label htmlFor="name" className="font-semibold">
          Your full name
        </label>
        <input
          id="name"
          name="name"
          autoComplete="name"
          required
          maxLength={TAKEDOWN_LIMITS.name}
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
          maxLength={TAKEDOWN_LIMITS.email}
          className={field}
        />
        <p className="text-sm text-text-2">You do not need an Activity Planet account.</p>
      </div>

      <fieldset className="flex flex-col gap-2">
        <legend className="mb-2 font-semibold">Who are you?</legend>
        <label className="flex items-start gap-3">
          <input type="radio" name="relationship" value="self" required className="mt-1 size-4" />
          <span>I am the person shown in the image.</span>
        </label>
        <label className="flex items-start gap-3">
          <input type="radio" name="relationship" value="authorized" className="mt-1 size-4" />
          <span>
            I am acting for the person shown, with their permission (for example a parent, a lawyer
            or someone they asked to help).
          </span>
        </label>
      </fieldset>

      <div className="flex flex-col gap-2">
        <label htmlFor="locations" className="font-semibold">
          Where is the image?
        </label>
        <textarea
          id="locations"
          name="locations"
          required
          rows={4}
          maxLength={TAKEDOWN_LIMITS.locations}
          className={field}
          aria-describedby="locations-help"
        />
        <p id="locations-help" className="text-sm text-text-2">
          Paste links to the profile, plan or page, or give the person&rsquo;s name or handle and
          say where the image appears (a profile photo, a plan&rsquo;s cover). Please do not send us
          the image itself.
        </p>
      </div>

      <div className="flex flex-col gap-2">
        <label htmlFor="description" className="font-semibold">
          Anything else that helps us (optional)
        </label>
        <textarea
          id="description"
          name="description"
          rows={3}
          maxLength={TAKEDOWN_LIMITS.description}
          className={field}
        />
      </div>

      <label className="flex items-start gap-3 rounded-xl bg-warning-tint p-4">
        <input type="checkbox" name="involvesMinor" className="mt-1 size-4" />
        <span>
          The person shown is, or may be, under 18. We treat this as urgent and report it to the
          National Center for Missing &amp; Exploited Children as the law requires.
        </span>
      </label>

      <label className="flex items-start gap-3">
        <input type="checkbox" name="goodFaith" required className="mt-1 size-4" />
        <span>
          I believe in good faith that this intimate image was shared without the consent of the
          person shown, and the information in this request is accurate.
        </span>
      </label>

      <div className="flex flex-col gap-2">
        <label htmlFor="signature" className="font-semibold">
          Signature: type your full name
        </label>
        <input
          id="signature"
          name="signature"
          required
          maxLength={TAKEDOWN_LIMITS.signature}
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
            href={`mailto:${supportEmail}?subject=Intimate%20image%20removal`}
            className="font-semibold text-text underline-offset-2 hover:underline"
          >
            {supportEmail}
          </a>
          .
        </p>
      </div>
    </form>
  );
}
