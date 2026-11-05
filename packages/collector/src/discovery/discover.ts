// Discovery for one region, end to end, without writing anything (D-042 slice 8): candidates from
// the region's OSM tile rows and Wikidata, then probes. The CLI (discover-cli.ts) posts the
// candidates and results to the collector Edge Function, or, for the Atlanta gate, only counts.
// Logs carry counts and public organisation hosts, never region points or member data.

import type { Fetcher, PoliteFetcher } from "../net/fetcher.ts";
import type { Denylist } from "../policy/denylist.ts";
import { call, checkService, type ServiceOptions } from "../regions.ts";
import type { Region } from "../types.ts";
import { siteOf, hostOf } from "../util/url.ts";
import {
  aroundQuery,
  type Candidate,
  cheapScore,
  entitiesQuery,
  type KindYield,
  mergeCandidates,
  osmCandidates,
  parseAround,
  parseEntities,
  sparqlUrl,
  type TileRow,
  tilesForRegion,
} from "./candidates.ts";
import type { DiscoveryCaps, GateExpectation } from "./config.ts";
import { probe, type ProbeInput, type ProbeResult } from "./probe.ts";

/** Rows of a region's place tiles from GET /collector/tiles/{id}/rows (5,000 a page). */
export async function fetchTileRows(
  opts: ServiceOptions,
  region: Region,
): Promise<{ rows: TileRow[]; tiles: number; tilesWithRows: number }> {
  checkService(opts);
  const rows: TileRow[] = [];
  const tiles = tilesForRegion(region);
  let tilesWithRows = 0;
  for (const t of tiles) {
    let after: string | null = null;
    let got = 0;
    for (let page = 0; page < 40; page++) {
      const q: string = after ? `?after=${encodeURIComponent(after)}&limit=5000` : "?limit=5000";
      const { status, body } = await call(opts, `/tiles/${t}/rows${q}`);
      if (status === 404) break;
      const b = body as { rows?: unknown; next?: unknown } | null;
      if (status !== 200 || !Array.isArray(b?.rows))
        throw new Error(`GET /tiles/${t}/rows failed: ${status}`);
      rows.push(...(b.rows as TileRow[]));
      got += b.rows.length;
      after = typeof b.next === "string" ? b.next : null;
      if (!after) break;
    }
    if (got > 0) tilesWithRows++;
  }
  return { rows, tiles: tiles.length, tilesWithRows };
}

export interface BuildCounts {
  osm: number;
  wikidata_entities: number;
  wikidata_around: number;
  candidates: number;
  wikidata_calls: number;
  wikidata_failed: number;
  dropped_denylisted: number;
  dropped_known: number;
}

/**
 * Candidates for a region (design 6.1): OSM website tags of event-likely places, the official
 * websites of their Wikidata items (50 a query, at most caps.wikidataEntityCallsPerRegion), and
 * one Wikidata "around" query of event-type venues. Wikidata failures cost candidates, not the run.
 */
export async function buildCandidates(o: {
  region: Region;
  rows: TileRow[];
  fetcher: PoliteFetcher | Fetcher;
  denylist: Denylist;
  caps: DiscoveryCaps;
  country?: string | null;
  skipSites?: Set<string>;
  wikidata?: boolean;
  /** Learned yield by kind (candidates runs; the gate keeps the static priors). */
  yields?: KindYield;
}): Promise<{ candidates: Candidate[]; counts: BuildCounts }> {
  const osm = osmCandidates(o.rows, o.region, {
    denylist: o.denylist,
    country: o.country,
    skipSites: o.skipSites,
  });
  let calls = 0;
  let failed = 0;
  const sparql = async (query: string): Promise<string | null> => {
    calls++;
    const res = await o.fetcher.get(sparqlUrl(query), {
      api: true,
      accept: "application/sparql-results+json",
    });
    if (!res.ok) {
      failed++;
      return null;
    }
    return res.body;
  };
  const entitySites = new Map<string, string>();
  let around: Candidate[] = [];
  if (o.wikidata !== false) {
    // The 50-id entity lookups go to the best OSM places with a wikidata tag first, so the cap
    // (caps.wikidataEntityCallsPerRegion) cuts the weakest.
    const scoreOf = new Map(osm.candidates.map((c) => [c.host, cheapScore(c, o.yields)]));
    const ids = [...osm.wikidataIds.keys()].sort(
      (a, b) =>
        (scoreOf.get(osm.wikidataIds.get(b) ?? "") ?? 0) -
          (scoreOf.get(osm.wikidataIds.get(a) ?? "") ?? 0) || a.localeCompare(b),
    );
    for (let i = 0; i < ids.length && i / 50 < o.caps.wikidataEntityCallsPerRegion; i += 50) {
      const body = await sparql(entitiesQuery(ids.slice(i, i + 50)));
      if (body) for (const [k, v] of parseEntities(body)) entitySites.set(k, v);
    }
    if (o.caps.wikidataSparqlPerRegion > 0) {
      const body = await sparql(
        aroundQuery(
          o.region.lat,
          o.region.lng,
          Math.min(o.caps.wikidataAroundKm, o.region.radiusKm),
        ),
      );
      if (body)
        around = parseAround(body, o.region, { denylist: o.denylist, skipSites: o.skipSites });
    }
  }
  const candidates = mergeCandidates(
    osm.candidates,
    entitySites,
    osm.wikidataIds,
    around,
    o.caps.candidatesPerRegion,
    o.yields,
  );
  return {
    candidates,
    counts: {
      osm: osm.candidates.length,
      wikidata_entities: entitySites.size,
      wikidata_around: around.length,
      candidates: candidates.length,
      wikidata_calls: calls,
      wikidata_failed: failed,
      dropped_denylisted: osm.dropped.denylisted ?? 0,
      dropped_known: osm.dropped.known_source ?? 0,
    },
  };
}

