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
  | { kind: "not_found" };

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
}

const SLUG = /^[a-z0-9]+(-[a-z0-9]+)*$/;

/**
 * Body of POST /collector/ingest/events: {run_id, source: {slug, kind, url, name, attribution,
 * lane, enabled, hubs?, homepage_url?, region?}, items: [...], complete, enable}. The shape is
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
  return {
    ok: true,
    runId: b.run_id,
    args: {
      p_source: src as Record<string, unknown>,
      p_items: b.items,
      p_complete: b.complete,
      p_enable: b.enable === true,
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
