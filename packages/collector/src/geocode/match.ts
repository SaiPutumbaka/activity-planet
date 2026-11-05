// Step 1 of venue geocoding (design 2.5): our own places first. A location text is matched
// against the named place rows of its region's tiles (GET /collector/tiles/{id}/rows, the public
// ODbL facts the place files are built from) by trigram similarity of the venue name, as pg_trgm
// computes it (meeting_spot_refresh's threshold, 0.45), with address tokens as a tie-breaker. No
// request leaves the runner for a match.

import type { TileRow } from "../discovery/candidates.ts";
import { haversineKm } from "../util/geo.ts";

/** meeting_spot_refresh's trigram threshold (migration 30). */
export const MATCH_THRESHOLD = 0.45;

/** pg_trgm's trigrams: lower-cased alphanumeric words, each padded with two spaces before, one after. */
export function trigrams(text: string): Set<string> {
  const out = new Set<string>();
  for (const w of text.toLowerCase().split(/[^\p{L}\p{N}]+/u)) {
    if (!w) continue;
    const p = `  ${w} `;
    for (let i = 0; i + 3 <= p.length; i++) out.add(p.slice(i, i + 3));
  }
  return out;
}

export function similarity(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 || b.size === 0) return 0;
  let shared = 0;
  for (const t of a) if (b.has(t)) shared++;
  return shared / (a.size + b.size - shared);
}

function tokens(text: string | null): Set<string> {
  return new Set(
    (text ?? "")
      .toLowerCase()
      .split(/[^\p{L}\p{N}]+/u)
      .filter((t) => t.length >= 2),
  );
}

export interface PlaceMatch {
  lat: number;
  lng: number;
  place_ref: string;
  confidence: number;
}

interface Indexed {
  row: TileRow;
  grams: Set<string>;
}

/** An index of a region's named places for repeated lookups. */
export class PlaceIndex {
  private readonly items: Indexed[] = [];
  private readonly byGram = new Map<string, number[]>();

  constructor(rows: TileRow[]) {
    for (const row of rows) {
      const name = row[4];
      if (!name || typeof row[1] !== "number" || typeof row[2] !== "number") continue;
      const grams = trigrams(name);
      if (grams.size === 0) continue;
      const i = this.items.push({ row, grams }) - 1;
      for (const g of grams) {
        const list = this.byGram.get(g);
        if (list) list.push(i);
        else this.byGram.set(g, [i]);
      }
    }
  }

  get size(): number {
    return this.items.length;
  }

  /**
   * The best place for a location text inside the region: the venue part (before the first comma)
   * or the whole text, whichever matches better; a tie on similarity goes to the place sharing
   * more address tokens, and a tie that remains between places over 1 km apart is no match.
   */
  match(
    location: string,
    region: { lat: number; lng: number; radius_km: number },
  ): PlaceMatch | null {
    const venue = location.split(",")[0] ?? location;
    const queries = [trigrams(venue), trigrams(location)];
    const locTokens = tokens(location);
    const seen = new Set<number>();
    for (const q of queries)
      for (const g of q) for (const i of this.byGram.get(g) ?? []) seen.add(i);
    let best: { it: Indexed; sim: number; addr: number }[] = [];
    let bestSim = 0;
    let bestAddr = -1;
    for (const i of seen) {
      const it = this.items[i]!;
      const lat = it.row[2];
      const lng = it.row[1];
      if (haversineKm(region.lat, region.lng, lat, lng) > region.radius_km) continue;
      const sim = Math.max(...queries.map((q) => similarity(q, it.grams)));
      if (sim < MATCH_THRESHOLD) continue;
      let addr = 0;
      for (const t of tokens(it.row[6])) if (locTokens.has(t)) addr++;
      const better = sim > bestSim + 1e-9 || (Math.abs(sim - bestSim) <= 1e-9 && addr > bestAddr);
      const tie = Math.abs(sim - bestSim) <= 1e-9 && addr === bestAddr;
      if (better) {
        best = [{ it, sim, addr }];
        bestSim = sim;
        bestAddr = addr;
      } else if (tie) best.push({ it, sim, addr });
    }
    if (best.length === 0) return null;
    const first = best[0]!;
    for (const other of best.slice(1)) {
      if (haversineKm(first.it.row[2], first.it.row[1], other.it.row[2], other.it.row[1]) > 1)
        return null;
    }
    return {
      lat: first.it.row[2],
      lng: first.it.row[1],
      place_ref: `osm:${first.it.row[0]}`,
      confidence: Math.round(first.sim * 100) / 100,
    };
  }
}
