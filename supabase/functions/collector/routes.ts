// Request parsing for the collector Edge Function (D-040, D-041 slice 4). Pure functions, no I/O,
// so they run under `deno test` without network or secrets.

export const MAX_BATCH_ROWS = 2000;
/** collector_ingest_events' largest item set (migration 37). */
export const MAX_EVENT_ITEMS = 2000;
export const MAX_BODY_BYTES = 6 * 1024 * 1024;

const RUN_ID = /^[A-Za-z0-9][A-Za-z0-9._:-]{0,99}$/;
const UUID = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
/** places_odbl_page's largest page (migration 35). */
export const EXPORT_PAGE = 5000;
const SOURCES = ["osm", "geoapify"] as const;
export type PlaceSource = (typeof SOURCES)[number];

export type Route =
  | { kind: "tiles"; statuses: string[]; limit: number }
  | { kind: "ingest" }
  | { kind: "events" }
  | { kind: "done"; tileId: number }
  | { kind: "export"; after: string | null; limit: number }
  | { kind: "dump" }
  | { kind: "files_queue"; limit: number; all: boolean; tiles: number[] | null }
  | { kind: "file_rows"; tileId: number; after: string | null; limit: number }
  | { kind: "files_record" }
  | { kind: "regions"; limit: number; all: boolean }
  | { kind: "regions_record" }
  | { kind: "sources"; regions: string[] }
  | { kind: "sources_record" }
  | { kind: "candidates"; limit: number; regions: string[] | null }
  | { kind: "candidates_add" }
  | { kind: "gate_status"; hash: string }
  | { kind: "gate_record" }
  | {
      kind: "probe_queue";
      hash: string;
      regions: string[] | null;
      perRegion: number;
      limit: number;
    }
  | { kind: "discovery_regions"; limit: number }
  | { kind: "discovery_regions_record" }
  | { kind: "api_keys" }
  | { kind: "api_budget_take" }
  | { kind: "api_budget_return" }
  // Collector completion (migrations 62 and 63).
  | { kind: "denylist" }
  | { kind: "claims_due"; limit: number }
  | { kind: "claims_record" }
  | { kind: "geocode_queue"; limit: number }
  | { kind: "geocode_record" }
  | { kind: "runs_record" }
  | { kind: "discovery_yield" }
  | { kind: "not_found" };

/** collector_sources_for_regions' and source_candidates_due's largest region list (migration 46). */
export const SOURCES_REGIONS_MAX = 100;
/** source_candidates_record's and source_candidates_add's largest list (migration 46). */
export const DISCOVERY_MAX = 500;

/** The discovery probe's code hash (migration 47): 16 to 64 lower-case hex. */
const PROBE_HASH = /^[0-9a-f]{16,64}$/;
/** source_discovery_probe_queue's largest list and per-region cap (migration 47). */
export const PROBE_QUEUE_MAX = 2000;
export const PROBE_PER_REGION_MAX = 500;

/** A comma-separated list of 1 to SOURCES_REGIONS_MAX uuids, lower-cased and deduplicated. */
function regionList(raw: string | null): string[] | null {
  if (raw === null || raw === "") return null;
  const ids = raw.split(",").map((s) => s.trim().toLowerCase());
  if (ids.length > SOURCES_REGIONS_MAX || ids.some((id) => !UUID.test(id))) return null;
  return [...new Set(ids)];
}

/** collector_regions_due's and collector_regions_record's largest list (migration 45). */
export const REGIONS_MAX = 100;

/** place_tile_file_page's largest page and place_files_queue's largest list (migration 42). */
export const FILE_PAGE = 5000;
export const FILES_QUEUE_MAX = 500;
const OSM_REF = /^[nwr][0-9]{1,15}$/;

