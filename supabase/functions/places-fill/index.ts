// places-fill: Geoapify quick fill for new place tiles (D-042 slice 9; the logic is in fill.ts).
//
//   POST /places-fill {reason?}  -> runFill(): claims up to 2 fillable tiles, asks Geoapify for
//                                   the specific hubs' categories in each tile within the daily
//                                   budget, ingests the rows as source 'geoapify'.
//
// The caller is the database (pg_cron job places-fill every 15 minutes, and a ping when a tile
// becomes fillable, both through pg_net and public.places_fill_dispatch, migration 43), not a
// user, so the gateway JWT check is off (config.toml). Every request must carry the header
// x-collector-secret, checked through collector_verify_secret (vault secret collector_secret,
// migration 28; it never leaves the database except in that pg_net header).
//
// GEOAPIFY_SERVER_KEY is an optional Supabase Edge Function secret (FOUNDER-TODO item 5). Without
// it the function answers 200 {"skipped": "no_key"}, logs "places-fill skipped: no key" and calls
// nothing else: a missing key is never an error (D-042 Keys). The key is never logged or returned.
// Responses carry counts and error names only. SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are
// injected by Supabase.
import { runFill } from "./fill.ts";

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

class RpcFailure extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`rpc_http_${status}`);
  }
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") return json({ error: "not_found" }, 404);
  await req.body?.cancel();

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ error: "misconfigured" }, 500);

  const rpc = async (name: string, args: Record<string, unknown>) => {
    const res = await fetch(`${supabaseUrl}/rest/v1/rpc/${name}`, {
      method: "POST",
      headers: {
        apikey: serviceKey,
        Authorization: `Bearer ${serviceKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(args),
    });
    const text = await res.text();
    if (!res.ok) throw new RpcFailure(res.status, text);
    return text ? JSON.parse(text) : null;
  };

  const secret = req.headers.get("x-collector-secret") ?? "";
  let allowed = false;
  try {
    allowed =
      secret.length >= 32 && (await rpc("collector_verify_secret", { p_secret: secret })) === true;
  } catch (err) {
    console.error(
      "places-fill: secret check failed",
      err instanceof RpcFailure ? err.status : String(err),
    );
    return json({ error: "secret_check_failed" }, 500);
  }
  if (!allowed) return json({ error: "unauthorized" }, 401);

  try {
    const result = await runFill({
      key: Deno.env.get("GEOAPIFY_SERVER_KEY"),
      rpc,
      fetch: (url) =>
        fetch(url, {
          headers: {
            Accept: "application/json",
            "User-Agent":
              "ActivityPlanet-places-fill/1 (+https://github.com/SaiPutumbaka/activity-planet)",
          },
        }),
    });
    console.log(
      "places-fill",
      JSON.stringify({
        skipped: result.skipped ?? null,
        tiles: result.tiles.length,
        filled: result.tiles.filter((t) => t.outcome === "filled").length,
        budget_left: result.budget_left,
        stopped: result.stopped ?? null,
      }),
    );
    return json(result);
  } catch (err) {
    if (err instanceof RpcFailure) {
      console.error("places-fill: rpc failed", err.status, err.body.slice(0, 300));
      return json({ error: "rpc_failed" }, 502);
    }
    console.error("places-fill: failed", String(err).slice(0, 300));
    return json({ error: "fill_failed" }, 500);
  }
});
