// One pass over an HTML page for everything the collector may read from it: robots meta tags,
// <base href>, feed links (<link rel=alternate> and calendar anchors), event links, JSON-LD
// blocks and microdata items. Page text is never read beyond the schema.org fields the page
// itself marks up; no model reads it (D-040: no LLM extraction).

import { parseDocument } from "htmlparser2";
import type { ChildNode, Element } from "domhandler";
import { looksLikeLoginPage } from "../policy/meta.ts";
import { fetchableUrl } from "../util/url.ts";
import { classifyLink, isPerEventExport, type LinkSkipReason } from "./links.ts";

export interface PageLink {
  href: string;
  rel: string[];
  type: string | null;
  text: string;
  /** The element's class names (anchors only; used to spot The Events Calendar's event links). */
  classes?: string[];
}

/** A microdata item in JSON-LD shape: {"@type": "Event", name: "...", location: {...}}. */
export type MicroItem = Record<string, unknown>;

export interface PageScan {
  baseUrl: string;
  metas: { name: string; content: string }[];
  links: PageLink[];
  anchors: PageLink[];
  jsonLd: string[];
  microdata: MicroItem[];
  loginForm: boolean;
}

function isElement(n: ChildNode): n is Element {
  return n.type === "tag" || n.type === "script" || n.type === "style";
}

function textContent(n: ChildNode): string {
  if (n.type === "text") return (n as unknown as { data: string }).data;
  if (isElement(n)) {
    if (n.name === "script" || n.name === "style") return "";
    return n.children.map(textContent).join(" ");
  }
  return "";
}

function rawText(n: Element): string {
  return n.children
    .map((c) => (c.type === "text" ? (c as unknown as { data: string }).data : ""))
    .join("");
}

function attr(el: Element, name: string): string | null {
  const v = el.attribs[name];
  return v === undefined ? null : v;
}

