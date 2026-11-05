// organizer-verify (migration 62, design 2.3): a signed-in organizer asks for the DNS TXT check of
// their claim now ({claim_id}). The user JWT is verified against the project's JWKS (getClaims),
// as delete-account does; the claim is read with that same JWT (organizer_claim_check checks the
// owner), the record through DNS-over-HTTPS, and the outcome stored with the service role
// (collector_claims_record). Other methods are only marked due for the verify job. No key, no
// secret of its own. Logs carry outcomes only, never a host or a token.
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { handleVerify } from "./verify.ts";

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
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!url || !serviceKey || !anonKey) return json({ error: "misconfigured" }, 500);
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
  const rpc = async (
    name: string,
    args: Record<string, unknown>,
    bearer: string,
    apikey: string,
  ) => {
    const res = await fetch(`${url}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: { apikey, Authorization: `Bearer ${bearer}`, "Content-Type": "application/json" },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) {
      let message = "rpc_failed";
      try {
        message = JSON.parse(text)?.message ?? message;
      } catch {
        // keep rpc_failed
      }
      throw new Error(message);
    }
    return text ? JSON.parse(text) : null;
  };
  try {
    const answer = await handleVerify(body, {
      claimCheck: (id) => rpc("organizer_claim_check", { p_claim: id }, token, anonKey),
      record: (results) =>
        rpc("collector_claims_record", { p_results: results }, serviceKey, serviceKey),
      fetch: (u, init) => fetch(u, init),
    });
    console.log("organizer-verify", answer.status, String(answer.body.status ?? answer.body.error));
    return json(answer.body, answer.status);
  } catch (err) {
    const message = err instanceof Error ? err.message : "failed";
    const known = ["not_found", "not_authenticated"].includes(message);
    return json({ error: known ? message : "verify_failed" }, known ? 404 : 500);
  }
});
