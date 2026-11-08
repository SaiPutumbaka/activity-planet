// Geoapify quick fill for new place tiles (D-042 slice 9, docs/design/auto-coverage/
// AUTO_COVERAGE_DESIGN.md 5.2 and 7, docs/design/hub-map/HUB_MAP_DESIGN.md 3.2).
//
// Pure functions plus runFill(), which takes its I/O (database RPCs, fetch, clock) as arguments,
// so everything here runs under `deno test` without network, keys or a database.
//
// One run:
//   1. places_fill_plan claims up to 2 tiles (wanted or filling, demand >= 1, no OSM or Geoapify
//      run yet) and returns today's budget, the Geoapify categories of active specific hubs, and
//      the place rules (the same OSM tag rules the nightly extract uses).
//   2. For each tile: GET /v2/places?categories=...&filter=rect:<tile>&limit=100, at most
//      MAX_REQUESTS_PER_TILE requests, round-robin over category groups so sports, outdoor,
//      learning, shop and food categories each get a page before any gets a second. Every request
//      first takes its credits from the daily budget (places_fill_spend, 500 a day); a refusal
//      stops the run.
//   3. Each feature's OSM tags (datasource.raw) are matched against the place rules exactly like
//      scripts/places/extract_places.py (Rules.match and Rules.best), so a Geoapify row gets the
//      same kind and rule ids the OSM row will have. Unnamed, private and home-building features
//      and features outside the tile are dropped. osm_ref comes from raw.osm_type + raw.osm_id,
//      so the nightly OSM build merges the row (ingest_places, migration 28).
//   4. ingest_places(source 'geoapify') then finish_place_tile(source 'geoapify'): the tile goes
//      from wanted to filling, and the map's "Powered by Geoapify" credit shows (place flag 32).
//
// Storage (design 4 and 5.2): rows stay in Postgres only until the tile has an OSM run; then the
// database deletes the ones no OSM row merged (places_fill_supersede, migration 43). The API key
// never leaves this function: it is not logged, and errors carry only HTTP status codes.

export const PAGE_LIMIT = 100;
/** Geoapify Places bills 1 credit per 20 places requested (pricing page, re-check when the key exists). */
export const CREDITS_PER_PAGE = Math.ceil(PAGE_LIMIT / 20);
export const MAX_REQUESTS_PER_TILE = 8;
export const TILES_PER_RUN = 2;
export const MAX_ROWS = 2000;
/** Geoapify free plan: 5 requests a second; one every 250 ms stays under it. */
export const REQUEST_GAP_MS = 250;
export const GEOAPIFY_PLACES_URL = "https://api.geoapify.com/v2/places";

/** Too broad to be worth a request: the specific categories under them are asked for instead. */
export const BROAD_CATEGORIES = new Set([
  "building",
  "catering",
  "commercial",
  "entertainment",
  "heritage",
  "natural",
  "sport",
]);

const GROUP_OF: Record<string, string> = {
  sport: "sport",
  activity: "activity",
  entertainment: "activity",
  ski: "outdoors",
  beach: "outdoors",
  camping: "outdoors",
  leisure: "outdoors",
  natural: "outdoors",
  pet: "outdoors",
  rental: "outdoors",
  tourism: "outdoors",
  heritage: "outdoors",
  education: "learning",
  religion: "learning",
  commercial: "shops",
  service: "shops",
  catering: "food",
  adult: "food",
};
export const GROUP_ORDER = ["sport", "activity", "outdoors", "learning", "shops", "food"];

const TAG_ALLOWLIST = [
  "sport",
  "religion",
  "denomination",
  "lgbtq",
  "access",
  "fee",
  "lit",
  "indoor",
  "surface",
  "hoops",
  "wheelchair",
  "wikidata",
  "phone",
  "brand",
];
const BUSINESS_KEYS = ["amenity", "shop", "craft", "office", "tourism", "leisure", "club"];
const HOME_BUILDINGS = new Set([
  "house",
  "residential",
  "apartments",
  "detached",
  "semidetached_house",
  "terrace",
  "bungalow",
  "dormitory",
]);
const PRIVATE_ACCESS = new Set(["private", "no"]);
const CATEGORY = /^[a-z_]+(\.[a-z_]+){0,4}$/;