/** Matches `/collector/...` (or the path without the function name, as on a local server). */
export function matchRoute(method: string, url: string): Route {
  const u = new URL(url);
  const path =
    u.pathname.replace(/^\/functions\/v1/, "").replace(/^\/collector(?=\/|$)/, "") || "/";
  if (method === "GET" && path === "/tiles") {
    const statuses = (u.searchParams.get("status") ?? "wanted,refresh")
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s === "wanted" || s === "refresh");
    const limitRaw = Number(u.searchParams.get("limit") ?? "20");
    const limit = Number.isInteger(limitRaw) ? Math.min(100, Math.max(1, limitRaw)) : 20;
    return { kind: "tiles", statuses: statuses.length ? statuses : ["wanted", "refresh"], limit };
  }
  if (method === "POST" && path === "/ingest/places") return { kind: "ingest" };
  if (method === "POST" && path === "/ingest/events") return { kind: "events" };
  if (method === "GET" && path === "/places/export") {
    const afterRaw = u.searchParams.get("after");
    if (afterRaw !== null && afterRaw !== "" && !UUID.test(afterRaw)) return { kind: "not_found" };
    const limitRaw = Number(u.searchParams.get("limit") ?? String(EXPORT_PAGE));
    const limit = Number.isInteger(limitRaw)
      ? Math.min(EXPORT_PAGE, Math.max(1, limitRaw))
      : EXPORT_PAGE;
    return { kind: "export", after: afterRaw ? afterRaw.toLowerCase() : null, limit };
  }
  if (method === "POST" && path === "/runs/dump") return { kind: "dump" };
  // Static place files (D-042 slices 3 and 4, migration 42).
  if (method === "GET" && path === "/files/queue") {
    const limitRaw = Number(u.searchParams.get("limit") ?? "50");
    const limit = Number.isInteger(limitRaw)
      ? Math.min(FILES_QUEUE_MAX, Math.max(1, limitRaw))
      : 50;
    const tilesRaw = u.searchParams.get("tiles");
    let tiles: number[] | null = null;
    if (tilesRaw !== null && tilesRaw !== "") {
      if (!/^[0-9]{1,6}(,[0-9]{1,6}){0,499}$/.test(tilesRaw)) return { kind: "not_found" };
      tiles = [...new Set(tilesRaw.split(",").map(Number))];
      if (tiles.some((t) => t > 259199)) return { kind: "not_found" };
    }
    return { kind: "files_queue", limit, all: u.searchParams.get("all") === "1", tiles };
  }
  if (method === "POST" && path === "/files/record") return { kind: "files_record" };
  // Collector regions for the nightly event run (D-042 slice 6, migration 45).
  if (method === "GET" && path === "/regions") {
    const limitRaw = Number(u.searchParams.get("limit") ?? "20");
    const limit = Number.isInteger(limitRaw) ? Math.min(REGIONS_MAX, Math.max(1, limitRaw)) : 20;
    return { kind: "regions", limit, all: u.searchParams.get("due") === "0" };
  }
  if (method === "POST" && path === "/regions/record") return { kind: "regions_record" };
  // Discovered sources (D-042 slice 7, migration 46).
  if (method === "GET" && path === "/sources") {
    const regions = regionList(u.searchParams.get("regions"));
    return regions ? { kind: "sources", regions } : { kind: "not_found" };
  }
  if (method === "POST" && path === "/sources/record") return { kind: "sources_record" };
  if (method === "GET" && path === "/candidates") {
    const limitRaw = Number(u.searchParams.get("limit") ?? "150");
    const limit = Number.isInteger(limitRaw) ? Math.min(DISCOVERY_MAX, Math.max(1, limitRaw)) : 150;
    const raw = u.searchParams.get("regions");
    const regions = regionList(raw);
    if (raw !== null && raw !== "" && !regions) return { kind: "not_found" };
    return { kind: "candidates", limit, regions };
  }
  if (method === "POST" && path === "/candidates") return { kind: "candidates_add" };
  // The discovery probe and its Atlanta gate (D-042 slice 8, migration 47).
  if (method === "GET" && path === "/discovery/gate") {
    const hash = (u.searchParams.get("hash") ?? "").toLowerCase();
    return PROBE_HASH.test(hash) ? { kind: "gate_status", hash } : { kind: "not_found" };
  }
  if (method === "POST" && path === "/discovery/gate") return { kind: "gate_record" };
  if (method === "GET" && path === "/discovery/queue") {
    const hash = (u.searchParams.get("hash") ?? "").toLowerCase();
    if (!PROBE_HASH.test(hash)) return { kind: "not_found" };
    const raw = u.searchParams.get("regions");
    const regions = regionList(raw);
    if (raw !== null && raw !== "" && !regions) return { kind: "not_found" };
    const per = Number(u.searchParams.get("per_region") ?? "150");
    const lim = Number(u.searchParams.get("limit") ?? "500");
    return {
      kind: "probe_queue",
      hash,
      regions,
      perRegion: Number.isInteger(per) ? Math.min(PROBE_PER_REGION_MAX, Math.max(1, per)) : 150,
      limit: Number.isInteger(lim) ? Math.min(PROBE_QUEUE_MAX, Math.max(1, lim)) : 500,
    };
  }
  if (method === "GET" && path === "/discovery/regions") {
    const lim = Number(u.searchParams.get("limit") ?? "10");
    return {
      kind: "discovery_regions",
      limit: Number.isInteger(lim) ? Math.min(REGIONS_MAX, Math.max(1, lim)) : 10,
    };
  }
  if (method === "POST" && path === "/discovery/regions/record")
    return { kind: "discovery_regions_record" };
  // The lane 1 APIs' daily call budget (D-042 slice 10, migration 48).
  if (method === "GET" && path === "/api-keys") return { kind: "api_keys" };
  if (method === "POST" && path === "/api-budget") return { kind: "api_budget_take" };
  if (method === "POST" && path === "/api-budget/return") return { kind: "api_budget_return" };
  // Collector completion (migrations 62 and 63).
  if (method === "GET" && path === "/denylist") return { kind: "denylist" };
  if (method === "GET" && path === "/claims/due") {
    const lim = Number(u.searchParams.get("limit") ?? "50");
    return {
      kind: "claims_due",
      limit: Number.isInteger(lim) ? Math.min(CLAIMS_MAX, Math.max(1, lim)) : 50,
    };
  }
  if (method === "POST" && path === "/claims/record") return { kind: "claims_record" };
  if (method === "GET" && path === "/geocode/queue") {
    const lim = Number(u.searchParams.get("limit") ?? "300");
    return {
      kind: "geocode_queue",
      limit: Number.isInteger(lim) ? Math.min(GEOCODE_MAX, Math.max(1, lim)) : 300,
    };
  }
  if (method === "POST" && path === "/geocode/record") return { kind: "geocode_record" };
  if (method === "POST" && path === "/runs/record") return { kind: "runs_record" };
  if (method === "GET" && path === "/discovery/yield") return { kind: "discovery_yield" };
  const rows = /^\/tiles\/([0-9]{1,6})\/rows$/.exec(path);
  if (method === "GET" && rows) {
    const tileId = Number(rows[1]);
    const afterRaw = u.searchParams.get("after");
    if (afterRaw !== null && afterRaw !== "" && !OSM_REF.test(afterRaw))
      return { kind: "not_found" };
    const limitRaw = Number(u.searchParams.get("limit") ?? String(FILE_PAGE));
    const limit = Number.isInteger(limitRaw)
      ? Math.min(FILE_PAGE, Math.max(1, limitRaw))
      : FILE_PAGE;
    if (tileId <= 259199) return { kind: "file_rows", tileId, after: afterRaw || null, limit };
  }
  const done = /^\/tiles\/([0-9]{1,6})\/done$/.exec(path);
  if (method === "POST" && done) {
    const tileId = Number(done[1]);
    if (tileId <= 259199) return { kind: "done", tileId };
  }
  return { kind: "not_found" };
}

