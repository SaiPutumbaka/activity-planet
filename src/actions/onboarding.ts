"use server";

import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import { onboardingSchema } from "@/lib/validation/onboarding";

export type OnboardingActionResult = { status: "error"; message: string };

const UNIQUE_VIOLATION = "23505";

export async function completeOnboardingAction(
  input: unknown,
): Promise<OnboardingActionResult> {
  const parsed = onboardingSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Please fix the errors and try again." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();

  if (!user || !user.email) {
    redirect("/login");
  }

  // RLS additionally guarantees id = auth.uid() and email = JWT email —
  // a tampered payload cannot create a profile for anyone else.
  const { error } = await supabase.from("profiles").insert({
    id: user.id,
    email: user.email,
    username: parsed.data.username,
    full_name: parsed.data.fullName,
    organization: parsed.data.organization,
    selected_hobbies: parsed.data.selectedHobbies,
  });

  if (error) {
    if (error.code === UNIQUE_VIOLATION) {
      // Duplicate primary key means the profile already exists (double
      // submit or revisit) — onboarding is done, move along.
      if (error.message.includes("profiles_pkey")) {
        redirect("/home");
      }
      return {
        status: "error",
        message: "That username is already taken. Try another one.",
      };
    }
    return {
      status: "error",
      message: "Something went wrong saving your profile. Please try again.",
    };
  }

  redirect("/home");
}
