// Organizer ownership checks (design 2.3, migration 62) that need the organizer's own site: the
// page token (a <meta name="activityplanet-verification" content="ap-verify-..."> on the claimed
// host's home page or source page, or the token in /.well-known/activityplanet-verification.txt)
// and the feed token (the token in a connected calendar's X-WR-CALDESC, X-WR-CALNAME or the
// DESCRIPTION of an upcoming event). DNS TXT proofs are checked by the organizer-verify Edge
// Function over DNS-over-HTTPS instead.
//
// Every request goes through the PoliteFetcher like any collector request (https only, public
// hosts only, the connect-time address check, the denylist, robots.txt, one request per 2 seconds
// per host, the 3 MB and 20 s caps). A claimed site whose robots.txt keeps the bot out is not
// read: the claim reports fetch_failed:robots_disallowed and the owner can use the DNS proof. At
// most 3 URLs a claim. A redirect to another host does not count: the token must be served by
// the claimed host (or, for a feed, by the feed's own host). A token inside an HTML comment or
// in page text is not a meta tag and does not count.

import type { Fetcher } from "./net/fetcher.ts";
import { scanHtml } from "./parse/html.ts";
import { parseComponents, unescapeText } from "./parse/ics.ts";

export const META_NAME = "activityplanet-verification";
export const MAX_URLS = 3;
const TOKEN = /^ap-verify-[a-z2-7]{24}$/;

export interface ClaimJob {
  claim_id: string;
  method: "meta" | "well_known" | "feed";
  host: string;
  token: string;
  urls: string[];
}

export interface ClaimResult {
  claim_id: string;
  outcome: "verified" | "token_not_found" | "fetch_failed";
  method?: "meta" | "well_known" | "feed";
  reason?: string;
}

const bare = (h: string) =>
  h
    .toLowerCase()
    .replace(/\.$/, "")
    .replace(/^www\./, "");

function hostOf(url: string): string {
  try {
    return bare(new URL(url).hostname);
  } catch {
    return "";
  }
}

/** The host a fetched page must come from: the claimed host or one of its subdomains. */
function sameHost(finalUrl: string, host: string): boolean {
  const h = hostOf(finalUrl);
  const want = bare(host);
  return h === want || h.endsWith(`.${want}`);
}

/** The token in a meta tag of the page (never in a comment, a script or the text). */
export function pageHasToken(html: string, token: string): boolean {
  const scan = scanHtml(html, "https://example.invalid/");
  return scan.metas.some((m) => m.name.toLowerCase() === META_NAME && m.content.trim() === token);
}

/** The token alone on a line (or as a whole word) of the .well-known file. */
export function wellKnownHasToken(text: string, token: string): boolean {
  return text.split(/\s+/).some((w) => w === token);
}

/** The token in the calendar's name or description, or in the description of an upcoming event. */
export function feedHasToken(ics: string, token: string, now: Date): boolean {
  const root = parseComponents(ics);
  const cal = root.children.find((c) => c.type === "VCALENDAR");
  if (!cal) return false;
  const has = (v: string) => unescapeText(v).includes(token);
  if (
    cal.props.some((p) => (p.name === "X-WR-CALDESC" || p.name === "X-WR-CALNAME") && has(p.value))
  )
    return true;
  const today = now.toISOString().slice(0, 10).replace(/-/g, "");
  for (const ev of cal.children) {
    if (ev.type !== "VEVENT") continue;
    const start = ev.props.find((p) => p.name === "DTSTART")?.value.slice(0, 8) ?? "";
    const rrule = ev.props.some((p) => p.name === "RRULE");
    if (!(start >= today || rrule)) continue;
    if (ev.props.some((p) => p.name === "DESCRIPTION" && has(p.value))) return true;
  }
  return false;
}

const reasonOf = (r: string) => r.replace(/[^a-z_]/g, "_").slice(0, 40);

export async function verifyClaim(
  job: ClaimJob,
  fetcher: Pick<Fetcher, "get">,
  now: Date = new Date(),
): Promise<ClaimResult> {
  if (!TOKEN.test(job.token))
    return { claim_id: job.claim_id, outcome: "fetch_failed", reason: "bad_token" };
  const urls = [...new Set(job.urls)].slice(0, MAX_URLS);
  let fetched = 0;
  let firstFail: string | null = null;
  for (const url of urls) {
    const expectHost = job.method === "feed" ? hostOf(url) : job.host;
    if (!sameHost(url, expectHost)) {
      firstFail ??= "other_host";
      continue;
    }
    const res = await fetcher.get(url, {
      accept:
        job.method === "feed" ? "text/calendar,*/*;q=0.5" : "text/html,text/plain;q=0.9,*/*;q=0.5",
    });
    if (!res.ok) {
      firstFail ??= reasonOf(res.reason);
      continue;
    }
    if (!sameHost(res.url, expectHost)) {
      firstFail ??= "redirect_other_host";
      continue;
    }
    fetched++;
    const wellKnown = /\/\.well-known\/activityplanet-verification\.txt$/.test(
      new URL(res.url).pathname,
    );
    if (job.method === "feed") {
      if (feedHasToken(res.body, job.token, now))
        return { claim_id: job.claim_id, outcome: "verified", method: "feed" };
    } else if (wellKnown) {
      if (wellKnownHasToken(res.body, job.token))
        return { claim_id: job.claim_id, outcome: "verified", method: "well_known" };
    } else if (pageHasToken(res.body, job.token)) {
      return { claim_id: job.claim_id, outcome: "verified", method: "meta" };
    }
  }
  if (fetched === 0)
    return { claim_id: job.claim_id, outcome: "fetch_failed", reason: firstFail ?? "no_url" };
  return { claim_id: job.claim_id, outcome: "token_not_found" };
}

/** Checks a GET /collector/claims/due answer; malformed entries are dropped. */
export function parseClaims(body: unknown): ClaimJob[] {
  const list = Array.isArray((body as { claims?: unknown })?.claims)
    ? (body as { claims: unknown[] }).claims
    : [];
  const out: ClaimJob[] = [];
  for (const e of list) {
    const o = (e ?? {}) as Record<string, unknown>;
    if (typeof o.claim_id !== "string" || !/^[0-9a-f-]{36}$/.test(o.claim_id)) continue;
    if (o.method !== "meta" && o.method !== "well_known" && o.method !== "feed") continue;
    if (typeof o.host !== "string" || typeof o.token !== "string" || !TOKEN.test(o.token)) continue;
    const urls = (Array.isArray(o.urls) ? o.urls : []).filter(
      (u): u is string => typeof u === "string" && u.startsWith("https://"),
    );
    out.push({ claim_id: o.claim_id, method: o.method, host: o.host, token: o.token, urls });
  }
  return out;
}
