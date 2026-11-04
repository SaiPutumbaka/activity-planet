// place-files: place matching and row lookups from the static place files (D-042 slice 11; the
// logic is in files.ts, the database side in migration 49).
//
//   POST /place-files/match   The database (pg_cron job place-match, minutes 11 and 41, through
//                             pg_net and public.place_match_dispatch). Header x-collector-secret,
//                             checked through collector_verify_secret. Matches the queued public
//                             venues against the published files and records the results.
//   POST /place-files/place   A signed-in member (Authorization: Bearer <user JWT>, checked with
//                             the Auth API). Body {osm_ref, tile}: the database row of a place
//                             that only its tile's file holds, so it can be reported, corrected or
//                             used for "Start a plan here". Answers {id} or {id: null, reason}.
//
// The gateway JWT check is off (config.toml) because the match caller is the database; the place
// route checks the member's token itself. Files are read from PLACES_BASE_URL (an optional Edge
// Function secret) or else meta.places_base_url (GitHub Pages, D-042). Without either, or before
// any file is published, both routes answer cleanly and change nothing. Responses carry counts,
// ids and reason names only; nothing logs a name, a point or a user id. SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import { parsePlaceRequest, placeFromFile, runMatch } from "./files.ts";

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

class RpcFailure extends Error {
  constructor(
    readonly status: number,
    readonly body: string,
  ) {
    super(`rpc_http_${status}`);
  }
}

const USER_AGENT =
  "ActivityPlanet-place-files/1 (+https://github.com/SaiPutumbaka/activity-planet)";

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS_HEADERS });
  const route = new URL(req.url).pathname.replace(/\/+$/, "").split("/").pop();
  if (req.method !== "POST" || (route !== "match" && route !== "place")) {
    await req.body?.cancel();
    return json({ error: "not_found" }, 404);
  }

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
  const fileFetch = (url: string) =>
    fetch(url, { headers: { Accept: "application/json", "User-Agent": USER_AGENT } });
  const base = Deno.env.get("PLACES_BASE_URL") ?? null;

  try {
    if (route === "match") {
      await req.body?.cancel();
      const secret = req.headers.get("x-collector-secret") ?? "";
      const allowed =
        secret.length >= 32 &&
        (await rpc("collector_verify_secret", { p_secret: secret })) === true;
      if (!allowed) return json({ error: "unauthorized" }, 401);
      const result = await runMatch({ rpc, fetch: fileFetch, base });
      console.log(
        "place-files match",
        JSON.stringify({
          skipped: result.skipped ?? null,
          venues: result.venues,
          matched: result.matched,
          files: result.files,
          file_errors: result.file_errors,
          recorded: result.recorded,
        }),
      );
      return json(result);
    }

    // route === "place"
    const token = /^Bearer\s+(.+)$/i.exec(req.headers.get("Authorization") ?? "")?.[1];
    if (!token || token === serviceKey) {
      await req.body?.cancel();
      return json({ error: "sign_in_required" }, 401);
    }
    const who = await fetch(`${supabaseUrl}/auth/v1/user`, {
      headers: { apikey: serviceKey, Authorization: `Bearer ${token}` },
    });
    const user = who.ok ? ((await who.json()) as { id?: string; role?: string }) : null;
    if (!who.ok) await who.body?.cancel();
    if (!user?.id || user.role !== "authenticated") {
      await req.body?.cancel();
      return json({ error: "sign_in_required" }, 401);
    }
    let body: unknown = null;
    try {
      body = await req.json();
    } catch {
      body = null;
    }
    const parsed = parsePlaceRequest(body);
    if (!parsed) return json({ error: "request_invalid" }, 400);
    const result = await placeFromFile({ rpc, fetch: fileFetch, base }, parsed.osmRef, parsed.tile);
    console.log("place-files place", result.id ? "row" : (result.reason ?? "none"));
    return json(result);
  } catch (err) {
    if (err instanceof RpcFailure) {
      console.error("place-files: rpc failed", err.status, err.body.slice(0, 300));
      return json({ error: "rpc_failed" }, 502);
    }
    console.error("place-files: failed", String(err).slice(0, 300));
    return json({ error: "failed" }, 500);
  }
});
