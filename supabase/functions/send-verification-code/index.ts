// send-verification-code: emails a 6-digit campus verification code (PLAN.md 4.1).
//
// The app POSTs { email } with the signed-in person's JWT. With the service role this
// function:
//   1. verifies the caller's token locally against the project's JWKS (role must be
//      authenticated; the gateway's verify_jwt is advisory, see config.toml);
//   2. calls create_verification_code(p_user_id = the token's sub, p_email), which is
//      service-role only: it throttles (one send a minute, three an hour per user and per
//      address), checks the domain against org_email_domains and stores only a hash of the
//      code;
//   3. emails the code through Resend when RESEND_API_KEY is set. Without the key (staging
//      today) it logs that no email went out, never the code, and still answers
//      { status: 'sent' } so the flow can be tested with a code obtained from the database.
//
// Responses
//   200 { status: 'sent', expires_at }            code issued (email sent or logged as skipped), or
//                                                 the address is already linked to another account:
//                                                 the same answer, no code, and the email (when
//                                                 sent) tells the address owner it is linked
//                                                 (migration 22: no enumeration of linked addresses)
//   200 { status: 'already_verified', own: true } the address is already verified by this account
//   400 { error: 'invalid_email' | 'invalid_body' }
//   401 { error: 'missing_token' | 'invalid_token' }
//   403 { error: 'user_not_found' }               no active profile for the token's user
//   422 { error: 'domain_not_recognized' }        not a campus email we know yet
//   429 { error: 'too_many_sends' }               one a minute, three an hour
//   503 { error: 'email_budget' }                 migration 77: the account-wide daily or monthly
//                                                 email budget is used up (email_budget_take); try
//                                                 again tomorrow
//   502 { error: 'send_failed' }                  Resend refused; the code exists, ask again in a minute
//   500 { error: 'misconfigured' | 'rpc_failed' }
//
// Secrets come from the runtime environment only (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// are injected by Supabase; RESEND_API_KEY is a project secret); nothing is read from code.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { disclaimerFor, subjectFor } from "./copy.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

const FROM = "Activity Planet <hello@activityplanet.app>";
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

interface CodeResult {
  status: "sent" | "already_verified";
  code: string | null;
  own?: boolean;
  org_name: string;
  expires_at: string | null;
}

function codeEmail(code: string, orgName: string): { text: string; html: string } {
  const text = [
    `Your Activity Planet verification code is ${code}`,
    "",
    `Enter it in the app to verify your ${orgName} email. The code works for 15 minutes.`,
    "",
    "If you didn't ask for this, you can ignore this email; nothing changes without the code.",
    "",
    disclaimerFor(orgName),
  ].join("\n");
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#ffffff;color:#0e0f11;font-family:Figtree,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
<p style="margin:0 0 16px">Your Activity Planet verification code is</p>
<p style="margin:0 0 16px;font-size:40px;font-weight:800;letter-spacing:0.2em;font-variant-numeric:tabular-nums">${code}</p>
<p style="margin:0 0 16px">Enter it in the app to verify your ${escapeHtml(orgName)} email. The code works for <strong>15 minutes</strong>.</p>
<p style="margin:0 0 16px;color:#5b5f66">If you didn't ask for this, you can ignore this email; nothing changes without the code.</p>
<p style="margin:0;color:#8a8f98;font-size:13px">${escapeHtml(disclaimerFor(orgName))}</p>
</body></html>`;
  return { text, html };
}

function alreadyVerifiedEmail(orgName: string): { text: string; html: string } {
  const text = [
    "Someone asked to verify this email address on Activity Planet, but it is already linked to an account.",
    "",
    `If that was you, sign in to the account that verified your ${orgName} email. If it wasn't, you can ignore this email; no code was sent and nothing changes.`,
    "",
    disclaimerFor(orgName),
  ].join("\n");
  const html = `<!doctype html><html><body style="margin:0;padding:24px;background:#ffffff;color:#0e0f11;font-family:Figtree,-apple-system,Segoe UI,Helvetica,Arial,sans-serif;font-size:16px;line-height:1.5">
<p style="margin:0 0 16px">Someone asked to verify this email address on Activity Planet, but it is already linked to an account.</p>
<p style="margin:0 0 16px">If that was you, sign in to the account that verified your ${escapeHtml(orgName)} email. If it wasn't, you can ignore this email; no code was sent and nothing changes.</p>
<p style="margin:0;color:#8a8f98;font-size:13px">${escapeHtml(disclaimerFor(orgName))}</p>
</body></html>`;
  return { text, html };
}