export interface IngestArgs {
  p_tile_id: number;
  p_run_id: string;
  p_batch: unknown[];
  p_source: PlaceSource;
  p_batch_no: number | null;
}

export interface DoneArgs {
  p_tile_id: number;
  p_run_id: string;
  p_count: number;
  p_source: PlaceSource;
  /** Only sent when true, so finish_place_tile keeps its row_count_drop guard by default. */
  p_allow_drop?: true;
}

export type Parsed<T> = { ok: true; args: T } | { ok: false; error: string };

function source(value: unknown): PlaceSource | null {
  if (value === undefined || value === null) return "osm";
  return (SOURCES as readonly unknown[]).includes(value) ? (value as PlaceSource) : null;
}

/** Body of POST /collector/ingest/places: {tile_id, run_id, source?, batch_no?, rows: [...]}. */
export function parseIngestBody(body: unknown): Parsed<IngestArgs> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (!Number.isInteger(b.tile_id) || (b.tile_id as number) < 0 || (b.tile_id as number) > 259199) {
    return { ok: false, error: "invalid_tile_id" };
  }
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  const src = source(b.source);
  if (!src) return { ok: false, error: "invalid_source" };
  let batchNo: number | null = null;
  if (b.batch_no !== undefined && b.batch_no !== null) {
    if (
      !Number.isInteger(b.batch_no) ||
      (b.batch_no as number) < 0 ||
      (b.batch_no as number) > 100000
    ) {
      return { ok: false, error: "invalid_batch_no" };
    }
    batchNo = b.batch_no as number;
  }
  if (!Array.isArray(b.rows)) return { ok: false, error: "invalid_rows" };
  if (b.rows.length > MAX_BATCH_ROWS) return { ok: false, error: "batch_too_large" };
  return {
    ok: true,
    args: {
      p_tile_id: b.tile_id as number,
      p_run_id: b.run_id,
      p_batch: b.rows,
      p_source: src,
      p_batch_no: batchNo,
    },
  };
}

