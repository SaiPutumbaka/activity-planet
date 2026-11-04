// Coverage follows users: an item is kept when its point is inside one of the requested
// regions, or, with no point, when its source is seeded for one of them (the source's own city).
// Then the run window, then dedupe within the run.

import type { ImportItem, Lane, Region } from "./types.ts";
import { haversineKm } from "./util/geo.ts";

export type FilterReason = "outside_region" | "ended" | "beyond_window" | "duplicate_in_run";

export function inAnyRegion(item: ImportItem, regions: Region[]): boolean {
  if (item.lat === null || item.lng === null) return true;
  return regions.some(
    (r) => haversineKm(r.lat, r.lng, item.lat as number, item.lng as number) <= r.radiusKm,
  );
}

export function windowReason(item: ImportItem, start: Date, end: Date): FilterReason | null {
  if (new Date(item.ends_at).getTime() <= start.getTime()) return "ended";
  if (new Date(item.starts_at).getTime() >= end.getTime()) return "beyond_window";
  return null;
}

/** The same event from two places: same title (letters and digits only) and start minute. */
export function dedupeKey(item: ImportItem): string {
  const title = item.title
    .normalize("NFKD")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, "");
  return `${title}|${item.starts_at.slice(0, 16)}`;
}

/** Official calendars first, then the APIs, then page markup; items with a point beat items without. */
const LANE_RANK: Record<Lane, number> = { feed: 0, api: 1, page: 2 };

export interface Candidate {
  sourceKey: string;
  item: ImportItem;
  /** Order the source was processed in; earlier wins a tie. */
  order: number;
}

/**
 * Items that survive dedupe, and how many each source lost. Within a source the external id
 * must be unique (import_upsert_batch skips duplicate_in_batch); across sources one copy of an
 * event is kept so the feed does not show it twice.
 */
export function dedupe(candidates: Candidate[]): {
  kept: Candidate[];
  dropped: Map<string, number>;
} {
  const sorted = [...candidates].sort((a, b) => {
    const lane = LANE_RANK[a.item.lane] - LANE_RANK[b.item.lane];
    if (lane !== 0) return lane;
    const pa = a.item.lat === null ? 1 : 0;
    const pb = b.item.lat === null ? 1 : 0;
    if (pa !== pb) return pa - pb;
    return a.order - b.order;
  });
  const byKey = new Set<string>();
  const byId = new Set<string>();
  const byUrl = new Set<string>();
  const kept: Candidate[] = [];
  const dropped = new Map<string, number>();
  for (const c of sorted) {
    const idKey = `${c.sourceKey}\u0000${c.item.external_id}`;
    const key = dedupeKey(c.item);
    const urlKey = `${c.item.url}|${c.item.starts_at.slice(0, 16)}`;
    if (byId.has(idKey) || byKey.has(key) || byUrl.has(urlKey)) {
      dropped.set(c.sourceKey, (dropped.get(c.sourceKey) ?? 0) + 1);
      continue;
    }
    byId.add(idKey);
    byKey.add(key);
    byUrl.add(urlKey);
    kept.push(c);
  }
  kept.sort((a, b) => a.order - b.order || a.item.starts_at.localeCompare(b.item.starts_at));
  return { kept, dropped };
}
