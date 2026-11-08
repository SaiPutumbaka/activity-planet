import { createClient, type EmailOtpType, type Session } from "@supabase/supabase-js";

import { supabase, supabasePublishableKey, supabaseUrl } from "./supabase";

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

/** The two accounts an email link would swap between, for the "switch account?" interstitial. */
export interface AccountSwitch {
  /** The account signed in on this device now. */
  currentEmail: string | null;
  /** The account the link signs into (read from the verified session, never from the URL). */
  incomingEmail: string | null;
}

/**
 * Asked when an email link belongs to a different account than the one signed in here.
 * Resolves true to switch, false to stay. Without it, such a link is refused.
 */
export type ConfirmSwitch = (accounts: AccountSwitch) => Promise<boolean>;

/** Thrown when the person chose to stay in the account they were already signed in to. */
export const SWITCH_CANCELLED = "switch_cancelled";

/** Supabase reports some failures in the hash fragment rather than the query string. */
export function readHashParams(): Record<string, string> {
  const raw = window.location.hash.startsWith("#") ? window.location.hash.slice(1) : "";
  return Object.fromEntries(new URLSearchParams(raw));
}

function isOtpType(value: string): value is EmailOtpType {
  return (EMAIL_OTP_TYPES as readonly string[]).includes(value);
}

/**
 * A client that keeps its session in memory only and shares nothing with the app's client, so
 * verifying a link with it never touches the signed-in session (login CSRF / session swap: a
 * link someone else sent must not silently replace the account on this device).
 */
function isolatedClient() {
  return createClient(supabaseUrl, supabasePublishableKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
      detectSessionInUrl: false,
      storageKey: "ap-auth-link-check",
    },
  });
}

/**
 * Finishes an email or OAuth link and returns the session. Handles, in order:
 *  1. an error carried in the query or the hash;
 *  2. a `token_hash` link (our email templates; works from any device). When someone is
 *     already signed in here, the token is verified on an isolated client first; a link for
 *     the same account is adopted, a link for a different account is adopted only after
 *     `confirmSwitch` says yes (otherwise the new session is revoked and SWITCH_CANCELLED is
 *     thrown);
 *  3. a session supabase-js already created from a `?code=` while initializing;
 *  4. a `?code=` we still need to exchange (same device as the request; PKCE needs this
 *     browser's code verifier, so a code from someone else's request cannot sign in here).
 */
export async function completeAuthLink(
  params: LinkParams,
  confirmSwitch?: ConfirmSwitch,
): Promise<Session> {
  const hash = readHashParams();
  const error = params.error ?? hash.error;
  if (error) {
    // Launch audit L7: the code only. error_description comes from the URL, so anyone who
    // sends a link could write it; authErrorMessage maps the code to fixed copy.
    throw Object.assign(new Error("That link is not valid."), {
      code: String(params.error_code ?? hash.error_code ?? error).slice(0, 64),
    });
  }

  if (params.token_hash && params.type && isOtpType(params.type)) {
    const current = (await supabase.auth.getSession()).data.session;
    if (!current) {
      const { data, error: otpError } = await supabase.auth.verifyOtp({
        token_hash: params.token_hash,
        type: params.type,
      });
      if (otpError) throw otpError;
      if (!data.session)
        throw Object.assign(new Error("That link is not valid."), { code: "otp_expired" });
      return data.session;
    }
    return verifyWhileSignedIn(current, params.token_hash, params.type, confirmSwitch);
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

async function verifyWhileSignedIn(
  current: Session,
  tokenHash: string,
  type: EmailOtpType,
  confirmSwitch: ConfirmSwitch | undefined,
): Promise<Session> {
  const probe = isolatedClient();
  const { data, error } = await probe.auth.verifyOtp({ token_hash: tokenHash, type });
  if (error) throw error;
  const incoming = data.session;
  if (!incoming) {
    throw Object.assign(new Error("That link is not valid."), { code: "otp_expired" });
  }

  if (incoming.user.id !== current.user.id) {
    const accepted = confirmSwitch
      ? await confirmSwitch({
          currentEmail: current.user.email ?? null,
          incomingEmail: incoming.user.email ?? null,
        })
      : false;
    if (!accepted) {
      // Revoke only the session the link just created; the signed-in account stays as it was.
      await probe.auth.signOut({ scope: "local" }).catch(() => undefined);
      throw Object.assign(new Error("You stayed signed in to your account."), {
        code: SWITCH_CANCELLED,
      });
    }
    // Sign the current account out on this device first, so its cached data is cleared
    // (main.tsx listens for SIGNED_OUT) before the other account's session is stored.
    await supabase.auth.signOut({ scope: "local" });
  }

  const { data: adopted, error: setError } = await supabase.auth.setSession({
    access_token: incoming.access_token,
    refresh_token: incoming.refresh_token,
  });
  if (setError) throw setError;
  if (!adopted.session) {
    throw Object.assign(new Error("That link is not valid."), { code: "otp_expired" });
  }
  return adopted.session;
}
