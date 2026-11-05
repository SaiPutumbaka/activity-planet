// stripe-connect (migration 60; docs/design/coaching/COACHING_DESIGN.md section 9.2): Stripe
// Connect Express for coaches. The logic is in connect.ts.
//
//   POST {op: "onboard", country}  -> {url}  an Account Link (creates the Express account once)
//   POST {op: "dashboard"}         -> {url}  a login link to the Express dashboard
//   POST {op: "refresh"}           -> account states, synced into coach_stripe_accounts
//
// Key gate: without STRIPE_SECRET_KEY (an optional Edge Function secret, never in a file) every
// request answers 503 {error: "payments_off"} before anything is parsed; with the key but
// meta.coach_payments off it answers the same. The caller is a signed-in coach: the user JWT is
// verified against the project's JWKS (getClaims), as delete-account does.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected by Supabase; APP_URL is optional.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import {
  CORS_HEADERS,
  createRpc,
  createStripe,
  json,
  keyGate,
  RpcError,
} from "../_shared/stripe.ts";
import { handleConnect } from "./connect.ts";

function appUrl(): string {
  try {
    const u = new URL(Deno.env.get("APP_URL") ?? "https://app.activityplanet.app");
    return u.protocol === "https:" || u.hostname === "localhost"
      ? u.origin
      : "https://app.activityplanet.app";
  } catch {
    return "https://app.activityplanet.app";
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  const gated = keyGate((n) => Deno.env.get(n), ["STRIPE_SECRET_KEY"]);
  if (gated) {
    await req.body?.cancel();
    return gated;
  }
  const secretKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "misconfigured" }, 500);

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
  if (!token) return json({ error: "missing_token" }, 401);
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.auth.getClaims(token);
  const claims = data?.claims;
  if (error || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string") {
    return json({ error: "invalid_token" }, 401);
  }

  let body: unknown = null;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  try {
    const answer = await handleConnect(claims.sub, body, {
      stripe: createStripe(secretKey),
      rpc: createRpc(url, serviceKey),
      appUrl: appUrl(),
    });
    return json(answer.body, answer.status);
  } catch (err) {
    const code = err instanceof RpcError ? err.code : "error";
    console.error("stripe-connect: failed", err instanceof RpcError ? err.message : "unexpected");
    return json({ error: code === "error" ? "connect_failed" : code }, 500);
  }
});
