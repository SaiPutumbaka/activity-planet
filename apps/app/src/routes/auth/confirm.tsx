import { useEffect, useRef, useState } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { z } from "zod";

import { Button } from "@/components/ui/button";
import { Spinner } from "@/components/ui/spinner";
import { authErrorMessage } from "@/lib/auth";
import { completeAuthLink } from "@/lib/auth-links";
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

  useEffect(() => {
    if (started.current) return; // StrictMode mounts twice in dev; a token can be used once.
    started.current = true;
    completeAuthLink(search)
      .then(() => {
        if (search.type === "recovery") return navigate({ to: "/auth/reset", replace: true });
        return navigate({ to: internalTo(search.next), replace: true });
      })
      .catch((err: unknown) => setError(authErrorMessage(err)));
  }, [search, navigate]);

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

  return (
    <div className="flex flex-col items-center gap-3 pt-10 text-text-2">
      <Spinner className="size-7" label="Signing you in" />
      <p>Signing you in…</p>
    </div>
  );
}
