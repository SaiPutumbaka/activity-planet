// The discovery probe (design 6.2): reads one candidate site politely and says whether it has a
// public calendar the collector can read, and what kind.
//
//   1. robots.txt (the fetcher reads it once per host and obeys it).
//   2. The homepage: <link rel=alternate> calendar and RSS feeds, calendar export links,
//      schema.org Event markup, platform marks (The Events Calendar, Localist, Trumba, CivicPlus,
//      LibCal, Communico, Google Calendar embeds), and links whose path, host or link text names an
//      event page (keywords.ts, in the region's languages). Body text is never read.
//   3. Up to 3 such event pages on the same site (or a known calendar platform); the region's
//      guessed paths (/events/, /veranstaltungen/, ...) only when no link matched.
//   4. Localist is never read automatically (the vendor says API use is licensed): the result is
//      needs_permission. Otherwise the best seed (a calendar-wide feed, then a page with event
//      markup, then the event pages) is read once through collect(), with the same politeness,
//      noindex and window rules as a nightly run, until one gives items inside the region.
//   5. The result: outcome, kind (ics, rss, page), URL, platform, items, items inside the region,
//      requests, errors, and the score (design 6.3).
// At most `requestsPerHostPerProbe` requests (8) go to one host in one probe, robots.txt included.

import { collect } from "../collect.ts";
import { detectBodyType, looksLikeChallenge } from "../diagnose.ts";
import type { Fetcher, FetchOptions, FetchResult, PoliteFetcher } from "../net/fetcher.ts";
import { discoverLinks, scanHtml, type PageScan } from "../parse/html.ts";
import { classifyLink, isActionPath, isPerEventExport } from "../parse/links.ts";
import { jsonLdEvents, schemaEvents } from "../parse/schema.ts";
import { mergeDirectives, metaDirectives, parseXRobotsTag } from "../policy/meta.ts";
import { isGap } from "../sources.ts";
import type { Region, Seed } from "../types.ts";
import { haversineKm } from "../util/geo.ts";
import { fetchableUrl, hostOf, shortHash, siteOf } from "../util/url.ts";
import { cheapScore } from "./candidates.ts";
import { guessedPaths, keywordsFor, keywordStrength } from "./keywords.ts";

export type ProbeOutcome =
  | "ok"
  | "empty"
  | "no_feed"
  | "error"
  | "blocked"
  | "robots"
  | "noindex"
  | "needs_permission"
  | "denylisted";

export interface ProbeInput {
  /** source_candidates.id when the candidate came from the database. */
  id?: string;
  url: string;
  host: string;
  origin: string;
  name?: string | null;
  place_kind?: string | null;
  wikidata_id?: string | null;
  country?: string | null;
  score?: number;
  places?: number;
  extra_urls?: string[];
}

export interface ProbeResult {
  candidate: ProbeInput;
  outcome: ProbeOutcome;
  kind: "ics" | "rss" | "page" | null;
  url: string | null;
  platform: string | null;
  platforms: string[];
  items: number;
  in_region: number;
  requests: number;
  errors: number;
  complete: boolean;
  /** The run deadline came before the probe finished: not recorded, retried next night. */
  deadline: boolean;
  score: number;
  /** Fixed words for the log: what the probe saw (no page text). */
  notes: string[];
  /** Each request: host and path, status or failure reason (no page text). */
  trace: string[];
}

export interface ProbeContext {
  fetcher: PoliteFetcher | Fetcher;
  region: Region;
  now: Date;
  windowDays?: number;
  /** Requests per host per probe, robots.txt included (default 8). */
  requestsPerHost?: number;
  /** Event pages after the homepage (default 3). */
  eventPages?: number;
}

/**
 * Calendar platforms whose pages are read from another host than the candidate's own. Localist is
 * not one: its calendars are never read automatically (needs_permission).
 */
const PLATFORM_HOSTS = /(?:^|\.)(?:trumba\.com|libcal\.com|libnet\.info|calendar\.google\.com)$/i;

