// One collector run: regions in, one SourceBatch per source out.
//   Lane 1  API adapters per region (only those whose key is set) and open-data seeds.
//   Lane 2  ICS and RSS/Atom seeds, plus feeds discovered on seed pages.
//   Lane 3  schema.org Event JSON-LD and microdata on seed pages and on same-site event pages
//           linked from them (one level), honouring noindex, nofollow and X-Robots-Tag.
// Every request goes through the PoliteFetcher; every item through normalize() and the
// region, window and dedupe filters.

import { type ApiAdapter, enabledAdapters, redactUrl } from "./adapters/api.ts";
import { arcgisUrl, parseArcgis, parseSocrata, socrataUrl } from "./adapters/opendata.ts";
import { citiesFor } from "./config.ts";
import { type Candidate, dedupe, inAnyRegion, windowReason } from "./filter.ts";
import type { FetchResult, PoliteFetcher } from "./net/fetcher.ts";
import { EXCERPT_MAX, normalize } from "./normalize.ts";
import { isFeed, parseFeed } from "./parse/feed.ts";
import { discoverLinks, scanHtml } from "./parse/html.ts";
import { parseIcs } from "./parse/ics.ts";
import { jsonLdEvents, schemaEvents } from "./parse/schema.ts";
import { mergeDirectives, metaDirectives, parseXRobotsTag, snippetLimit } from "./policy/meta.ts";
import type { CityFile, RawEvent, Region, Seed, SourceBatch } from "./types.ts";
import { hostOf, shortHash, siteOf } from "./util/url.ts";

export interface CollectOptions {
  regions: Region[];
  cities: CityFile[];
  fetcher: PoliteFetcher;
  env?: Record<string, string | undefined>;
  now?: Date;
  windowDays?: number;
  /** Discovered event pages per page seed (default 25). */
  maxPagesPerSeed?: number;
  /** Discovered feeds per page seed (default 10). */
  maxFeedsPerSeed?: number;
  /** Seeds processed at once; per-host spacing still applies (default 4). */
  concurrency?: number;
  adapters?: ApiAdapter[];
  log?: (line: string) => void;
}

export interface SourceError {
  sourceKey: string;
  url: string;
  reason: string;
  status?: number;
}

export interface CollectResult {
  batches: SourceBatch[];
  errors: SourceError[];
  stats: {
    sources: number;
    fetched: number;
    raw: number;
    items: number;
    skipped: Record<string, number>;
    requestsByHost: Record<string, number>;
  };
}

interface SourceRun {
  key: string;
  name: string;
  attribution: string;
  regionId: string;
  /** The city's region for seeds, the requested region for API sources. */
  region: Region;
  order: number;
  seed?: Seed;
  /** Raw events with their normalize context bits. */
  raws: { raw: RawEvent; idPrefix: string; fallbackUrl: string | null; snippetMax?: number }[];
}

const CALENDAR_TYPE = /text\/calendar|application\/calendar/i;

function looksLikeIcs(res: Extract<FetchResult, { ok: true }>): boolean {
  return (
    CALENDAR_TYPE.test(res.contentType ?? "") || /^\s*BEGIN:VCALENDAR/i.test(res.body.slice(0, 200))
  );
}

async function pool<T>(items: T[], n: number, fn: (item: T) => Promise<void>): Promise<void> {
  let i = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(n, items.length)) }, async () => {
    while (i < items.length) {
      const item = items[i++] as T;
      await fn(item);
    }
  });
  await Promise.all(workers);
}

