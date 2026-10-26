import { queryOptions } from "@tanstack/react-query";
import { FunctionsHttpError } from "@supabase/supabase-js";
import { z } from "zod";

import { supabase } from "./supabase";

/**
 * Campus email verification (PLAN.md 4.1): a one-time code to a second email whose domain is
 * in org_email_domains. Sending goes through the send-verification-code Edge Function (it
 * holds the service role); confirming is the confirm_email_verification RPC, which answers
 * with a status for the expected failures (wrong, expired, exhausted) and raises for the rest.
 */

export const campusEmailSchema = z
  .string()
  .trim()
  .toLowerCase()
  .min(3, "Enter your student email.")
  .max(254, "That email is too long.")
  .email("Enter a valid email.");

export const CODE_LENGTH = 6;
export const RESEND_COOLDOWN_SECONDS = 60;

/* ------------------------------------------------------------------ */
/* Verified membership (what the You tab and /you/verify show)          */
/* ------------------------------------------------------------------ */

/** The caller's verified organization membership, or null. Written only by the database. */
export const membershipQuery = (userId: string) =>
  queryOptions({
    queryKey: ["org-membership", userId] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("org_memberships")
        .select(
          "org_id,campus_id,verified_at,source,organizations(name,slug),org_campuses(name,slug)",
        )
        .eq("user_id", userId)
        .order("verified_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      if (error) throw error;
      return data;
    },
    staleTime: 60_000,
  });

export type Membership = NonNullable<
  Awaited<ReturnType<NonNullable<ReturnType<typeof membershipQuery>["queryFn"]>>>
>;

/* ------------------------------------------------------------------ */
/* Send                                                                 */
/* ------------------------------------------------------------------ */

const sendResponseSchema = z.discriminatedUnion("status", [
  z.object({ status: z.literal("sent"), expires_at: z.string().nullable().optional() }),
  z.object({ status: z.literal("already_verified"), own: z.boolean().optional() }),
]);
export type SendResult = z.infer<typeof sendResponseSchema>;

/** Error codes the Edge Function answers with, carried as Error.message. */
export class VerificationError extends Error {
  constructor(public readonly code: string) {
    super(code);
    this.name = "VerificationError";
  }
}

async function functionErrorCode(error: unknown): Promise<string> {
  if (error instanceof FunctionsHttpError) {
    const response: unknown = error.context;
    if (response instanceof Response) {
      try {
        const body: unknown = await response.clone().json();
        if (typeof body === "object" && body && "error" in body && typeof body.error === "string") {
          return body.error;
        }
      } catch {
        /* not JSON */
      }
      if (response.status === 401) return "invalid_token";
      if (response.status === 429) return "too_many_sends";
    }
    return "request_failed";
  }
  return "network";
}

export async function sendVerificationCode(email: string): Promise<SendResult> {
  const { data, error } = await supabase.functions.invoke<unknown>("send-verification-code", {
    method: "POST",
    body: { email },
  });
  if (error) throw new VerificationError(await functionErrorCode(error));
  const parsed = sendResponseSchema.safeParse(data);
  if (!parsed.success) throw new VerificationError("request_failed");
  return parsed.data;
}

/* ------------------------------------------------------------------ */
/* Confirm                                                              */
/* ------------------------------------------------------------------ */

const confirmResponseSchema = z.discriminatedUnion("status", [
  z.object({
    status: z.literal("ok"),
    org_id: z.string(),
    org_slug: z.string(),
    org_name: z.string(),
    campus_id: z.string().nullable(),
    campus_name: z.string().nullable(),
  }),
  z.object({ status: z.literal("code_invalid"), attempts_left: z.number().int().optional() }),
  z.object({ status: z.literal("code_expired") }),
  z.object({ status: z.literal("too_many_attempts") }),
  z.object({ status: z.literal("code_not_found") }),
]);
export type ConfirmResult = z.infer<typeof confirmResponseSchema>;

/**
 * Checks a code. Resolves with the RPC's status object (including the soft failures); rejects
 * with the PostgrestError for raised ones (not_authenticated, domain_not_recognized,
 * email_already_verified), which verificationErrorMessage turns into a sentence.
 */
export async function confirmVerificationCode(code: string, email: string): Promise<ConfirmResult> {
  const { data, error } = await supabase.rpc("confirm_email_verification", {
    p_code: code,
    p_email: email,
  });
  if (error) throw error;
  const parsed = confirmResponseSchema.safeParse(data);
  if (!parsed.success) throw new VerificationError("request_failed");
  return parsed.data;
}

/* ------------------------------------------------------------------ */
/* Copy                                                                 */
/* ------------------------------------------------------------------ */

/** Copy for a soft confirm status (everything but 'ok'). */
export function confirmStatusMessage(result: Exclude<ConfirmResult, { status: "ok" }>): string {
  switch (result.status) {
    case "code_invalid": {
      const left = result.attempts_left;
      if (left === undefined) return "That code isn't right. Check the six digits and try again.";
      if (left <= 0) return "That code isn't right, and it's used up. Send a new one.";
      return `That code isn't right. ${left} ${left === 1 ? "try" : "tries"} left.`;
    }
    case "code_expired":
      return "That code has expired. Codes work for 15 minutes; send a new one.";
    case "too_many_attempts":
      return "Five wrong tries locks that code. Send a new one; if you've already had three codes this hour, wait an hour and try again.";
    case "code_not_found":
      return "No code is waiting for that email. Send a new one.";
  }
}

/**
 * Maps errors from the Edge Function (VerificationError codes) and the RPC (PostgrestError
 * with the code in .message) to sentences. Only this file knows these codes.
 */
export function verificationErrorMessage(err: unknown): string {
  const message =
    err instanceof VerificationError
      ? err.code
      : typeof err === "object" && err && "message" in err && typeof err.message === "string"
        ? err.message
        : String(err ?? "");
  if (message.includes("domain_not_recognized")) {
    return "That email isn't from a campus we know yet. Use the address your school gave you, like you@student.gsu.edu.";
  }
  if (message.includes("email_already_verified")) {
    return "That email is already verified on another account. If it's yours, sign in with that account instead.";
  }
  if (message.includes("too_many_sends")) {
    return "Too many codes. One a minute and three an hour; wait and try again.";
  }
  if (message.includes("invalid_email")) return "Enter a valid email.";
  if (message.includes("send_failed")) {
    return "We couldn't send the email just now. Wait a minute and try again.";
  }
  if (message.includes("user_not_found") || message.includes("onboarding_required")) {
    return "Finish setting up your profile first.";
  }
  if (
    message.includes("not_authenticated") ||
    message.includes("invalid_token") ||
    message.includes("missing_token")
  ) {
    return "Your session ended. Sign in again.";
  }
  if (message.includes("network")) return "Check your connection and try again.";
  if (message.includes("request_failed") || message.includes("rpc_failed")) {
    return "Something went wrong on our side. Try again in a moment.";
  }
  return message || "Something went wrong. Try again.";
}
