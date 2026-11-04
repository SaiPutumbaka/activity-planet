// place-files: place matching and row lookups from the static place files (D-042 slice 11,
// docs/design/auto-coverage/AUTO_COVERAGE_DESIGN.md 4.5 "Moves off Postgres"; migration 49).
//
// The files are the gzipped per-tile JSON that places-files.yml publishes to GitHub Pages
// (format v1: {v, tile, rules_version, rows: [[osm_ref, lng, lat, kind, name, rule_ids, address,
// locality, hours, website, tags]]}). Every file is checked before use: the bytes must hash to
// the tile's recorded sha256 (the gzip), or, when a host already decoded the gzip, the JSON must
// hash to the 16 hex digits in the file name. A file that fails is never used.
//
//   runMatch: the venues place_match_queue lists (public venues on their own meeting spot or with
//     no place) are matched against the file rows with the database's rule (meeting_spot_refresh,
//     migration 36): the nearest row within 60 m whose name is the same or close (pg_trgm
//     similarity of the lower-cased names at least 0.45), the same name first. Each result goes to
//     place_match_record, which makes the row (place_from_file) and lets the database link it.
//   placeFromFile: the database row of one file place (place_from_file), for a member acting on a
//     place that only its file holds (report, correction, "Start a plan here").
//
// Nothing here logs a venue name, a point or a user id; results are counts.

export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;
export type Fetcher = (url: string) => Promise<Response>;

export interface FileRef {
  tile: number;
  path: string;
  sha256: string;
}

export interface FileRow {
  osm_ref: string;
  lng: number;
  lat: number;
  kind: string;
  name: string;
  rule_ids: number[];
  address_text: string;
  locality: string;
  opening_hours: string | null;
  website: string | null;
  tags: Record<string, string>;
}

/* ------------------------------------------------------------------ */
/* pg_trgm and distance                                                 */
/* ------------------------------------------------------------------ */

/**
 * pg_trgm's trigram set (show_trgm): words are runs of letters and digits, each padded with two
 * spaces in front and one behind, and every three-character window is a trigram.
 */
export function trigrams(text: string): Set<string> {
  const out = new Set<string>();
  for (const word of text.toLowerCase().match(/[\p{L}\p{N}]+/gu) ?? []) {
    const chars = Array.from(`  ${word} `);
    for (let i = 0; i + 3 <= chars.length; i++) out.add(chars.slice(i, i + 3).join(""));
  }
  return out;
}

/** pg_trgm similarity(a, b): shared trigrams over all distinct trigrams. */
export function similarity(a: string, b: string): number {
  const ta = trigrams(a);
  const tb = trigrams(b);
  if (!ta.size || !tb.size) return 0;
  let common = 0;
  for (const t of ta) if (tb.has(t)) common++;
  return common / (ta.size + tb.size - common);
}

/** Metres between two points (haversine on the mean Earth radius). */
export function distanceM(
  a: { lng: number; lat: number },
  b: { lng: number; lat: number },
): number {
  const r = 6371008.8;
  const rad = Math.PI / 180;
  const dLat = (b.lat - a.lat) * rad;
  const dLng = (b.lng - a.lng) * rad;
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(a.lat * rad) * Math.cos(b.lat * rad) * Math.sin(dLng / 2) ** 2;
  return 2 * r * Math.asin(Math.min(1, Math.sqrt(h)));
}

export const MATCH_RADIUS_M = 60;
export const MATCH_SIMILARITY = 0.45;

/** The database's venue rule: within 60 m, same or close name; same name, then nearest, first. */
export function bestMatch(
  rows: readonly FileRow[],
  venue: { lng: number; lat: number; name: string },
): FileRow | null {
  const name = venue.name.toLowerCase();
  let best: { row: FileRow; same: boolean; d: number } | null = null;
  for (const row of rows) {
    const d = distanceM(venue, row);
    if (d > MATCH_RADIUS_M) continue;
    const same = row.name.toLowerCase() === name;
    if (!same && similarity(row.name, venue.name) < MATCH_SIMILARITY) continue;
    if (
      !best ||
      (same && !best.same) ||
      (same === best.same && (d < best.d || (d === best.d && row.osm_ref < best.row.osm_ref)))
    ) {
      best = { row, same, d };
    }
  }
  return best?.row ?? null;
}

