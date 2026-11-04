// deno test supabase/functions/collector
import { assertEquals } from "jsr:@std/assert@1.0.19";
import { matchRoute, parseDoneBody, parseIngestBody, rpcError } from "./routes.ts";

const base = "https://example.supabase.co/functions/v1/collector";

Deno.test("routes: the three collector paths and nothing else", () => {
  assertEquals(matchRoute("GET", `${base}/tiles`), {
    kind: "tiles",
    statuses: ["wanted", "refresh"],
    limit: 20,
  });
  assertEquals(matchRoute("GET", `${base}/tiles?status=wanted,bogus&limit=500`), {
    kind: "tiles",
    statuses: ["wanted"],
    limit: 100,
  });
  assertEquals(matchRoute("POST", `${base}/ingest/places`), { kind: "ingest" });
  assertEquals(matchRoute("POST", `${base}/tiles/176832/done`), { kind: "done", tileId: 176832 });
  assertEquals(matchRoute("POST", "http://localhost:8000/collector/tiles/12/done"), {
    kind: "done",
    tileId: 12,
  });
  assertEquals(matchRoute("POST", `${base}/tiles/999999/done`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/ingest/places`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/tiles`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/../import-feed`), { kind: "not_found" });
});

Deno.test("ingest body: shape checked before the database sees it", () => {
  const ok = parseIngestBody({ tile_id: 176832, run_id: "gh-123.1", rows: [{ source_id: "n1" }] });
  assertEquals(ok, {
    ok: true,
    args: {
      p_tile_id: 176832,
      p_run_id: "gh-123.1",
      p_batch: [{ source_id: "n1" }],
      p_source: "osm",
      p_batch_no: null,
    },
  });
  assertEquals(
    parseIngestBody({ tile_id: 1, run_id: "r", rows: [], source: "geoapify", batch_no: 3 }),
    {
      ok: true,
      args: { p_tile_id: 1, p_run_id: "r", p_batch: [], p_source: "geoapify", p_batch_no: 3 },
    },
  );
  assertEquals(parseIngestBody([]), { ok: false, error: "invalid_body" });
  assertEquals(parseIngestBody({ tile_id: -1, run_id: "r", rows: [] }), {
    ok: false,
    error: "invalid_tile_id",
  });
  assertEquals(parseIngestBody({ tile_id: 1, run_id: "bad id", rows: [] }), {
    ok: false,
    error: "invalid_run_id",
  });
  assertEquals(parseIngestBody({ tile_id: 1, run_id: "r", rows: [], source: "user" }), {
    ok: false,
    error: "invalid_source",
  });
  assertEquals(parseIngestBody({ tile_id: 1, run_id: "r", rows: {} }), {
    ok: false,
    error: "invalid_rows",
  });
  assertEquals(parseIngestBody({ tile_id: 1, run_id: "r", rows: new Array(2001).fill({}) }), {
    ok: false,
    error: "batch_too_large",
  });
});

Deno.test("done body: run id and a non-negative count", () => {
  assertEquals(parseDoneBody(5, { run_id: "r1", count: 0 }), {
    ok: true,
    args: { p_tile_id: 5, p_run_id: "r1", p_count: 0, p_source: "osm" },
  });
  assertEquals(parseDoneBody(5, { run_id: "r1", count: -1 }), {
    ok: false,
    error: "invalid_count",
  });
  assertEquals(parseDoneBody(5, { run_id: "r1", count: 1.5 }), {
    ok: false,
    error: "invalid_count",
  });
});

Deno.test("done body: allow_drop is sent only when true", () => {
  assertEquals(parseDoneBody(5, { run_id: "r1", count: 3, allow_drop: true }), {
    ok: true,
    args: { p_tile_id: 5, p_run_id: "r1", p_count: 3, p_source: "osm", p_allow_drop: true },
  });
  assertEquals(parseDoneBody(5, { run_id: "r1", count: 3, allow_drop: false }), {
    ok: true,
    args: { p_tile_id: 5, p_run_id: "r1", p_count: 3, p_source: "osm" },
  });
  assertEquals(parseDoneBody(5, { run_id: "r1", count: 3, allow_drop: "yes" }), {
    ok: false,
    error: "invalid_allow_drop",
  });
});

Deno.test("rpc errors: known names keep their meaning, the rest are 502", () => {
  assertEquals(rpcError(JSON.stringify({ code: "P0002", message: "tile_unknown" })), {
    error: "tile_unknown",
    status: 404,
  });
  assertEquals(rpcError(JSON.stringify({ message: "count_mismatch" })), {
    error: "count_mismatch",
    status: 409,
  });
  assertEquals(rpcError(JSON.stringify({ message: "row_count_drop" })), {
    error: "row_count_drop",
    status: 409,
  });
  assertEquals(rpcError(JSON.stringify({ message: "something else" })), {
    error: "rpc_failed",
    status: 502,
  });
  assertEquals(rpcError("not json"), { error: "rpc_failed", status: 502 });
});
