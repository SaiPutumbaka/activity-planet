// The only way the collector reaches the network (D-040 politeness rules):
//   - https only, port 443, public hosts only: every URL and every redirect hop is checked
//     against private and loopback addresses, the denylist and the login-page patterns before
//     it is requested, and the default transport re-checks every resolved address when the
//     connection opens (DNS rebinding),
//   - API-lane redirects may only land on another official API endpoint, and custom headers
//     never follow a redirect to another host,
//   - API responses are never cached (their URLs carry keys),
//   - robots.txt is read once per host per run (conditional GET across runs) and obeyed,
//   - at most one request per 2 seconds per host (longer when robots.txt sets Crawl-delay),
//   - an identifying User-Agent with a link to the bot page and no email,
//   - conditional GET (If-None-Match / If-Modified-Since) from the cache,
//   - a timeout per request and a cap on body size; anything bigger is abandoned.
// The transport, clock and sleep are injected, so tests run against fixtures with no network.

import { Agent, fetch as undiciFetch } from "undici";
import { Denylist } from "../policy/denylist.ts";
import { isLoginUrl } from "../policy/meta.ts";
import { ALLOW_ALL, DISALLOW_ALL, type Robots, robotsForStatus } from "../policy/robots.ts";
import { publicHostProblem, safeLookup } from "./address.ts";
import { type HttpCache, MemoryHttpCache } from "./cache.ts";

export const USER_AGENT = "ActivityPlanetBot/0.1 (+https://activity-planet.vercel.app/bot)";
export const MIN_INTERVAL_MS = 2000;
export const TIMEOUT_MS = 20_000;
export const MAX_BYTES = 3_000_000;
export const MAX_REDIRECTS = 5;
/** Crawl-delay above this is treated as "do not crawl this run" rather than waited out. */
export const MAX_CRAWL_DELAY_SEC = 60;

export type Transport = (url: string, init: RequestInit) => Promise<Response>;

export type FetchFailReason =
  | "not_https"
  | "private_address"
  | "denylisted"
  | "login_page"
  | "robots_disallowed"
  | "robots_unavailable"
  | "crawl_delay_too_long"
  | "http_error"
  | "auth_required"
  | "too_large"
  | "unsupported_type"
  | "too_many_redirects"
  | "timeout"
  | "network_error";

export type FetchResult =
  | {
      ok: true;
      url: string;
      status: number;
      contentType: string | null;
      xRobotsTag: string | null;
      body: string;
      notModified: boolean;
    }
  | { ok: false; url: string; reason: FetchFailReason; status?: number; detail?: string };

export interface FetchOptions {
  /** The API lane calling an official endpoint: denylist apiAllow applies and robots.txt does not. */
  api?: boolean;
  accept?: string;
  /** Request headers to add (never credentials in URLs that get logged). */
  headers?: Record<string, string>;
}

export interface FetcherOptions {
  denylist: Denylist;
  transport?: Transport;
  cache?: HttpCache;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  userAgent?: string;
  minIntervalMs?: number;
  timeoutMs?: number;
  maxBytes?: number;
}

const BINARY_TYPE =
  /^(image|video|audio|font)\/|^application\/(pdf|zip|octet-stream|x-gzip|gzip|vnd\.)/i;

export class PoliteFetcher {
  readonly userAgent: string;
  private readonly denylist: Denylist;
  private readonly transport: Transport;
  private readonly cache: HttpCache;
  private readonly now: () => number;
  private readonly sleep: (ms: number) => Promise<void>;
  private readonly minIntervalMs: number;
  private readonly timeoutMs: number;
  private readonly maxBytes: number;
  private readonly nextAt = new Map<string, number>();
  private readonly chains = new Map<string, Promise<void>>();
  private readonly robots = new Map<string, Promise<Robots>>();
  /** Requests actually sent, by host (tests and the run summary read it). */
  readonly requests = new Map<string, number>();

  constructor(opts: FetcherOptions) {
    this.denylist = opts.denylist;
    this.transport = opts.transport ?? defaultTransport();
    this.cache = opts.cache ?? new MemoryHttpCache();
    this.now = opts.now ?? (() => Date.now());
    this.sleep = opts.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.userAgent = opts.userAgent ?? USER_AGENT;
    this.minIntervalMs = opts.minIntervalMs ?? MIN_INTERVAL_MS;
    this.timeoutMs = opts.timeoutMs ?? TIMEOUT_MS;
    this.maxBytes = opts.maxBytes ?? MAX_BYTES;
  }

