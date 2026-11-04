// One collector run: regions in, one SourceBatch per source out.
//   Lane 1  API adapters per region (only those whose key is set) and open-data seeds.
//   Lane 2  ICS and RSS/Atom seeds, Localist API seeds, plus feeds discovered on seed pages.
//           A page's own calendar-wide feed is preferred: when it yields events, single-event
//           exports and event pages are not crawled (unless the seed sets crawlPages).
//   Lane 3  schema.org Event JSON-LD and microdata on seed pages and on same-site event pages
//           linked from them (one level), honouring noindex, nofollow and X-Robots-Tag.
// Every request goes through the PoliteFetcher; every item through normalize() and the
// region, window and dedupe filters.

import { type ApiAdapter, enabledAdapters, redactUrl } from "./adapters/api.ts";
import { LOCALIST_MAX_PAGES, localistEventsUrl, parseLocalist } from "./adapters/localist.ts";
import { arcgisUrl, parseArcgis, parseSocrata, socrataUrl } from "./adapters/opendata.ts";
import { citiesFor } from "./config.ts";
import {
  byteSize,
  type DiagnosticEntry,
  detectBodyType,
  expectsFeed,
  isFeedType,
  jsonLdTypes,
  looksLikeChallenge,
} from "./diagnose.ts";
import { type Candidate, dedupe, inAnyRegion, windowReason } from "./filter.ts";
import type { FetchResult, PoliteFetcher } from "./net/fetcher.ts";
import { EXCERPT_MAX, normalize } from "./normalize.ts";
import { parseFeed } from "./parse/feed.ts";
import { discoverLinks, scanHtml, tecListViewsFor } from "./parse/html.ts";
import { parseIcs } from "./parse/ics.ts";
import { isPerEventExport } from "./parse/links.ts";
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
  /**
   * --diagnose: called once per request (and per URL the precheck refused) with request
   * metadata and the parser's verdict, never with item text (see diagnose.ts).
   */
  diagnose?: (entry: DiagnosticEntry) => void;
}

export interface SourceError {
  sourceKey: string;
  url: string;
  reason: string;
  status?: number;
  /** not_a_feed: what the body was instead (html, json, text, empty, ...). */
  detected?: string;
}

/** The summary key for an error: "not_a_feed:html", or the bare reason. */
export function errorKey(e: SourceError): string {
  return e.detected ? `${e.reason}:${e.detected}` : e.reason;
}

const count = (text: string, re: RegExp): number => text.match(re)?.length ?? 0;

/** Listing views (The Events Calendar's /list/, /month/, ?eventDisplay=list) read per seed. */
export const MAX_LISTING_VIEWS = 3;

/** Fetch failures that mean the host's or the run's budget is spent: the seed stops there. */
const BUDGET_STOP = new Set<string>(["host_budget_spent", "crawl_budget_spent", "run_deadline"]);

