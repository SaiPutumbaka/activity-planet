import { useState } from "react";
import { createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { toast } from "sonner";
import { Mark } from "@ap/ui/brand";
import { ageOn } from "@ap/core/validation";

import {
  AboutStep,
  BirthdayStep,
  CampusStep,
  HubsStep,
  UnderageScreen,
} from "@/components/onboarding/steps";
import { authErrorMessage, getSession, rpcErrorMessage, signOut } from "@/lib/auth";
import { cn } from "@/lib/cn";
import { campusesQuery, getProfile, hubCatalogQuery, profileQuery } from "@/lib/profile";
import { supabase } from "@/lib/supabase";

/**
 * First run: birthday (18+ gate), name and handle, hubs, campus. Everything is held in local
 * state and written in one transaction by complete_onboarding at the end, so an abandoned
 * flow leaves nothing behind.
 */
export const Route = createFileRoute("/onboarding")({
  beforeLoad: async ({ context: { queryClient } }) => {
    const session = await getSession(queryClient);
    if (!session)
      throw redirect({ to: "/auth/sign-in", search: { next: "/onboarding" }, replace: true });
    const profile = await getProfile(queryClient, session.user.id);
    if (profile.onboarding_completed_at) throw redirect({ to: "/", replace: true });
    return { session, profile };
  },
  loader: ({ context: { queryClient } }) => {
    void queryClient.prefetchQuery(hubCatalogQuery);
    void queryClient.prefetchQuery(campusesQuery);
  },
  component: OnboardingPage,
});

type Step = "birthday" | "about" | "hubs" | "campus";
const STEPS: Step[] = ["birthday", "about", "hubs", "campus"];

function OnboardingPage() {
  const { session, profile } = Route.useRouteContext();
  const { queryClient } = Route.useRouteContext();
  const navigate = useNavigate();

  const [step, setStep] = useState<Step>("birthday");
  const [underage, setUnderage] = useState(false);
  const [birthDate, setBirthDate] = useState("");
  const [firstName, setFirstName] = useState(profile.first_name);
  const [handle, setHandle] = useState("");
  const [hubIds, setHubIds] = useState<string[]>([]);
  const [campusId, setCampusId] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [signingOut, setSigningOut] = useState(false);

  async function onSignOut() {
    setSigningOut(true);
    try {
      await signOut();
      await navigate({ to: "/auth/sign-in", replace: true });
    } catch (err) {
      toast.error(authErrorMessage(err));
      setSigningOut(false);
    }
  }

  async function finish(chosenCampus: string | null) {
    setCampusId(chosenCampus);
    setSubmitting(true);
    setSubmitError(null);
    const { data, error } = await supabase.rpc("complete_onboarding", {
      p_handle: handle,
      p_first_name: firstName,
      p_birth_date: birthDate,
      p_hub_ids: hubIds,
      ...(chosenCampus ? { p_campus_id: chosenCampus } : {}),
    });
    setSubmitting(false);
    if (error) {
      const message = rpcErrorMessage(error);
      if (message.includes("18 and over")) {
        setUnderage(true);
        return;
      }
      if (message.includes("handle")) {
        setSubmitError(message);
        setStep("about");
        return;
      }
      setSubmitError(message);
      return;
    }
    queryClient.setQueryData(profileQuery(session.user.id).queryKey, data);
    void queryClient.invalidateQueries({ queryKey: ["my-hubs"] });
    toast.success(`You're in, ${data.first_name}.`);
    await navigate({ to: "/", replace: true });
  }

  const index = STEPS.indexOf(step);

  return (
    <div className="mx-auto flex min-h-dvh w-full max-w-lg flex-col safe-px safe-pt">
      <header className="flex items-center gap-3 py-4">
        <Mark size={28} />
        <div
          className="flex flex-1 gap-1.5"
          aria-label={`Step ${index + 1} of ${STEPS.length}`}
          role="progressbar"
          aria-valuenow={index + 1}
          aria-valuemin={1}
          aria-valuemax={STEPS.length}
        >
          {STEPS.map((s, i) => (
            <span
              key={s}
              className={cn(
                "h-1.5 flex-1 rounded-full",
                i <= index && !underage ? "bg-primary" : "bg-surface-3",
              )}
            />
          ))}
        </div>
        {index > 0 && !underage ? (
          <button
            type="button"
            onClick={() => setStep(STEPS[index - 1] ?? "birthday")}
            className="text-[14px] font-semibold text-text-2"
          >
            Back
          </button>
        ) : (
          <button
            type="button"
            onClick={onSignOut}
            disabled={signingOut}
            className="text-[14px] font-semibold text-text-2"
          >
            Sign out
          </button>
        )}
      </header>

      <main className="flex flex-1 flex-col">
        {underage ? (
          <UnderageScreen onSignOut={onSignOut} signingOut={signingOut} />
        ) : step === "birthday" ? (
          <BirthdayStep
            initial={birthDate}
            onUnderage={() => setUnderage(true)}
            onContinue={(d) => {
              setBirthDate(d);
              setStep("about");
            }}
          />
        ) : step === "about" ? (
          <AboutStep
            initialFirstName={firstName}
            initialHandle={handle}
            onContinue={(v) => {
              setFirstName(v.firstName);
              setHandle(v.handle);
              setSubmitError(null);
              setStep("hubs");
            }}
          />
        ) : step === "hubs" ? (
          <HubsStep
            age={ageOn(birthDate)}
            initialSelected={hubIds}
            onContinue={(ids) => {
              setHubIds(ids);
              setStep("campus");
            }}
          />
        ) : (
          <CampusStep
            initialCampusId={campusId}
            submitting={submitting}
            error={submitError}
            onFinish={finish}
          />
        )}
      </main>
    </div>
  );
}