/** Body of POST /collector/tiles/{id}/done: {run_id, count, source?, allow_drop?}. */
export function parseDoneBody(tileId: number, body: unknown): Parsed<DoneArgs> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  if (!Number.isInteger(b.count) || (b.count as number) < 0)
    return { ok: false, error: "invalid_count" };
  const src = source(b.source);
  if (!src) return { ok: false, error: "invalid_source" };
  if (b.allow_drop !== undefined && b.allow_drop !== null && typeof b.allow_drop !== "boolean") {
    return { ok: false, error: "invalid_allow_drop" };
  }
  const args: DoneArgs = {
    p_tile_id: tileId,
    p_run_id: b.run_id,
    p_count: b.count as number,
    p_source: src,
  };
  if (b.allow_drop === true) args.p_allow_drop = true;
  return { ok: true, args };
}

export interface EventsArgs {
  p_source: Record<string, unknown>;
  p_items: unknown[];
  p_complete: boolean;
  p_enable: boolean;
  /** The job's run: a second post for the source in the same run counts no missed runs. */
  p_run_id: string;
  /** External ids the source still lists that the job did not send (ids only). */
  p_seen: string[];
}

/** collector_ingest_events' largest seen-id list (migration 38). */
export const MAX_SEEN_IDS = 2000;

const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * Body of POST /collector/ingest/events: {run_id, source: {slug, kind, url, name, attribution,
 * lane, enabled, hubs?, homepage_url?, images_licensed?, region?}, items: [...], seen?: [external
 * ids], complete, enable}. The shape is
 * checked here; collector_ingest_events validates every field again.
 */
export function parseEventsBody(body: unknown): Parsed<EventsArgs> & { runId?: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  const src = b.source;
  if (typeof src !== "object" || src === null || Array.isArray(src))
    return { ok: false, error: "invalid_source" };
  const slug = (src as Record<string, unknown>).slug;
  if (typeof slug !== "string" || slug.length < 3 || slug.length > 60 || !SLUG.test(slug))
    return { ok: false, error: "invalid_source" };
  if (!Array.isArray(b.items)) return { ok: false, error: "invalid_items" };
  if (b.items.length > MAX_EVENT_ITEMS) return { ok: false, error: "batch_too_large" };
  if (typeof b.complete !== "boolean") return { ok: false, error: "invalid_complete" };
  if (b.enable !== undefined && typeof b.enable !== "boolean")
    return { ok: false, error: "invalid_enable" };
  const seen = b.seen ?? [];
  if (
    !Array.isArray(seen) ||
    seen.length > MAX_SEEN_IDS ||
    seen.some((id) => typeof id !== "string" || id.length < 1 || id.length > 200)
  )
    return { ok: false, error: "invalid_seen" };
  return {
    ok: true,
    runId: b.run_id,
    args: {
      p_source: src as Record<string, unknown>,
      p_items: b.items,
      p_complete: b.complete,
      p_enable: b.enable === true,
      p_run_id: b.run_id,
      p_seen: seen as string[],
    },
  };
}

export interface DumpArgs {
  p_month: string;
  p_rows: number;
  p_bytes: number;
  p_sha256: string;
  p_published: boolean;
  p_counts: Record<string, number>;
}

/** Body of POST /collector/runs/dump: {month, rows, bytes, sha256, published, counts?}. */
export function parseDumpBody(body: unknown): Parsed<DumpArgs> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.month !== "string" || !/^[0-9]{4}-(0[1-9]|1[0-2])$/.test(b.month)) {
    return { ok: false, error: "invalid_month" };
  }
  for (const k of ["rows", "bytes"] as const) {
    if (!Number.isSafeInteger(b[k]) || (b[k] as number) < 0)
      return { ok: false, error: `invalid_${k}` };
  }
  if (typeof b.sha256 !== "string" || !/^[0-9a-f]{64}$/.test(b.sha256)) {
    return { ok: false, error: "invalid_sha256" };
  }
  if (typeof b.published !== "boolean") return { ok: false, error: "invalid_published" };
  const counts: Record<string, number> = {};
  if (b.counts !== undefined && b.counts !== null) {
    if (typeof b.counts !== "object" || Array.isArray(b.counts)) {
      return { ok: false, error: "invalid_counts" };
    }
    const entries = Object.entries(b.counts as Record<string, unknown>);
    if (entries.length > 8) return { ok: false, error: "invalid_counts" };
    for (const [k, v] of entries) {
      if (!/^[a-z]{1,20}$/.test(k) || !Number.isSafeInteger(v) || (v as number) < 0) {
        return { ok: false, error: "invalid_counts" };
      }
      counts[k] = v as number;
    }
  }
  return {
    ok: true,
    args: {
      p_month: b.month,
      p_rows: b.rows as number,
      p_bytes: b.bytes as number,
      p_sha256: b.sha256,
      p_published: b.published,
      p_counts: counts,
    },
  };
}

/**
 * Body of POST /collector/files/record: {published, rules?, tiles?}. Only the outline is checked
 * here; place_files_record validates every field again (paths, hashes, sizes, tile ids).
 */