async function sendWithResend(
  apiKey: string,
  to: string,
  subject: string,
  body: { text: string; html: string },
): Promise<boolean> {
  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { Authorization: `Bearer ${apiKey}`, "Content-Type": "application/json" },
    body: JSON.stringify({
      from: FROM,
      to: [to],
      subject,
      text: body.text,
      html: body.html,
    }),
  });
  if (!res.ok) {
    // Status and error name only: Resend's body can echo the address (the logs are public).
    let name = "unknown";
    try {
      const body: unknown = await res.json();
      if (body && typeof body === "object" && "name" in body && typeof body.name === "string") {
        name = body.name.replace(/[^a-z_]/gi, "").slice(0, 40);
      }
    } catch {
      /* not JSON */
    }
    console.error(`resend refused the email: ${res.status} ${name}`);
    return false;
  }
  return true;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "misconfigured" }, 500);
  const resendKey = Deno.env.get("RESEND_API_KEY") ?? "";

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
  if (!token) return json({ error: "missing_token" }, 401);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Who is asking. getClaims checks the signature locally against the project's JWKS. Only a
  // real user token qualifies, never the anon or publishable key.
  const { data: claimsData, error: claimsError } = await admin.auth.getClaims(token);
  const claims = claimsData?.claims;
  if (claimsError || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string") {
    return json({ error: "invalid_token" }, 401);
  }
  const userId = claims.sub;

  // The address. The RPC validates again; this keeps junk out of the throttle rows.
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_body" }, 400);
  }
  const rawEmail =
    typeof body === "object" && body && "email" in body && typeof body.email === "string"
      ? body.email
      : "";
  const email = rawEmail.trim().toLowerCase();
  if (!email || email.length > 254 || !EMAIL_RE.test(email)) {
    return json({ error: "invalid_email" }, 400);
  }

  const { data, error } = await admin.rpc("create_verification_code", {
    p_user_id: userId,
    p_email: email,
  });
  if (error) {
    const message = error.message ?? "";
    if (message.includes("too_many_sends")) return json({ error: "too_many_sends" }, 429);
    if (message.includes("domain_not_recognized")) {
      return json({ error: "domain_not_recognized" }, 422);
    }
    if (message.includes("invalid_email")) return json({ error: "invalid_email" }, 400);
    if (message.includes("user_not_found")) return json({ error: "user_not_found" }, 403);
    console.error(`create_verification_code failed for user ${userId}: ${message}`);
    return json({ error: "rpc_failed" }, 500);
  }
  const result = data as CodeResult | null;
  if (!result || (result.status !== "sent" && result.status !== "already_verified")) {
    return json({ error: "rpc_failed" }, 500);
  }

  // The caller's own, already verified address: they know it, so the answer may differ.
  if (result.status === "already_verified") {
    return json({ status: "already_verified", own: true });
  }

  // Linked to another account (no code): tell only the address owner, by email, and answer
  // exactly as for a fresh code so the caller cannot tell the two apart.
  // Migration 77: every email counts against the account-wide budget, which keeps a reserve for
  // sign-up and password email; past it nothing is sent.
  async function budgetAllows(): Promise<boolean> {
    if (!resendKey) return true;
    const { data: ok, error: budgetError } = await admin.rpc("email_budget_take", {
      p_source: "verification",
      p_n: 1,
    });
    return !budgetError && ok === true;
  }
  const subject = subjectFor(result.org_name);

  if (!result.code) {
    if (resendKey && (await budgetAllows())) {
      await sendWithResend(resendKey, email, subject, alreadyVerifiedEmail(result.org_name));
    } else {
      console.log(`RESEND_API_KEY not set: already-linked notice not emailed for user ${userId}`);
    }
    return json({ status: "sent", expires_at: result.expires_at });
  }
  if (resendKey) {
    if (!(await budgetAllows())) return json({ error: "email_budget" }, 503);
    const sent = await sendWithResend(
      resendKey,
      email,
      subject,
      codeEmail(result.code, result.org_name),
    );
    if (!sent) return json({ error: "send_failed" }, 502);
  } else {
    // Staging: no mail provider yet. Never log the code; the developer reads one from the
    // database by calling create_verification_code as postgres.
    console.log(`RESEND_API_KEY not set: verification code not emailed for user ${userId}`);
  }
  return json({ status: "sent", expires_at: result.expires_at });
});
