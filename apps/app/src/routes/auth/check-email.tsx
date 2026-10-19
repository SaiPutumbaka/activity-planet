import { useEffect, useState } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { z } from "zod";
import { MailCheck } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { authErrorMessage, authRedirect } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

const searchSchema = z.object({
  email: z.string().optional(),
  kind: z.enum(["signup", "magic", "reset"]).optional(),
  next: z.string().optional(),
});

export const Route = createFileRoute("/auth/check-email")({
  validateSearch: searchSchema,
  component: CheckEmailPage,
});

const COPY = {
  signup: {
    title: "Check your email",
    body: "We sent a link to finish creating your account. If there's already an account with this email, the link signs you in instead.",
  },
  magic: {
    title: "Check your email",
    body: "Tap the link we sent to sign in. It works on this phone or any other.",
  },
  reset: { title: "Check your email", body: "Tap the link we sent to choose a new password." },
} as const;

function CheckEmailPage() {
  const { email, kind = "signup", next } = Route.useSearch();
  const [cooldown, setCooldown] = useState(0);
  const [resending, setResending] = useState(false);

  useEffect(() => {
    if (cooldown <= 0) return;
    const id = setTimeout(() => setCooldown((c) => c - 1), 1000);
    return () => clearTimeout(id);
  }, [cooldown]);

  async function resend() {
    if (!email) return;
    setResending(true);
    const result =
      kind === "signup"
        ? await supabase.auth.resend({
            type: "signup",
            email,
            options: { emailRedirectTo: authRedirect.confirm() },
          })
        : kind === "magic"
          ? await supabase.auth.signInWithOtp({
              email,
              options: { emailRedirectTo: authRedirect.confirm() },
            })
          : await supabase.auth.resetPasswordForEmail(email, { redirectTo: authRedirect.reset() });
    setResending(false);
    if (result.error) {
      toast.error(authErrorMessage(result.error));
      return;
    }
    toast.success("Sent again. Give it a minute.");
    setCooldown(60);
  }

  const copy = COPY[kind];

  return (
    <div className="flex flex-col items-center gap-5 pt-6 text-center">
      <div className="flex size-16 items-center justify-center rounded-full bg-primary-tint text-primary-text">
        <MailCheck className="size-8" aria-hidden="true" />
      </div>
      <div>
        <h1 className="text-[26px] font-extrabold tracking-[-0.025em]">{copy.title}</h1>
        {email ? <p className="mt-1 font-semibold">{email}</p> : null}
        <p className="mt-2 max-w-[34ch] text-text-2">{copy.body}</p>
      </div>
      <p className="text-[13px] text-text-3">
        Not there? Check spam, or wait a minute and try again.
      </p>
      <Button
        variant="secondary"
        onClick={resend}
        disabled={!email || cooldown > 0}
        loading={resending}
      >
        {cooldown > 0 ? `Resend in ${cooldown}s` : "Resend email"}
      </Button>
      <Link
        to="/auth/sign-in"
        search={{ next }}
        className="text-[14px] font-semibold text-primary-text"
      >
        Back to sign in
      </Link>
    </div>
  );
}
