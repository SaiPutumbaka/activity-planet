// deno test supabase/functions/collector
import { assertEquals } from "jsr:@std/assert@1.0.19";
import {
  matchRoute,
  parseApiBudgetReturnBody,
  parseApiBudgetTakeBody,
  parseCandidatesBody,
  parseDiscoveryRegionsBody,
  parseDoneBody,
  parseGateBody,
  parseSourcesRecordBody,
  parseDumpBody,
  parseEventsBody,
  parseFilesRecordBody,
  parseIngestBody,
  parseRegionsRecordBody,
  rpcError,
} from "./routes.ts";

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

Deno.test("export and dump routes (slice 14)", () => {
  assertEquals(matchRoute("GET", `${base}/places/export`), {
    kind: "export",
    after: null,
    limit: 5000,
  });
  assertEquals(
    matchRoute(
      "GET",
      `${base}/places/export?after=0F8FAD5B-D9CB-469F-A165-70867728950E&limit=99999`,
    ),
    { kind: "export", after: "0f8fad5b-d9cb-469f-a165-70867728950e", limit: 5000 },
  );
  assertEquals(matchRoute("GET", `${base}/places/export?limit=0`), {
    kind: "export",
    after: null,
    limit: 1,
  });
  assertEquals(matchRoute("GET", `${base}/places/export?after=1;drop`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/places/export`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/runs/dump`), { kind: "dump" });
  assertEquals(matchRoute("GET", `${base}/runs/dump`), { kind: "not_found" });
});

Deno.test("dump body: checked before the database sees it", () => {
  const sha = "a".repeat(64);
  assertEquals(
    parseDumpBody({
      month: "2026-11",
      rows: 10,
      bytes: 2048,
      sha256: sha,
      published: true,
      counts: { osm: 9, user: 1 },
    }),
    {
      ok: true,
      args: {
        p_month: "2026-11",
        p_rows: 10,
        p_bytes: 2048,
        p_sha256: sha,
        p_published: true,
        p_counts: { osm: 9, user: 1 },
      },
    },
  );
  assertEquals(
    parseDumpBody({ month: "2026-13", rows: 1, bytes: 1, sha256: sha, published: false }),
    {
      ok: false,
      error: "invalid_month",
    },
  );
  assertEquals(
    parseDumpBody({ month: "2026-11", rows: -1, bytes: 1, sha256: sha, published: false }),
    {
      ok: false,
      error: "invalid_rows",
    },
  );
  assertEquals(
    parseDumpBody({ month: "2026-11", rows: 1, bytes: 1, sha256: "XYZ", published: false }),
    {
      ok: false,
      error: "invalid_sha256",
    },
  );
  assertEquals(parseDumpBody({ month: "2026-11", rows: 1, bytes: 1, sha256: sha }), {
    ok: false,
    error: "invalid_published",
  });
  assertEquals(
    parseDumpBody({
      month: "2026-11",
      rows: 1,
      bytes: 1,
      sha256: sha,
      published: false,
      counts: { "a b": 1 },
    }),
    { ok: false, error: "invalid_counts" },
  );
  assertEquals(rpcError(JSON.stringify({ message: "sha256_invalid" })), {
    error: "sha256_invalid",
    status: 400,
  });
});

Deno.test("events body: POST /ingest/events, shape checked before the database sees it", () => {
  assertEquals(matchRoute("POST", `${base}/ingest/events`), { kind: "events" });
  assertEquals(matchRoute("GET", `${base}/ingest/events`), { kind: "not_found" });
  const source = { slug: "atl-botanical-garden", kind: "jsonld" };
  assertEquals(
    parseEventsBody({ run_id: "gh-9-1", source, items: [{ external_id: "a" }], complete: true }),
    {
      ok: true,
      runId: "gh-9-1",
      args: {
        p_source: source,
        p_items: [{ external_id: "a" }],
        p_complete: true,
        p_enable: false,
        p_run_id: "gh-9-1",
        p_seen: [],
      },
    },
  );
  assertEquals(
    parseEventsBody({ run_id: "r", source, items: [], complete: false, enable: true }).ok,
    true,
  );
  assertEquals(
    parseEventsBody({ run_id: "r", source: { slug: "Bad Slug" }, items: [], complete: true }),
    {
      ok: false,
      error: "invalid_source",
    },
  );
  assertEquals(parseEventsBody({ run_id: "r", source, items: {}, complete: true }), {
    ok: false,
    error: "invalid_items",
  });
  assertEquals(parseEventsBody({ run_id: "r", source, items: [] }), {
    ok: false,
    error: "invalid_complete",
  });
  assertEquals(
    parseEventsBody({ run_id: "r", source, items: new Array(2001).fill({}), complete: true }),
    { ok: false, error: "batch_too_large" },
  );
  const withSeen = parseEventsBody({ run_id: "r", source, items: [], seen: ["a"], complete: true });
  assertEquals(withSeen.ok && withSeen.args.p_seen, ["a"]);
  for (const seen of [{}, [1], [""], ["x".repeat(201)], new Array(2001).fill("a")]) {
    assertEquals(parseEventsBody({ run_id: "r", source, items: [], seen, complete: true }), {
      ok: false,
      error: "invalid_seen",
    });
  }
  assertEquals(rpcError(JSON.stringify({ message: "source_not_collector" })), {
    error: "source_not_collector",
    status: 409,
  });
});

