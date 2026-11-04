// What a discovered link is, before anything fetches it:
//   - Google Calendar pages (render, embed, "add to calendar", subscribe links) are never
//     followed. A link that names a public calendar (cid=, src=) is turned into that
//     calendar's own public ICS address; a cid that wraps a feed on another site (webcal:,
//     https:) becomes that feed. Everything else on calendar.google.com is skipped.
//   - Other "add to calendar" buttons (Outlook, Yahoo) are skipped.
//   - Action pages (Localist /event/<slug>/confirm, /event/create, register, RSVP, edit,
//     sign-in and sign-up) are skipped: they are never event listings, and many sites
//     disallow them in robots.txt anyway, so following them only wastes requests.
// The caller still runs every resulting URL through the fetcher's checks (https, denylist,
// robots.txt, login patterns).

import { fetchableUrl } from "../util/url.ts";

export type LinkClass =
  { kind: "feed"; urls: string[] } | { kind: "skip"; reason: LinkSkipReason } | { kind: "other" };

export type LinkSkipReason = "calendar_action" | "google_calendar_page" | "action_page";

const GOOGLE_CAL_HOST = /^(calendar\.google\.com|www\.google\.com|google\.com)$/i;
const ADD_TO_CALENDAR_HOST =
  /^(outlook\.live\.com|outlook\.office(365)?\.com|calendar\.yahoo\.com|calendar\.aol\.com)$/i;
/** A Google Calendar id: an address (user@gmail.com, …@group.calendar.google.com). */
const CALENDAR_ID = /^[\w.%+-]+@[\w-]+(\.[\w-]+)+$/;

/** The public ICS address Google documents for a public calendar. */
export function googlePublicIcs(calendarId: string): string {
  return `https://calendar.google.com/calendar/ical/${encodeURIComponent(calendarId)}/public/basic.ics`;
}

function decodeBase64(value: string): string | null {
  const s = value.replace(/-/g, "+").replace(/_/g, "/").replace(/\s+/g, "");
  if (!/^[A-Za-z0-9+/]+=*$/.test(s)) return null;
  try {
    const text = Buffer.from(s, "base64").toString("utf8");
    // Base64 of a calendar id or URL is printable ASCII; anything else was not base64.
    return /^[\x21-\x7e]+$/.test(text) ? text : null;
  } catch {
    return null;
  }
}

/** A cid= or src= value: a calendar id, a feed URL, or base64 of either. */
function calendarTarget(value: string, depth: number): string | null {
  const v = value.trim();
  if (!v) return null;
  if (/^(webcals?|https?):\/\//i.test(v)) {
    const u = fetchableUrl(v);
    if (!u) return null;
    // A cid that points back into Google Calendar: resolve it once, never loop.
    if (GOOGLE_CAL_HOST.test(new URL(u).hostname)) {
      if (depth > 0) return null;
      const inner = classifyLink(u, undefined, depth + 1);
      return inner.kind === "feed" ? (inner.urls[0] ?? null) : null;
    }
    return u;
  }
  if (CALENDAR_ID.test(v)) return googlePublicIcs(v);
  const decoded = decodeBase64(v);
  if (decoded && decoded !== v) return calendarTarget(decoded, depth);
  return null;
}

function classifyGoogle(u: URL, depth: number): LinkClass {
  const path = u.pathname;
  // Already the public ICS export: the one Google Calendar URL the collector reads.
  const ical = /^\/calendar\/ical\/([^/]+)\/public\/(basic|full)\.ics$/i.exec(path);
  if (ical) return { kind: "feed", urls: [`https://calendar.google.com${path}`] };
  if (!path.startsWith("/calendar")) return { kind: "other" };
  if (/^template$/i.test(u.searchParams.get("action") ?? "") || /\/event\b/.test(path))
    return { kind: "skip", reason: "calendar_action" };
  const values = [...u.searchParams.getAll("cid"), ...u.searchParams.getAll("src")];
  const urls = [
    ...new Set(values.map((v) => calendarTarget(v, depth)).filter((x): x is string => x !== null)),
  ];
  if (urls.length > 0) return { kind: "feed", urls };
  return { kind: "skip", reason: "google_calendar_page" };
}

/**
 * Paths that are actions, not listings: Localist confirm/register/create pages, generic
 * create/submit/edit forms, and sign-in or sign-up pages.
 */
const ACTION_PATH =
  /\/(?:event|events)\/[^/]+\/(?:confirm|register|registration|rsvp|attend|attendees|edit|delete|invite|share|report|subscribe|flag|tickets\/new)(?:\/|$)|\/(?:event|events|calendar)\/(?:create|new|submit|add|suggest)(?:\/|$|\.)|\/(?:login|logout|signin|sign_in|sign-in|signup|sign_up|sign-up|register|auth|users\/sign_in|session|sessions)(?:\/|$|\.)/i;

/** True for an action page that never lists events (see ACTION_PATH). */
export function isActionPath(url: string): boolean {
  try {
    return ACTION_PATH.test(new URL(url).pathname);
  } catch {
    return false;
  }
}

/**
 * Classifies a link found on a page. `href` may be relative to `base`. Returns the feed URLs
 * a calendar link stands for, a skip reason, or "other" for links the caller judges itself.
 */
export function classifyLink(href: string, base?: string, depth = 0): LinkClass {
  const abs = fetchableUrl(href, base);
  if (!abs) return { kind: "other" };
  const u = new URL(abs);
  if (GOOGLE_CAL_HOST.test(u.hostname)) return classifyGoogle(u, depth);
  if (ADD_TO_CALENDAR_HOST.test(u.hostname)) return { kind: "skip", reason: "calendar_action" };
  if (ACTION_PATH.test(u.pathname)) return { kind: "skip", reason: "action_page" };
  return { kind: "other" };
}

/**
 * A single event's export (The Events Calendar's /event/<slug>/?ical=1, Localist's
 * /event/<slug>.ics): one event per request. Read only when the page offers no
 * calendar-wide feed that yields events.
 */
export function isPerEventExport(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  const isExport =
    /[?&](?:ical|ics|outlook-ical)=1\b/i.test(u.search) || /\.ics$/i.test(u.pathname);
  if (!isExport) return false;
  const segment = /\/events?\/([^/]+)/i.exec(u.pathname)?.[1]?.replace(/\.ics$/i, "");
  if (!segment) return false;
  return !LISTING_SEGMENT.test(segment);
}

/** Listing views and taxonomies under /events/ whose exports cover many events. */
const LISTING_SEGMENT =
  /^(?:list|month|week|day|today|upcoming|photo|map|feed|ical|calendar|category|tag|venue|organizer|series|\d{4}-\d{2}(?:-\d{2})?)$/i;
