// delete-account: finishes an account deletion that request_account_deletion() started (D-031).
//
//   POST with the member's JWT        -> finishes that member's deletion (the app calls it right
//                                        after the RPC); see finish.ts for the steps.
//   POST {op: "sweep"} with the header -> migration 77, pg_cron account-deletion-sweep through
//        x-deletion-secret                public.account_deletion_dispatch: finishes up to five
//                                        deletions left unfinished over 10 minutes
//                                        (account_deletion_sweep_claim) and deletes expired
//                                        legal-hold copies. The secret is the vault entry
//                                        account_deletion_secret, generated inside the database;
//                                        it is checked through account_deletion_verify_secret.
//
// The gateway JWT check is off (config.toml, migration 77) so the database can call the sweep;
// a member's token is verified here with getClaims (the project's JWKS), as before, and only a
// real user token qualifies, never the anon or publishable key. Without a ledger row and a
// tombstone it refuses (409), so a leaked token cannot delete an account by itself: consent
// lives in the database. Responses carry error codes only, never internal messages.
//
// Secrets come from the runtime environment only (SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY are
// injected by Supabase; STRIPE_SECRET_KEY is optional); nothing is read from code.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { finishDeletion, purgeLegalHolds, stripeFromEnv } from "./finish.ts";

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
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const stripe = stripeFromEnv(Deno.env.get("STRIPE_SECRET_KEY"));

  // The sweep (migration 77).
  const secret = req.headers.get("x-deletion-secret");
  if (secret !== null) {
    const { data: allowed, error: verifyError } = await admin.rpc(
      "account_deletion_verify_secret",
      { p_secret: secret },
    );
    if (verifyError || allowed !== true) return json({ error: "forbidden" }, 403);
    const { data: ids, error: claimError } = await admin.rpc("account_deletion_sweep_claim", {
      p_limit: 5,
    });
    if (claimError) return json({ error: "claim_failed" }, 500);
    let finished = 0;
    let failed = 0;
    for (const id of (ids ?? []) as string[]) {
      const result = await finishDeletion({ admin, stripe }, id);
      if (result.ok) {
        finished++;
      } else {
        failed++;
        await admin.rpc("account_deletion_failed", { p_user: id, p_error: result.error });
        console.error(`delete-account sweep: ${result.error}`);
      }
    }
    let purged = 0;
    try {
      purged = await purgeLegalHolds(admin);
    } catch (err) {
      console.error(`delete-account sweep: ${err instanceof Error ? err.message : "purge_failed"}`);
    }
    return json({ finished, failed, purged });
  }

  // A member finishing their own deletion.
  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
  if (!token) return json({ error: "missing_token" }, 401);
  const { data: claimsData, error: claimsError } = await admin.auth.getClaims(token);
  const claims = claimsData?.claims;
  if (claimsError || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string") {
    return json({ error: "invalid_token" }, 401);
  }
  const result = await finishDeletion({ admin, stripe }, claims.sub);
  if (!result.ok) {
    console.error(`delete-account: ${result.error}`);
    return json({ error: result.error }, result.status);
  }
  return json(result.alreadyCompleted ? { ok: true, alreadyCompleted: true } : { ok: true });
});
