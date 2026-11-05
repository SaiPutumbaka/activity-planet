// --diagnose: one line per request, saying why a source gave what it gave. The repository and
// its Action logs are public, so a line carries only request metadata and counts: the source
// id, the URL with secret-looking query values redacted, the HTTP status, the host the
// redirects ended on, the media type, the body size, the robots.txt verdict and the parser's
// verdict (ics vevents=N events=N, rss items=N events=N, html no-event-markup, ...). Titles,
// descriptions and page text never reach it; every field is reduced to a fixed vocabulary or
// a number before it is printed.

import { redactUrl } from "./adapters/api.ts";

/** What a response body is, judged from its first bytes (and the media type as a last resort). */
export type BodyType = "ics" | "rss" | "atom" | "rdf" | "html" | "xml" | "json" | "text" | "empty";

const CALENDAR_TYPE = /text\/calendar|application\/calendar/i;

/**
 * Sniffs a body. A body that starts like an HTML page is "html" whatever the Content-Type says
 * (a feed URL answering with its events page, a bot challenge, an error page).
 */
export function detectBodyType(body: string, contentType: string | null = null): BodyType {
  const head = body.slice(0, 2000).replace(/^\uFEFF/, "");
  const start = head.trimStart();
  if (start === "") return "empty";
  if (/^BEGIN:VCALENDAR/i.test(start)) return "ics";
  if (start.startsWith("<")) {
    if (/<rss\b/i.test(head)) return "rss";
    if (/<feed\b[^>]*xmlns="http:\/\/www\.w3\.org\/2005\/Atom"/i.test(head)) return "atom";
    if (/<rdf:RDF\b/i.test(head)) return "rdf";
    if (/^<!doctype\s+html|<html[\s>]|<head[\s>]|<body[\s>]/i.test(head)) return "html";
    return "xml";
  }
  if (start.startsWith("{") || start.startsWith("[")) return "json";
  // Calendar servers that send a few header lines before BEGIN:VCALENDAR.
  if (CALENDAR_TYPE.test(contentType ?? "") && /BEGIN:VCALENDAR/i.test(head)) return "ics";
  return "text";
}

/** Whether a body type is a feed the feed lane reads. */
export function isFeedType(t: BodyType): t is "ics" | "rss" | "atom" | "rdf" {
  return t === "ics" || t === "rss" || t === "atom" || t === "rdf";
}

/**
 * A URL that names a feed export: The Events Calendar's ?ical=1, ics=1 and outlook-ical=1,
 * a .ics path, a CivicPlus iCalendar.aspx?catID= feed, format=ical. A response to one of these
 * that is not a feed is "not_a_feed" with the detected type. (A bare CivicPlus iCalendar.aspx
 * is the HTML page listing the feeds, not a feed.)
 */
export function expectsFeed(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  return (
    /[?&](?:ical|ics|outlook-ical)=1(?:&|$)/i.test(u.search) ||
    /\.ics$/i.test(u.pathname) ||
    (/\/iCalendar\.aspx$/i.test(u.pathname) && u.searchParams.has("catID")) ||
    /[?&]format=ical(?:&|$)/i.test(u.search)
  );
}

/** Query keys whose values are never printed. */
const SECRET_KEY =
  /(?:^|[_-])(?:key|apikey|api_key|token|secret|sig|signature|auth|password|passwd|pwd|session|sid|client_id|app_token|access|credential|code)(?:$|[_-])|^\$\$app_token$/i;
const MAX_URL = 200;

/**
 * Hosted calendar services whose feed paths name a person (a Google Calendar ICS path holds the
 * calendar's email address; Outlook, iCloud and Yahoo paths hold account or calendar ids).
 */
const PERSONAL_CALENDAR_HOST =
  /(?:^|\.)(?:calendar\.google\.com|outlook\.live\.com|outlook\.office365\.com|outlook\.office\.com|icloud\.com|calendar\.yahoo\.com|calendar\.proton\.me|calendar\.zoho\.com|fastmail\.com|user\.fm)$/i;