Deno.test("static place files routes (migration 42)", () => {
  const base = "https://x.supabase.co/functions/v1/collector";
  assertEquals(matchRoute("GET", `${base}/files/queue`), {
    kind: "files_queue",
    limit: 50,
    all: false,
    tiles: null,
  });
  assertEquals(
    matchRoute("GET", `${base}/files/queue?limit=9999&all=1&tiles=198375,178030,198375`),
    {
      kind: "files_queue",
      limit: 500,
      all: true,
      tiles: [198375, 178030],
    },
  );
  assertEquals(matchRoute("GET", `${base}/files/queue?tiles=300000`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/files/queue?tiles=1;drop`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/tiles/198375/rows`), {
    kind: "file_rows",
    tileId: 198375,
    after: null,
    limit: 5000,
  });
  assertEquals(matchRoute("GET", `${base}/tiles/198375/rows?after=w123&limit=10`), {
    kind: "file_rows",
    tileId: 198375,
    after: "w123",
    limit: 10,
  });
  assertEquals(matchRoute("GET", `${base}/tiles/198375/rows?after=x1`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/tiles/999999/rows`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/files/record`), { kind: "files_record" });
  assertEquals(matchRoute("GET", `${base}/files/record`), { kind: "not_found" });
});

Deno.test("parseFilesRecordBody", () => {
  assertEquals(parseFilesRecordBody({ published: false, tiles: [] }), {
    ok: true,
    args: { p: { published: false, tiles: [] } },
  });
  assertEquals(parseFilesRecordBody({ published: "yes" }), {
    ok: false,
    error: "invalid_published",
  });
  assertEquals(parseFilesRecordBody({ published: true, tiles: {} }), {
    ok: false,
    error: "invalid_tiles",
  });
  assertEquals(parseFilesRecordBody({ published: true, rules: [] }), {
    ok: false,
    error: "invalid_rules",
  });
  assertEquals(parseFilesRecordBody([]), { ok: false, error: "invalid_body" });
});

Deno.test("regions routes: due list and record (migration 45)", () => {
  assertEquals(matchRoute("GET", `${base}/regions`), { kind: "regions", limit: 20, all: false });
  assertEquals(matchRoute("GET", `${base}/regions?due=1&limit=500`), {
    kind: "regions",
    limit: 100,
    all: false,
  });
  assertEquals(matchRoute("GET", `${base}/regions?due=0&limit=0`), {
    kind: "regions",
    limit: 1,
    all: true,
  });
  assertEquals(matchRoute("POST", `${base}/regions/record`), { kind: "regions_record" });
  assertEquals(matchRoute("POST", `${base}/regions`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/regions/record`), { kind: "not_found" });
});

Deno.test("regions record body: ids, counts and an optional zone name", () => {
  const id = "0B1C2D3E-4F50-4a6b-8c7d-9e0f1a2b3c4d";
  const ok = parseRegionsRecordBody({
    run_id: "gh-1-1",
    regions: [
      { id, sources: 2, items: 40, timezone: "America/New_York" },
      { id, sources: 0, items: 0 },
    ],
  });
  assertEquals(ok, {
    ok: true,
    runId: "gh-1-1",
    args: {
      p_regions: [
        { id: id.toLowerCase(), sources: 2, items: 40, timezone: "America/New_York" },
        { id: id.toLowerCase(), sources: 0, items: 0 },
      ],
    },
  });
  assertEquals(parseRegionsRecordBody({ run_id: "x", regions: [] }).ok, true);
  assertEquals(parseRegionsRecordBody([]), { ok: false, error: "invalid_body" });
  assertEquals(parseRegionsRecordBody({ regions: [] }), { ok: false, error: "invalid_run_id" });
  for (const bad of [
    { id: "nope", sources: 0, items: 0 },
    { id, sources: -1, items: 0 },
    { id, sources: 1.5, items: 0 },
    { id, sources: 0 },
    { id, sources: 0, items: 0, timezone: "Europe/Berlin; drop" },
    { id, sources: 0, items: 0, timezone: 7 },
    "x",
  ]) {
    assertEquals(parseRegionsRecordBody({ run_id: "r", regions: [bad] }), {
      ok: false,
      error: "invalid_regions",
    });
  }
  const many = Array.from({ length: 101 }, () => ({ id, sources: 0, items: 0 }));
  assertEquals(parseRegionsRecordBody({ run_id: "r", regions: many }), {
    ok: false,
    error: "invalid_regions",
  });
  assertEquals(rpcError(JSON.stringify({ message: "regions_invalid" })), {
    error: "regions_invalid",
    status: 400,
  });
});

Deno.test("discovered sources and candidate routes (migration 46)", () => {
  const base = "https://x.supabase.co/functions/v1/collector";
  const a = "0B1C2D3E-4F50-4a6b-8c7d-9e0f1a2b3c4d";
  const b = "1b1c2d3e-4f50-4a6b-8c7d-9e0f1a2b3c4d";
  assertEquals(matchRoute("GET", `${base}/sources?regions=${a},${b},${a}`), {
    kind: "sources",
    regions: [a.toLowerCase(), b],
  });
  assertEquals(matchRoute("GET", `${base}/sources`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/sources?regions=nope`), { kind: "not_found" });
  const many = Array.from({ length: 101 }, () => a).join(",");
  assertEquals(matchRoute("GET", `${base}/sources?regions=${many}`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/sources/record`), { kind: "sources_record" });
  assertEquals(matchRoute("GET", `${base}/candidates`), {
    kind: "candidates",
    limit: 150,
    regions: null,
  });
  assertEquals(matchRoute("GET", `${base}/candidates?limit=9999&regions=${b}`), {
    kind: "candidates",
    limit: 500,
    regions: [b],
  });
  assertEquals(matchRoute("GET", `${base}/candidates?regions=x`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/candidates`), { kind: "candidates_add" });
});

