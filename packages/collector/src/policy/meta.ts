// Page-level permissions: robots meta tags and X-Robots-Tag headers (noindex: read nothing
// from the page; nofollow: discover nothing from it; nosnippet: no excerpt; max-snippet:N: an
// excerpt of at most N characters), and login pages, which are never read.

import { BOT_TOKEN } from "./robots.ts";

export interface IndexDirectives {
  noindex: boolean;
  nofollow: boolean;
  nosnippet: boolean;
  /** max-snippet:N when N >= 0 (0 means no snippet); null when unlimited or unset. */
  maxSnippet: number | null;
}

function empty(): IndexDirectives {
  return { noindex: false, nofollow: false, nosnippet: false, maxSnippet: null };
}

/** Both sets apply: the stricter value of each directive wins. */
export function mergeDirectives(a: IndexDirectives, b: IndexDirectives): IndexDirectives {
  const limits = [a.maxSnippet, b.maxSnippet].filter((n): n is number => n !== null);
  return {
    noindex: a.noindex || b.noindex,
    nofollow: a.nofollow || b.nofollow,
    nosnippet: a.nosnippet || b.nosnippet,
    maxSnippet: limits.length ? Math.min(...limits) : null,
  };
}

/**
 * The longest excerpt the directives allow, given our own cap: 0 for nosnippet or
 * max-snippet:0, else the smaller of max-snippet and the cap.
 */
export function snippetLimit(d: IndexDirectives, cap: number): number {
  if (d.nosnippet) return 0;
  return d.maxSnippet === null ? cap : Math.min(cap, d.maxSnippet);
}

/** Directives from one robots meta content or X-Robots-Tag value ("noindex, nofollow", "none"). */
function parseDirectiveList(value: string, into: IndexDirectives): void {
  for (const raw of value.split(",")) {
    const d = raw.trim().toLowerCase();
    if (d === "noindex" || d === "none") into.noindex = true;
    if (d === "nofollow" || d === "none") into.nofollow = true;
    if (d === "nosnippet") into.nosnippet = true;
    const max = /^max-snippet\s*:\s*(-?\d+)$/.exec(d);
    if (max) {
      const n = Number(max[1]);
      if (n >= 0) into.maxSnippet = into.maxSnippet === null ? n : Math.min(into.maxSnippet, n);
    }
  }
}

/**
 * X-Robots-Tag values, possibly several headers joined with ", ". A value may start with a bot
 * name ("googlebot: noindex"); only ours and unprefixed ones apply.
 */
export function parseXRobotsTag(header: string | null | undefined): IndexDirectives {
  const out = empty();
  if (!header) return out;
  // Split on commas that start a new "agent:" section, keeping directive lists together.
  const sections = header.split(/,(?=\s*[A-Za-z0-9_-]+\s*:)/);
  for (const section of sections) {
    const m = /^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)$/.exec(section);
    if (
      m &&
      !/^(unavailable_after|max-snippet|max-image-preview|max-video-preview)$/i.test(m[1] ?? "")
    ) {
      const agent = (m[1] ?? "").toLowerCase();
      if (agent === BOT_TOKEN || agent === "*") parseDirectiveList(m[2] ?? "", out);
    } else {
      parseDirectiveList(section, out);
    }
  }
  return out;
}

/** Robots meta tags: name="robots" and name="activityplanetbot" apply; other bots' names do not. */
export function metaDirectives(metas: { name: string; content: string }[]): IndexDirectives {
  const out = empty();
  for (const m of metas) {
    const name = m.name.trim().toLowerCase();
    if (name === "robots" || name === BOT_TOKEN) parseDirectiveList(m.content, out);
  }
  return out;
}

const LOGIN_PATH =
  /(^|\/)(login|log-in|logon|signin|sign-in|sign_in|signup|sign-up|register|sso|saml|oauth2?|auth|authorize|cas\/login|account\/login|users\/sign_in|wp-login\.php|my-account)(\/|\.|$|\?)/i;
const LOGIN_QUERY = /[?&](returnurl|return_to|redirect_uri|redirect_to|next)=/i;

/** A URL that looks like a login, sign-up or SSO page. Never fetched, never followed. */
export function isLoginUrl(url: string): boolean {
  try {
    const u = new URL(url);
    if (/^(login|signin|sso|auth|accounts|idp|cas)\./i.test(u.hostname)) return true;
    return (
      LOGIN_PATH.test(u.pathname) ||
      (LOGIN_QUERY.test(u.search) && /log|sign|auth/i.test(u.pathname + u.search))
    );
  } catch {
    return true;
  }
}

/** A page whose content is a sign-in form: a password field, or a login-form marker. */
export function looksLikeLoginPage(html: string): boolean {
  return (
    /<input\b[^>]*\btype\s*=\s*["']?password\b/i.test(html) ||
    /<form\b[^>]*\b(id|name|class|action)\s*=\s*["'][^"']*(login|signin|sign-in|log-in)[^"']*["']/i.test(
      html,
    )
  );
}
