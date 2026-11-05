// The denylist (D-040): domains whose terms forbid automated collection. Kept in
// data/denylist.json so adding a site is a data change. Every fetch, redirect hop and
// discovered link is checked; the only way onto a listed site is an official API endpoint in
// apiAllow, and only the API lane may use it.

import { readFileSync } from "node:fs";
import { siteOf } from "../util/url.ts";

export interface DenylistData {
  domains: { domain: string; reason?: string }[];
  anyTld: { name: string; reason?: string }[];
  apiAllow: { host: string; pathPrefix: string; reason?: string }[];
}

export interface DenyVerdict {
  denied: boolean;
  reason?: string;
  /** True when the URL is an allowed official API endpoint on a listed site. */
  api?: boolean;
}

/**
 * The database-only part of the denylist (GET /collector/denylist, migration 63): hosts removed on
 * an owner's request, and the slugs of sources switched off on request. Names only.
 */
export interface RemoteDenylist {
  entries: { name: string; match: "domain" | "any_tld" }[];
  sources: string[];
}

const NAME = /^[a-z0-9]([a-z0-9.-]{0,98}[a-z0-9])?$/;

/** Checks a GET /collector/denylist answer; anything malformed is dropped. */
export function parseRemoteDenylist(body: unknown): RemoteDenylist {
  const b = (body ?? {}) as { entries?: unknown; sources?: unknown };
  const entries: RemoteDenylist["entries"] = [];
  for (const e of Array.isArray(b.entries) ? b.entries : []) {
    const o = (e ?? {}) as Record<string, unknown>;
    if (
      typeof o.name === "string" &&
      NAME.test(o.name) &&
      (o.match === "domain" || o.match === "any_tld")
    )
      entries.push({ name: o.name, match: o.match });
  }
  const sources = (Array.isArray(b.sources) ? b.sources : []).filter(
    (s): s is string => typeof s === "string" && /^[a-z0-9]+(-[a-z0-9]+)*$/.test(s),
  );
  return { entries, sources };
}

export class Denylist {
  private readonly domains: { domain: string; reason: string }[];
  private readonly anyTld: { name: string; reason: string }[];
  private readonly apiAllow: { host: string; pathPrefix: string }[];

  constructor(data: DenylistData) {
    this.domains = data.domains.map((d) => ({
      domain: d.domain.toLowerCase().replace(/^\.+/, ""),
      reason: d.reason ?? "denylisted",
    }));
    this.anyTld = data.anyTld.map((d) => ({
      name: d.name.toLowerCase(),
      reason: d.reason ?? "denylisted",
    }));
    this.apiAllow = data.apiAllow.map((a) => ({
      host: a.host.toLowerCase(),
      pathPrefix: a.pathPrefix,
    }));
  }

  /**
   * Adds the database-only entries (an owner's removal request) to this list for the run, so a
   * host removed on request is refused at every hop, even when a city seed still names it.
   */
  merge(remote: RemoteDenylist): this {
    for (const e of remote.entries) {
      if (e.match === "domain" && !this.domains.some((d) => d.domain === e.name))
        this.domains.push({ domain: e.name, reason: "owner request" });
      if (e.match === "any_tld" && !this.anyTld.some((d) => d.name === e.name))
        this.anyTld.push({ name: e.name, reason: "owner request" });
    }
    return this;
  }

  static load(path = new URL("../../data/denylist.json", import.meta.url)): Denylist {
    return new Denylist(JSON.parse(readFileSync(path, "utf8")) as DenylistData);
  }

  /** Whether a host is on the list, ignoring API exceptions. */
  hostDenied(host: string): string | null {
    const h = host.toLowerCase().replace(/\.$/, "");
    for (const d of this.domains) {
      if (h === d.domain || h.endsWith(`.${d.domain}`)) return d.reason;
    }
    // "eventbrite.com", "www.eventbrite.co.uk", "eventbrite.events": the name is the site's
    // own label, second to last, or third to last under a two-part suffix (co.uk, com.au).
    const name = siteOf(h).split(".")[0] ?? "";
    for (const t of this.anyTld) {
      if (name === t.name) return t.reason;
    }
    return null;
  }

  /** Whether a URL is one of the official API endpoints in apiAllow. */
  isApiEndpoint(url: string): boolean {
    try {
      const u = new URL(url);
      const host = u.hostname.toLowerCase();
      return this.apiAllow.some((a) => a.host === host && u.pathname.startsWith(a.pathPrefix));
    } catch {
      return false;
    }
  }

  /** Verdict for a URL. allowApi: the caller is the API lane calling an official endpoint. */
  check(url: string, opts: { allowApi?: boolean } = {}): DenyVerdict {
    let u: URL;
    try {
      u = new URL(url);
    } catch {
      return { denied: true, reason: "bad_url" };
    }
    const host = u.hostname.toLowerCase();
    const isApi = this.apiAllow.some((a) => a.host === host && u.pathname.startsWith(a.pathPrefix));
    if (isApi)
      return opts.allowApi ? { denied: false, api: true } : { denied: true, reason: "api_only" };
    const reason = this.hostDenied(host);
    return reason ? { denied: true, reason } : { denied: false };
  }
}
