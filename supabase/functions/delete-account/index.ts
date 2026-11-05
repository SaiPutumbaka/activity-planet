// delete-account: finishes an account deletion that request_account_deletion() started.
//
// The app calls the RPC first (one transaction: ledger row, tombstone profile, private data
// and memberships removed, auth user banned), then invokes this function with the same user
// JWT. With the service role it:
//   1. removes the person's avatar files from the avatars bucket, and their chat images from
//      chat-images (<user id>/<conversation id>/<file>; migration 58);
//   2. drops provider tokens (Apple revocation is a TODO until Capacitor ships). Migration 62:
//      the RPC already removed the person's organizer_claims and organizer_oauth_states rows,
//      stopped the feeds they connected (feed_sources.origin organizer) and took their Eventbrite
//      token out of the vault; Eventbrite has no token revocation endpoint, so nothing is sent
//      there (the person can remove the app in their Eventbrite settings). Listing removal
//      requests hold no account link. None of these rows is in Storage;
//   3. fans out to processors: Stripe (migration 60), when STRIPE_SECRET_KEY is set and the
//      person has a connected account, is asked to delete it; if Stripe refuses (funds still
//      pending), a stripe_jobs close_account row retries it later. Migration 61: while money can
//      still move back through the account (the refunds request_account_deletion just queued,
//      a paid session not yet completed, a dispute; coach_stripe_close_blocked), nothing is
//      deleted now and the close_account job waits for them. Without the key nothing is sent
//      and the coach_stripe_accounts row stays for when the key exists;
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
import { createStripe, stripeErrorName } from "../_shared/stripe.ts";

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

  // Every entry under a folder: storage.list returns at most `limit` rows, so page by offset
  // until a short page (migration 59 review: more than 1000 entries were left behind).
  const LIST_PAGE = 1000;
  async function listAll(
    bucket: string,
    prefix: string,
  ): Promise<{ data: { id: string | null; name: string }[] | null; error: unknown }> {
    const out: { id: string | null; name: string }[] = [];
    for (let offset = 0; ; offset += LIST_PAGE) {
      const { data, error } = await admin.storage
        .from(bucket)
        .list(prefix, { limit: LIST_PAGE, offset, sortBy: { column: "name", order: "asc" } });
      if (error) return { data: null, error };
      out.push(...(data ?? []));
      if (!data || data.length < LIST_PAGE) return { data: out, error: null };
    }
  }

  // 1. Avatar files. The RPC cleared avatar_url; objects live under <user id>/ in the bucket.
  const { data: files, error: listError } = await listAll("avatars", userId);
  if (listError) return json({ error: "avatar_list_failed" }, 500);
  const avatarPaths = (files ?? []).map((file) => `${userId}/${file.name}`);
  for (let i = 0; i < avatarPaths.length; i += 500) {
    const { error: removeError } = await admin.storage
      .from("avatars")
      .remove(avatarPaths.slice(i, i + 500));
    if (removeError) return json({ error: "avatar_remove_failed" }, 500);
  }

  // 1b. Chat images (migration 58). The RPC kept the messages others received under the
  //     tombstone and set their images to removed; the files go here. Reported images were
  //     copied to chat-evidence when the report was filed, so the originals can always go.
  const chatPaths: string[] = [];
  const { data: chatFolders, error: chatListError } = await listAll("chat-images", userId);
  if (chatListError) return json({ error: "chat_images_list_failed" }, 500);
  for (const entry of chatFolders ?? []) {
    // Folders (one per conversation) come back without an id.
    if (entry.id) {
      chatPaths.push(`${userId}/${entry.name}`);
      continue;
    }
    const { data: inner, error: innerError } = await listAll(
      "chat-images",
      `${userId}/${entry.name}`,
    );
    if (innerError) return json({ error: "chat_images_list_failed" }, 500);
    for (const file of inner ?? []) chatPaths.push(`${userId}/${entry.name}/${file.name}`);
  }
  for (let i = 0; i < chatPaths.length; i += 500) {
    const { error: chatRemoveError } = await admin.storage
      .from("chat-images")
      .remove(chatPaths.slice(i, i + 500));
    if (chatRemoveError) return json({ error: "chat_images_remove_failed" }, 500);
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
  // Messages (migration 58) are anonymized by request_account_deletion: what others received
  // stays under "Deleted user"; chat images were removed in step 1b.
  const processorsNotified: Record<string, string> = {};

  // 3a. Stripe (migration 60). Booking and payment records stay 7 years under "Deleted user"
  //     (ids and amounts only); the connected account is closed when its balance allows.
  const stripeKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  const { data: stripeAccount, error: stripeLookupError } = await admin
    .from("coach_stripe_accounts")
    .select("stripe_account_id")
    .eq("coach_id", userId)
    .maybeSingle();
  if (stripeLookupError) return json({ error: "stripe_lookup_failed" }, 500);
  if (stripeAccount && stripeKey) {
    const acct = stripeAccount.stripe_account_id as string;
    // Migration 61: refunds use reverse_transfer against this account, so it stays open until
    // they have run; the close_account job (stripe_jobs_claim) waits for them.
    const { data: blocked, error: blockedError } = await admin.rpc("coach_stripe_close_blocked", {
      p_coach: userId,
    });
    if (blockedError) return json({ error: "stripe_lookup_failed" }, 500);
    const res =
      blocked === true
        ? null
        : await createStripe(stripeKey).request(
            "DELETE",
            `/v1/accounts/${encodeURIComponent(acct)}`,
          );
    if (res && (res.ok || res.status === 404)) {
      await admin.from("coach_stripe_accounts").delete().eq("coach_id", userId);
      processorsNotified.stripe = "account_deleted";
    } else {
      const { error: jobError } = await admin.from("stripe_jobs").upsert(
        {
          op: "close_account",
          stripe_account_id: acct,
          idempotency_key: `close:${acct}`,
          next_at: new Date(Date.now() + (res ? 8 * 24 * 3600 * 1000 : 3600 * 1000)).toISOString(),
        },
        { onConflict: "idempotency_key", ignoreDuplicates: true },
      );
      if (jobError) return json({ error: "stripe_job_failed" }, 500);
      processorsNotified.stripe = res
        ? `close_queued:${stripeErrorName(res)}`
        : "close_queued:refunds_pending";
    }
  } else if (stripeAccount) {
    processorsNotified.stripe = "no_key";
  }

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
