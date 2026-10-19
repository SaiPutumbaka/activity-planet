import type { EmailOtpType, Session } from "@supabase/supabase-js";

import { supabase } from "./supabase";

export const EMAIL_OTP_TYPES = [
  "signup",
  "invite",
  "magiclink",
  "recovery",
  "email_change",
  "email",
] as const;

export interface LinkParams {
  token_hash?: string;
  type?: string;
  code?: string;
  error?: string;
  error_code?: string;
  error_description?: string;
}

/** Supabase reports some failures in the hash fragment rather than the query string. */
export function readHashParams(): Record<string, string> {
  const raw = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
  return Object.fromEntries(new URLSearchParams(raw));
}

function isOtpType(value: string): value is EmailOtpType {
  return (EMAIL_OTP_TYPES as readonly string[]).includes(value);
}

/**
 * Finishes an email or OAuth link and returns the session. Handles, in order:
 *  1. an error carried in the query or the hash;
 *  2. a `token_hash` link (our email templates; works from any device);
 *  3. a session supabase-js already created from a `?code=` while initializing;
 *  4. a `?code=` we still need to exchange (same device as the request).
 */
export async function completeAuthLink(params: LinkParams): Promise<Session> {
  const hash = readHashParams();
  const error = params.error ?? hash.error;
  if (error) {
    throw Object.assign(
      new Error(params.error_description ?? hash.error_description ?? "That link is not valid."),
      {
        code: params.error_code ?? hash.error_code ?? error,
      },
    );
  }

  if (params.token_hash && params.type && isOtpType(params.type)) {
    const { data, error: otpError } = await supabase.auth.verifyOtp({
      token_hash: params.token_hash,
      type: params.type,
    });
    if (otpError) throw otpError;
    if (!data.session)
      throw Object.assign(new Error("That link is not valid."), { code: "otp_expired" });
    return data.session;
  }

  // getSession waits for supabase-js's own URL handling (detectSessionInUrl) to finish first.
  const existing = await supabase.auth.getSession();
  if (existing.data.session) return existing.data.session;

  if (params.code) {
    const { data, error: codeError } = await supabase.auth.exchangeCodeForSession(params.code);
    if (codeError) throw codeError;
    return data.session;
  }

  throw Object.assign(new Error("That link is missing its code. Open it from the email again."), {
    code: "otp_expired",
  });
}