export function parseFilesRecordBody(body: unknown): Parsed<{ p: Record<string, unknown> }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.published !== "boolean") return { ok: false, error: "invalid_published" };
  if (b.tiles !== undefined && (!Array.isArray(b.tiles) || b.tiles.length > 2000)) {
    return { ok: false, error: "invalid_tiles" };
  }
  if (
    b.rules !== undefined &&
    b.rules !== null &&
    (typeof b.rules !== "object" || Array.isArray(b.rules))
  ) {
    return { ok: false, error: "invalid_rules" };
  }
  const p: Record<string, unknown> = { published: b.published };
  if (b.rules !== undefined) p.rules = b.rules;
  if (b.tiles !== undefined) p.tiles = b.tiles;
  return { ok: true, args: { p } };
}

export interface RegionsRecordArgs {
  p_regions: { id: string; sources: number; items: number; timezone?: string }[];
}

const ZONE = /^[A-Za-z0-9_+/-]{1,64}$/;

/**
 * Body of POST /collector/regions/record: {run_id, regions: [{id, sources, items, timezone?}]}.
 * collector_regions_record checks every field again (and the zone against pg_timezone_names).
 */
export function parseRegionsRecordBody(
  body: unknown,
): Parsed<RegionsRecordArgs> & { runId?: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  if (!Array.isArray(b.regions) || b.regions.length > REGIONS_MAX)
    return { ok: false, error: "invalid_regions" };
  const out: RegionsRecordArgs["p_regions"] = [];
  for (const r of b.regions) {
    if (typeof r !== "object" || r === null || Array.isArray(r))
      return { ok: false, error: "invalid_regions" };
    const o = r as Record<string, unknown>;
    if (typeof o.id !== "string" || !UUID.test(o.id))
      return { ok: false, error: "invalid_regions" };
    for (const k of ["sources", "items"] as const) {
      if (!Number.isInteger(o[k]) || (o[k] as number) < 0 || (o[k] as number) > 999_999)
        return { ok: false, error: "invalid_regions" };
    }
    const entry: RegionsRecordArgs["p_regions"][number] = {
      id: o.id.toLowerCase(),
      sources: o.sources as number,
      items: o.items as number,
    };
    if (o.timezone !== undefined && o.timezone !== null) {
      if (typeof o.timezone !== "string" || !ZONE.test(o.timezone))
        return { ok: false, error: "invalid_regions" };
      entry.timezone = o.timezone;
    }
    out.push(entry);
  }
  return { ok: true, runId: b.run_id, args: { p_regions: out } };
}

const OUTCOMES = new Set([
  "ok",
  "empty",
  "no_feed",
  "error",
  "blocked",
  "robots",
  "noindex",
  "needs_permission",
  "denylisted",
]);

/**
 * Body of POST /collector/sources/record: {run_id, results: [{candidate_id, outcome, kind?, url?,
 * platform?, items?, in_region?, requests?, errors?, complete?}]}. The run id is copied onto each
 * result; source_candidates_record checks every field again and applies the lifecycle.
 */
export function parseSourcesRecordBody(
  body: unknown,
): Parsed<{ p_results: Record<string, unknown>[] }> & { runId?: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  if (!Array.isArray(b.results) || b.results.length > DISCOVERY_MAX)
    return { ok: false, error: "invalid_results" };
  const out: Record<string, unknown>[] = [];
  for (const r of b.results) {
    if (typeof r !== "object" || r === null || Array.isArray(r))
      return { ok: false, error: "invalid_results" };
    const o = r as Record<string, unknown>;
    if (typeof o.candidate_id !== "string" || !UUID.test(o.candidate_id))
      return { ok: false, error: "invalid_results" };
    if (typeof o.outcome !== "string" || !OUTCOMES.has(o.outcome))
      return { ok: false, error: "invalid_results" };
    const e: Record<string, unknown> = {
      candidate_id: o.candidate_id.toLowerCase(),
      run_id: b.run_id,
      outcome: o.outcome,
    };
    if (o.kind !== undefined && o.kind !== null) {
      if (o.kind !== "ics" && o.kind !== "rss" && o.kind !== "page")
        return { ok: false, error: "invalid_results" };
      e.kind = o.kind;
    }
    if (o.url !== undefined && o.url !== null) {
      if (typeof o.url !== "string" || !o.url.startsWith("https://") || o.url.length > 500)
        return { ok: false, error: "invalid_results" };
      e.url = o.url;
    }
    if (o.platform !== undefined && o.platform !== null) {
      if (typeof o.platform !== "string" || !/^[a-z0-9_]{1,40}$/.test(o.platform))
        return { ok: false, error: "invalid_results" };
      e.platform = o.platform;
    }
    for (const k of ["items", "in_region", "requests", "errors"] as const) {
      if (o[k] === undefined || o[k] === null) continue;
      if (!Number.isInteger(o[k]) || (o[k] as number) < 0 || (o[k] as number) > 9_999_999)
        return { ok: false, error: "invalid_results" };
      e[k] = o[k];
    }
    if (o.complete !== undefined && o.complete !== null) {
      if (typeof o.complete !== "boolean") return { ok: false, error: "invalid_results" };
      e.complete = o.complete;
    }
    out.push(e);
  }
  return { ok: true, runId: b.run_id, args: { p_results: out } };
}

