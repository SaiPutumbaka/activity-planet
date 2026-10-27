import { useState, type FormEvent } from "react";
import { Link } from "@tanstack/react-router";
import { BadgeCheck } from "lucide-react";

import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Field, FormError } from "@/components/ui/field";
import { CODE_LENGTH, campusEmailSchema } from "@/lib/verification";

/* ------------------------------------------------------------------ */
/* 1. Email                                                             */
/* ------------------------------------------------------------------ */

export function EmailStep({
  initialEmail,
  busy,
  error,
  onSend,
}: {
  initialEmail: string;
  busy: boolean;
  error: string | null;
  onSend: (email: string) => void;
}) {
  const [email, setEmail] = useState(initialEmail);
  const [fieldError, setFieldError] = useState<string | null>(null);

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (busy) return;
    const parsed = campusEmailSchema.safeParse(email);
    if (!parsed.success) {
      setFieldError(parsed.error.issues[0]?.message ?? "Enter a valid email.");
      return;
    }
    onSend(parsed.data);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <Field
        label="Student email"
        type="email"
        inputMode="email"
        autoComplete="email"
        autoCapitalize="none"
        autoCorrect="off"
        spellCheck={false}
        placeholder="you@student.gsu.edu"
        value={email}
        onChange={(e) => {
          setEmail(e.target.value);
          setFieldError(null);
        }}
        error={fieldError ?? undefined}
        hint="We send a six-digit code there. Your sign-in email stays the same."
        disabled={busy}
      />
      <FormError>{error}</FormError>
      <Button type="submit" size="lg" block loading={busy}>
        Send code
      </Button>
    </form>
  );
}

/* ------------------------------------------------------------------ */
/* 2. Code                                                              */
/* ------------------------------------------------------------------ */

export function CodeStep({
  email,
  busy,
  error,
  cooldown,
  resending,
  onConfirm,
  onResend,
  onChangeEmail,
}: {
  email: string;
  busy: boolean;
  /** The last failed attempt, in words. Cleared by the parent when a new code is sent. */
  error: string | null;
  /** Seconds until "Send again" is allowed; 0 means now. */
  cooldown: number;
  resending: boolean;
  onConfirm: (code: string) => void;
  onResend: () => void;
  onChangeEmail: () => void;
}) {
  const [code, setCode] = useState("");
  const complete = code.length === CODE_LENGTH;

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!complete || busy) return;
    onConfirm(code);
  }

  return (
    <form onSubmit={submit} className="flex flex-col gap-4" noValidate>
      <p className="text-text-2">
        We sent a code to <span className="font-semibold text-text">{email}</span>. It works for 15
        minutes. Not there? Check spam.
      </p>
      <Field
        label="Six-digit code"
        type="text"
        inputMode="numeric"
        autoComplete="one-time-code"
        pattern="[0-9]*"
        maxLength={CODE_LENGTH}
        placeholder="123456"
        autoFocus
        className="tabular"
        value={code}
        onChange={(e) => setCode(e.target.value.replace(/\D/g, "").slice(0, CODE_LENGTH))}
        error={error ?? undefined}
        disabled={busy}
      />
      <Button type="submit" size="lg" block loading={busy} disabled={!complete}>
        Verify
      </Button>
      <div className="flex flex-col items-center gap-1">
        <Button
          variant="ghost"
          onClick={onResend}
          disabled={cooldown > 0 || busy}
          loading={resending}
        >
          {cooldown > 0 ? `Send again in ${cooldown}s` : "Send a new code"}
        </Button>
        <Button variant="ghost" onClick={onChangeEmail} disabled={busy || resending}>
          Use a different email
        </Button>
      </div>
    </form>
  );
}

/* ------------------------------------------------------------------ */
/* 3. Verified                                                          */
/* ------------------------------------------------------------------ */

/** The "You're in" state (green, like a going RSVP). */
export function VerifiedCard({
  orgName,
  campusName,
  justNow,
}: {
  orgName: string;
  campusName: string | null;
  /** True right after a successful code, false when the page opens already verified. */
  justNow: boolean;
}) {
  const space = campusName ? `${orgName} ${campusName}` : orgName;
  return (
    <div className="flex flex-col items-center gap-4 pt-4 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-going-tint text-going">
        <BadgeCheck className="size-8" aria-hidden="true" />
      </div>
      <div className="flex flex-col gap-1">
        <span className="inline-flex self-center rounded-control bg-going-tint px-2.5 py-1 text-[13px] font-bold text-going">
          You're in
        </span>
        <h2 className="text-[22px] font-extrabold tracking-[-0.02em]">
          {justNow ? `You're verified at ${space}` : `Verified at ${space}`}
        </h2>
        <p className="max-w-[34ch] text-text-2">
          {campusName
            ? `Chapters, campus events and the ${campusName} shelf show up for you now.`
            : `Your ${orgName} email is verified. Pick your campus on the You tab to see its space.`}
        </p>
      </div>
      <Link to="/you" className={buttonVariants({ variant: "secondary", size: "lg" })}>
        Back to You
      </Link>
    </div>
  );
}