/* ------------------------------------------------------------------ */
/* Files                                                                */
/* ------------------------------------------------------------------ */

const OSM_REF = /^[nwr][0-9]{1,15}$/;
const TILE_PATH = /^places\/v[0-9]{1,4}\/([0-9]{1,6})\.([0-9a-f]{16})\.json\.gz$/;

async function sha256Hex(bytes: Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function gunzip(bytes: Uint8Array): Promise<Uint8Array> {
  const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
  return new Uint8Array(await new Response(stream).arrayBuffer());
}

const str = (v: unknown): string | null => (typeof v === "string" && v ? v : null);

/** A v1 tile file's rows, as place_from_file takes them; malformed rows are dropped. */
export function decodeRows(json: unknown, tile: number): FileRow[] {
  const d = json as Record<string, unknown> | null;
  if (!d || d.v !== 1 || d.tile !== tile || !Array.isArray(d.rows)) {
    throw new Error("file_format");
  }
  const rows: FileRow[] = [];
  for (const r of d.rows) {
    if (!Array.isArray(r) || r.length < 6) continue;
    const [ref, lng, lat, kind, name, rules, address, locality, hours, website, tags] =
      r as unknown[];
    if (typeof ref !== "string" || !OSM_REF.test(ref)) continue;
    if (typeof lng !== "number" || typeof lat !== "number") continue;
    if (typeof name !== "string" || !name || typeof kind !== "string" || !kind) continue;
    const ruleIds = Array.isArray(rules)
      ? rules.filter((x): x is number => Number.isInteger(x))
      : [];
    if (!ruleIds.length) continue;
    rows.push({
      osm_ref: ref,
      lng,
      lat,
      kind,
      name,
      rule_ids: ruleIds,
      address_text: str(address) ?? "",
      locality: str(locality) ?? "",
      opening_hours: str(hours),
      website: str(website),
      tags:
        tags && typeof tags === "object" && !Array.isArray(tags)
          ? Object.fromEntries(
              Object.entries(tags as Record<string, unknown>).filter(
                (e): e is [string, string] => typeof e[1] === "string",
              ),
            )
          : {},
    });
  }
  return rows;
}

/**
 * Fetches a published tile file and checks it: the gzip must hash to `sha256`, or JSON a host
 * already decoded must hash to the name's 16 hex digits. Throws file_unverified otherwise.
 */
export async function loadTile(fetchFn: Fetcher, base: string, ref: FileRef): Promise<FileRow[]> {
  const m = TILE_PATH.exec(ref.path);
  if (!m || Number(m[1]) !== ref.tile || !/^[0-9a-f]{64}$/.test(ref.sha256)) {
    throw new Error("file_ref_invalid");
  }
  const res = await fetchFn(new URL(ref.path, base).toString());
  if (!res.ok) {
    await res.body?.cancel();
    throw new Error(`file_http_${res.status}`);
  }
  const bytes = new Uint8Array(await res.arrayBuffer());
  let plain: Uint8Array;
  if (bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
    if ((await sha256Hex(bytes)) !== ref.sha256) throw new Error("file_unverified");
    plain = await gunzip(bytes);
  } else {
    if ((await sha256Hex(bytes)).slice(0, 16) !== m[2]) throw new Error("file_unverified");
    plain = bytes;
  }
  return decodeRows(JSON.parse(new TextDecoder().decode(plain)), ref.tile);
}

export function normalBase(raw: unknown): string | null {
  if (typeof raw !== "string" || !raw.trim()) return null;
  try {
    const u = new URL(raw.trim());
    if (u.protocol !== "https:") return null;
    return u.toString().endsWith("/") ? u.toString() : `${u.toString()}/`;
  } catch {
    return null;
  }
}

/* ------------------------------------------------------------------ */
/* Venue matching                                                       */
/* ------------------------------------------------------------------ */

interface QueuedVenue {
  venue_id: string;
  name: string;
  lng: number;
  lat: number;
  key: string;
  files: FileRef[];
}

export interface MatchResult {
  skipped?: "no_base_url";
  venues: number;
  matched: number;
  files: number;
  file_errors: number;
  recorded: Record<string, number> | null;
}

export async function runMatch(deps: {
  rpc: Rpc;
  fetch: Fetcher;
  base?: string | null;
  limit?: number;
}): Promise<MatchResult> {
  const queue = (await deps.rpc("place_match_queue", { p_limit: deps.limit ?? 50 })) as {
    base?: string | null;
    venues?: QueuedVenue[];
  } | null;
  const venues = Array.isArray(queue?.venues) ? queue.venues : [];
  const base = normalBase(deps.base) ?? normalBase(queue?.base);
  if (!base) {
    return {
      skipped: "no_base_url",
      venues: venues.length,
      matched: 0,
      files: 0,
      file_errors: 0,
      recorded: null,
    };
  }
  const tiles = new Map<string, Promise<FileRow[]>>();
  const load = (ref: FileRef) => {
    const key = `${ref.path}#${ref.sha256}`;
    let p = tiles.get(key);
    if (!p) {
      p = loadTile(deps.fetch, base, ref);
      tiles.set(key, p);
    }
    return p;
  };
  const results: unknown[] = [];
  let matched = 0;
  const failed = new Set<string>();
  for (const v of venues) {
    const files = Array.isArray(v.files) ? v.files : [];
    let best: { row: FileRow; ref: FileRef } | null = null;
    let ok = files.length > 0;
    for (const ref of files) {
      let rows: FileRow[];
      try {
        rows = await load(ref);
      } catch {
        failed.add(ref.path);
        ok = false;
        break;
      }
      const row = bestMatch(rows, v);
      if (row && (!best || better(row, best.row, v))) best = { row, ref };
    }
    // A venue whose files could not all be read is left for the next run (not recorded).
    if (!ok) continue;
    if (best) matched++;
    results.push({
      venue_id: v.venue_id,
      key: v.key,
      match: best ? { tile: best.ref.tile, sha256: best.ref.sha256, row: best.row } : null,
    });
  }
  const recorded = results.length
    ? ((await deps.rpc("place_match_record", { p_results: results })) as Record<string, number>)
    : null;
  return {
    venues: venues.length,
    matched,
    files: tiles.size,
    file_errors: failed.size,
    recorded,
  };
}

function better(a: FileRow, b: FileRow, v: { lng: number; lat: number; name: string }): boolean {
  return bestMatch([b, a], v) === a;
}

/* ------------------------------------------------------------------ */
/* One file place's row                                                 */
/* ------------------------------------------------------------------ */

export interface PlaceResult {
  id: string | null;
  reason?: "no_base_url" | "no_file" | "not_in_file" | "moderated" | "file_unverified" | "refused";
}

export async function placeFromFile(
  deps: { rpc: Rpc; fetch: Fetcher; base?: string | null },
  osmRef: string,
  tile: number,
): Promise<PlaceResult> {
  const file = (await deps.rpc("place_file_of_tile", { p_tile: tile })) as
    (FileRef & { base?: string | null }) | null;
  if (!file) return { id: null, reason: "no_file" };
  const base = normalBase(deps.base) ?? normalBase(file.base);
  if (!base) return { id: null, reason: "no_base_url" };
  let rows: FileRow[];
  try {
    rows = await loadTile(deps.fetch, base, { tile, path: file.path, sha256: file.sha256 });
  } catch {
    return { id: null, reason: "file_unverified" };
  }
  const row = rows.find((r) => r.osm_ref === osmRef);
  if (!row) return { id: null, reason: "not_in_file" };
  let id: unknown;
  try {
    id = await deps.rpc("place_from_file", { p_tile: tile, p_sha256: file.sha256, p_row: row });
  } catch {
    // file_not_current (replaced meanwhile) or a row the database refuses.
    return { id: null, reason: "refused" };
  }
  return typeof id === "string" ? { id } : { id: null, reason: "moderated" };
}

export function parsePlaceRequest(body: unknown): { osmRef: string; tile: number } | null {
  if (!body || typeof body !== "object") return null;
  const o = body as Record<string, unknown>;
  if (typeof o.osm_ref !== "string" || !OSM_REF.test(o.osm_ref)) return null;
  if (!Number.isInteger(o.tile) || (o.tile as number) < 0 || (o.tile as number) > 259199)
    return null;
  return { osmRef: o.osm_ref, tile: o.tile as number };
}
