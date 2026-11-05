import { useEffect, useState } from "react";
import { createFileRoute, redirect } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import { coachingErrorMessage } from "@ap/core/coaching";

import { Note } from "@/components/coaching/parts";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import {
  coachTermsUrl,
  coaching,
  coachingConfigQuery,
  coachingKeys,
  payoutStatusQuery,
} from "@/lib/coaching";
import { SITE_URL } from "@/lib/site";

/**
 * Get paid in the app (design section 9.2): Stripe Connect Express onboarding, its state and the
 * Express dashboard. Payments on only: with coaching_config().payments_enabled false the route
 * goes back to /coach and no Stripe link exists anywhere in the app.
 */
export const Route = createFileRoute("/_app/coach_/payouts")({
  beforeLoad: async ({ context: { queryClient } }) => {
    const config = await queryClient.ensureQueryData(coachingConfigQuery).catch(() => null);
    if (!config?.payments_enabled) throw redirect({ to: "/coach", replace: true });
  },
  component: PayoutsPage,
});

const STATE_COPY = {
  none: "Not set up. Clients pay you directly until you connect a payout account.",
  onboarding: "Started. Finish the Stripe form to take payments in the app.",
  restricted: "Stripe needs more details before it can pay you.",
  active: "Ready. Payable listings take card payments in the app.",
} as const;

function PayoutsPage() {
  const queryClient = useQueryClient();
  const status = useQuery(payoutStatusQuery);
  const [country, setCountry] = useState("");

  // Coming back from Stripe: sync the account state before the webhook lands.
  useEffect(() => {
    if (status.data && status.data.state !== "none") {
      void coaching
        .stripeConnect("refresh")
        .then(() => queryClient.invalidateQueries({ queryKey: coachingKeys.payouts }))
        .catch(() => undefined);
    }
    // Once per visit.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [status.data?.state === undefined]);

  const go = useMutation({
    mutationFn: (op: "onboard" | "dashboard") =>
      coaching.stripeConnect(
        op,
        op === "onboard" ? country.trim().toUpperCase() || undefined : undefined,
      ),
    onSuccess: (r) => {
      if (r.url) window.location.assign(r.url);
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  return (
    <>
      <TopBar title="Get paid in the app" back />
      <main className="flex flex-col gap-5 pb-8 safe-px">
        {status.isPending ? (
          <Skeleton className="mt-2 h-32" />
        ) : status.isError ? (
          <FormError>{coachingErrorMessage(status.error)}</FormError>
        ) : (
          <>
            <p className="pt-2 text-[15px]">{STATE_COPY[status.data.state]}</p>
            {status.data.requirements_due > 0 ? (
              <p className="text-[14px] text-text-2">
                {status.data.requirements_due} item{status.data.requirements_due === 1 ? "" : "s"}{" "}
                due on Stripe.
              </p>
            ) : null}
            {status.data.state === "none" ? (
              <Field
                label="Country you coach in"
                maxLength={2}
                placeholder="Two letters, like US, GB, DE"
                value={country}
                onChange={(e) => setCountry(e.target.value)}
              />
            ) : null}
            {status.data.state !== "active" ? (
              <Button
                size="lg"
                block
                loading={go.isPending && go.variables === "onboard"}
                disabled={status.data.state === "none" && !/^[A-Za-z]{2}$/.test(country.trim())}
                onClick={() => go.mutate("onboard")}
              >
                {status.data.state === "none" ? "Set up payouts with Stripe" : "Continue on Stripe"}
              </Button>
            ) : null}
            {status.data.state !== "none" ? (
              <Button
                variant="secondary"
                block
                loading={go.isPending && go.variables === "dashboard"}
                onClick={() => go.mutate("dashboard")}
              >
                Open the Stripe dashboard
              </Button>
            ) : null}
            <Note>
              Payouts are made by Stripe under the{" "}
              <a
                href="https://stripe.com/connect-account/legal"
                target="_blank"
                rel="noreferrer"
                className="font-semibold text-link underline-offset-2 hover:underline"
              >
                Stripe Connected Account Agreement
              </a>
              , part of the{" "}
              <a
                href={coachTermsUrl(SITE_URL)}
                target="_blank"
                rel="noreferrer"
                className="font-semibold text-link underline-offset-2 hover:underline"
              >
                Coach Terms
              </a>
              . The platform fee is 12% (at least $3 in USD) and Activity Planet covers card
              processing.
            </Note>
          </>
        )}
      </main>
    </>
  );
}
