// collector: the one ingest path for the hub map collector jobs (D-040, D-041 slice 4,
// docs/design/hub-map/HUB_MAP_DESIGN.md 3.1).
//
//   GET  /collector/tiles?status=wanted,refresh&limit=20  -> place_tiles_queue()
//   POST /collector/ingest/places {tile_id, run_id, source?, batch_no?, rows}
//                                                         -> ingest_places() (<= 2,000 rows)
//   POST /collector/ingest/events {run_id, source, items, complete, enable}
//                                                         -> collector_ingest_events() (one event
//                                                            source's complete item set, <= 2,000;
//                                                            D-040 event collector, migration 37)
//   POST /collector/tiles/{id}/done {run_id, count, source?}
//                                                         -> finish_place_tile()
//   GET  /collector/places/export?after=<cursor>&limit=5000
//                                                         -> places_odbl_page() (the monthly
//                                                            ODbL dump, slice 14)
//   POST /collector/runs/dump {month, rows, bytes, sha256, published, counts?}
//                                                         -> record_place_dump()
//
// The caller (a GitHub Actions job) sends the header x-collector-secret. The secret is generated
// inside the database (vault secret collector_secret, migration 28) and checked here through
// collector_verify_secret(), which only the service role can call; it is not in code, files or
// GitHub, and it is a different secret from import-feed's, so it reaches these routes only. The
// job never holds the service-role key. The gateway JWT check is off for this function
// (config.toml) because the caller is not a user.
//
// Responses carry counts and error names only, never row data, except the export route: its rows
// are the public place facts the monthly ODbL release publishes anyway (no ids, no member data). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import {
  matchRoute,
  MAX_BODY_BYTES,
  parseDoneBody,
  parseDumpBody,
  parseEventsBody,
  parseIngestBody,
  rpcError,
} from "./routes.ts";

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
    super(`HTTP ${status}`);
  }
}

async function readJson(req: Request): Promise<unknown> {
  const length = Number(req.headers.get("content-length") ?? "0");
  if (length > MAX_BODY_BYTES) throw new Error("body_too_large");
  const text = await req.text();
  if (text.length > MAX_BODY_BYTES) throw new Error("body_too_large");
  return JSON.parse(text);
}

Deno.serve(async (req: Request): Promise<Response> => {
  const route = matchRoute(req.method, req.url);
  if (route.kind === "not_found") return json({ error: "not_found" }, 404);

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
      "collector: secret check failed",
      err instanceof RpcFailure ? err.status : String(err),
    );
    return json({ error: "secret_check_failed" }, 500);
  }
  if (!allowed) return json({ error: "unauthorized" }, 401);

  try {
    if (route.kind === "tiles") {
      const tiles = await rpc("place_tiles_queue", {
        p_kinds: route.statuses,
        p_limit: route.limit,
      });
      return json({ tiles });
    }

    if (route.kind === "export") {
      const page = await rpc("places_odbl_page", { p_after: route.after, p_limit: route.limit });
      return json(page);
    }

    let body: unknown;
    try {
      body = await readJson(req);
    } catch (err) {
      const tooLarge = err instanceof Error && err.message === "body_too_large";
      return json({ error: tooLarge ? "body_too_large" : "invalid_body" }, tooLarge ? 413 : 400);
    }

    if (route.kind === "ingest") {
      const parsed = parseIngestBody(body);
      if (!parsed.ok)
        return json({ error: parsed.error }, parsed.error === "batch_too_large" ? 413 : 400);
      const result = await rpc("ingest_places", { ...parsed.args });
      console.log(
        "collector ingest",
        parsed.args.p_tile_id,
        parsed.args.p_run_id,
        JSON.stringify(result),
      );
      return json(result);
    }

    if (route.kind === "events") {
      const parsed = parseEventsBody(body);
      if (!parsed.ok)
        return json({ error: parsed.error }, parsed.error === "batch_too_large" ? 413 : 400);
      const result = await rpc("collector_ingest_events", { ...parsed.args });
      // Counts only: first_error can quote an item, so it stays in the database (feed_sources).
      const counts = { ...(result as Record<string, unknown>) };
      delete counts.first_error;
      console.log(
        "collector events",
        parsed.args.p_source.slug,
        parsed.runId,
        parsed.args.p_items.length,
        JSON.stringify(counts),
      );
      return json(counts);
    }

    if (route.kind === "dump") {
      const parsed = parseDumpBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("record_place_dump", { ...parsed.args });
      console.log(
        "collector dump",
        parsed.args.p_month,
        parsed.args.p_rows,
        parsed.args.p_published,
      );
      return json(result);
    }

    const parsed = parseDoneBody(route.tileId, body);
    if (!parsed.ok) return json({ error: parsed.error }, 400);
    const result = await rpc("finish_place_tile", { ...parsed.args });
    console.log(
      "collector done",
      parsed.args.p_tile_id,
      parsed.args.p_run_id,
      JSON.stringify(result),
    );
    return json(result);
  } catch (err) {
    if (err instanceof RpcFailure) {
      const mapped = rpcError(err.body);
      if (mapped.status === 502)
        console.error("collector: rpc failed", err.status, err.body.slice(0, 300));
      return json({ error: mapped.error }, mapped.status);
    }
    console.error("collector: failed", String(err));
    return json({ error: "collector_failed" }, 500);
  }
});