/** A URL as a coverage key: no fragment, no trailing slash. */
const urlKey = (u: string): string => u.replace(/#.*$/, "").replace(/\/+$/, "");

/** A single event's page (/event/<slug>/), as The Events Calendar and Localist lay them out. */
const isSingleEventPath = (u: string): boolean => {
  try {
    return /^\/event\/[^/]+\/?$/i.test(new URL(u).pathname);
  } catch {
    return false;
  }
};

interface PageRead {
  feeds: string[];
  pages: string[];
  listings: string[];
  /** Event URLs the page's own markup gave (their pages need not be fetched). */
  eventUrls: string[];
  verdict: string;
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
    /** Discovered links never followed (Google Calendar pages, action pages), by reason. */
    linksSkipped: Record<string, number>;
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
  const linksSkipped: Record<string, number> = {};
  let fetched = 0;

  /** One --diagnose line: `res` null when the precheck refused the URL before any request. */
  const diag = (
    sourceKey: string,
    url: string,
    res: FetchResult | null,
    verdict: string,
    api = false,
  ) => {
    if (!opts.diagnose) return;
    const finalUrl = res ? res.url : null;
    opts.diagnose({
      sourceKey,
      url,
      status: res ? (res.ok ? res.status : (res.status ?? null)) : null,
      finalUrl,
      contentType: res?.ok ? res.contentType : null,
      bytes: res?.ok ? byteSize(res.body) : null,
      robots: api ? "n/a" : finalUrl ? fetcher.robotsVerdict(finalUrl) : "unchecked",
      verdict,
      cached: res?.ok ? res.notModified : false,
    });
  };

  const fail = (
    sourceKey: string,
    res: Extract<FetchResult, { ok: false }>,
    requested: string = res.url,
    api = false,
  ) => {
    errors.push({ sourceKey, url: redactUrl(res.url), reason: res.reason, status: res.status });
    log(
      `skip ${sourceKey} ${redactUrl(res.url)}: ${res.reason}${res.status ? ` (${res.status})` : ""}`,
    );
    diag(sourceKey, requested, res, `fetch_failed reason=${res.reason}`, api);
  };

  /** A URL the precheck refused: recorded, and never requested. */
  const refused = (sourceKey: string, url: string, reason: string) => {
    errors.push({ sourceKey, url: redactUrl(url), reason });
    diag(sourceKey, url, null, `not_requested reason=${reason}`);
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

  /** Reads a feed into the run; returns how many events it gave and the parser's verdict. */
  const readFeed = (
    run: SourceRun,
    res: Extract<FetchResult, { ok: true }>,
    idPrefix: string,
  ): { events: number; verdict: string; noindex: boolean } => {
    const directives = parseXRobotsTag(res.xRobotsTag);
    if (directives.noindex) {
      errors.push({ sourceKey: run.key, url: redactUrl(res.url), reason: "noindex" });
      return { events: 0, verdict: "noindex (x-robots-tag)", noindex: true };
    }
    // Sniffed from the body: a feed URL that answers with an HTML page (a ?ical=1 export
    // turned off, a bot challenge, an error page sent as 200) is not a feed, whatever its
    // Content-Type says.
    const type = detectBodyType(res.body, res.contentType);
    let events: RawEvent[];
    let verdict: string;
    if (type === "ics") {
      events = parseIcs(res.body, {
        sourceUrl: res.url,
        defaultZone: zoneFor(run),
        windowStart,
        windowEnd,
      });
      verdict = `ics vevents=${count(res.body, /^BEGIN:VEVENT\b/gim)} events=${events.length}`;
    } else if (isFeedType(type)) {
      events = parseFeed(res.body, { sourceUrl: res.url });
      const items = count(res.body, /<item\b/gi) + count(res.body, /<entry\b/gi);
      verdict = `${type} items=${items} events=${events.length}`;
    } else {
      errors.push({
        sourceKey: run.key,
        url: redactUrl(res.url),
        reason: "not_a_feed",
        detected: type,
      });
      const challenge = type === "html" && looksLikeChallenge(res.body) ? " bot-challenge" : "";
      return { events: 0, verdict: `not_a_feed detected=${type}${challenge}`, noindex: false };
    }
    const fallback = run.seed?.kind === "page" ? run.seed.url : null;
    const snippetMax = snippetLimit(directives, EXCERPT_MAX);
    for (const raw of events) run.raws.push({ raw, idPrefix, fallbackUrl: fallback, snippetMax });
    return { events: events.length, verdict, noindex: false };
  };

  const readPage = (
    run: SourceRun,
    res: Extract<FetchResult, { ok: true }>,
    discover: boolean,
    requested: string = res.url,
  ): PageRead => {
    const type = detectBodyType(res.body, res.contentType);
    if (isFeedType(type)) {
      const { verdict } = readFeed(
        run,
        res,
        run.seed && res.url === run.seed.url ? "" : `f${shortHash(res.url, 8)}:`,
      );
      return { feeds: [], pages: [], listings: [], eventUrls: [], verdict };
    }
    const parts: string[] = [];
    // A feed export URL (?ical=1, .ics, iCalendar.aspx?catID=) that answered with a page.
    if (expectsFeed(requested) || expectsFeed(res.url)) {
      errors.push({
        sourceKey: run.key,
        url: redactUrl(res.url),
        reason: "not_a_feed",
        detected: type,
      });
      parts.push(`not_a_feed detected=${type}`);
    }
    parts.push(type);
    if (type === "html" && looksLikeChallenge(res.body)) parts.push("bot-challenge");
    const eventUrls: string[] = [];
    const done = (): PageRead => ({
      feeds: [],
      pages: [],
      listings: [],
      eventUrls,
      verdict: parts.join(" "),
    });
    const scan = scanHtml(res.body, res.url);
    if (scan.loginForm) {
      errors.push({ sourceKey: run.key, url: redactUrl(res.url), reason: "login_page" });
      parts.push("login-form");
      return done();
    }
    const directives = mergeDirectives(parseXRobotsTag(res.xRobotsTag), metaDirectives(scan.metas));
    const { noindex, nofollow } = directives;
    const snippetMax = snippetLimit(directives, EXCERPT_MAX);
    if (noindex) {
      errors.push({ sourceKey: run.key, url: redactUrl(res.url), reason: "noindex" });
      parts.push("noindex");
    } else {
      const ld = jsonLdEvents(scan.jsonLd, { pageUrl: res.url });
      const micro = schemaEvents(scan.microdata, { pageUrl: res.url });
      for (const raw of [...ld, ...micro]) {
        run.raws.push({ raw, idPrefix: "p:", fallbackUrl: res.url, snippetMax });
        if (raw.url) eventUrls.push(raw.url);
      }
      if (ld.length + micro.length === 0) {
        parts.push("no-event-markup", `jsonld blocks=${scan.jsonLd.length}`);
        const types = jsonLdTypes(scan.jsonLd);
        if (types.length > 0) parts.push(`types=${types.join(",")}`);
        parts.push(`microdata items=${scan.microdata.length}`);
      } else {
        parts.push(`jsonld events=${ld.length}`, `microdata events=${micro.length}`);
      }
    }
    if (!discover) return done();
    if (nofollow) {
      parts.push("nofollow");
      return done();
    }
    const site = siteOf(hostOf(res.url));
    const found = discoverLinks(scan, (u) => siteOf(hostOf(u)) === site);
    for (const [reason, n] of Object.entries(found.skipped))
      linksSkipped[reason] = (linksSkipped[reason] ?? 0) + (n ?? 0);
    parts.push(`feed links found=${found.feeds.length}`, `page links found=${found.pages.length}`);
    if (found.listings.length > 0) parts.push(`listing links found=${found.listings.length}`);
    return {
      feeds: found.feeds,
      pages: found.pages,
      listings: found.listings,
      eventUrls,
      verdict: parts.join(" "),
    };
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
      if (!res.ok) return fail(run.key, res, url);
      fetched++;
      try {
        const events =
          seed.kind === "socrata" ? parseSocrata(res.body, seed) : parseArcgis(res.body, seed);
        for (const raw of events) run.raws.push({ raw, idPrefix: "", fallbackUrl: null });
        diag(run.key, url, res, `${seed.kind} events=${events.length}`);
      } catch {
        errors.push({ sourceKey: run.key, url: redactUrl(url), reason: "bad_json" });
        diag(run.key, url, res, `bad_json detected=${detectBodyType(res.body, res.contentType)}`);
      }
      return;
    }

    let pageUrl = seed.url;
    if (seed.kind === "localist") {
      const days = Math.ceil((windowEnd.getTime() - windowStart.getTime()) / 86_400_000);
      let fallback = false;
      for (let page = 1; page <= LOCALIST_MAX_PAGES; page++) {
        const url = localistEventsUrl(seed, days, page);
        const res = await fetcher.get(url, { accept: "application/json" });
        if (!res.ok) {
          fail(run.key, res, url);
          // A calendar whose robots.txt keeps us off its API is read as a page instead
          // (schema.org markup and its own feed links), like any other calendar.
          fallback = page === 1 && res.reason === "robots_disallowed";
          break;
        }
        fetched++;
        const directives = parseXRobotsTag(res.xRobotsTag);
        if (directives.noindex) {
          errors.push({ sourceKey: run.key, url: redactUrl(url), reason: "noindex" });
          diag(run.key, url, res, "noindex (x-robots-tag)");
          return;
        }
        let parsed: ReturnType<typeof parseLocalist>;
        try {
          parsed = parseLocalist(res.body, url);
        } catch {
          errors.push({ sourceKey: run.key, url: redactUrl(url), reason: "bad_json" });
          diag(run.key, url, res, `bad_json detected=${detectBodyType(res.body, res.contentType)}`);
          return;
        }
        // nosnippet / max-snippet on the API response limit the excerpt like on any feed.
        const snippetMax = snippetLimit(directives, EXCERPT_MAX);
        for (const raw of parsed.events)
          run.raws.push({ raw, idPrefix: "", fallbackUrl: null, snippetMax });
        diag(
          run.key,
          url,
          res,
          `localist events=${parsed.events.length} page=${parsed.page}/${parsed.totalPages}`,
        );
        if (parsed.page >= parsed.totalPages || parsed.events.length === 0) return;
      }
      if (!fallback) return;
      pageUrl = `${new URL(seed.url).origin}/`;
    }

    visited.add(pageUrl);
    const res = await fetcher.get(pageUrl);
    if (!res.ok) return fail(run.key, res, pageUrl);
    fetched++;
    if (seed.kind === "ics" || seed.kind === "rss") {
      const read = readFeed(run, res, "");
      diag(run.key, pageUrl, res, read.verdict);
      // A calendar-wide The Events Calendar export that says noindex is not read. The
      // calendar's own HTML list view may still be indexable: read it (lane 3) instead, with
      // the same per-page noindex, nosnippet and nofollow checks.
      const views = read.noindex ? tecListViewsFor(pageUrl) : null;
      if (views) await crawlListings(run, seed, [views], [], new Set());
      return;
    }

    const found = readPage(run, res, seed.discover !== false, pageUrl);
    diag(run.key, pageUrl, res, found.verdict);
    const feeds = found.feeds.filter((u) => !visited.has(u)).slice(0, maxFeeds);
    // The source's own calendar-wide feed first; single-event exports and event pages are a
    // fallback for when it gives nothing.
    let feedEvents = 0;
    const noindexExports: string[] = [];
    for (const url of feeds) {
      if (feedEvents > 0 && isPerEventExport(url)) continue;
      visited.add(url);
      const pre = fetcher.precheck(url);
      if (pre) {
        refused(run.key, url, pre);
        continue;
      }
      const fr = await fetcher.get(url);
      if (!fr.ok) {
        fail(run.key, fr, url);
        if (BUDGET_STOP.has(fr.reason)) return;
        continue;
      }
      fetched++;
      const read = readFeed(run, fr, `f${shortHash(url, 8)}:`);
      diag(run.key, url, fr, read.verdict);
      if (read.noindex) noindexExports.push(url);
      if (!isPerEventExport(url)) feedEvents += read.events;
    }
    if (feedEvents > 0 && seed.crawlPages !== true) return;
    // No events from a feed (none offered, or noindex): the listing views the page links to,
    // or, for a The Events Calendar export skipped for noindex, its list view.
    const groups: string[][] = found.listings.map((u) => [u]);
    if (groups.length === 0) {
      for (const u of noindexExports) {
        const views = tecListViewsFor(u);
        if (views) {
          groups.push(views);
          break;
        }
      }
    }
    await crawlListings(run, seed, groups, found.pages, new Set(found.eventUrls.map(urlKey)));
  };

  /**
   * Lane 3 behind a listing: reads up to MAX_LISTING_VIEWS listing views (each group is one
   * view and its alternative addresses, tried in order while the previous one is missing),
   * then the event pages found on the seed page and those views, within the seed's page
   * budget. Event pages whose events the listings' own markup already gave are not fetched
   * (unless the seed sets crawlPages). A host or run budget that runs out ends the seed.
   */
  const crawlListings = async (
    run: SourceRun,
    seed: Seed,
    groups: string[][],
    seedPages: string[],
    covered: Set<string>,
  ) => {
    const pages: string[] = [...seedPages];
    let views = 0;
    groupLoop: for (const group of groups) {
      if (views >= MAX_LISTING_VIEWS) break;
      for (const url of group) {
        if (visited.has(url)) break;
        visited.add(url);
        const pre = fetcher.precheck(url);
        if (pre) {
          refused(run.key, url, pre);
          break;
        }
        const lr = await fetcher.get(url);
        if (!lr.ok) {
          fail(run.key, lr, url);
          if (BUDGET_STOP.has(lr.reason)) return;
          // A missing view: try the group's next address.
          if (lr.reason === "http_error" && lr.status === 404) continue;
          break;
        }
        fetched++;
        views++;
        const read = readPage(run, lr, seed.discover !== false, url);
        diag(run.key, url, lr, read.verdict);
        pages.push(...read.pages);
        for (const u of read.eventUrls) covered.add(urlKey(u));
        continue groupLoop;
      }
    }
    const crawlAll = seed.crawlPages === true;
    const todo = [...new Set(pages)]
      .filter((u) => !visited.has(u) && (crawlAll || !covered.has(urlKey(u))))
      // Single-event pages (/event/<slug>/) before category and other listing pages.
      .sort((a, b) => Number(isSingleEventPath(b)) - Number(isSingleEventPath(a)))
      .slice(0, seed.maxPages ?? maxPages);
    for (const url of todo) {
      visited.add(url);
      const pre = fetcher.precheck(url);
      if (pre) {
        refused(run.key, url, pre);
        continue;
      }
      const pr = await fetcher.get(url);
      if (!pr.ok) {
        fail(run.key, pr, url);
        if (BUDGET_STOP.has(pr.reason)) return;
        continue;
      }
      fetched++;
      diag(run.key, url, pr, readPage(run, pr, false, url).verdict);
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
      if (!res.ok) return fail(run.key, res, current, true);
      fetched++;
      try {
        const page = adapter.parse(res.body, current);
        for (const raw of page.events) run.raws.push({ raw, idPrefix: "", fallbackUrl: null });
        diag(run.key, current, res, `api events=${page.events.length}`, true);
        url = page.next;
      } catch {
        errors.push({ sourceKey: run.key, url: redactUrl(current), reason: "bad_json" });
        diag(
          run.key,
          current,
          res,
          `bad_json detected=${detectBodyType(res.body, res.contentType)}`,
          true,
        );
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

  const errorsBySource = new Map<string, Record<string, number>>();
  for (const e of errors) {
    const s = errorsBySource.get(e.sourceKey) ?? {};
    const k = errorKey(e);
    s[k] = (s[k] ?? 0) + 1;
    errorsBySource.set(e.sourceKey, s);
  }

  const batches: SourceBatch[] = allRuns.map((run) => ({
    sourceKey: run.key,
    sourceName: run.name,
    attribution: run.attribution,
    regionId: run.regionId,
    items: kept.filter((c) => c.sourceKey === run.key).map((c) => c.item),
    skipped: skipped.get(run.key) ?? {},
    errors: errorsBySource.get(run.key) ?? {},
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
      linksSkipped,
    },
  };
}