export interface Rule {
  id: number;
  key: string;
  value: string | null;
  extra: Record<string, string[]>;
  osm_type: string;
  kind: string;
}

export interface Tile {
  id: number;
  bbox: [number, number, number, number];
}

export interface Plan {
  tiles: Tile[];
  budget: { day: string; cap: number; used: number; left: number };
  categories: [string, number][];
  kinds: string[];
  rules: Rule[];
}

export interface PlaceRow {
  source_id: string;
  osm_ref?: string;
  name: string;
  kind: string;
  rule_ids: number[];
  lat: number;
  lng: number;
  address_text?: string;
  locality?: string;
  country?: string;
  opening_hours?: string;
  website?: string;
  tags?: Record<string, string>;
}

// ---------------------------------------------------------------------------------------------
// Tiles (same arithmetic as public.place_tile_id)
export function tileId(lat: number, lng: number): number {
  const row = Math.min(359, Math.max(0, Math.floor((lat + 90) / 0.5)));
  const col = Math.min(719, Math.max(0, Math.floor((lng + 180) / 0.5)));
  return row * 720 + col;
}

// ---------------------------------------------------------------------------------------------
// Category groups

/**
 * Hub categories ([category, hub count], most used first) -> request groups in GROUP_ORDER. Broad
 * and malformed categories are dropped; a group keeps its categories most-used first.
 */
export function categoryGroups(categories: [string, number][]): string[][] {
  const groups = new Map<string, string[]>();
  for (const [cat] of categories) {
    if (typeof cat !== "string" || !CATEGORY.test(cat) || BROAD_CATEGORIES.has(cat)) continue;
    const group = GROUP_OF[cat.split(".")[0]];
    if (!group) continue;
    const list = groups.get(group) ?? [];
    if (!list.includes(cat)) list.push(cat);
    groups.set(group, list);
  }
  return GROUP_ORDER.filter((g) => groups.has(g)).map((g) => groups.get(g)!);
}

export function placesUrl(
  categories: string[],
  bbox: [number, number, number, number],
  offset: number,
  key: string,
): string {
  const u = new URL(GEOAPIFY_PLACES_URL);
  u.searchParams.set("categories", categories.join(","));
  u.searchParams.set("filter", `rect:${bbox.join(",")}`);
  u.searchParams.set("limit", String(PAGE_LIMIT));
  if (offset > 0) u.searchParams.set("offset", String(offset));
  u.searchParams.set("apiKey", key);
  return u.toString();
}

// ---------------------------------------------------------------------------------------------
// Rules (port of Rules.match / Rules.best in scripts/places/extract_places.py)

function tagValues(raw: unknown): Set<string> {
  return new Set(
    String(raw)
      .split(";")
      .map((v) => v.trim())
      .filter((v) => v !== ""),
  );
}

export class Rules {
  private byKey = new Map<string, Rule[]>();
  private kindOrder = new Map<string, number>();

  constructor(rules: Rule[], kinds: string[]) {
    kinds.forEach((k, i) => this.kindOrder.set(k, i));
    for (const r of rules) {
      const list = this.byKey.get(r.key) ?? [];
      list.push(r);
      this.byKey.set(r.key, list);
    }
  }

  match(tags: Record<string, string>, osmType: string): Rule[] {
    const hits: Rule[] = [];
    for (const [key, rules] of this.byKey) {
      if (!(key in tags)) continue;
      const vals = tagValues(tags[key]);
      for (const r of rules) {
        if (r.osm_type === "relation" && osmType !== "r") continue;
        if (r.value !== null && !vals.has(r.value)) continue;
        let ok = true;
        for (const [ek, evs] of Object.entries(r.extra ?? {})) {
          if (!(ek in tags)) {
            ok = false;
            break;
          }
          if (!evs.includes("*")) {
            const have = tagValues(tags[ek]);
            if (!evs.some((v) => have.has(v))) {
              ok = false;
              break;
            }
          }
        }
        if (ok) hits.push(r);
      }
    }
    return hits;
  }