/** Seeds of organizer-connected feeds (migration 62: slug org-<12 hex>), submitted by members. */
export function isOrganizerSourceKey(sourceKey: string): boolean {
  return /^org-[0-9a-f]{12}(?:$|[^0-9a-f])/.test(sourceKey);
}

/**
 * The URL as it may appear in a public log: the API-key redaction, plus every query value
 * whose key looks like a secret, with no user info and no fragment, capped in length. With
 * hidePath (a member-submitted URL, such as an organizer-connected feed) or for a hosted
 * calendar service, only the scheme and host are kept: those paths can hold an email address.
 */
export function redactForLog(url: string, opts: { hidePath?: boolean } = {}): string {
  let u: URL;
  try {
    u = new URL(redactUrl(url));
  } catch {
    return "(bad url)";
  }
  if (opts.hidePath || PERSONAL_CALENDAR_HOST.test(u.hostname))
    return `${u.protocol}//${u.host}/_path_hidden_`;
  u.username = "";
  u.password = "";
  u.hash = "";
  for (const k of [...new Set(u.searchParams.keys())])
    if (SECRET_KEY.test(k)) u.searchParams.set(k, "REDACTED");
  const s = u.toString();
  return s.length > MAX_URL ? `${s.slice(0, MAX_URL)}...` : s;
}

/** The media type alone ("text/html"), or "other" when the header is not a plain media type. */
export function mediaType(contentType: string | null): string {
  if (!contentType) return "-";
  const t = contentType.split(";")[0]?.trim().toLowerCase() ?? "";
  return /^[a-z0-9.+-]{1,40}\/[a-z0-9.+-]{1,80}$/.test(t) ? t : "other";
}

export interface DiagnosticEntry {
  sourceKey: string;
  /** The URL the collector asked for. */
  url: string;
  /** null when the request was never sent (precheck) or failed before a response. */
  status: number | null;
  /** Where the redirects ended (or where the request failed); null when never requested. */
  finalUrl: string | null;
  contentType: string | null;
  /** Body size in bytes; null without a body. */
  bytes: number | null;
  /** robots.txt verdict for the final URL ("allow", "disallow", "n/a" for the API lane, ...). */
  robots: string;
  /** Parser verdict, built only from counts and fixed words (see verdict helpers in collect). */
  verdict: string;
  /** Served from the conditional-GET cache (304). */
  cached?: boolean;
}

/** A field value safe for one log line: fixed charset, no spaces or line breaks. */
function token(s: string): string {
  return s.replace(/[^\w.:/?&=%+@,-]/g, "_").slice(0, 240);
}

/** One line per request. The verdict comes last and may contain spaces. */
export function formatDiagnostic(e: DiagnosticEntry): string {
  let finalHost = "-";
  if (e.finalUrl) {
    try {
      finalHost = new URL(e.finalUrl).host;
    } catch {
      finalHost = "(bad url)";
    }
  }
  const status = e.status === null ? "-" : `${e.status}${e.cached ? "(cached)" : ""}`;
  const verdict = e.verdict.replace(/[^\w.:/=,() -]/g, "_").slice(0, 500);
  return [
    "[diagnose]",
    `source=${token(e.sourceKey)}`,
    `url=${token(redactForLog(e.url, { hidePath: isOrganizerSourceKey(e.sourceKey) }))}`,
    `status=${status}`,
    `final_host=${token(finalHost)}`,
    `type=${mediaType(e.contentType)}`,
    `bytes=${e.bytes === null ? "-" : String(e.bytes)}`,
    `robots=${token(e.robots)}`,
    `verdict=${verdict}`,
  ].join(" ");
}

/** Byte length of a decoded body, as UTF-8. */
export function byteSize(body: string): number {
  return Buffer.byteLength(body, "utf8");
}

