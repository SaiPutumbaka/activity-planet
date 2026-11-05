// eventbrite-connect (migration 62, design 2.8): see connect.ts. The gateway JWT check is off
// (config.toml) because the sync caller is the collector job: {op: "sync"} needs the header
// x-collector-secret (checked through collector_verify_secret); every other op verifies the user
// JWT itself against the project's JWKS (getClaims), as delete-account does, except status.
// EVENTBRITE_CLIENT_ID, EVENTBRITE_CLIENT_SECRET and EVENTBRITE_REDIRECT_URI are optional Edge
// Function secrets; without them every request answers 200 {"skipped":"no key"}.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { handleUser, keysFrom, sync } from "./connect.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-collector-secret",
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
  const keys = keysFrom((n) => Deno.env.get(n));
  const rpc = async (name: string, args: Record<string, unknown>) => {
    const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`rpc ${name} failed: ${res.status}`);
    return text ? JSON.parse(text) : null;
  };
  let body: Record<string, unknown> = {};
  try {
    body = (await req.json()) as Record<string, unknown>;
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  try {
    if (body.op === "sync") {
      const secret = req.headers.get("x-collector-secret") ?? "";
      if (
        secret.length < 32 ||
        (await rpc("collector_verify_secret", { p_secret: secret })) !== true
      )
        return json({ error: "unauthorized" }, 401);
      const runId =
        typeof body.run_id === "string" && /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/.test(body.run_id)
          ? body.run_id
          : `eb-${Date.now()}`;
      const out = await sync({ keys, rpc, fetch: (u, i) => fetch(u, i), runId });
      console.log("eventbrite-connect sync", JSON.stringify(out.body));
      return json(out.body, out.status);
    }
    if (body.op === "status") return json({ available: keys !== null });
    if (!keys) return json({ skipped: "no key" });
    const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
    if (!token) return json({ error: "missing_token" }, 401);
    const admin = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await admin.auth.getClaims(token);
    const claims = data?.claims;
    if (error || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string")
      return json({ error: "invalid_token" }, 401);
    const out = await handleUser(claims.sub, body, { keys, rpc, fetch: (u, i) => fetch(u, i) });
    console.log("eventbrite-connect", String(body.op), out.status);
    return json(out.body, out.status);
  } catch (err) {
    console.error(
      "eventbrite-connect: failed",
      err instanceof Error ? err.message.slice(0, 120) : "unexpected",
    );
    return json({ error: "connect_failed" }, 500);
  }
});