Deno.test("sources record body: outcomes, kinds and counts", () => {
  const id = "0B1C2D3E-4F50-4a6b-8c7d-9e0f1a2b3c4d";
  const ok = parseSourcesRecordBody({
    run_id: "gh-9-1",
    results: [
      {
        candidate_id: id,
        outcome: "ok",
        kind: "ics",
        url: "https://lib.example.org/events.ics",
        platform: "libcal",
        items: 12,
        in_region: 9,
        requests: 3,
        errors: 0,
        complete: true,
      },
      { candidate_id: id, outcome: "empty", items: null },
    ],
  });
  assertEquals(ok, {
    ok: true,
    runId: "gh-9-1",
    args: {
      p_results: [
        {
          candidate_id: id.toLowerCase(),
          run_id: "gh-9-1",
          outcome: "ok",
          kind: "ics",
          url: "https://lib.example.org/events.ics",
          platform: "libcal",
          items: 12,
          in_region: 9,
          requests: 3,
          errors: 0,
          complete: true,
        },
        { candidate_id: id.toLowerCase(), run_id: "gh-9-1", outcome: "empty" },
      ],
    },
  });
  assertEquals(parseSourcesRecordBody({ results: [] }), { ok: false, error: "invalid_run_id" });
  for (const bad of [
    { candidate_id: "x", outcome: "ok" },
    { candidate_id: id, outcome: "great" },
    { candidate_id: id, outcome: "ok", kind: "localist" },
    { candidate_id: id, outcome: "ok", url: "http://a.org/" },
    { candidate_id: id, outcome: "ok", platform: "Bad Name" },
    { candidate_id: id, outcome: "ok", items: -1 },
    { candidate_id: id, outcome: "ok", errors: 1.5 },
    { candidate_id: id, outcome: "ok", complete: "yes" },
    7,
  ]) {
    assertEquals(parseSourcesRecordBody({ run_id: "r", results: [bad] }), {
      ok: false,
      error: "invalid_results",
    });
  }
  const many = Array.from({ length: 501 }, () => ({ candidate_id: id, outcome: "ok" }));
  assertEquals(parseSourcesRecordBody({ run_id: "r", results: many }).ok, false);
  assertEquals(rpcError(JSON.stringify({ message: "results_invalid" })).status, 400);
});

Deno.test("candidates body: url and automatic origin only", () => {
  const c = { url: "https://lib.example.org/", origin: "osm", score: 70 };
  assertEquals(parseCandidatesBody({ candidates: [c] }), {
    ok: true,
    args: { p_candidates: [c] },
  });
  for (const bad of [
    { url: "https://a.org/", origin: "member" },
    { origin: "osm" },
    { url: "https://a.org/" + "x".repeat(500), origin: "wikidata" },
    null,
  ]) {
    assertEquals(parseCandidatesBody({ candidates: [bad] }), {
      ok: false,
      error: "invalid_candidates",
    });
  }
  assertEquals(parseCandidatesBody([]), { ok: false, error: "invalid_body" });
  assertEquals(rpcError(JSON.stringify({ message: "candidates_invalid" })).status, 400);
});