/** Probes candidates a few hosts at a time (the shared fetcher keeps per-host spacing). */
export async function probeAll(
  inputs: ProbeInput[],
  o: {
    region: Region;
    fetcher: PoliteFetcher | Fetcher;
    now: Date;
    caps: DiscoveryCaps;
    onResult?: (r: ProbeResult) => void;
  },
): Promise<ProbeResult[]> {
  const out: ProbeResult[] = new Array(inputs.length);
  let i = 0;
  const worker = async () => {
    while (i < inputs.length) {
      const k = i++;
      const input = inputs[k] as ProbeInput;
      const r = await probe(input, {
        fetcher: o.fetcher,
        region: o.region,
        now: o.now,
        requestsPerHost: o.caps.requestsPerHostPerProbe,
        eventPages: o.caps.eventPagesPerProbe,
      });
      out[k] = r;
      o.onResult?.(r);
    }
  };
  await Promise.all(
    Array.from({ length: Math.max(1, Math.min(o.caps.probeConcurrency, inputs.length)) }, worker),
  );
  return out;
}

/** A result that found a calendar: items inside the region, or Localist (needs permission). */
export function foundCalendar(r: ProbeResult): boolean {
  return (r.outcome === "ok" && r.in_region > 0) || r.outcome === "needs_permission";
}

export interface GateReport {
  expected: number;
  required: number;
  found: number;
  /** Found with items inside the region (needs_permission not counted). */
  foundWithItems: number;
  passed: boolean;
  rows: {
    seed: string;
    site: string;
    found: boolean;
    candidate: boolean;
    outcome: string | null;
    platform: string | null;
    kind: string | null;
    in_region: number;
  }[];
}

/**
 * The design 6.4 gate: which of the hand-written sources were rediscovered. A source counts when
 * a probe on its site (the candidate's host, or the feed it found) found a calendar there.
 */
export function gateReport(
  results: ProbeResult[],
  candidates: Candidate[],
  expected: GateExpectation[],
  required: number,
): GateReport {
  const siteHits = (r: ProbeResult) =>
    new Set([siteOf(r.candidate.host), ...(r.url ? [siteOf(hostOf(r.url))] : [])]);
  const rows = expected.map((e) => {
    const mine = results.filter((r) => siteHits(r).has(e.site));
    const hit = mine.find(foundCalendar);
    const best = hit ?? mine[0] ?? null;
    return {
      seed: e.seed,
      site: e.site,
      found: Boolean(hit),
      candidate: candidates.some((c) => siteOf(c.host) === e.site),
      outcome: best?.outcome ?? null,
      platform: best?.platform ?? null,
      kind: best?.kind ?? null,
      in_region: best?.in_region ?? 0,
    };
  });
  const found = rows.filter((r) => r.found).length;
  return {
    expected: expected.length,
    required,
    found,
    foundWithItems: rows.filter((r) => r.found && r.outcome === "ok").length,
    passed: found >= required,
    rows,
  };
}
