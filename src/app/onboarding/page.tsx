import type { Metadata } from "next";
import { redirect } from "next/navigation";

import { LogoWordmark } from "@/components/shared/logo";
import { OnboardingFlow } from "@/components/shared/onboarding-flow";
import { ThemeToggle } from "@/components/shared/theme-toggle";
import { createClient } from "@/lib/supabase/server";

export const metadata: Metadata = {
  title: "Welcome",
};

export default async function OnboardingPage() {
  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user) {
    redirect("/login");
  }

  // Already onboarded → nothing to do here.
  const { data: profile } = await supabase
    .from("profiles")
    .select("id")
    .eq("id", user.id)
    .maybeSingle();

  if (profile) {
    redirect("/home");
  }

  return (
    <main className="relative flex min-h-dvh flex-col items-center justify-center gap-6 overflow-x-clip px-4 py-10">
      <div className="pointer-events-none absolute inset-x-0 top-0 -z-10 h-full bg-grid bg-grid-fade" />
      <div className="pointer-events-none absolute -top-32 left-1/2 -z-10 h-96 w-[36rem] -translate-x-1/2 rounded-full bg-violet-600/25 blur-[110px]" />
      <div className="absolute right-4 top-4">
        <ThemeToggle />
      </div>
      <LogoWordmark className="text-xl" />
      <OnboardingFlow />
    </main>
  );
}
