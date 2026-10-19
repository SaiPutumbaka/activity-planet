import type { Session } from "@supabase/supabase-js";
import { queryOptions, type QueryClient } from "@tanstack/react-query";

import { supabase } from "./supabase";

/**
 * The current session, read from supabase-js's storage. Cached forever and replaced by the
 * onAuthStateChange listener in main.tsx, so route guards never wait on the network.
 */
export const sessionQuery = queryOptions({
  queryKey: ["auth", "session"] as const,
  queryFn: async (): Promise<Session | null> => {
    const { data, error } = await supabase.auth.getSession();
    if (error) throw error;
    return data.session;
  },
  staleTime: Infinity,
  gcTime: Infinity,
});

export function getSession(queryClient: QueryClient): Promise<Session | null> {
  return queryClient.ensureQueryData(sessionQuery);
}

/** Where email links and OAuth providers send people back. Each must be in Supabase's redirect allow list. */
export const authRedirect = {
  confirm: () => `${window.location.origin}/auth/confirm`,
  callback: () => `${window.location.origin}/auth/callback`,
  reset: () => `${window.location.origin}/auth/reset`,
};

export const googleEnabled = import.meta.env.VITE_AUTH_GOOGLE === "1";

export async function signOut(): Promise<void> {
  const { error } = await supabase.auth.signOut();
  if (error) throw error;
}

/** Maps Supabase Auth error codes to sentences a person can act on. */
export function authErrorMessage(err: unknown): string {
  const code = typeof err === "object" && err && "code" in err ? String(err.code) : "";
  switch (code) {
    case "invalid_credentials":
      return "That email and password don't match.";
    case "email_not_confirmed":
      return "Confirm your email first. We can send the link again.";
    case "user_already_exists":
    case "email_exists":
      return "There's already an account with that email. Sign in instead.";
    case "weak_password":
      return "Pick a stronger password: at least 8 characters and not a common one.";
    case "over_email_send_rate_limit":
    case "over_request_rate_limit":
    case "over_sms_send_rate_limit":
      return "Too many attempts. Wait a minute and try again.";
    case "email_address_invalid":
      return "Enter a valid email.";
    case "otp_expired":
    case "otp_disabled":
      return "That link has expired. Request a new one.";
    case "same_password":
      return "Use a password you haven't used before.";
    case "signup_disabled":
      return "Sign-ups are paused right now.";
    case "provider_disabled":
      return "That sign-in method isn't available yet.";
    case "bad_code_verifier":
    case "flow_state_not_found":
    case "flow_state_expired":
      return "Open the link on the same device and browser you started from, or sign in with your password.";
    case "validation_failed":
      return "Check the form and try again.";
    default:
      return err instanceof Error && err.message ? err.message : "Something went wrong. Try again.";
  }
}

/** Maps errors raised by the database RPCs (complete_onboarding and friends). */
export function rpcErrorMessage(err: unknown): string {
  // PostgrestError is a plain object, not an Error instance, so read .message structurally.
  const message =
    typeof err === "object" && err && "message" in err && typeof err.message === "string"
      ? err.message
      : String(err ?? "");
  if (message.includes("handle_taken")) return "That handle is taken.";
  if (message.includes("handle_reserved")) return "That handle is reserved.";
  if (message.includes("handle_cooldown")) return "Handles can change once every 30 days.";
  if (message.includes("birth_date_locked"))
    return "Your birth date is already recorded. Contact support to correct it.";
  if (message.includes("too_many_hubs"))
    return "Pick at most 25 hubs to start; you can join more later.";
  if (message.includes("pick_at_least_one_hub")) return "Pick at least one hub.";
  if (message.includes("minimum_age")) return "Activity Planet is for people 18 and over.";
  if (message.includes("not_authenticated")) return "Your session ended. Sign in again.";
  return message || "Something went wrong. Try again.";
}