function typeName(itemtype: string): string {
  const first = itemtype.trim().split(/\s+/)[0] ?? "";
  return first.replace(/^https?:\/\/(www\.)?schema\.org\//i, "").replace(/\/$/, "");
}

/** Microdata property value (HTML Living Standard, "values"). */
function propValue(el: Element, base: string): unknown {
  if (attr(el, "itemscope") !== null) return microItem(el, base);
  const content = attr(el, "content");
  if (content !== null) return content;
  switch (el.name) {
    case "a":
    case "area":
    case "link":
      return absolute(attr(el, "href"), base);
    case "img":
    case "audio":
    case "video":
    case "source":
    case "embed":
    case "iframe":
    case "track":
      return absolute(attr(el, "src"), base);
    case "object":
      return absolute(attr(el, "data"), base);
    case "data":
    case "meter":
      return attr(el, "value") ?? "";
    case "time":
      return attr(el, "datetime") ?? textContent(el).replace(/\s+/g, " ").trim();
    default:
      return textContent(el).replace(/\s+/g, " ").trim();
  }
}

function absolute(href: string | null, base: string): string {
  if (!href) return "";
  try {
    return new URL(href, base).toString();
  } catch {
    return href;
  }
}

function microItem(scope: Element, base: string): MicroItem {
  const item: MicroItem = {};
  const itemtype = attr(scope, "itemtype");
  if (itemtype) item["@type"] = typeName(itemtype);
  const itemid = attr(scope, "itemid");
  if (itemid) item["@id"] = itemid;
  const add = (name: string, value: unknown) => {
    const prev = item[name];
    if (prev === undefined) item[name] = value;
    else item[name] = Array.isArray(prev) ? [...prev, value] : [prev, value];
  };
  const walk = (nodes: ChildNode[]) => {
    for (const n of nodes) {
      if (!isElement(n)) continue;
      const props = attr(n, "itemprop");
      if (props) {
        const value = propValue(n, base);
        for (const p of props.trim().split(/\s+/)) add(p, value);
      }
      // A nested itemscope's own properties belong to it, not to this item.
      if (attr(n, "itemscope") === null) walk(n.children);
    }
  };
  walk(scope.children);
  return item;
}

export function scanHtml(html: string, pageUrl: string): PageScan {
  const doc = parseDocument(html, {
    lowerCaseTags: true,
    lowerCaseAttributeNames: true,
    decodeEntities: true,
  });
  const scan: PageScan = {
    baseUrl: pageUrl,
    metas: [],
    links: [],
    anchors: [],
    jsonLd: [],
    microdata: [],
    loginForm: looksLikeLoginPage(html),
  };
  const topScopes: Element[] = [];

  const walk = (nodes: ChildNode[], inScope: boolean) => {
    for (const n of nodes) {
      if (!isElement(n)) continue;
      switch (n.name) {
        case "base": {
          const href = attr(n, "href");
          const resolved = href ? fetchableUrl(href, pageUrl) : null;
          if (resolved) scan.baseUrl = resolved;
          break;
        }
        case "meta": {
          const name = attr(n, "name");
          const content = attr(n, "content");
          if (name && content !== null) scan.metas.push({ name, content });
          break;
        }
        case "link": {
          const href = attr(n, "href");
          if (href)
            scan.links.push({
              href,
              rel: (attr(n, "rel") ?? "").toLowerCase().split(/\s+/).filter(Boolean),
              type: attr(n, "type")?.toLowerCase().trim() ?? null,
              text: attr(n, "title") ?? "",
            });
          break;
        }
        case "a": {
          const href = attr(n, "href");
          if (href)
            scan.anchors.push({
              href,
              rel: (attr(n, "rel") ?? "").toLowerCase().split(/\s+/).filter(Boolean),
              type: attr(n, "type")?.toLowerCase().trim() ?? null,
              text: textContent(n).replace(/\s+/g, " ").trim().slice(0, 200),
              classes: (attr(n, "class") ?? "").split(/\s+/).filter(Boolean).slice(0, 20),
            });
          break;
        }
        case "script": {
          if ((attr(n, "type") ?? "").toLowerCase().trim() === "application/ld+json")
            scan.jsonLd.push(rawText(n));
          break;
        }
      }
      const scope = attr(n, "itemscope") !== null;
      if (scope && !inScope && attr(n, "itemprop") === null) topScopes.push(n);
      walk(n.children, inScope || scope);
    }
  };
  walk(doc.children, false);

  for (const s of topScopes) scan.microdata.push(microItem(s, scan.baseUrl));
  return scan;
}

const FEED_TYPES = new Set([
  "text/calendar",
  "application/calendar+xml",
  "application/rss+xml",
  "application/atom+xml",
]);

/**
 * Calendar export links: .ics, webcal:, The Events Calendar's ?ical=1, CivicPlus iCalendar
 * feeds, Localist and Drupal-style /rss and .rss links. A feed whose items carry no event
 * times yields nothing, so a news feed picked up here costs one request and no items.
 */
const CALENDAR_HREF =
  /^webcal:|\.ics(?:$|[?#])|[?&](?:ical|ics|outlook-ical)=1\b|\/iCalendar\.aspx\?[^#]*\bcatID=|\/RSSFeed\.aspx\?[^#]*\bmodID=58\b|\/calendar\.ics|\/events?\.ics|\/(?:events|calendar)\/(?:feed|rss|ical)\/?(?:$|[?#])|\.rss(?:$|[?#])|\/rss(?:\/|$|[?#])|[?&]format=(?:rss|ical)\b/i;

export interface DiscoveredLinks {
  /**
   * Feed URLs, best first: the page's own <link rel="alternate"> feeds, then calendar-wide
   * export links, then single-event exports (which the caller reads only as a fallback).
   */
  feeds: string[];
  pages: string[];
  /**
   * Same-site listing views of The Events Calendar (/events/list/, /events/month/,
   * ?eventDisplay=list): read only to find event pages when the source's feed gives nothing
   * (for example because the export says noindex). Never read as event pages themselves.
   */
  listings: string[];
  /** Links never followed, by reason (Google Calendar pages, add-to-calendar, action pages). */
  skipped: Partial<Record<LinkSkipReason, number>>;
}

/**
 * Feed and same-site event links on a page. rel=nofollow anchors are skipped; the caller skips
 * the whole page when it says nofollow. Google Calendar links become the calendar's public
 * ICS (or the feed a cid= wraps) and are otherwise dropped; action pages are dropped.
 */
export function discoverLinks(scan: PageScan, sameSite: (url: string) => boolean): DiscoveredLinks {
  const documented = new Set<string>();
  const exports = new Set<string>();
  const pages = new Set<string>();
  const listings = new Set<string>();
  const skipped: Partial<Record<LinkSkipReason, number>> = {};
  const skip = (r: LinkSkipReason) => {
    skipped[r] = (skipped[r] ?? 0) + 1;
  };
  const addFeed = (u: string, into: Set<string>) => {
    const c = classifyLink(u);
    if (c.kind === "skip") return skip(c.reason);
    if (c.kind === "feed") for (const f of c.urls) into.add(f);
    else into.add(u);
  };
  for (const l of scan.links) {
    if (!l.rel.includes("alternate") || !l.type || !FEED_TYPES.has(l.type)) continue;
    const u = fetchableUrl(l.href, scan.baseUrl);
    if (u) addFeed(u, documented);
  }
  for (const a of scan.anchors) {
    if (a.rel.includes("nofollow")) continue;
    const u = fetchableUrl(a.href, scan.baseUrl);
    if (!u) continue;
    const c = classifyLink(u);
    if (c.kind === "skip") {
      skip(c.reason);
      continue;
    }
    if (c.kind === "feed") {
      for (const f of c.urls) exports.add(f);
      continue;
    }
    if (CALENDAR_HREF.test(a.href) || (a.type !== null && FEED_TYPES.has(a.type))) {
      exports.add(u);
      continue;
    }
    if (!sameSite(u)) continue;
    const clean = u.replace(/#.*$/, "");
    if (isListingView(clean)) {
      listings.add(clean);
      continue;
    }
    const path = new URL(clean).pathname;
    if (/\.(pdf|jpe?g|png|gif|docx?|xlsx?|zip)$/i.test(path)) continue;
    if (
      /\/(events?|calendar|programs?|exhibitions?)\/[^/]+/i.test(path) ||
      (a.classes ?? []).some((c) => TEC_EVENT_LINK_CLASS.test(c))
    ) {
      pages.add(clean);
    }
  }
  const all = [...documented, ...[...exports].filter((u) => !documented.has(u))];
  const feeds = [
    ...all.filter((u) => !isPerEventExport(u)),
    ...all.filter((u) => isPerEventExport(u)),
  ];
  return { feeds, pages: [...pages], listings: [...listings], skipped };
}

/** The Events Calendar's event title links in its list, month, day and photo views. */
const TEC_EVENT_LINK_CLASS =
  /^(?:tribe-events-calendar-(?:list|month|day|photo|latest-past)__event-title-link|tribe-events-calendar-month__calendar-event-title-link|tribe-event-url|tribe-events-pro-photo__event-title-link)$/;

/** View segments of The Events Calendar that list many events. */
const VIEW_SEGMENT = /^(?:list|month|week|day|photo|map|summary|today|upcoming)$/i;

/**
 * A listing view of The Events Calendar: /<events slug>/list/, /month/ (optionally with
 * /page/N/ or a date), or ?eventDisplay=list|month. Exports (?ical=1) are feeds, not views.
 */
export function isListingView(url: string): boolean {
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return false;
  }
  if (/[?&](?:ical|ics|outlook-ical)=/i.test(u.search)) return false;
  const display = u.searchParams.get("eventDisplay") ?? u.searchParams.get("tribe_event_display");
  if (display && /^(?:list|month|day|week|photo)$/i.test(display)) return true;
  const segs = u.pathname.split("/").filter(Boolean);
  // /events/list/, /events/list/page/2/, /calendar/month/2026-11/, /events/list/?tribe-bar-date=
  for (let i = 1; i < segs.length; i++) {
    if (!VIEW_SEGMENT.test(segs[i] ?? "")) continue;
    const rest = segs.slice(i + 1);
    if (
      rest.length === 0 ||
      (rest.length === 1 && /^\d{4}-\d{2}(?:-\d{2})?$/.test(rest[0] ?? "")) ||
      (rest.length === 2 && rest[0] === "page" && /^\d{1,3}$/.test(rest[1] ?? ""))
    )
      return true;
  }
  return false;
}

/**
 * The listing views of The Events Calendar to try when a calendar-wide ?ical=1 export may not
 * be read (noindex): the export URL without its export parameter, as the list view
 * (/<slug>/list/) and then as ?eventDisplay=list. Null for anything that is not such an export.
 */
export function tecListViewsFor(exportUrl: string): string[] | null {
  let u: URL;
  try {
    u = new URL(exportUrl);
  } catch {
    return null;
  }
  if (u.searchParams.get("ical") !== "1" || isPerEventExport(exportUrl)) return null;
  u.searchParams.delete("ical");
  u.hash = "";
  const segs = u.pathname.split("/").filter(Boolean);
  // /events/month/2026-11/ -> /events/
  const view = segs.findIndex((s, i) => i > 0 && VIEW_SEGMENT.test(s));
  const base = view >= 0 ? segs.slice(0, view) : segs;
  if (base.length === 0) return null;
  const root = `${u.origin}/${base.join("/")}/`;
  const extra = u.searchParams.toString();
  const list = `${root}list/${extra ? `?${extra}` : ""}`;
  const display = new URL(root);
  for (const [k, v] of u.searchParams) display.searchParams.set(k, v);
  display.searchParams.set("eventDisplay", "list");
  return [list, display.toString()];
}
