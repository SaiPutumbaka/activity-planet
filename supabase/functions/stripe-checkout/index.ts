// stripe-checkout (migration 60; docs/design/coaching/COACHING_DESIGN.md section 9.3). The logic is
// in checkout.ts and fees.ts.
//
//   POST {op: "create", booking_id}  (a signed-in client)  -> {url} of a Stripe Checkout Session
//   POST {op: "job"}                 (the database)        -> runs due stripe_jobs, counts only
//
// Key gate: without STRIPE_SECRET_KEY (an optional Edge Function secret, never in a file) every
// request answers 503 {error: "payments_off"} before anything is parsed. verify_jwt is off
// (config.toml) because the database calls it: {op: "job"} must carry x-stripe-dispatch-secret,
// checked through stripe_dispatch_verify_secret (vault secret stripe_dispatch_secret, generated
// inside the database by migration 60); {op: "create"} must carry a user JWT, verified against
// the project's JWKS (getClaims) as delete-account does.
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
import { createCheckout, runJobs } from "./checkout.ts";

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
  const rpc = createRpc(url, serviceKey);
  const deps = { stripe: createStripe(secretKey), rpc, appUrl: appUrl() };

  let body: { op?: unknown; booking_id?: unknown } = {};
  try {
    body = (await req.json()) ?? {};
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  try {
    // The function runs with its key: coaching_tick may now cancel unpaid bookings (section 9.1).
    await rpc("stripe_checkout_heartbeat", {}).catch(() => null);
    if (body.op === "job") {
      const secret = req.headers.get("x-stripe-dispatch-secret") ?? "";
      const allowed =
        secret.length >= 32 &&
        (await rpc("stripe_dispatch_verify_secret", { p_secret: secret })) === true;
      if (!allowed) return json({ error: "unauthorized" }, 401);
      const summary = await runJobs(deps);
      console.log("stripe-checkout jobs", JSON.stringify(summary));
      return json(summary);
    }
    if (body.op !== "create") return json({ error: "invalid_op" }, 400);
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
    const answer = await createCheckout(claims.sub, body.booking_id, deps);
    return json(answer.body, answer.status);
  } catch (err) {
    console.error("stripe-checkout: failed", err instanceof RpcError ? err.message : "unexpected");
    return json({ error: "checkout_failed" }, 500);
  }
});