Deno.test("discovery routes: gate, probe queue and regions (migration 47)", () => {
  const hash = "0123456789abcdef0123456789abcdef";
  assertEquals(matchRoute("GET", `${base}/discovery/gate?hash=${hash.toUpperCase()}`), {
    kind: "gate_status",
    hash,
  });
  assertEquals(matchRoute("GET", `${base}/discovery/gate?hash=xyz`), { kind: "not_found" });
  assertEquals(matchRoute("POST", `${base}/discovery/gate`), { kind: "gate_record" });
  assertEquals(matchRoute("GET", `${base}/discovery/queue?hash=${hash}`), {
    kind: "probe_queue",
    hash,
    regions: null,
    perRegion: 150,
    limit: 500,
  });
  const id = "11111111-2222-3333-4444-555555555555";
  assertEquals(
    matchRoute("GET", `${base}/discovery/queue?hash=${hash}&regions=${id}&per_region=9999&limit=0`),
    { kind: "probe_queue", hash, regions: [id], perRegion: 500, limit: 1 },
  );
  assertEquals(matchRoute("GET", `${base}/discovery/queue?hash=${hash}&regions=bad`), {
    kind: "not_found",
  });
  assertEquals(matchRoute("GET", `${base}/discovery/queue`), { kind: "not_found" });
  assertEquals(matchRoute("GET", `${base}/discovery/regions?limit=500`), {
    kind: "discovery_regions",
    limit: 100,
  });
  assertEquals(matchRoute("POST", `${base}/discovery/regions/record`), {
    kind: "discovery_regions_record",
  });
  assertEquals(rpcError(JSON.stringify({ message: "discovery_gate_closed" })).status, 409);
  assertEquals(rpcError(JSON.stringify({ message: "gate_invalid" })).status, 400);
});

Deno.test("gate body: counts and hosts only; passed is never passed through", () => {
  const hash = "0123456789abcdef";
  const good = {
    run_id: "gh-1-1",
    probe_hash: hash,
    region: "atl",
    expected: 9,
    required: 6,
    found: 7,
    passed: true,
    found_sites: ["atlantabg.org"],
    counts: { candidates: 400 },
  };
  const parsed = parseGateBody(good);
  assertEquals(parsed.ok, true);
  if (parsed.ok) assertEquals("passed" in parsed.args.p_gate, false);
  for (const bad of [
    { ...good, run_id: "" },
    { ...good, probe_hash: "XYZ" },
    { ...good, region: "Atlanta Metro" },
    { ...good, found: -1 },
    { ...good, found_sites: "atlantabg.org" },
    { ...good, counts: { "Bad Key": 1 } },
    { ...good, counts: { n: 1.5 } },
  ]) {
    assertEquals(parseGateBody(bad).ok, false);
  }
  assertEquals(parseGateBody([]), { ok: false, error: "invalid_body" });
  const id = "11111111-2222-3333-4444-555555555555";
  assertEquals(parseDiscoveryRegionsBody({ regions: [id.toUpperCase()] }), {
    ok: true,
    args: { p_ids: [id] },
  });
  assertEquals(parseDiscoveryRegionsBody({ regions: ["x"] }).ok, false);
});

Deno.test("api budget: routes and bodies (D-042 slice 10)", () => {
  assertEquals(matchRoute("POST", `${base}/api-budget`), { kind: "api_budget_take" });
  assertEquals(matchRoute("POST", `${base}/api-budget/return`), { kind: "api_budget_return" });
  assertEquals(matchRoute("GET", `${base}/api-budget`), { kind: "not_found" });
  assertEquals(parseApiBudgetTakeBody({ api: "ticketmaster", calls: 100 }), {
    ok: true,
    args: { p_api: "ticketmaster", p_calls: 100 },
  });
  for (const bad of [
    { api: "eventbrite", calls: 1 },
    { api: "seatgeek", calls: 0 },
    { api: "seatgeek", calls: 1001 },
    { api: "seatgeek", calls: 1.5 },
    { api: "seatgeek" },
  ]) {
    assertEquals(parseApiBudgetTakeBody(bad).ok, false);
  }
  assertEquals(parseApiBudgetTakeBody([]), { ok: false, error: "invalid_body" });
  assertEquals(parseApiBudgetReturnBody({ api: "seatgeek", day: "2026-11-04", calls: 3 }), {
    ok: true,
    args: { p_api: "seatgeek", p_day: "2026-11-04", p_calls: 3 },
  });
  assertEquals(parseApiBudgetReturnBody({ api: "seatgeek", day: "Nov 4", calls: 3 }), {
    ok: false,
    error: "day_invalid",
  });
  assertEquals(rpcError(JSON.stringify({ message: "calls_invalid" })), {
    error: "calls_invalid",
    status: 400,
  });
});
