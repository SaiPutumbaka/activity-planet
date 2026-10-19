import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { authErrorMessage, authRedirect, googleEnabled } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

/** Third-party sign-in. Only renders providers that are configured (VITE_AUTH_GOOGLE=1). */
export function OAuthButtons({ next }: { next?: string }) {
  const [busy, setBusy] = useState(false);
  if (!googleEnabled) return null;

  async function google() {
    setBusy(true);
    const redirectTo = next
      ? `${authRedirect.callback()}?next=${encodeURIComponent(next)}`
      : authRedirect.callback();
    const { error } = await supabase.auth.signInWithOAuth({
      provider: "google",
      options: { redirectTo, queryParams: { prompt: "select_account" } },
    });
    if (error) {
      toast.error(authErrorMessage(error));
      setBusy(false);
    }
  }

  return (
    <div className="flex flex-col gap-3">
      <Button variant="outline" block loading={busy} onClick={google} leading={<GoogleGlyph />}>
        Continue with Google
      </Button>
      <div className="flex items-center gap-3 text-[12px] font-semibold uppercase tracking-[0.08em] text-text-3">
        <span className="h-px flex-1 bg-border" />
        or
        <span className="h-px flex-1 bg-border" />
      </div>
    </div>
  );
}

function GoogleGlyph() {
  return (
    <svg viewBox="0 0 24 24" className="size-5" aria-hidden="true">
      <path
        fill="#4285F4"
        d="M21.6 12.23c0-.68-.06-1.33-.17-1.96H12v3.7h5.38a4.6 4.6 0 0 1-2 3.02v2.5h3.24c1.9-1.75 2.98-4.32 2.98-7.26Z"
      />
      <path
        fill="#34A853"
        d="M12 22c2.7 0 4.96-.9 6.62-2.42l-3.24-2.5c-.9.6-2.04.96-3.38.96-2.6 0-4.8-1.76-5.58-4.12H3.07v2.58A10 10 0 0 0 12 22Z"
      />
      <path
        fill="#FBBC05"
        d="M6.42 13.92A6 6 0 0 1 6.1 12c0-.67.12-1.31.32-1.92V7.5H3.07A10 10 0 0 0 2 12c0 1.61.39 3.14 1.07 4.5l3.35-2.58Z"
      />
      <path
        fill="#EA4335"
        d="M12 5.96c1.47 0 2.78.5 3.82 1.5l2.86-2.87A9.98 9.98 0 0 0 12 2a10 10 0 0 0-8.93 5.5l3.35 2.58C7.2 7.72 9.4 5.96 12 5.96Z"
      />
    </svg>
  );
}
