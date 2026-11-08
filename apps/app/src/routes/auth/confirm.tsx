import { useEffect, useRef, useState } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";

import { AccountSwitchPrompt } from "@/components/auth/account-switch";
import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { authErrorMessage } from "@/lib/auth";
import { SWITCH_CANCELLED, completeAuthLink } from "@/lib/auth-links";
import { useAccountSwitchPrompt } from "@/lib/use-account-switch";
import { markRecoveryVerified } from "@/lib/recovery";
import { internalTo } from "@/lib/navigation";

const searchSchema = z.object({
  token_hash: z.string().optional(),
  type: z.string().optional(),
  code: z.string().optional(),
  next: z.string().optional(),
  error: z.string().optional(),
  error_code: z.string().optional(),
  error_description: z.string().optional(),
});

/** Lands every email link: sign-up confirmation, magic link, email change. */
export const Route = createFileRoute("/auth/confirm")({
  validateSearch: searchSchema,
  component: ConfirmPage,
});

function ConfirmPage() {
  const search = Route.useSearch();
  const navigate = useNavigate();
  const [error, setError] = useState<string | null>(null);
  const started = useRef(false);
  const switchPrompt = useAccountSwitchPrompt();
  const { confirm } = switchPrompt;

  useEffect(() => {
    if (started.current) return; // StrictMode mounts twice in dev; a token can be used once.
    started.current = true;
    completeAuthLink(search, confirm)
      .then(() => {
        if (search.type === "recovery") {
          markRecoveryVerified();
          return navigate({ to: "/auth/reset", replace: true });
        }
        // internalTo keeps `next` to a same-origin relative path (no open redirect).
        return navigate({ to: internalTo(search.next), replace: true });
      })
      .catch((err: unknown) => {
        const code = typeof err === "object" && err && "code" in err ? String(err.code) : "";
        // Chose to stay in the account already signed in here: back to the app; the
        // session the link created was revoked.
        if (code === SWITCH_CANCELLED) return navigate({ to: "/", replace: true });
        setError(authErrorMessage(err));
      });
  }, [search, navigate, confirm]);

  if (error) {
    return (
      <div className="flex flex-col items-center gap-4 pt-6 text-center">
        <h1 className="text-[26px] font-extrabold tracking-[-0.025em]">That link didn't work</h1>
        <p className="max-w-[34ch] text-text-2">{error}</p>
        <Link to="/auth/sign-in">
          <Button variant="secondary">Sign in</Button>
        </Link>
      </div>
    );
  }

  if (switchPrompt.pending) {
    return <AccountSwitchPrompt accounts={switchPrompt.pending} onAnswer={switchPrompt.answer} />;
  }

  return (
    <div className="flex flex-col items-center gap-3 pt-10 text-text-2">
      <Spinner className="size-7" label="Signing you in" />
      <p>Signing you in…</p>
    </div>
  );
}
