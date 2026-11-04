import { createHash } from "node:crypto";

/** Only https links survive (events_external_url_format, events_cover_url_format); webcal:// reads as https://. */
export function httpsUrl(value: unknown, base?: string): string | null {
  if (typeof value !== "string") return null;
  const s = value.trim();
  if (!s) return null;
  try {
    const v = s.replace(/^webcals?:\/\//i, "https://");
    const u = base ? new URL(v, base) : new URL(v);
    return u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/**
 * A link to fetch: absolute, webcal:// read as https://, http:// upgraded to https:// (the
 * collector only fetches over TLS), fragment dropped. Null for mailto:, javascript: and junk.
 */
export function fetchableUrl(value: string, base?: string): string | null {
  try {
    // webcal: is not a "special" scheme, so URL will not switch it to https: in place.
    const v = value.trim().replace(/^webcals?:\/\//i, "https://");
    const u = base ? new URL(v, base) : new URL(v);
    if (u.protocol === "http:") u.protocol = "https:";
    if (u.protocol !== "https:") return null;
    u.hash = "";
    return u.toString();
  } catch {
    return null;
  }
}

export function hostOf(url: string): string {
  try {
    return new URL(url).hostname.toLowerCase();
  } catch {
    return "";
  }
}

/**
 * The site a host belongs to, close enough for "same site" checks without the public suffix
 * list: the last two labels, or three under a two-letter second-level suffix (co.uk, com.au).
 */
export function siteOf(host: string): string {
  const labels = host.toLowerCase().split(".").filter(Boolean);
  if (labels.length <= 2) return labels.join(".");
  const sld = labels[labels.length - 2] ?? "";
  const tld = labels[labels.length - 1] ?? "";
  const twoPart = tld.length === 2 && /^(co|com|org|net|gov|ac|edu)$/.test(sld);
  return labels.slice(twoPart ? -3 : -2).join(".");
}

export function shortHash(value: string, length = 12): string {
  return createHash("sha256").update(value).digest("hex").slice(0, length);
}