/**
 * Body of POST /collector/candidates: {candidates: [{url, origin osm|wikidata, region_id?, name?,
 * place_kind?, wikidata_id?, country?, score?}]}. source_candidates_add applies the D-040 URL
 * rules and the denylist and counts what it refused.
 */
export function parseCandidatesBody(
  body: unknown,
): Parsed<{ p_candidates: Record<string, unknown>[] }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const list = (body as Record<string, unknown>).candidates;
  if (!Array.isArray(list) || list.length > DISCOVERY_MAX)
    return { ok: false, error: "invalid_candidates" };
  for (const c of list) {
    if (typeof c !== "object" || c === null || Array.isArray(c))
      return { ok: false, error: "invalid_candidates" };
    const o = c as Record<string, unknown>;
    if (typeof o.url !== "string" || o.url.length > 500)
      return { ok: false, error: "invalid_candidates" };
    if (o.origin !== "osm" && o.origin !== "wikidata")
      return { ok: false, error: "invalid_candidates" };
  }
  return { ok: true, args: { p_candidates: list as Record<string, unknown>[] } };
}

/**
 * Body of POST /collector/discovery/gate: {run_id, probe_hash, region, expected, required, found,
 * found_sites?, counts?}. source_discovery_gate_record checks it again and decides "passed" itself.
 */
export function parseGateBody(body: unknown): Parsed<{ p_gate: Record<string, unknown> }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const b = body as Record<string, unknown>;
  if (typeof b.run_id !== "string" || !RUN_ID.test(b.run_id))
    return { ok: false, error: "invalid_run_id" };
  if (typeof b.probe_hash !== "string" || !PROBE_HASH.test(b.probe_hash))
    return { ok: false, error: "invalid_gate" };
  if (typeof b.region !== "string" || !/^[a-z0-9-]{2,40}$/.test(b.region))
    return { ok: false, error: "invalid_gate" };
  for (const k of ["expected", "required", "found"] as const) {
    if (!Number.isInteger(b[k]) || (b[k] as number) < 0 || (b[k] as number) > 100)
      return { ok: false, error: "invalid_gate" };
  }
  const sites = b.found_sites ?? [];
  if (
    !Array.isArray(sites) ||
    sites.length > 100 ||
    sites.some((h) => typeof h !== "string" || h.length > 253)
  )
    return { ok: false, error: "invalid_gate" };
  const counts = b.counts ?? {};
  if (typeof counts !== "object" || counts === null || Array.isArray(counts))
    return { ok: false, error: "invalid_gate" };
  for (const [k, v] of Object.entries(counts as Record<string, unknown>)) {
    if (!/^[a-z0-9_]{1,40}$/.test(k) || !Number.isInteger(v) || (v as number) < 0)
      return { ok: false, error: "invalid_gate" };
  }
  return {
    ok: true,
    args: {
      p_gate: {
        run_id: b.run_id,
        probe_hash: b.probe_hash,
        region: b.region,
        expected: b.expected,
        required: b.required,
        found: b.found,
        found_sites: sites,
        counts,
      },
    },
  };
}

/** Body of POST /collector/discovery/regions/record: {regions: ["<uuid>", ...]} (at most 100). */
export function parseDiscoveryRegionsBody(body: unknown): Parsed<{ p_ids: string[] }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const list = (body as Record<string, unknown>).regions;
  if (
    !Array.isArray(list) ||
    list.length > REGIONS_MAX ||
    list.some((id) => typeof id !== "string" || !UUID.test(id))
  )
    return { ok: false, error: "invalid_regions" };
  return { ok: true, args: { p_ids: (list as string[]).map((id) => id.toLowerCase()) } };
}

/**
 * The APIs with a daily call budget (collector_api_budget_cap, migration 48; geoapify_geocode,
 * venue geocoding with GEOAPIFY_SERVER_KEY, migration 63).
 */
export const BUDGET_APIS = ["ticketmaster", "seatgeek", "geoapify_geocode"] as const;
/** collector_api_budget_take's and _return's largest request. */
export const API_CALLS_MAX = 1000;

