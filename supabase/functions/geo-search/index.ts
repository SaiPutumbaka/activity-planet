// geo-search: address and city autocomplete for the app (migration 80), so the Geoapify key never
// reaches a browser. The app POSTs { kind: "address" | "city", text, bias?, lang? } with the
// signed-in member's JWT (supabase.functions.invoke).
//
//   1. The token is verified locally against the project's JWKS (getClaims; role must be
//      authenticated). The gateway's verify_jwt stays on as well (config.toml).
//   2. geo_search_take (service role) counts the search: per member and UTC day
//      (meta.geo_search_user_daily_cap) and, on a cache miss, one Geoapify credit of the day for
//      the project (meta.geo_search_daily_cap). A cached answer (30 days) needs no credit.
//   3. On a miss it asks Geoapify with GEOAPIFY_SERVER_KEY, keeps only the fields the app reads,
//      caches the answer (geo_search_store) and returns it.
//
// Responses
//   200 { enabled: true, results, cached? }   results: Geoapify fields the app reads (search.ts)
//   200 { enabled: false, results: [] }       no GEOAPIFY_SERVER_KEY on this project: the app
//                                             uses its starter city list and typed addresses
//   400 { error: invalid_body | invalid_kind | invalid_text | invalid_bias }
//   401 { error: missing_token | invalid_token }
//   403 { error: user_not_found }
//   429 { error: too_many_searches, limit: user | global }
//   502 { error: lookup_failed }               Geoapify did not answer
//   500 { error: misconfigured | rpc_failed }
//
// Logs never hold the search text or the member's id (the logs are not private enough for
// addresses people type).
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.118.0";
import { type GeoResult, handle } from "./search.ts";

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
  const apiKey = (Deno.env.get("GEOAPIFY_SERVER_KEY") ?? "").trim() || null;
  const admin = createClient(url, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1] ?? null;
  let body: unknown = null;
  try {
    body = await req.json();
  } catch {
    body = null;
  }

  const answer = await handle(token, body, {
    apiKey,
    userId: async (t) => {
      const { data, error } = await admin.auth.getClaims(t);
      const claims = data?.claims;
      if (error || !claims || claims.role !== "authenticated" || typeof claims.sub !== "string") {
        return null;
      }
      return claims.sub;
    },
    take: async (userId, key) => {
      const { data, error } = await admin.rpc("geo_search_take", { p_user_id: userId, p_key: key });
      if (error) throw new Error("rpc_failed");
      return (data ?? { allowed: false }) as { allowed: boolean; cached?: unknown; limit?: string };
    },
    store: async (key, results: GeoResult[]) => {
      const { error } = await admin.rpc("geo_search_store", { p_key: key, p_results: results });
      if (error) throw new Error("rpc_failed");
    },
    fetch: (u) => fetch(u, { signal: AbortSignal.timeout(8000) }),
  });
  if (answer.status >= 500)
    console.error(`geo-search: ${answer.status} ${String(answer.body.error)}`);
  return json(answer.body, answer.status);
});
