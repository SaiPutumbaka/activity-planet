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
//   GET  /collector/files/queue?limit=50&all=1&tiles=1,2  -> place_files_queue() (static place
//                                                            files, D-042 slice 3, migration 42)
//   GET  /collector/tiles/{id}/rows?after=<osm_ref>&limit=5000
//                                                         -> place_tile_file_page()
//   POST /collector/files/record {published, rules?, tiles?}
//                                                         -> place_files_record()
//   GET  /collector/regions?due=1&limit=20                -> collector_regions_due() (collector
//                                                            regions not collected today; due=0
//                                                            for all; D-042 slice 6, migration 45)
//   POST /collector/regions/record {run_id, regions: [{id, sources, items, timezone?}]}
//                                                         -> collector_regions_record()
//   GET  /collector/sources?regions=<ids>                 -> collector_sources_for_regions() (the
//                                                            discovered sources of the regions as
//                                                            seeds; D-042 slice 7, migration 46)
//   POST /collector/sources/record {run_id, results: [{candidate_id, outcome, ...}]}
//                                                         -> source_candidates_record() (lifecycle)
//   GET  /collector/candidates?limit=150&regions=<ids>    -> source_candidates_due() (to probe)
//   POST /collector/candidates {candidates: [{url, origin, ...}]}
//                                                         -> source_candidates_add()
//   GET  /collector/discovery/gate?hash=<probe hash>      -> source_discovery_gate_status() (the
//                                                            Atlanta gate; D-042 slice 8,
//                                                            migration 47)
//   POST /collector/discovery/gate {run_id, probe_hash, region, expected, required, found, ...}
//                                                         -> source_discovery_gate_record()
//   GET  /collector/discovery/queue?hash=&regions=&per_region=150&limit=500
//                                                         -> source_discovery_probe_queue() (409
//                                                            discovery_gate_closed until the gate
//                                                            passed for that probe code)
//   GET  /collector/discovery/regions?limit=10            -> source_discovery_regions_due()
//   POST /collector/discovery/regions/record {regions: [<uuid>, ...]}
//                                                         -> source_discovery_regions_record()
//
// The caller (a GitHub Actions job) sends the header x-collector-secret. The secret is generated
// inside the database (vault secret collector_secret, migration 28) and checked here through
// collector_verify_secret(), which only the service role can call; it is not in code, files or
// GitHub, and it is a different secret from import-feed's, so it reaches these routes only. The
// job never holds the service-role key. The gateway JWT check is off for this function
// (config.toml) because the caller is not a user.
//
// Responses carry counts and error names only, never row data, except the export and tile rows routes: their rows
// are the public place facts the monthly ODbL release publishes anyway (no ids, no member data). SUPABASE_URL and
// SUPABASE_SERVICE_ROLE_KEY are injected by Supabase.
import {
  matchRoute,
  MAX_BODY_BYTES,
  parseDoneBody,
  parseDumpBody,
  parseEventsBody,
  parseFilesRecordBody,
  parseIngestBody,
  parseCandidatesBody,
  parseDiscoveryRegionsBody,
  parseGateBody,
  parseRegionsRecordBody,
  parseSourcesRecordBody,
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

    if (route.kind === "files_queue") {
      return json(
        await rpc("place_files_queue", {
          p_limit: route.limit,
          p_all: route.all,
          p_tiles: route.tiles,
        }),
      );
    }

    // Public ODbL facts of one tile (no ids, no member rows), as the files job writes them.
    if (route.kind === "file_rows") {
      return json(
        await rpc("place_tile_file_page", {
          p_tile_id: route.tileId,
          p_after: route.after,
          p_limit: route.limit,
        }),
      );
    }

    // Region points (0.1 degree) and radii for the nightly event run; no home counts, no user ids.
    if (route.kind === "regions") {
      const regions = await rpc("collector_regions_due", {
        p_limit: route.limit,
        p_all: route.all,
      });
      return json({ regions });
    }

    // Discovered sources as seeds and candidates to probe: public calendar URLs, no user ids.
    if (route.kind === "sources") {
      const sources = await rpc("collector_sources_for_regions", { p_regions: route.regions });
      return json({ sources });
    }
    if (route.kind === "candidates") {
      const candidates = await rpc("source_candidates_due", {
        p_limit: route.limit,
        p_regions: route.regions,
      });
      return json({ candidates });
    }

    // The discovery probe (D-042 slice 8): gate status, the probe queue and regions to build.
    if (route.kind === "gate_status") {
      return json(await rpc("source_discovery_gate_status", { p_probe_hash: route.hash }));
    }
    if (route.kind === "probe_queue") {
      const candidates = await rpc("source_discovery_probe_queue", {
        p_probe_hash: route.hash,
        p_regions: route.regions,
        p_per_region: route.perRegion,
        p_limit: route.limit,
      });
      return json({ candidates });
    }
    if (route.kind === "discovery_regions") {
      const regions = await rpc("source_discovery_regions_due", { p_limit: route.limit });
      return json({ regions });
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

    if (route.kind === "regions_record") {
      const parsed = parseRegionsRecordBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("collector_regions_record", { ...parsed.args });
      console.log("collector regions", parsed.runId, JSON.stringify(result));
      return json(result);
    }

    if (route.kind === "sources_record") {
      const parsed = parseSourcesRecordBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("source_candidates_record", { ...parsed.args });
      console.log("collector sources", parsed.runId, JSON.stringify(result));
      return json(result);
    }

    if (route.kind === "candidates_add") {
      const parsed = parseCandidatesBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("source_candidates_add", { ...parsed.args });
      console.log("collector candidates", JSON.stringify(result));
      return json(result);
    }

    if (route.kind === "gate_record") {
      const parsed = parseGateBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("source_discovery_gate_record", { ...parsed.args });
      console.log("collector gate", parsed.args.p_gate.run_id, JSON.stringify(result));
      return json(result);
    }

    if (route.kind === "discovery_regions_record") {
      const parsed = parseDiscoveryRegionsBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("source_discovery_regions_record", { ...parsed.args });
      console.log("collector discovery regions", JSON.stringify(result));
      return json(result);
    }

    if (route.kind === "files_record") {
      const parsed = parseFilesRecordBody(body);
      if (!parsed.ok) return json({ error: parsed.error }, 400);
      const result = await rpc("place_files_record", { ...parsed.args });
      console.log("collector files", JSON.stringify(result));
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