function apiCalls(o: Record<string, unknown>): { api: string; calls: number } | null {
  if (typeof o.api !== "string" || !(BUDGET_APIS as readonly string[]).includes(o.api)) return null;
  if (typeof o.calls !== "number" || !Number.isInteger(o.calls)) return null;
  if (o.calls < 1 || o.calls > API_CALLS_MAX) return null;
  return { api: o.api, calls: o.calls };
}

/** Body of POST /collector/api-budget: {api: "ticketmaster" | "seatgeek", calls: 1..1000}. */
export function parseApiBudgetTakeBody(body: unknown): Parsed<{ p_api: string; p_calls: number }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const c = apiCalls(body as Record<string, unknown>);
  return c
    ? { ok: true, args: { p_api: c.api, p_calls: c.calls } }
    : { ok: false, error: "calls_invalid" };
}

/** Body of POST /collector/api-budget/return: {api, day: "YYYY-MM-DD", calls: 1..1000}. */
export function parseApiBudgetReturnBody(
  body: unknown,
): Parsed<{ p_api: string; p_day: string; p_calls: number }> {
  if (typeof body !== "object" || body === null || Array.isArray(body)) {
    return { ok: false, error: "invalid_body" };
  }
  const o = body as Record<string, unknown>;
  const c = apiCalls(o);
  if (!c) return { ok: false, error: "calls_invalid" };
  if (typeof o.day !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(o.day))
    return { ok: false, error: "day_invalid" };
  return { ok: true, args: { p_api: c.api, p_day: o.day, p_calls: c.calls } };
}

/** collector_claims_due's and collector_claims_record's largest list (migration 62). */
export const CLAIMS_MAX = 200;
/** collector_geocode_queue's and collector_geocode_record's largest list (migration 63). */
export const GEOCODE_MAX = 500;
const CLAIM_OUTCOMES = ["verified", "token_not_found", "dns_no_txt", "fetch_failed"];
const CLAIM_METHODS = ["meta", "well_known", "dns_txt", "feed"];
const GEO_PROVIDERS = ["place", "venue", "geoapify", "nominatim", "photon", "none"];
const RUN_JOBS = ["ingest", "discovery", "verify", "places_extract", "places_files"];

/** Body of POST /collector/claims/record: {results: [{claim_id, outcome, method?, reason?}]} (<= 200). */
export function parseClaimsRecordBody(
  body: unknown,
): Parsed<{ p_results: Record<string, unknown>[] }> {
  if (typeof body !== "object" || body === null || Array.isArray(body))
    return { ok: false, error: "invalid_body" };
  const list = (body as Record<string, unknown>).results;
  if (!Array.isArray(list) || list.length === 0 || list.length > CLAIMS_MAX)
    return { ok: false, error: "results_invalid" };
  const out: Record<string, unknown>[] = [];
  for (const e of list) {
    if (typeof e !== "object" || e === null || Array.isArray(e))
      return { ok: false, error: "results_invalid" };
    const o = e as Record<string, unknown>;
    if (typeof o.claim_id !== "string" || !UUID.test(o.claim_id))
      return { ok: false, error: "results_invalid" };
    if (typeof o.outcome !== "string" || !CLAIM_OUTCOMES.includes(o.outcome))
      return { ok: false, error: "results_invalid" };
    if (
      o.method !== undefined &&
      (typeof o.method !== "string" || !CLAIM_METHODS.includes(o.method))
    )
      return { ok: false, error: "results_invalid" };
    if (
      o.reason !== undefined &&
      (typeof o.reason !== "string" || !/^[a-z_]{1,40}$/.test(o.reason))
    )
      return { ok: false, error: "results_invalid" };
    out.push({
      claim_id: o.claim_id.toLowerCase(),
      outcome: o.outcome,
      ...(o.method !== undefined ? { method: o.method } : {}),
      ...(o.reason !== undefined ? { reason: o.reason } : {}),
    });
  }
  return { ok: true, args: { p_results: out } };
}

