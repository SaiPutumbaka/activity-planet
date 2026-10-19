"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import {
  loginSchema,
  safeInternalPath,
  signupSchema,
} from "@/lib/validation/auth";

export type AuthActionResult =
  | { status: "error"; message: string }
  | { status: "confirm_email"; message: string };

export async function signUpAction(input: unknown): Promise<AuthActionResult> {
  const parsed = signupSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Please fix the errors and try again." };
  }

  const supabase = await createClient();
  const requestHeaders = await headers();
  const origin = requestHeaders.get("origin");
  if (!origin) {
    return { status: "error", message: "Could not determine request origin." };
  }

  const { data, error } = await supabase.auth.signUp({
    email: parsed.data.email,
    password: parsed.data.password,
    options: {
      emailRedirectTo: `${origin}/auth/callback`,
    },
  });

  if (error) {
    return { status: "error", message: error.message };
  }

  // When email confirmation is on, Supabase returns a fake success with an
  // empty identities array for an already-registered email.
  if (data.user && data.user.identities?.length === 0) {
    return {
      status: "error",
      message: "An account with this email already exists. Try logging in.",
    };
  }

  // Email confirmation disabled in the Supabase project → session is live now.
  if (data.session) {
    redirect("/home");
  }

  return {
    status: "confirm_email",
    message:
      "Almost there! Check your inbox and click the confirmation link to activate your account.",
  };
}

export async function signInAction(
  input: unknown,
  nextPath?: string,
): Promise<AuthActionResult> {
  const parsed = loginSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Please fix the errors and try again." };
  }

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({
    email: parsed.data.email,
    password: parsed.data.password,
  });

  if (error) {
    // Deliberately generic: never reveal whether the email exists.
    return { status: "error", message: "Invalid email or password." };
  }

  redirect(safeInternalPath(nextPath));
}

export async function signOutAction(): Promise<void> {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
