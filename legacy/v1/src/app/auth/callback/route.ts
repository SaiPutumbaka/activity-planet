import { NextResponse } from "next/server";
import type { EmailOtpType } from "@supabase/supabase-js";

import { createClient } from "@/lib/supabase/server";
import { safeInternalPath } from "@/lib/validation/auth";

const OTP_TYPES: readonly EmailOtpType[] = [
  "signup",
  "email",
  "recovery",
  "invite",
  "magiclink",
  "email_change",
];

function isEmailOtpType(value: string): value is EmailOtpType {
  return (OTP_TYPES as readonly string[]).includes(value);
}

/**
 * Exchanges the one-time credential from a Supabase auth link for a session
 * cookie. Handles both PKCE `?code=` links (OAuth, magic links) and
 * `?token_hash=&type=` links (email confirmation templates).
 */
export async function GET(request: Request) {
  const { searchParams, origin } = new URL(request.url);
  const code = searchParams.get("code");
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type");
  const next = safeInternalPath(searchParams.get("next"));

  const supabase = await createClient();

  if (code) {
    const { error } = await supabase.auth.exchangeCodeForSession(code);
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  } else if (tokenHash && type && isEmailOtpType(type)) {
    const { error } = await supabase.auth.verifyOtp({
      token_hash: tokenHash,
      type,
    });
    if (!error) {
      return NextResponse.redirect(`${origin}${next}`);
    }
  }

  return NextResponse.redirect(
    `${origin}/login?error=${encodeURIComponent("This link is invalid or has expired. Please try again.")}`,
  );
}
