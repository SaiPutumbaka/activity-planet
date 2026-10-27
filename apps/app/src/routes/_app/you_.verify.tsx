import { useEffect, useState, type ReactNode } from "react";
import { createFileRoute, getRouteApi, useRouter } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { TopBar } from "@/components/shell/top-bar";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { CodeStep, EmailStep, VerifiedCard } from "@/components/you/verify-steps";
import {
  RESEND_COOLDOWN_SECONDS,
  confirmStatusMessage,
  confirmVerificationCode,
  membershipQuery,
  sendVerificationCode,
  verificationErrorMessage,
} from "@/lib/verification";

const appRoute = getRouteApi("/_app");

/**
 * Campus email verification. A sibling of the You tab at /you/verify (file name
 * `you_.verify.tsx`, like `you_.delete.tsx`), so it renders with its own TopBar.
 */
export const Route = createFileRoute("/_app/you_/verify")({
  component: VerifyPage,
});

interface Verified {
  orgName: string;
  campusName: string | null;
}

function VerifyPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const router = useRouter();
  const membership = useQuery(membershipQuery(userId));

  const [email, setEmail] = useState("");
  const [step, setStep] = useState<"email" | "code">("email");
  const [sendError, setSendError] = useState<string | null>(null);
  const [codeError, setCodeError] = useState<string | null>(null);
  const [cooldown, setCooldown] = useState(0);
  const [verified, setVerified] = useState<Verified | null>(null);

  useEffect(() => {
    if (cooldown <= 0) return;
    const id = setTimeout(() => setCooldown((c) => c - 1), 1000);
    return () => clearTimeout(id);
  }, [cooldown]);

  async function refreshAfterVerify() {
    await Promise.all([
      queryClient.invalidateQueries({ queryKey: ["org-membership"] }),
      // No profileQuery observer is mounted here, so an 'active' invalidation would leave the
      // cached row (home_org_id = null) for the _app guard's ensureQueryData to hand back.
      queryClient.invalidateQueries({ queryKey: ["profile"], refetchType: "all" }),
    ]);
    // Campus plans now show in the feed and on hub pages; mark them stale so they refetch on mount.
    void queryClient.invalidateQueries({ queryKey: ["feed"] });
    void queryClient.invalidateQueries({ queryKey: ["hubs", "events"] });
    // Re-runs the _app guard so its context carries the new home_org_id.
    await router.invalidate();
  }

  const send = useMutation({
    mutationFn: ({ to }: { to: string; again: boolean }) => sendVerificationCode(to),
    onSuccess: async (result, { to, again }) => {
      if (result.status === "already_verified" && result.own) {
        // Nothing to confirm: this account verified that address earlier.
        await refreshAfterVerify();
        const m = await queryClient.fetchQuery(membershipQuery(userId));
        setVerified({
          orgName: m?.organizations?.name ?? "your school",
          campusName: m?.org_campuses?.name ?? null,
        });
        return;
      }
      // 'sent' and 'already_verified' by someone else read the same here; the database
      // tells the difference when the code is checked.
      setEmail(to);
      setStep("code");
      setCodeError(null);
      setCooldown(RESEND_COOLDOWN_SECONDS);
      if (again) toast.success("Sent again. Give it a minute.");
    },
    onError: (err, { again }) => {
      const message = verificationErrorMessage(err);
      if (again) setCodeError(message);
      else setSendError(message);
    },
  });

  const confirm = useMutation({
    mutationFn: (code: string) => confirmVerificationCode(code, email),
    onSuccess: async (result) => {
      if (result.status === "ok") {
        await refreshAfterVerify();
        setVerified({ orgName: result.org_name, campusName: result.campus_name });
        return;
      }
      setCodeError(confirmStatusMessage(result));
    },
    onError: (err) => setCodeError(verificationErrorMessage(err)),
  });

  const existing = membership.data;
  const orgName = existing?.organizations?.name ?? "Georgia State University";

  let body: ReactNode;
  if (verified) {
    body = <VerifiedCard orgName={verified.orgName} campusName={verified.campusName} justNow />;
  } else if (membership.isPending) {
    body = (
      <div className="flex flex-col gap-3" aria-busy="true">
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-13 w-full rounded-control" />
      </div>
    );
  } else if (membership.isError) {
    body = (
      <FormError>
        Couldn't check your verification. {verificationErrorMessage(membership.error)}
      </FormError>
    );
  } else if (existing) {
    body = (
      <VerifiedCard
        orgName={orgName}
        campusName={existing.org_campuses?.name ?? null}
        justNow={false}
      />
    );
  } else if (step === "email") {
    body = (
      <EmailStep
        initialEmail={email}
        busy={send.isPending}
        error={sendError}
        onSend={(value) => {
          setSendError(null);
          send.mutate({ to: value, again: false });
        }}
      />
    );
  } else {
    body = (
      <CodeStep
        email={email}
        busy={confirm.isPending}
        error={codeError}
        cooldown={cooldown}
        resending={send.isPending}
        onConfirm={(code) => {
          setCodeError(null);
          confirm.mutate(code);
        }}
        onResend={() => {
          setCodeError(null);
          send.mutate({ to: email, again: true });
        }}
        onChangeEmail={() => {
          setStep("email");
          setCodeError(null);
          setSendError(null);
        }}
      />
    );
  }

  const showIntro = !verified && !existing && !membership.isPending;

  return (
    <>
      <TopBar title="Campus space" back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {showIntro ? (
          <section className="flex flex-col gap-2 pt-2">
            <h2 className="text-[22px] font-extrabold tracking-[-0.02em]">
              Verify your student email
            </h2>
            <p className="text-text-2">
              The campus space is where {orgName} students find chapters, campus events and the
              week's free food, and only verified students see it. Verify with the email your school
              gave you and the space opens up; it takes about a minute.
            </p>
          </section>
        ) : null}
        {body}
      </main>
    </>
  );
}
