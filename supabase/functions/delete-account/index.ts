// delete-account: finishes an account deletion that request_account_deletion() started.
//
// The app calls the RPC first (one transaction: ledger row, tombstone profile, private data
// and memberships removed, auth user banned), then invokes this function with the same user
// JWT. With the service role it:
//   1. removes the person's avatar files from the avatars bucket;
//   2. drops provider tokens (Apple revocation is a TODO until Capacitor ships);
//   3. fans out to processors (TODO: none hold personal data yet);
//   4. soft-deletes the auth user, which frees the email address and the OAuth identities
//      for a new signup, wipes metadata and ends every session and refresh token;
//   5. stamps completed_at on the account_deletions row.
// Without a ledger row and a tombstone it refuses (409), so a leaked token cannot delete an
// account by itself: consent lives in the database.
//
// Secrets come from the runtime environment only (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// are injected by Supabase); nothing is read from code or committed files.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "misconfigured" }, 500);

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
  if (!token) return json({ error: "missing_token" }, 401);

  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  // Who is asking. The gateway (verify_jwt) already checked the signature; getClaims checks
  // it again locally against the project's JWKS (ES256), so a user the RPC has just banned
  // can still finish. Only a real user token qualifies, never the anon or publishable key.
  const { data: claimsData, error: claimsError } = await admin.auth.getClaims(token);
  const claims = claimsData?.claims;
  if (claimsError || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string") {
    return json({ error: "invalid_token" }, 401);
  }
  const userId = claims.sub;

  // Consent happened in the database.
  const [ledgerResult, profileResult] = await Promise.all([
    admin.from("account_deletions").select("completed_at").eq("user_id", userId).maybeSingle(),
    admin.from("profiles").select("status").eq("id", userId).maybeSingle(),
  ]);
  if (ledgerResult.error || profileResult.error) return json({ error: "lookup_failed" }, 500);
  if (!ledgerResult.data || profileResult.data?.status !== "deleted") {
    return json({ error: "deletion_not_requested" }, 409);
  }
  if (ledgerResult.data.completed_at) return json({ ok: true, alreadyCompleted: true });

  // 1. Avatar files. The RPC cleared avatar_url; objects live under <user id>/ in the bucket.
  const { data: files, error: listError } = await admin.storage
    .from("avatars")
    .list(userId, { limit: 1000 });
  if (listError) return json({ error: "avatar_list_failed" }, 500);
  if (files && files.length > 0) {
    const { error: removeError } = await admin.storage
      .from("avatars")
      .remove(files.map((file) => `${userId}/${file.name}`));
    if (removeError) return json({ error: "avatar_remove_failed" }, 500);
  }

  // 2. Provider tokens.
  // TODO(apple): when Sign in with Apple ships (Capacitor), read auth_provider_secrets for
  // provider 'apple', POST to https://appleid.apple.com/auth/revoke with a client secret
  // signed by the Sign in with Apple key (token_type_hint=refresh_token), and stamp
  // account_deletions.apple_token_revoked_at. Apple App Review 5.1.1(v) requires it. Until
  // then the row is only removed.
  const { error: secretsError } = await admin
    .from("auth_provider_secrets")
    .delete()
    .eq("user_id", userId);
  if (secretsError) return json({ error: "secrets_delete_failed" }, 500);

  // 3. Processors.
  // TODO(processors): none hold personal data yet. When they do, call each one and record
  // the outcome in processors_notified: Resend (suppress the address), PostHog (person
  // deletion), Sentry (nothing stored per user), Stripe (customer records stay while payment
  // records must, per the retention policy), Sightengine (stateless).
  // TODO(messages): when the messages table exists, anonymize messages other people
  // received (author becomes the tombstone, content kept) rather than deleting them.
  const processorsNotified: Record<string, string> = {};

  // 4. Auth user. Soft delete keeps the row as an anonymous stub (the ban holds and the
  //    tombstone's foreign key stays intact) while freeing the email and identities.
  const { error: deleteError } = await admin.auth.admin.deleteUser(userId, true);
  if (deleteError) {
    return json({ error: "auth_delete_failed", message: deleteError.message }, 500);
  }

  // 5. Ledger.
  const { error: ledgerError } = await admin
    .from("account_deletions")
    .update({ completed_at: new Date().toISOString(), processors_notified: processorsNotified })
    .eq("user_id", userId);
  if (ledgerError) return json({ error: "ledger_update_failed" }, 500);

  return json({ ok: true });
});
