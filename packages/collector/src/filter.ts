// Coverage follows users: an item is kept when its point is inside one of the requested
// regions, or, with no point, when its source's own area (the seeded city, or the region an API
// was asked about) is centred inside one of them. A small region at the edge of a city does not
// get the city's coordinate-less events.
// Then the run window, then dedupe within each source (copies across sources are linked by the
// database).

import type { ImportItem, Lane, Region } from "./types.ts";
import { haversineKm } from "./util/geo.ts";

export type FilterReason = "outside_region" | "ended" | "beyond_window" | "duplicate_in_run";

export function inAnyRegion(
  item: ImportItem,
  regions: Region[],
  sourceArea?: Pick<Region, "lat" | "lng">,
): boolean {
  const point =
    item.lat !== null && item.lng !== null
      ? { lat: item.lat, lng: item.lng }
      : sourceArea
        ? { lat: sourceArea.lat, lng: sourceArea.lng }
        : null;
  if (!point) return true;
  return regions.some((r) => haversineKm(r.lat, r.lng, point.lat, point.lng) <= r.radiusKm);
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
 * Items that survive dedupe, how many each source lost, and the external ids of the copies
 * dropped. Dedupe is within a source only: the same external id, title (letters and digits) and
 * start minute, or URL and start minute, listed twice. Copies of one event from two sources are
 * all sent; import_upsert_batch links them with the same title key (import_title_key) or URL and
 * start minute, so each source keeps seeing its own copy and never counts it as missed. Sources
 * are posted in lane order (feeds, then APIs, then pages), so the official calendar's copy is
 * usually the primary.
 */
export function dedupe(candidates: Candidate[]): {
  kept: Candidate[];
  dropped: Map<string, number>;
  /** Per source, the external ids of dropped copies whose id no kept item has. */
  notSent: Map<string, Set<string>>;
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
  const droppedIds: Candidate[] = [];
  for (const c of sorted) {
    const idKey = `${c.sourceKey}\u0000${c.item.external_id}`;
    const key = `${c.sourceKey}\u0000${dedupeKey(c.item)}`;
    const urlKey = `${c.sourceKey}\u0000${c.item.url}|${c.item.starts_at.slice(0, 16)}`;
    if (byId.has(idKey) || byKey.has(key) || byUrl.has(urlKey)) {
      dropped.set(c.sourceKey, (dropped.get(c.sourceKey) ?? 0) + 1);
      droppedIds.push(c);
      continue;
    }
    byId.add(idKey);
    byKey.add(key);
    byUrl.add(urlKey);
    kept.push(c);
  }
  const notSent = new Map<string, Set<string>>();
  for (const c of droppedIds) {
    if (byId.has(`${c.sourceKey}\u0000${c.item.external_id}`)) continue;
    const s = notSent.get(c.sourceKey) ?? new Set<string>();
    s.add(c.item.external_id);
    notSent.set(c.sourceKey, s);
  }
  kept.sort((a, b) => a.order - b.order || a.item.starts_at.localeCompare(b.item.starts_at));
  return { kept, dropped, notSent };
}
