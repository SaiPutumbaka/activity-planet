// stripe-webhook (migration 60; docs/design/coaching/COACHING_DESIGN.md section 9.4). The logic is
// in signature.ts and events.ts.
//
//   POST (from Stripe) with Stripe-Signature  -> 200 {received}, 400 on a bad signature,
//                                                 500 when a handler failed (Stripe retries)
//
// Key gate: without STRIPE_SECRET_KEY and STRIPE_WEBHOOK_SECRET (optional Edge Function secrets,
// never in a file) every request answers 503 {error: "payments_off"} before anything is parsed.
// STRIPE_CONNECT_WEBHOOK_SECRET (the Connect endpoint's own secret) is optional; without it the
// account state is synced by stripe-connect {op: "refresh"}. verify_jwt is off (config.toml):
// Stripe signs the request instead. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected.
import { createRpc, json, keyGate, keyMode } from "../_shared/stripe.ts";
import { handleWebhook } from "./events.ts";

Deno.serve(async (req: Request): Promise<Response> => {
  const gated = keyGate((n) => Deno.env.get(n), ["STRIPE_SECRET_KEY", "STRIPE_WEBHOOK_SECRET"]);
  if (gated) {
    await req.body?.cancel();
    return gated;
  }
  const secretKey = Deno.env.get("STRIPE_SECRET_KEY") ?? "";
  const webhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET") ?? "";
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const url = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !serviceKey) return json({ error: "misconfigured" }, 500);

  const payload = await req.text();
  try {
    const answer = await handleWebhook(payload, req.headers.get("Stripe-Signature"), {
      rpc: createRpc(url, serviceKey),
      secrets: [webhookSecret, Deno.env.get("STRIPE_CONNECT_WEBHOOK_SECRET") ?? ""],
      keyMode: keyMode(secretKey),
      nowSeconds: () => Math.floor(Date.now() / 1000),
    });
    return json(answer.body, answer.status);
  } catch {
    console.error("stripe-webhook: failed");
    return json({ error: "webhook_failed" }, 500);
  }
});