  /** The rule that names the kind: most extra conditions, then kind order, then id. */
  best(hits: Rule[]): Rule {
    const rank = (r: Rule): [number, number, number] => [
      -Object.keys(r.extra ?? {}).length,
      this.kindOrder.get(r.kind) ?? 999,
      r.id,
    ];
    return hits.reduce((a, b) => {
      const ra = rank(a);
      const rb = rank(b);
      for (let i = 0; i < 3; i++) if (ra[i] !== rb[i]) return ra[i] < rb[i] ? a : b;
      return a;
    });
  }
}

// ---------------------------------------------------------------------------------------------
// Feature -> row

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : typeof v === "number" ? String(v) : "";
}

function cleanName(v: unknown): string {
  return str(v).replace(/\s+/g, " ").trim().slice(0, 120);
}

export function osmRefOf(raw: Record<string, unknown>): string | null {
  const t = str(raw.osm_type).toLowerCase();
  const type = t === "node" ? "n" : t === "way" ? "w" : t === "relation" ? "r" : t;
  const id = Number(raw.osm_id);
  if (!["n", "w", "r"].includes(type) || !Number.isFinite(id) || !Number.isInteger(id) || id === 0)
    return null;
  const ref = `${type}${Math.abs(id)}`;
  return /^[nwr][0-9]{1,15}$/.test(ref) ? ref : null;
}

export type DropReason =
  | "not_feature"
  | "no_place_id"
  | "no_osm_tags"
  | "no_rules"
  | "access_private"
  | "home_building"
  | "unnamed"
  | "no_point"
  | "outside_tile";