const MARKS: [string, RegExp][] = [
  ["tec", /tribe-events|the-events-calendar|tec-api-version|\/wp-json\/tribe\/events\//i],
  [
    "localist",
    /(?:src|href|content|action)\s*=\s*["'][^"']*\blocalist\b[^"']*["']|(?:powered by|software by|calendar by)\s*(?:<[^>]+>\s*)*localist\b|LocalistWidget|localist-widget/i,
  ],
  ["trumba", /\$Trumba\.addSpud|trumba\.com\/(?:calendars|scripts)\//i],
  ["civicplus", /civicplus|civicengage|\/(?:i)?Calendar\.aspx\b/i],
  ["libcal", /[a-z0-9-]+\.libcal\.com/i],
  ["communico", /[a-z0-9-]+\.libnet\.info|communico/i],
  ["gcal", /calendar\.google\.com\/calendar\/(?:embed|ical)/i],
];

/** Platform marks in a page (markup and URLs only). */
export function platformsIn(body: string): string[] {
  return MARKS.filter(([, re]) => re.test(body)).map(([n]) => n);
}

/** Trumba's public feed for a spud's web name (trumba.com/calendars/<name>.ics). */
export function trumbaFeeds(body: string): string[] {
  const out = new Set<string>();
  for (const m of body.matchAll(
    /\$Trumba\.addSpud\(\s*\{[^}]*?webName\s*:\s*["']([A-Za-z0-9._-]{1,80})["']/g,
  ))
    out.add(`https://www.trumba.com/calendars/${m[1]}.ics`);
  return [...out];
}

/** Public ICS feeds of Google Calendar embeds (iframes are not anchors, so scanHtml misses them). */
export function googleEmbedFeeds(body: string): string[] {
  const out = new Set<string>();
  for (const m of body.matchAll(
    /https:\/\/calendar\.google\.com\/calendar\/embed\?[^"'\s<>]{1,1000}/g,
  )) {
    const c = classifyLink(m[0].replace(/&amp;/g, "&"));
    if (c.kind === "feed") for (const u of c.urls) out.add(u);
  }
  return [...out];
}

/** The calendar root of The Events Calendar from its head links (…/events/?ical=1). */
export function tecRoots(scan: PageScan): string[] {
  const out = new Set<string>();
  for (const l of scan.links) {
    if (!l.rel.includes("alternate") || l.type !== "text/calendar") continue;
    const u = fetchableUrl(l.href, scan.baseUrl);
    if (!u) continue;
    const x = new URL(u);
    if (x.searchParams.get("ical") !== "1") continue;
    x.search = "";
    out.add(x.toString());
  }
  return [...out];
}

/**
 * One probe's view of the shared fetcher: the same per-host spacing, robots.txt and run deadline
 * (it is the same PoliteFetcher), plus a cap on this probe's requests per host and a memory of
 * the pages it already read, so collect() never asks twice.
 */
export class ProbeFetcher implements Fetcher {
  private readonly memo = new Map<string, Promise<FetchResult>>();
  /** The shared fetcher's per-host counts when this probe started. */
  private readonly start: Map<string, number>;
  readonly pages = new Map<string, { body: string; type: string; xRobotsTag: string | null }>();
  gaps = 0;
  /** Hosts this probe asked for (and landed on), for its request count. */
  private readonly touched = new Set<string>();
  /** One line per request (host, path, status or failure): for the gate's log of public sites. */
  readonly trace: string[] = [];
  deadline = false;

  private readonly inner: PoliteFetcher | Fetcher;
  private readonly cap: number;

  constructor(inner: PoliteFetcher | Fetcher, cap: number) {
    this.inner = inner;
    this.cap = cap;
    this.start = new Map(inner.requests);
  }

  get requests(): Map<string, number> {
    return this.inner.requests;
  }

  /** Requests this probe sent, robots.txt and redirect hops included. */
  get sent(): number {
    let n = 0;
    for (const h of this.touched) n += (this.inner.requests.get(h) ?? 0) - (this.start.get(h) ?? 0);
    return n;
  }

  precheck(url: string, opts?: FetchOptions) {
    return this.inner.precheck(url, opts);
  }

  robotsVerdict(url: string): string {
    return this.inner.robotsVerdict(url);
  }

  get(url: string, opts: FetchOptions = {}): Promise<FetchResult> {
    const key = url.replace(/#.*$/, "");
    const hit = this.memo.get(key);
    if (hit) return hit;
    const p = this.fetch(key, opts);
    this.memo.set(key, p);
    return p;
  }

  private async fetch(url: string, opts: FetchOptions): Promise<FetchResult> {
    const host = hostOf(url);
    const used = this.inner.requests.get(host) ?? 0;
    const start = this.start.get(host) ?? 0;
    // This probe's requests to the host so far, robots.txt and redirect hops included.
    if (used - start >= this.cap) return { ok: false, url, reason: "host_budget_spent" };
    this.touched.add(host);
    const sentBefore = this.sent;
    const res = await this.inner.get(url, opts);
    this.touched.add(hostOf(res.url));
    if (this.trace.length < 40) {
      let path = res.url;
      try {
        const u = new URL(res.url);
        path = `${u.host}${u.pathname}${u.search ? "?…" : ""}`.slice(0, 100);
      } catch {
        // keep the raw string
      }
      this.trace.push(
        `${path} ${res.ok ? res.status : `${res.reason}${res.status ? `:${res.status}` : ""}`} requests=${this.sent - sentBefore}`,
      );
    }
    if (!res.ok) {
      if (res.reason === "run_deadline") this.deadline = true;
      else if (res.reason !== "host_budget_spent" && isGap(res.reason, res.status, false))
        this.gaps++;
    } else {
      const type = detectBodyType(res.body, res.contentType);
      this.pages.set(res.url, { body: res.body, type, xRobotsTag: res.xRobotsTag });
    }
    return res;
  }
}

/**
 * The shared fetcher's per-host allowance for a probe run: each candidate host may get
 * `perHost` requests in the whole run (robots.txt and redirects included), which is the design's
 * 8 a probe because the run probes each host once. Calendar platforms that many candidates share
 * (Trumba, LibCal, Communico, Localist, Google Calendar) and Wikidata keep the fetcher's default.
 */
export function probeHostAllowance(perHost: number): (host: string) => number | undefined {
  return (host) =>
    /(?:^|\.)(?:trumba\.com|libcal\.com|libnet\.info|localist\.com|google\.com|wikidata\.org)$/i.test(
      host,
    )
      ? undefined
      : perHost;
}

function failOutcome(res: Extract<FetchResult, { ok: false }>): ProbeOutcome {
  switch (res.reason) {
    case "robots_disallowed":
    case "robots_unavailable":
      return "robots";
    case "auth_required":
    case "login_page":
      return "blocked";
    case "denylisted":
      return "denylisted";
    default:
      return "error";
  }
}

/** The design 6.3 score after a probe, 0 to 100. */
export function probeScore(
  c: ProbeInput,
  s: {
    feedEvents: boolean;
    platform: boolean;
    jsonLdEvents: number;
    items: number;
    inRegion: number;
  },
): number {
  let score = cheapScore({
    place_kind: c.place_kind ?? undefined,
    wikidata_id: c.wikidata_id ?? undefined,
    places: c.places ?? 1,
    extra_urls: c.extra_urls,
  });
  if (s.feedEvents) score += 50;
  if (s.platform) score += 30;
  if (s.jsonLdEvents >= 3) score += 40;
  if (s.items > 0 && s.inRegion * 2 < s.items) score -= 30;
  return Math.max(0, Math.min(100, Math.round(score)));
}

/** A calendar export (ICS, webcal, The Events Calendar's ?ical=1, CivicPlus, Trumba, Google). */
export function isCalendarExport(url: string): boolean {
  return /\.ics(?:$|[?#])|[?&](?:ical|ics|outlook-ical)=1\b|iCalendar\.aspx|\/ical\/|format=ical/i.test(
    url,
  );
}

const FILE_PATH = /\.(pdf|jpe?g|png|gif|svg|webp|docx?|xlsx?|pptx?|zip|mp[34]|mov)$/i;

interface Seen {
  url: string;
  scan: PageScan;
  body: string;
  noindex: boolean;
  nofollow: boolean;
  events: number;
}

export async function probe(c: ProbeInput, ctx: ProbeContext): Promise<ProbeResult> {
  const cap = Math.max(2, Math.min(8, ctx.requestsPerHost ?? 8));
  const pf = new ProbeFetcher(ctx.fetcher, cap);
  const region = ctx.region;
  const keywords = keywordsFor(c.country ?? null);
  const notes: string[] = [];
  const platforms = new Set<string>();
  const result = (
    outcome: ProbeOutcome,
    extra: Partial<ProbeResult> = {},
    signals = { feedEvents: false, jsonLdEvents: 0 },
  ): ProbeResult => {
    const items = extra.items ?? 0;
    const inRegion = extra.in_region ?? 0;
    return {
      candidate: c,
      outcome,
      kind: null,
      url: null,
      platform: null,
      platforms: [...platforms].sort(),
      items,
      in_region: inRegion,
      requests: pf.sent,
      errors: pf.gaps,
      complete: !pf.deadline,
      deadline: pf.deadline,
      notes,
      trace: pf.trace,
      ...extra,
      score: probeScore(c, {
        ...signals,
        platform: platforms.size > 0,
        items,
        inRegion,
      }),
    };
  };

  const read = async (url: string): Promise<Seen | Extract<FetchResult, { ok: false }> | null> => {
    const res = await pf.get(url);
    if (!res.ok) return res;
    const type = detectBodyType(res.body, res.contentType);
    if (type !== "html") return null;
    const scan = scanHtml(res.body, res.url);
    const d = mergeDirectives(parseXRobotsTag(res.xRobotsTag), metaDirectives(scan.metas));
    for (const p of platformsIn(res.body)) platforms.add(p);
    const events =
      jsonLdEvents(scan.jsonLd, { pageUrl: res.url }).length +
      schemaEvents(scan.microdata, { pageUrl: res.url }).length;
    return { url: res.url, scan, body: res.body, noindex: d.noindex, nofollow: d.nofollow, events };
  };

  // 2. The homepage.
  const home = await read(c.url);
  if (home === null) {
    notes.push("home_not_html");
    return result("no_feed");
  }
  if ("ok" in home) {
    notes.push(`home_${home.reason}`);
    return result(home.reason === "run_deadline" ? "error" : failOutcome(home));
  }
  if (looksLikeChallenge(home.body)) {
    notes.push("home_challenge");
    return result("blocked");
  }
  if (home.noindex) {
    notes.push("home_noindex");
    return result("noindex");
  }
  // Localist: never automatic. When the homepage itself carries its mark, nothing else is read.
  if (platforms.has("localist")) {
    notes.push("localist", "localist_home");
    return result("needs_permission", {
      platform: "localist",
      url: `${new URL(home.url).origin}/`,
      kind: "page",
    });
  }
  const homeSite = siteOf(hostOf(home.url));
  const sameSite = (u: string) => siteOf(hostOf(u)) === homeSite || PLATFORM_HOSTS.test(hostOf(u));

  // 3. Event pages: links that name one (path, host, then link text), the place's own deeper
  //    link, The Events Calendar's root, CivicPlus's iCalendar page; guesses only when none.
  const ranked = new Map<string, number>();
  const offer = (u: string | null, strength: number) => {
    if (!u) return;
    const clean = u.replace(/#.*$/, "");
    if (clean === home.url || clean === c.url || isActionPath(clean)) return;
    let path: string;
    try {
      path = new URL(clean).pathname;
    } catch {
      return;
    }
    if (FILE_PATH.test(path)) return;
    ranked.set(clean, Math.max(ranked.get(clean) ?? 0, strength));
  };
  for (const u of c.extra_urls ?? []) {
    const f = fetchableUrl(u);
    if (f && keywordStrength(f, "", keywords) > 0) offer(f, 4);
  }
  for (const r of tecRoots(home.scan)) offer(r, 5);
  if (platforms.has("civicplus")) offer(new URL("/iCalendar.aspx", home.url).toString(), 5);
  if (!home.nofollow) {
    for (const a of home.scan.anchors) {
      if (a.rel.includes("nofollow")) continue;
      const u = fetchableUrl(a.href, home.scan.baseUrl);
      if (!u || !sameSite(u)) continue;
      if (classifyLink(u).kind !== "other") continue;
      const s = keywordStrength(u, a.text, keywords);
      if (s > 0) offer(u, s);
    }
  } else notes.push("home_nofollow");
  const depth = (u: string) => new URL(u).pathname.split("/").filter(Boolean).length;
  let pages = [...ranked.entries()]
    .sort((a, b) => b[1] - a[1] || depth(a[0]) - depth(b[0]) || a[0].localeCompare(b[0]))
    .map(([u]) => u);
  // A calendar platform's own root (The Events Calendar, CivicPlus) is the calendar: read it and
  // at most the place's own events link, and keep the rest of the 8 requests for its events.
  const roots = [...ranked.entries()].filter(([, v]) => v >= 5).map(([u]) => u);
  if (roots.length > 0)
    pages = [
      ...roots.slice(0, 1),
      ...[...ranked.entries()]
        .filter(([, v]) => v === 4)
        .map(([u]) => u)
        .slice(0, 1),
    ];
  const guessed = pages.length === 0;
  if (guessed) pages = guessedPaths(c.country).map((p) => new URL(p, home.url).toString());
  pages = pages.slice(0, Math.max(0, Math.min(3, ctx.eventPages ?? 3)));
  notes.push(`event_pages=${pages.length}${guessed ? " guessed" : ""}`);

  const seen: Seen[] = [home];
  let noindexPages = 0;
  for (const u of pages) {
    const r = await read(u);
    if (r && !("ok" in r)) {
      if (r.noindex) noindexPages++;
      else seen.push(r);
    }
    // A page that shows Localist's mark ends the reading: no further pages of a Localist site.
    if (platforms.has("localist")) break;
  }

  // 4. Localist: never automatic.
  if (platforms.has("localist")) {
    const at = seen.find((s) => platformsIn(s.body).includes("localist")) ?? home;
    notes.push("localist");
    return result("needs_permission", {
      platform: "localist",
      url: `${new URL(at.url).origin}/`,
      kind: "page",
    });
  }

  // Seeds to read, best first.
  const seeds: Seed[] = [];
  const add = (kind: Seed["kind"], url: string, discover = kind === "page") => {
    if (seeds.some((s) => s.url === url)) return;
    seeds.push({
      id: `probe-${shortHash(url, 10)}`,
      kind,
      url,
      name: (c.name ?? c.host).slice(0, 80).padEnd(2, "."),
      attribution: `Events from ${c.host} (discovery probe)`,
      discover,
      maxPages: 2,
    });
  };
  // A sample of The Events Calendar's event pages (below), one calendar export, then pages whose
  // own markup has events, then the event pages
  // (collect() follows their feeds, listing views and event links), then RSS feeds last: a
  // site's blog feed (/feed/) or a single event's feed rarely carries event times.
  const calendarFeeds: string[] = [];
  const rssFeeds: string[] = [];
  for (const s of seen) {
    const found = discoverLinks(s.scan, sameSite);
    const feeds = [...found.feeds, ...trumbaFeeds(s.body), ...googleEmbedFeeds(s.body)].filter(
      (u) => !isPerEventExport(u),
    );
    for (const f of feeds) {
      if (isCalendarExport(f)) calendarFeeds.push(f);
      else if (!/\/comments\/feed\/?$/i.test(new URL(f).pathname)) rssFeeds.push(f);
    }
  }
  // The Events Calendar: its exports often say noindex, and its list views can too, while each
  // single event page is indexable and carries one schema.org Event. Two of the calendar's own
  // event pages are the cheapest proof, so they go first; the source recorded is the calendar
  // page that links them, which the nightly run reads with its full budget (its export first,
  // as for any page seed).
  const reportAs = new Map<string, string>();
  if (platforms.has("tec")) {
    for (const s of seen.slice(1)) {
      const singles = discoverLinks(s.scan, sameSite).pages.filter((u) =>
        /\/events?\/[^/]+\/?$/i.test(new URL(u).pathname),
      );
      for (const u of singles.slice(0, 2)) {
        add("page", u, false);
        const seed = seeds[seeds.length - 1];
        if (seed && seed.url === u) reportAs.set(seed.id, s.url);
      }
      if (reportAs.size > 0) break;
    }
  }
  for (const f of calendarFeeds.slice(0, 1)) add("ics", f);
  for (const s of seen) if (s.events > 0) add("page", s.url);
  for (const s of seen.slice(1)) add("page", s.url);
  for (const f of calendarFeeds.slice(1)) add("ics", f);
  for (const f of rssFeeds) add("rss", f);
  const jsonLd = Math.max(0, ...seen.map((s) => s.events));
  if (seeds.length === 0) {
    notes.push(noindexPages > 0 ? "pages_noindex" : "nothing_found");
    return result(
      noindexPages > 0 ? "noindex" : "no_feed",
      {},
      { feedEvents: false, jsonLdEvents: jsonLd },
    );
  }

  // Read them, one at a time, until one gives items inside the region.
  let best: { seed: Seed; items: number; inRegion: number; type: string } | null = null;
  let anyNoindex = false;
  for (const seed of seeds.slice(0, 4)) {
    if (pf.deadline) break;
    const run = await collect({
      regions: [region],
      cities: [{ region, seeds: [seed] }],
      fetcher: pf,
      now: ctx.now,
      windowDays: ctx.windowDays ?? 60,
      maxPagesPerSeed: 2,
      maxFeedsPerSeed: 3,
      maxListingViews: 1,
      concurrency: 1,
      env: {},
      adapters: [],
    });
    const batch = run.batches.find((b) => b.sourceKey === seed.id);
    if (!batch) continue;
    let path: string;
    try {
      const su = new URL(seed.url);
      path =
        `${su.host === new URL(home.url).host ? "" : su.host}${su.pathname}${su.search ? "?…" : ""}`.slice(
          0,
          80,
        );
    } catch {
      path = "?";
    }
    notes.push(
      `seed ${seed.kind}:${path} items=${batch.items.length} errs=${Object.keys(batch.errors ?? {}).join(",") || "-"}`,
    );
    if (Object.keys(batch.errors ?? {}).some((k) => k === "noindex")) anyNoindex = true;
    let inRegion = 0;
    for (const it of batch.items) {
      if (it.lat === null || it.lng === null) inRegion++;
      else if (haversineKm(region.lat, region.lng, it.lat, it.lng) <= region.radiusKm) inRegion++;
    }
    const type = pf.pages.get(seed.url)?.type ?? "";
    if (!best || inRegion > best.inRegion)
      best = { seed, items: batch.items.length, inRegion, type };
    if (inRegion > 0) break;
  }
  const platform =
    ["tec", "trumba", "civicplus", "libcal", "communico", "gcal"].find((p) => platforms.has(p)) ??
    null;
  if (!best || best.items === 0) {
    notes.push(anyNoindex ? "read_noindex" : "read_empty");
    const outcome: ProbeOutcome = pf.deadline
      ? "error"
      : anyNoindex && !best?.items
        ? "noindex"
        : pf.gaps > 0
          ? "error"
          : "empty";
    return result(outcome, { platform }, { feedEvents: false, jsonLdEvents: jsonLd });
  }
  const kind: ProbeResult["kind"] =
    best.seed.kind === "page"
      ? "page"
      : best.type === "ics"
        ? "ics"
        : ["rss", "atom", "rdf"].includes(best.type)
          ? "rss"
          : best.seed.kind === "rss"
            ? "rss"
            : "ics";
  const sampledFrom = reportAs.get(best.seed.id);
  if (sampledFrom) notes.push("tec_event_page_sample");
  const feedEvents = kind !== "page" && best.inRegion > 0;
  notes.push(`read kind=${kind} items=${best.items} in_region=${best.inRegion}`);
  return result(
    best.inRegion > 0 ? "ok" : "empty",
    {
      kind,
      url: sampledFrom ?? best.seed.url,
      platform,
      items: best.items,
      in_region: best.inRegion,
      // The probe reads a sample within its request cap; failed requests are reported as
      // errors, and the database applies the under-20% rule to them (design 6.3).
      complete: !pf.deadline,
    },
    { feedEvents, jsonLdEvents: jsonLd },
  );
}