  /** Checks a URL against https, the denylist and login patterns without fetching it. */
  precheck(url: string, opts: FetchOptions = {}): FetchFailReason | null {
    let u: URL;
    try {
      u = new URL(url);
    } catch {
      return "not_https";
    }
    if (u.protocol !== "https:") return "not_https";
    if (publicHostProblem(u)) return "private_address";
    if (this.denylist.check(url, { allowApi: opts.api === true }).denied) return "denylisted";
    if (!opts.api && isLoginUrl(url)) return "login_page";
    return null;
  }

  async get(url: string, opts: FetchOptions = {}): Promise<FetchResult> {
    let current = url;
    let originalHost: string;
    try {
      originalHost = new URL(url).host;
    } catch {
      return { ok: false, url, reason: "not_https" };
    }
    for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
      const pre = this.precheck(current, opts);
      if (pre) return { ok: false, url: current, reason: pre };
      const host = new URL(current).host;
      // An API redirect may only land on another official endpoint (never on a web page).
      if (opts.api && hop > 0 && !this.denylist.isApiEndpoint(current)) {
        return { ok: false, url: current, reason: "http_error", detail: "api_redirect_off_api" };
      }
      // Custom headers (API keys and the like) are for the host they were meant for.
      const hopOpts = host === originalHost ? opts : { ...opts, headers: undefined };

      let interval = this.minIntervalMs;
      if (!opts.api) {
        const robots = await this.robotsFor(current);
        if (!robots.isAllowed(current)) {
          const reason = robots.unavailable ? "robots_unavailable" : "robots_disallowed";
          return { ok: false, url: current, reason };
        }
        if (robots.crawlDelaySec !== null) {
          if (robots.crawlDelaySec > MAX_CRAWL_DELAY_SEC) {
            return { ok: false, url: current, reason: "crawl_delay_too_long" };
          }
          interval = Math.max(interval, robots.crawlDelaySec * 1000);
        }
      }

      const res = await this.request(current, host, interval, hopOpts);
      if (!res.ok || res.redirect === null) return res.ok ? res.result : res;
      current = res.redirect;
    }
    return { ok: false, url: current, reason: "too_many_redirects" };
  }

  /** robots.txt for the URL's host, fetched once per run through the same politeness. */
  robotsFor(url: string): Promise<Robots> {
    const u = new URL(url);
    const key = `${u.protocol}//${u.host}`;
    let p = this.robots.get(key);
    if (!p) {
      p = (async () => {
        let target = `${key}/robots.txt`;
        for (let hop = 0; hop <= MAX_REDIRECTS; hop++) {
          if (
            !target.startsWith("https://") ||
            publicHostProblem(new URL(target)) ||
            this.denylist.check(target).denied
          )
            return DISALLOW_ALL;
          const res = await this.request(target, new URL(target).host, this.minIntervalMs, {
            accept: "text/plain",
          });
          // A status (4xx: no rules; 5xx: disallow) or a network failure (disallow).
          if (!res.ok)
            return res.status !== undefined ? robotsForStatus(res.status, "") : DISALLOW_ALL;
          if (res.redirect === null) return robotsForStatus(200, res.result.body);
          target = res.redirect;
        }
        // RFC 9309 2.3.1.2: after five redirects robots.txt counts as unavailable (4xx).
        return ALLOW_ALL;
      })();
      this.robots.set(key, p);
    }
    return p;
  }

  private async slot(host: string, intervalMs: number): Promise<void> {
    const prev = this.chains.get(host) ?? Promise.resolve();
    const mine = prev.then(async () => {
      const wait = (this.nextAt.get(host) ?? 0) - this.now();
      if (wait > 0) await this.sleep(wait);
      this.nextAt.set(host, this.now() + intervalMs);
    });
    this.chains.set(
      host,
      mine.catch(() => undefined),
    );
    await mine;
  }

  private async request(
    url: string,
    host: string,
    intervalMs: number,
    opts: FetchOptions,
  ): Promise<
    | { ok: true; redirect: string; result?: undefined }
    | { ok: true; redirect: null; result: Extract<FetchResult, { ok: true }> }
    | Extract<FetchResult, { ok: false }>
  > {
    await this.slot(host, intervalMs);
    // API URLs carry keys (apikey=, client_id=): they never reach the persisted cache.
    const cached = opts.api ? undefined : this.cache.get(url);
    const headers: Record<string, string> = {
      "user-agent": this.userAgent,
      accept:
        opts.accept ??
        "text/html,application/xhtml+xml,text/calendar,application/rss+xml,application/atom+xml,application/xml;q=0.9,application/json;q=0.9,*/*;q=0.5",
      ...opts.headers,
    };
    if (cached?.etag) headers["if-none-match"] = cached.etag;
    if (cached?.lastModified) headers["if-modified-since"] = cached.lastModified;

    this.requests.set(host, (this.requests.get(host) ?? 0) + 1);
    let response: Response;
    try {
      response = await this.transport(url, {
        method: "GET",
        headers,
        redirect: "manual",
        signal: AbortSignal.timeout(this.timeoutMs),
      });
    } catch (err) {
      const name = err instanceof Error ? err.name : "";
      return {
        ok: false,
        url,
        reason: name === "TimeoutError" || name === "AbortError" ? "timeout" : "network_error",
        detail: err instanceof Error ? err.message.slice(0, 200) : undefined,
      };
    }

    const status = response.status;
    if (status >= 300 && status < 400 && status !== 304) {
      const location = response.headers.get("location");
      await response.body?.cancel().catch(() => undefined);
      if (!location) return { ok: false, url, reason: "http_error", status };
      let next: string;
      try {
        next = new URL(location, url).toString();
      } catch {
        return { ok: false, url, reason: "http_error", status };
      }
      return { ok: true, redirect: next };
    }

    if (status === 304 && cached) {
      await response.body?.cancel().catch(() => undefined);
      return {
        ok: true,
        redirect: null,
        result: {
          ok: true,
          url,
          status: 304,
          contentType: cached.contentType,
          xRobotsTag: response.headers.get("x-robots-tag") ?? cached.xRobotsTag,
          body: cached.body,
          notModified: true,
        },
      };
    }

    if (status === 401 || status === 403 || status === 407) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: "auth_required", status };
    }
    if (status < 200 || status >= 300) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: "http_error", status };
    }

    const contentType = response.headers.get("content-type");
    if (contentType && BINARY_TYPE.test(contentType)) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: "unsupported_type", status };
    }
    const declared = Number(response.headers.get("content-length") ?? "");
    if (Number.isFinite(declared) && declared > this.maxBytes) {
      await response.body?.cancel().catch(() => undefined);
      return { ok: false, url, reason: "too_large", status };
    }

    let body: string;
    try {
      const read = await readCapped(response, this.maxBytes, contentType);
      if (read === null) return { ok: false, url, reason: "too_large", status };
      body = read;
    } catch (err) {
      const name = err instanceof Error ? err.name : "";
      return {
        ok: false,
        url,
        reason: name === "TimeoutError" || name === "AbortError" ? "timeout" : "network_error",
      };
    }

    const xRobotsTag = response.headers.get("x-robots-tag");
    if (!opts.api)
      this.cache.set({
        url,
        etag: response.headers.get("etag"),
        lastModified: response.headers.get("last-modified"),
        contentType,
        xRobotsTag,
        body,
        fetchedAt: this.now(),
      });
    return {
      ok: true,
      redirect: null,
      result: { ok: true, url, status, contentType, xRobotsTag, body, notModified: false },
    };
  }
}

/**
 * fetch over an undici Agent whose DNS lookup refuses non-public addresses. The check runs as
 * each connection opens, so it covers every redirect hop and a name that rebinds between the
 * precheck and the connect.
 */
export function defaultTransport(): Transport {
  const agent = new Agent({ connect: { lookup: safeLookup } });
  return async (url, init) =>
    (await undiciFetch(url, {
      ...(init as Parameters<typeof undiciFetch>[1]),
      dispatcher: agent,
    })) as unknown as Response;
}

/** The body as text, or null once it passes maxBytes (the rest is never downloaded). */
async function readCapped(
  response: Response,
  maxBytes: number,
  contentType: string | null,
): Promise<string | null> {
  const charset = /charset\s*=\s*"?([\w.:-]+)/i.exec(contentType ?? "")?.[1] ?? "utf-8";
  let decoder: TextDecoder;
  try {
    decoder = new TextDecoder(charset);
  } catch {
    decoder = new TextDecoder("utf-8");
  }
  if (!response.body) return "";
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      return null;
    }
    chunks.push(value);
  }
  const all = new Uint8Array(total);
  let offset = 0;
  for (const c of chunks) {
    all.set(c, offset);
    offset += c.byteLength;
  }
  return decoder.decode(all);
}
