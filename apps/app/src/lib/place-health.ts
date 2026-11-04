import { queryOptions } from "@tanstack/react-query";

import { supabase } from "./supabase";

/**
 * The hub map health panel (D-041 slice 15; `mod_place_health()`, migration 35, moderators
 * only): place tiles by status, place rows by source, the table and database sizes against the
 * 120 MB alarm and the 150 MB cap, the last extract, Geoapify, lifecycle, size and dump runs,
 * the pg_cron jobs, and today's collector budget. Nothing in it is about a member.
 */

export type TileStatus = "wanted" | "filling" | "active" | "idle" | "retired";
export const TILE_STATUSES: readonly TileStatus[] = [
  "wanted",
  "filling",
  "active",
  "idle",
  "retired",
];

export interface HealthTile {
  id: number;
  status: TileStatus;
  keep: boolean;
  rows: number;
  demand: number;
  osmRunAt: Date | null;
  geoapifyRunAt: Date | null;
  lastMemberAt: Date | null;
  idleSince: Date | null;
  /** South-west corner of the 0.5-degree tile. */
  west: number;
  south: number;
}

export type SizeLevel = "ok" | "alarm" | "cap";

export interface HealthRun {
  at: Date;
  stats: Record<string, unknown>;
}

export interface PlaceHealth {
  tilesByStatus: Record<TileStatus, number>;
  tilesTotal: number;
  tiles: HealthTile[];
  rows: { source: string; status: string; isPublic: boolean; n: number }[];
  rowsTotal: number;
  size: {
    placesBytes: number;
    dbBytes: number;
    alarmBytes: number;
    capBytes: number;
    dbCapBytes: number;
    level: SizeLevel;
  };
  runs: {
    extract: { at: Date; tileId: number; received: number } | null;
    geoapify: { at: Date; tileId: number; received: number } | null;
    retire: HealthRun | null;
    size: HealthRun | null;
    dump: HealthRun | null;
    cron: {
      job: string;
      schedule: string;
      active: boolean;
      lastStart: Date | null;
      lastStatus: string | null;
    }[];
  };
  budget: { source: string; used: number; cap: number | null }[];
}

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {};
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);
const num = (v: unknown): number =>
  typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0;
const str = (v: unknown): string => (typeof v === "string" ? v : "");
function date(v: unknown): Date | null {
  if (typeof v !== "string" || !v) return null;
  const d = new Date(v);
  return Number.isNaN(d.getTime()) ? null : d;
}
function run(v: unknown): HealthRun | null {
  const o = obj(v);
  const at = date(o.ran_at);
  return at ? { at, stats: obj(o.stats) } : null;
}
function tileRun(v: unknown) {
  const o = obj(v);
  const at = date(o.finished_at);
  return at ? { at, tileId: num(o.tile_id), received: num(o.received) } : null;
}

/** Decodes `mod_place_health()`; unknown or missing parts become empty values, never a throw. */
export function decodePlaceHealth(raw: unknown): PlaceHealth {
  const r = obj(raw);
  const tiles = obj(r.tiles);
  const byStatusRaw = obj(tiles.by_status);
  const tilesByStatus = Object.fromEntries(
    TILE_STATUSES.map((s) => [s, num(byStatusRaw[s])]),
  ) as Record<TileStatus, number>;
  const rows = arr(r.rows).map((x) => {
    const o = obj(x);
    return {
      source: str(o.source),
      status: str(o.status),
      isPublic: o.public === true,
      n: num(o.n),
    };
  });
  const size = obj(r.size);
  const level = str(size.level);
  const runs = obj(r.runs);
  const caps = obj(r.budget_caps);
  const budget = arr(r.budget).map((x) => {
    const o = obj(x);
    const cap = o.cap ?? caps[str(o.source)];
    return {
      source: str(o.source),
      used: num(o.used),
      cap: cap === null || cap === undefined ? null : num(cap),
    };
  });
  for (const [source, cap] of Object.entries(caps)) {
    if (!budget.some((b) => b.source === source)) budget.push({ source, used: 0, cap: num(cap) });
  }
  return {
    tilesByStatus,
    tilesTotal: num(tiles.total),
    tiles: arr(tiles.list).map((x) => {
      const o = obj(x);
      const status = str(o.status) as TileStatus;
      return {
        id: num(o.id),
        status: TILE_STATUSES.includes(status) ? status : "wanted",
        keep: o.keep === true,
        rows: num(o.rows),
        demand: num(o.demand),
        osmRunAt: date(o.osm_run_at),
        geoapifyRunAt: date(o.geoapify_run_at),
        lastMemberAt: date(o.last_member_at),
        idleSince: date(o.idle_since),
        west: num(o.west),
        south: num(o.south),
      };
    }),
    rows,
    rowsTotal: rows.reduce((t, x) => t + x.n, 0),
    size: {
      placesBytes: num(size.places_bytes),
      dbBytes: num(size.db_bytes),
      alarmBytes: num(size.alarm_bytes) || 125_829_120,
      capBytes: num(size.cap_bytes) || 157_286_400,
      dbCapBytes: num(size.db_cap_bytes) || 471_859_200,
      level: level === "alarm" || level === "cap" ? level : "ok",
    },
    runs: {
      extract: tileRun(runs.extract),
      geoapify: tileRun(runs.geoapify),
      retire: run(runs.retire),
      size: run(runs.size),
      dump: run(runs.dump),
      cron: arr(runs.cron).map((x) => {
        const o = obj(x);
        return {
          job: str(o.job),
          schedule: str(o.schedule),
          active: o.active === true,
          lastStart: date(o.last_start),
          lastStatus: typeof o.last_status === "string" ? o.last_status : null,
        };
      }),
    },
    budget,
  };
}

/** "17.0 MB" (binary megabytes, as the design's measurements use). */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

/** Share of a limit, 0 to 100, for a meter. */
export function percentOf(value: number, limit: number): number {
  if (limit <= 0) return 0;
  return Math.max(0, Math.min(100, Math.round((value / limit) * 100)));
}

/** The panel's headline for the size check. */
export function sizeMessage(size: PlaceHealth["size"]): string {
  if (size.level === "cap") {
    return "Places are at the cap. The extract job will not post until rows are retired or moved to static files.";
  }
  if (size.level === "alarm") {
    return "Places passed the 120 MB alarm. Start the static-file fallback (design section 9) before the 150 MB cap.";
  }
  return "Places are under the 120 MB alarm.";
}

export const placeHealthQuery = () =>
  queryOptions({
    queryKey: ["admin", "place-health"] as const,
    queryFn: async () => {
      const { data, error } = await supabase.rpc("mod_place_health");
      if (error) throw error;
      return decodePlaceHealth(data);
    },
    staleTime: 60_000,
  });