export async function collect(opts: CollectOptions): Promise<CollectResult> {
  const now = opts.now ?? new Date();
  const windowDays = opts.windowDays ?? 60;
  const windowStart = now;
  const windowEnd = new Date(now.getTime() + windowDays * 86_400_000);
  const env = opts.env ?? {};
  const log = opts.log ?? (() => undefined);
  const fetcher = opts.fetcher;
  const maxPages = opts.maxPagesPerSeed ?? 25;
  const maxFeeds = opts.maxFeedsPerSeed ?? 10;
  const errors: SourceError[] = [];
  const visited = new Set<string>();
  let fetched = 0;

  const fail = (sourceKey: string, res: Extract<FetchResult, { ok: false }>) => {
    errors.push({ sourceKey, url: redactUrl(res.url), reason: res.reason, status: res.status });
    log(
      `skip ${sourceKey} ${redactUrl(res.url)}: ${res.reason}${res.status ? ` (${res.status})` : ""}`,
    );
  };

  // Seeds from every city overlapping a requested region, once each.
  const seedRuns: SourceRun[] = [];
  const seen = new Set<string>();
  let order = 0;
  for (const region of opts.regions) {
    for (const city of citiesFor(region, opts.cities)) {
      for (const seed of city.seeds) {
        if (seed.enabled === false || seen.has(seed.id)) continue;
        seen.add(seed.id);
        seedRuns.push({
          key: seed.id,
          name: seed.name,
          attribution: seed.attribution,
          regionId: city.region.id,
          region: city.region,
          order: order++,
          seed,
          raws: [],
        });
      }
    }
  }

  const zoneFor = (run: SourceRun) => run.region.timezone ?? "UTC";

  const readFeed = (run: SourceRun, res: Extract<FetchResult, { ok: true }>, idPrefix: string) => {
    const directives = parseXRobotsTag(res.xRobotsTag);
    if (directives.noindex) {
      errors.push({ sourceKey: run.key, url: res.url, reason: "noindex" });
      return;
    }
    let events: RawEvent[];
    if (looksLikeIcs(res)) {
      events = parseIcs(res.body, {
        sourceUrl: res.url,
        defaultZone: zoneFor(run),
        windowStart,
        windowEnd,
      });
    } else if (isFeed(res.body)) {
      events = parseFeed(res.body, { sourceUrl: res.url });
    } else {
      errors.push({ sourceKey: run.key, url: res.url, reason: "not_a_feed" });
      return;
    }
    const fallback = run.seed?.kind === "page" ? run.seed.url : null;
    const snippetMax = snippetLimit(directives, EXCERPT_MAX);
    for (const raw of events) run.raws.push({ raw, idPrefix, fallbackUrl: fallback, snippetMax });
  };

  const readPage = (
    run: SourceRun,
    res: Extract<FetchResult, { ok: true }>,
    discover: boolean,
  ): { feeds: string[]; pages: string[] } => {
    const none = { feeds: [], pages: [] };
    if (looksLikeIcs(res) || isFeed(res.body)) {
      readFeed(run, res, run.seed && res.url === run.seed.url ? "" : `f${shortHash(res.url, 8)}:`);
      return none;
    }
    const scan = scanHtml(res.body, res.url);
    if (scan.loginForm) {
      errors.push({ sourceKey: run.key, url: res.url, reason: "login_page" });
      return none;
    }
    const directives = mergeDirectives(parseXRobotsTag(res.xRobotsTag), metaDirectives(scan.metas));
    const { noindex, nofollow } = directives;
    const snippetMax = snippetLimit(directives, EXCERPT_MAX);
    if (noindex) errors.push({ sourceKey: run.key, url: res.url, reason: "noindex" });
    else {
      const events = [
        ...jsonLdEvents(scan.jsonLd, { pageUrl: res.url }),
        ...schemaEvents(scan.microdata, { pageUrl: res.url }),
      ];
      for (const raw of events)
        run.raws.push({ raw, idPrefix: "p:", fallbackUrl: res.url, snippetMax });
    }
    if (!discover || nofollow) return none;
    const site = siteOf(hostOf(res.url));
    return discoverLinks(scan, (u) => siteOf(hostOf(u)) === site);
  };

  const runSeed = async (run: SourceRun) => {
    const seed = run.seed as Seed;
    const region = run.region;

    if (seed.kind === "socrata" || seed.kind === "arcgis") {
      const url =
        seed.kind === "socrata"
          ? socrataUrl(seed, region, { start: windowStart, end: windowEnd })
          : arcgisUrl(seed, region);
      const res = await fetcher.get(url, { accept: "application/json" });
      if (!res.ok) return fail(run.key, res);
      fetched++;
      try {
        const events =
          seed.kind === "socrata" ? parseSocrata(res.body, seed) : parseArcgis(res.body, seed);
        for (const raw of events) run.raws.push({ raw, idPrefix: "", fallbackUrl: null });
      } catch {
        errors.push({ sourceKey: run.key, url: redactUrl(url), reason: "bad_json" });
      }
      return;
    }

    visited.add(seed.url);
    const res = await fetcher.get(seed.url);
    if (!res.ok) return fail(run.key, res);
    fetched++;
    if (seed.kind === "ics" || seed.kind === "rss") {
      readFeed(run, res, "");
      return;
    }

    const found = readPage(run, res, seed.discover !== false);
    const feeds = found.feeds.filter((u) => !visited.has(u)).slice(0, maxFeeds);
    const pages = found.pages.filter((u) => !visited.has(u)).slice(0, seed.maxPages ?? maxPages);
    for (const url of feeds) {
      visited.add(url);
      const pre = fetcher.precheck(url);
      if (pre) {
        errors.push({ sourceKey: run.key, url: redactUrl(url), reason: pre });
        continue;
      }
      const fr = await fetcher.get(url);
      if (!fr.ok) {
        fail(run.key, fr);
        continue;
      }
      fetched++;
      readFeed(run, fr, `f${shortHash(url, 8)}:`);
    }
    for (const url of pages) {
      visited.add(url);
      const pre = fetcher.precheck(url);
      if (pre) {
        errors.push({ sourceKey: run.key, url: redactUrl(url), reason: pre });
        continue;
      }
      const pr = await fetcher.get(url);
      if (!pr.ok) {
        fail(run.key, pr);
        continue;
      }
      fetched++;
      readPage(run, pr, false);
    }
  };

  // API adapters: one source per adapter per region.
  const apiRuns: { run: SourceRun; adapter: ApiAdapter; key: string; region: Region }[] = [];
  for (const { adapter, key } of enabledAdapters(env, opts.adapters)) {
    for (const region of opts.regions) {
      apiRuns.push({
        adapter,
        key,
        region,
        run: {
          key: `${adapter.id}-${region.id}`,
          name: adapter.name,
          attribution: adapter.attribution,
          regionId: region.id,
          region,
          order: order++,
          raws: [],
        },
      });
    }
  }
  const runApi = async ({ run, adapter, key, region }: (typeof apiRuns)[number]) => {
    let url: string | null = adapter.firstUrl(region, { start: windowStart, end: windowEnd }, key);
    while (url) {
      const current: string = url;
      const res = await fetcher.get(current, { api: true, accept: "application/json" });
      if (!res.ok) return fail(run.key, res);
      fetched++;
      try {
        const page = adapter.parse(res.body, current);
        for (const raw of page.events) run.raws.push({ raw, idPrefix: "", fallbackUrl: null });
        url = page.next;
      } catch {
        errors.push({ sourceKey: run.key, url: redactUrl(current), reason: "bad_json" });
        return;
      }
    }
  };

  const concurrency = opts.concurrency ?? 4;
  await Promise.all([
    pool(seedRuns, concurrency, runSeed),
    pool(apiRuns, Math.max(1, Math.min(2, concurrency)), runApi),
  ]);

  // Normalize, then region and window filters, then dedupe across the run.
  const allRuns = [...seedRuns, ...apiRuns.map((a) => a.run)];
  const skipped = new Map<string, Record<string, number>>();
  const bump = (key: string, reason: string) => {
    const s = skipped.get(key) ?? {};
    s[reason] = (s[reason] ?? 0) + 1;
    skipped.set(key, s);
  };
  const candidates: Candidate[] = [];
  let rawCount = 0;
  for (const run of allRuns) {
    skipped.set(run.key, skipped.get(run.key) ?? {});
    const region = run.region;
    for (const { raw, idPrefix, fallbackUrl, snippetMax } of run.raws) {
      rawCount++;
      const res = normalize(raw, {
        region,
        attribution: run.attribution,
        fallbackUrl,
        idPrefix,
        imagesLicensed: run.seed?.imagesLicensed === true,
        hostOrg: run.seed?.host_org ?? null,
        extraCategories: run.seed?.categories,
        snippetMax,
      });
      if (!res.ok) {
        bump(run.key, res.reason);
        continue;
      }
      if (!inAnyRegion(res.item, opts.regions, region)) {
        bump(run.key, "outside_region");
        continue;
      }
      const w = windowReason(res.item, windowStart, windowEnd);
      if (w) {
        bump(run.key, w);
        continue;
      }
      candidates.push({ sourceKey: run.key, item: res.item, order: run.order });
    }
  }
  const { kept, dropped } = dedupe(candidates);
  for (const [key, n] of dropped) {
    const s = skipped.get(key) ?? {};
    s.duplicate_in_run = (s.duplicate_in_run ?? 0) + n;
    skipped.set(key, s);
  }

  const batches: SourceBatch[] = allRuns.map((run) => ({
    sourceKey: run.key,
    sourceName: run.name,
    attribution: run.attribution,
    regionId: run.regionId,
    items: kept.filter((c) => c.sourceKey === run.key).map((c) => c.item),
    skipped: skipped.get(run.key) ?? {},
  }));

  const totalSkipped: Record<string, number> = {};
  for (const s of skipped.values())
    for (const [k, v] of Object.entries(s)) totalSkipped[k] = (totalSkipped[k] ?? 0) + v;

  return {
    batches,
    errors,
    stats: {
      sources: allRuns.length,
      fetched,
      raw: rawCount,
      items: kept.length,
      skipped: totalSkipped,
      requestsByHost: Object.fromEntries(fetcher.requests),
    },
  };
}