/** Body of POST /collector/geocode/record: {results: [{key, status, lat?, lng?, provider, place_ref?, confidence?}]}. */
export function parseGeocodeRecordBody(
  body: unknown,
): Parsed<{ p_results: Record<string, unknown>[] }> {
  if (typeof body !== "object" || body === null || Array.isArray(body))
    return { ok: false, error: "invalid_body" };
  const list = (body as Record<string, unknown>).results;
  if (!Array.isArray(list) || list.length === 0 || list.length > GEOCODE_MAX)
    return { ok: false, error: "results_invalid" };
  const out: Record<string, unknown>[] = [];
  for (const e of list) {
    if (typeof e !== "object" || e === null || Array.isArray(e))
      return { ok: false, error: "results_invalid" };
    const o = e as Record<string, unknown>;
    if (typeof o.key !== "string" || !/^[0-9a-f]{64}$/.test(o.key))
      return { ok: false, error: "results_invalid" };
    if (o.status !== "ok" && o.status !== "miss") return { ok: false, error: "results_invalid" };
    if (typeof o.provider !== "string" || !GEO_PROVIDERS.includes(o.provider))
      return { ok: false, error: "results_invalid" };
    const r: Record<string, unknown> = { key: o.key, status: o.status, provider: o.provider };
    if (o.status === "ok") {
      if (
        typeof o.lat !== "number" ||
        typeof o.lng !== "number" ||
        Math.abs(o.lat) > 90 ||
        Math.abs(o.lng) > 180
      )
        return { ok: false, error: "results_invalid" };
      r.lat = o.lat;
      r.lng = o.lng;
    }
    if (typeof o.place_ref === "string" && /^[A-Za-z0-9:._-]{1,80}$/.test(o.place_ref))
      r.place_ref = o.place_ref;
    if (typeof o.confidence === "number" && o.confidence >= 0 && o.confidence <= 1)
      r.confidence = o.confidence;
    out.push(r);
  }
  return { ok: true, args: { p_results: out } };
}

/** Body of POST /collector/runs/record: {job, run_id, outcome, started_at?, stats?} (counts only). */
export function parseRunsRecordBody(body: unknown): Parsed<{ p_run: Record<string, unknown> }> {
  if (typeof body !== "object" || body === null || Array.isArray(body))
    return { ok: false, error: "invalid_body" };
  const o = body as Record<string, unknown>;
  if (typeof o.job !== "string" || !RUN_JOBS.includes(o.job))
    return { ok: false, error: "run_invalid" };
  if (typeof o.run_id !== "string" || !RUN_ID.test(o.run_id))
    return { ok: false, error: "invalid_run_id" };
  if (o.outcome !== "ok" && o.outcome !== "partial" && o.outcome !== "failed")
    return { ok: false, error: "run_invalid" };
  const stats = o.stats ?? {};
  if (typeof stats !== "object" || stats === null || Array.isArray(stats))
    return { ok: false, error: "run_invalid" };
  const entries = Object.entries(stats as Record<string, unknown>);
  if (entries.length > 80) return { ok: false, error: "run_invalid" };
  for (const [k, v] of entries) {
    if (!/^[a-z0-9_]{1,40}$/.test(k)) return { ok: false, error: "run_invalid" };
    const okValue =
      (typeof v === "number" && Number.isFinite(v)) ||
      typeof v === "boolean" ||
      (typeof v === "string" && /^[a-z0-9_]{0,40}$/.test(v));
    if (!okValue) return { ok: false, error: "run_invalid" };
  }
  const run: Record<string, unknown> = { job: o.job, run_id: o.run_id, outcome: o.outcome, stats };
  if (typeof o.started_at === "string" && /^\d{4}-\d{2}-\d{2}T[0-9:.]+Z?$/.test(o.started_at))
    run.started_at = o.started_at;
  return { ok: true, args: { p_run: run } };
}

/** The database error names the RPCs raise, mapped to HTTP statuses for the job. */
const RPC_ERRORS: Record<string, number> = {
  tile_unknown: 404,
  run_unknown: 404,
  tile_retired: 409,
  run_finished: 409,
  count_mismatch: 409,
  empty_run: 409,
  row_count_drop: 409,
  batch_too_large: 413,
  source_invalid: 400,
  source_not_collector: 409,
  items_invalid: 400,
  run_id_invalid: 400,
  batch_invalid: 400,
  batch_no_invalid: 400,
  count_invalid: 400,
  month_invalid: 400,
  sha256_invalid: 400,
  counts_invalid: 400,
  tiles_invalid: 400,
  rules_invalid: 400,
  record_invalid: 400,
  cursor_invalid: 400,
  regions_invalid: 400,
  results_invalid: 400,
  candidates_invalid: 400,
  gate_invalid: 400,
  discovery_gate_closed: 409,
  api_invalid: 400,
  calls_invalid: 400,
  day_invalid: 400,
  run_invalid: 400,
};

/** Picks a known error name out of a PostgREST error body; anything else is a 502. */
export function rpcError(body: string): { error: string; status: number } {
  let message = "";
  try {
    const parsed = JSON.parse(body);
    message = typeof parsed?.message === "string" ? parsed.message : "";
  } catch {
    message = "";
  }
  const status = RPC_ERRORS[message];
  return status ? { error: message, status } : { error: "rpc_failed", status: 502 };
}
