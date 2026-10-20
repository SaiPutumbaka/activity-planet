import { useState, type FormEvent } from "react";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { toast } from "sonner";

import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { rpcErrorMessage } from "@/lib/auth";
import { supabase } from "@/lib/supabase";

/**
 * Delete my account (Apple 5.1.1(v), Google Play). The file is `you_.delete.tsx` rather than
 * `you/delete.tsx` so the screen is a sibling of the You tab at /you/delete instead of a child
 * rendered inside it.
 */
export const Route = createFileRoute("/_app/you_/delete")({
  component: DeleteAccountPage,
});

const CONFIRM_WORD = "delete";

const REMOVED_NOW = [
  "Your name, handle, photo, bio and campus",
  "Your date of birth, email address and location",
  "The hubs you joined, your notification settings and push registrations",
  "Your sign-in; the email address can be used for a new account straight away",
];

const KEPT = [
  "A deletion record (account ID, a one-way hash of your email, the time, any reason you give) for 30 days, so moderators can act on reports about the account",
  "Your old handle, held for 30 days before anyone else can take it",
  "Anything other people received from you stays with them, signed “Deleted user”",
];

function DeleteAccountPage() {
  const navigate = useNavigate();
  const [confirm, setConfirm] = useState("");
  const [reason, setReason] = useState("");
  const [busy, setBusy] = useState(false);
  const [formError, setFormError] = useState<string | null>(null);
  const confirmed = confirm.trim().toLowerCase() === CONFIRM_WORD;

  async function onSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!confirmed || busy) return;
    setBusy(true);
    setFormError(null);

    // One transaction in the database: ledger row, tombstone profile, private data gone,
    // sign-in banned. If this fails nothing has changed.
    const trimmedReason = reason.trim();
    const { error: rpcError } = await supabase.rpc(
      "request_account_deletion",
      trimmedReason ? { p_reason: trimmedReason } : {},
    );
    if (rpcError) {
      setFormError(rpcErrorMessage(rpcError));
      setBusy(false);
      return;
    }

    // From here the account is closed whatever happens next. The function frees the email
    // address and ends every session; if it fails, support finishes it from the ledger.
    const { error: fnError } = await supabase.functions.invoke("delete-account", {
      method: "POST",
    });

    // The server-side session is already gone when the function succeeded, so a refused
    // /logout is expected; fall back to clearing this device only.
    const { error: signOutError } = await supabase.auth.signOut();
    if (signOutError) await supabase.auth.signOut({ scope: "local" });

    if (fnError) {
      toast.warning(
        "Your account is closed. Freeing your email address didn't finish; email support@activityplanet.app if you need it sooner.",
        { duration: 10_000 },
      );
    } else {
      toast.success("Your account has been deleted.");
    }
    await navigate({ to: "/auth/sign-in", replace: true });
  }

  return (
    <>
      <TopBar title="Delete account" back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        <section className="flex flex-col gap-2 pt-2">
          <h2 className="text-[22px] font-extrabold tracking-[-0.02em]">
            This deletes your account right away
          </h2>
          <p className="text-text-2">
            It cannot be undone. You can create a new account later with the same email.
          </p>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Removed now
          </h3>
          <ul className="flex flex-col gap-1.5 rounded-card border border-border px-4 py-3 text-[15px]">
            {REMOVED_NOW.map((item) => (
              <li key={item} className="flex gap-2">
                <span aria-hidden="true" className="text-text-3">
                  –
                </span>
                <span>{item}</span>
              </li>
            ))}
          </ul>
        </section>

        <section className="flex flex-col gap-2">
          <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            Kept, and for how long
          </h3>
          <ul className="flex flex-col gap-1.5 rounded-card border border-border px-4 py-3 text-[15px] text-text-2">
            {KEPT.map((item) => (
              <li key={item} className="flex gap-2">
                <span aria-hidden="true" className="text-text-3">
                  –
                </span>
                <span>{item}</span>
              </li>
            ))}
          </ul>
          <p className="text-[13px] text-text-3">
            Nothing else is kept. If you ever pay for something through Activity Planet, that
            payment record stays as long as tax law requires.
          </p>
        </section>

        <form onSubmit={onSubmit} className="flex flex-col gap-4" noValidate>
          <Field
            label="Why are you leaving? (optional)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            maxLength={500}
            autoComplete="off"
            disabled={busy}
          />
          <Field
            label={`Type ${CONFIRM_WORD} to confirm`}
            value={confirm}
            onChange={(e) => setConfirm(e.target.value)}
            placeholder={CONFIRM_WORD}
            autoComplete="off"
            autoCapitalize="none"
            autoCorrect="off"
            spellCheck={false}
            disabled={busy}
          />
          <FormError>{formError}</FormError>
          <Button
            type="submit"
            variant="danger"
            size="lg"
            block
            disabled={!confirmed}
            loading={busy}
          >
            Delete my account
          </Button>
        </form>
      </main>
    </>
  );
}