/** @type names in JSON-LD blocks, for "html no-event-markup jsonld types=Organization,WebSite". */
export function jsonLdTypes(blocks: string[], max = 6): string[] {
  const out = new Set<string>();
  for (const b of blocks) {
    for (const m of b.matchAll(/"@type"\s*:\s*(?:"([A-Za-z]{1,40})"|\[([^\]]{0,400})\])/g)) {
      const names = m[1]
        ? [m[1]]
        : [...(m[2] ?? "").matchAll(/"([A-Za-z]{1,40})"/g)].map((x) => x[1]);
      for (const n of names) if (n) out.add(n);
      if (out.size >= max) return [...out];
    }
  }
  return [...out];
}

/**
 * Common bot-challenge and block pages (Cloudflare, Akamai, Sucuri, captchas). Matched on
 * markup markers only; nothing from the page is printed.
 */
export function looksLikeChallenge(body: string): boolean {
  const head = body.slice(0, 20_000);
  return /cf-chl|challenge-platform|cf_chl_opt|__cf_bm|_Incapsula_Resource|sucuri-firewall|g-recaptcha|h-captcha|<title>\s*(?:just a moment|attention required|access denied)/i.test(
    head,
  );
}

/**
 * Fixed markers that say what kind of page answered when it has no event markup (BeltLine's
 * list view in dry run 41860959049): the platform (WordPress, The Events Calendar and its REST
 * API, a JavaScript app shell), the hosts of iframes and of scripts loaded from other sites
 * (an embedded calendar widget), and anchor counts. Every value is a fixed word, a host name
 * or a number; no page text is printed.
 */
export function pageHints(body: string, pageUrl: string): string[] {
  const out: string[] = [];
  const marks: [string, RegExp][] = [
    ["wordpress", /\/wp-content\/|\/wp-includes\//i],
    ["tec", /tribe-events|tribe_events|the-events-calendar/i],
    ["tec-rest", /\/wp-json\/tribe\/events\/v1/i],
    ["wp-rest", /\/wp-json\//i],
    ["nextjs", /__NEXT_DATA__|\/_next\/static\//],
    ["nuxt", /__NUXT__|\/_nuxt\//],
    ["js-app-root", /<div[^>]+id=["'](?:root|app|__next|___gatsby)["'][^>]*>\s*<\/div>/i],
    ["noscript", /<noscript\b/i],
  ];
  for (const [name, re] of marks) if (re.test(body)) out.push(name);
  let own = "";
  try {
    own = new URL(pageUrl).host.replace(/^www\./, "");
  } catch {
    own = "";
  }
  const hosts = (re: RegExp, max: number): string[] => {
    const set = new Set<string>();
    for (const m of body.matchAll(re)) {
      try {
        const h = new URL(m[1] ?? "", pageUrl).host.toLowerCase();
        if (h && h.replace(/^www\./, "") !== own && /^[a-z0-9.-]{1,80}$/.test(h)) set.add(h);
      } catch {
        // not a URL
      }
      if (set.size >= max) break;
    }
    return [...set];
  };
  const frames = hosts(/<iframe\b[^>]*\bsrc=["']([^"']{1,500})["']/gi, 4);
  if (frames.length) out.push(`iframes=${frames.join(",")}`);
  const scripts = hosts(/<script\b[^>]*\bsrc=["']([^"']{1,500})["']/gi, 8);
  if (scripts.length) out.push(`script_hosts=${scripts.join(",")}`);
  let anchors = 0;
  let eventish = 0;
  for (const m of body.matchAll(/<a\b[^>]*\bhref=["']([^"']{1,500})["']/gi)) {
    anchors++;
    if (/\/events?\/[^/?#]+/i.test(m[1] ?? "")) eventish++;
    if (anchors >= 5000) break;
  }
  out.push(`anchors=${anchors}`, `event_path_anchors=${eventish}`);
  return out;
}