/** One Geoapify feature -> a place row for ingest_places, or the reason it is dropped. */
export function featureRow(
  feature: unknown,
  tile: number,
  rules: Rules,
): { row: PlaceRow } | { drop: DropReason } {
  if (typeof feature !== "object" || feature === null) return { drop: "not_feature" };
  const p = ((feature as Record<string, unknown>).properties ?? {}) as Record<string, unknown>;
  const placeId = str(p.place_id);
  if (placeId === "" || placeId.length > 200) return { drop: "no_place_id" };
  const ds = (p.datasource ?? {}) as Record<string, unknown>;
  const raw = (ds.raw ?? {}) as Record<string, unknown>;
  const tags: Record<string, string> = {};
  for (const [k, v] of Object.entries(raw)) {
    if (k === "osm_id" || k === "osm_type") continue;
    if (typeof v === "string" || typeof v === "number") tags[k] = String(v);
  }
  if (Object.keys(tags).length === 0) return { drop: "no_osm_tags" };
  const ref = osmRefOf(raw);
  const hits = rules.match(tags, ref ? ref[0] : "n");
  if (hits.length === 0) return { drop: "no_rules" };
  if (PRIVATE_ACCESS.has(str(tags.access))) return { drop: "access_private" };
  if (HOME_BUILDINGS.has(str(tags.building))) return { drop: "home_building" };
  const name = cleanName(p.name ?? tags.name);
  if (name === "") return { drop: "unnamed" };
  const lat = Number(p.lat);
  const lng = Number(p.lon);
  if (
    typeof p.lat !== "number" ||
    typeof p.lon !== "number" ||
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    Math.abs(lat) > 90 ||
    Math.abs(lng) > 180
  )
    return { drop: "no_point" };
  if (tileId(lat, lng) !== tile) return { drop: "outside_tile" };

  const best = rules.best(hits);
  const row: PlaceRow = {
    source_id: placeId,
    name,
    kind: best.kind,
    rule_ids: [...new Set(hits.map((h) => h.id))].sort((a, b) => a - b).slice(0, 64),
    lat: Math.round(lat * 1e7) / 1e7,
    lng: Math.round(lng * 1e7) / 1e7,
  };
  if (ref) row.osm_ref = ref;
  const street = [str(p.housenumber), str(p.street)].filter((x) => x !== "").join(" ");
  if (street) row.address_text = street.slice(0, 200);
  const city = str(p.city);
  if (city) row.locality = city.slice(0, 120);
  const cc = str(p.country_code).toUpperCase();
  if (/^[A-Z]{2}$/.test(cc)) row.country = cc;
  const hours = str(tags.opening_hours ?? p.opening_hours);
  if (hours && hours.length <= 255) row.opening_hours = hours;
  const web = str(p.website ?? tags.website ?? tags["contact:website"]);
  if (/^https?:\/\//.test(web) && web.length <= 500) row.website = web;
  const kept: Record<string, string> = {};
  const business = BUSINESS_KEYS.some((b) => b in tags);
  for (const k of TAG_ALLOWLIST) {
    const v = str(k === "phone" && !("phone" in tags) ? tags["contact:phone"] : tags[k]);
    if (v === "") continue;
    if (k === "phone" && !business) continue;
    kept[k] = v.slice(0, 255);
  }
  if (Object.keys(kept).length > 0) row.tags = kept;
  return { row };
}

// ---------------------------------------------------------------------------------------------
// One run

export type Rpc = (name: string, args: Record<string, unknown>) => Promise<unknown>;

export interface FillDeps {
  key: string | null | undefined;
  rpc: Rpc;
  fetch: (url: string) => Promise<Response>;
  now?: () => Date;
  sleep?: (ms: number) => Promise<void>;
  log?: (...args: unknown[]) => void;
}

export interface TileResult {
  tile_id: number;
  requests: number;
  credits: number;
  features: number;
  rows: number;
  dropped: Record<string, number>;
  outcome: "filled" | "released";
  reason?: string;
  ingest?: Record<string, unknown>;
}

export interface FillResult {
  skipped?: "no_key";
  tiles: TileResult[];
  budget_left: number | null;
  stopped?: string;
}

export function runId(now: Date, tile: number): string {
  const s = now.toISOString().replace(/[-:T]/g, "").slice(0, 12);
  return `geoapify-${s}-${tile}`;
}

function isPlan(v: unknown): v is Plan {
  if (typeof v !== "object" || v === null) return false;
  const p = v as Record<string, unknown>;
  return (
    Array.isArray(p.tiles) &&
    Array.isArray(p.categories) &&
    Array.isArray(p.rules) &&
    Array.isArray(p.kinds)
  );
}

/** Fills the claimed tiles. Without a key it returns {skipped: "no_key"} and calls nothing. */
export async function runFill(deps: FillDeps): Promise<FillResult> {
  const log = deps.log ?? console.log;
  const key = (deps.key ?? "").trim();
  if (key === "") {
    log("places-fill skipped: no key");
    return { skipped: "no_key", tiles: [], budget_left: null };
  }
  const now = deps.now ?? (() => new Date());
  const sleep = deps.sleep ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));

  const plan = await deps.rpc("places_fill_plan", { p_limit: TILES_PER_RUN });
  if (!isPlan(plan)) throw new Error("plan_invalid");
  const result: FillResult = { tiles: [], budget_left: plan.budget?.left ?? null };
  if (plan.tiles.length === 0) return result;

  const groups = categoryGroups(plan.categories);
  const rules = new Rules(plan.rules, plan.kinds);
  let stopped: string | undefined;

  for (const tile of plan.tiles) {
    const res: TileResult = {
      tile_id: tile.id,
      requests: 0,
      credits: 0,
      features: 0,
      rows: 0,
      dropped: {},
      outcome: "released",
    };
    result.tiles.push(res);
    if (stopped || groups.length === 0) {
      res.reason = stopped ?? "no_categories";
      await deps.rpc("places_fill_release", { p_tile_id: tile.id });
      continue;
    }

    const rows = new Map<string, PlaceRow>();
    const refs = new Set<string>();
    // Round-robin: every group gets a first page before any group gets a second.
    const queue = groups.map((cats) => ({ cats, offset: 0 }));
    let failed = 0;
    while (queue.length > 0 && res.requests < MAX_REQUESTS_PER_TILE) {
      const next = queue.shift()!;
      const left = await deps.rpc("places_fill_spend", { p_credits: CREDITS_PER_PAGE });
      if (left === null || left === undefined) {
        stopped = "budget";
        break;
      }
      result.budget_left = Number(left);
      if (res.requests > 0) await sleep(REQUEST_GAP_MS);
      res.requests += 1;
      res.credits += CREDITS_PER_PAGE;
      let body: { features?: unknown[] };
      try {
        const r = await deps.fetch(placesUrl(next.cats, tile.bbox, next.offset, key));
        if (!r.ok) {
          await r.body?.cancel();
          res.reason = `geoapify_http_${r.status}`;
          failed += 1;
          // A 400 refuses that request's category list only (a category Geoapify does not know):
          // the tile's other groups are still asked for (Nov 8 staging run: the second group's
          // 400 had ended the tile after one page).
          if (r.status === 400) {
            res.dropped.refused_group = (res.dropped.refused_group ?? 0) + 1;
            continue;
          }
          // A refused key or a used-up plan stops the whole run; anything else only this tile.
          if (r.status === 401 || r.status === 403 || r.status === 429) stopped = res.reason;
          break;
        }
        body = (await r.json()) as { features?: unknown[] };
      } catch (_err) {
        res.reason = "geoapify_unreachable";
        failed += 1;
        break;
      }
      const features = Array.isArray(body.features) ? body.features : [];
      res.features += features.length;
      for (const f of features) {
        const out = featureRow(f, tile.id, rules);
        if ("drop" in out) {
          res.dropped[out.drop] = (res.dropped[out.drop] ?? 0) + 1;
          continue;
        }
        const row = out.row;
        if (rows.has(row.source_id) || (row.osm_ref && refs.has(row.osm_ref))) {
          res.dropped.duplicate = (res.dropped.duplicate ?? 0) + 1;
          continue;
        }
        if (rows.size >= MAX_ROWS) {
          res.dropped.row_cap = (res.dropped.row_cap ?? 0) + 1;
          continue;
        }
        rows.set(row.source_id, row);
        if (row.osm_ref) refs.add(row.osm_ref);
      }
      if (features.length >= PAGE_LIMIT)
        queue.push({ cats: next.cats, offset: next.offset + PAGE_LIMIT });
    }

    // Nothing came back from Geoapify (budget or an error before the first page): free the tile.
    const answered = res.requests - failed;
    if (answered <= 0) {
      res.reason = res.reason ?? stopped ?? "no_request";
      await deps.rpc("places_fill_release", { p_tile_id: tile.id });
      continue;
    }

    const run = runId(now(), tile.id);
    const list = [...rows.values()];
    res.rows = list.length;
    try {
      const ingest = (await deps.rpc("ingest_places", {
        p_tile_id: tile.id,
        p_run_id: run,
        p_batch: list,
        p_source: "geoapify",
        p_batch_no: 0,
      })) as Record<string, unknown>;
      const done = (await deps.rpc("finish_place_tile", {
        p_tile_id: tile.id,
        p_run_id: run,
        p_count: list.length,
        p_source: "geoapify",
      })) as Record<string, unknown>;
      res.outcome = "filled";
      res.ingest = {
        inserted: ingest?.inserted ?? 0,
        updated: ingest?.updated ?? 0,
        skipped: ingest?.skipped ?? {},
        row_count: done?.row_count ?? null,
      };
    } catch (err) {
      res.reason = err instanceof Error ? err.message.slice(0, 80) : "ingest_failed";
      await deps.rpc("places_fill_release", { p_tile_id: tile.id });
    }
    log(
      "places-fill tile",
      tile.id,
      JSON.stringify({
        requests: res.requests,
        credits: res.credits,
        rows: res.rows,
        outcome: res.outcome,
        reason: res.reason ?? null,
      }),
    );
  }
  if (stopped) result.stopped = stopped;
  return result;
}
