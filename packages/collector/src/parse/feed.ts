// RSS 2.0 and Atom feeds whose entries are events. An entry counts only when it carries an
// event time: the RSS event module (ev:startdate, ev:enddate, ev:location), Engage-style
// <start>/<end>/<location>, xCal-ish <dtstart>, Localist-style <localist:start>, or hCalendar
// markup (dt-start, dtstart) in the description. pubDate and updated are publication times,
// never event times, so news feeds yield nothing.

import type { RawEvent } from "../types.ts";
import { decodeEntities, htmlToText, plain } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";

// Every scan below is a single forward pass (find an opening tag, then its closing tag from
// there, and stop when none is left), so a feed full of unclosed tags costs linear time, not a
// lazy-regex rescan to the end of the file for each one.

/** CDATA sections unwrapped; an unclosed one runs to the end. */
function unwrapCdata(text: string): string {
  let out = "";
  let pos = 0;
  for (;;) {
    const i = text.indexOf("<![CDATA[", pos);
    if (i < 0) break;
    out += text.slice(pos, i);
    const j = text.indexOf("]]>", i + 9);
    if (j < 0) return out + text.slice(i + 9);
    out += text.slice(i + 9, j);
    pos = j + 3;
  }
  return out + text.slice(pos);
}

/** Inner text of each element `prefix + name` (self-closed ones give ""), in document order. */
function elements(xml: string, name: string, prefix: string): string[] {
  const open = new RegExp(`<${prefix}${name}\\b[^<>]{0,4000}?(/?)>`, "gi");
  const close = new RegExp(`</${prefix}${name}\\s*>`, "gi");
  const out: string[] = [];
  let pos = 0;
  for (;;) {
    open.lastIndex = pos;
    const m = open.exec(xml);
    if (!m) break;
    const bodyStart = m.index + m[0].length;
    if (m[1] === "/") {
      out.push("");
      pos = bodyStart;
      continue;
    }
    close.lastIndex = bodyStart;
    const c = close.exec(xml);
    if (!c) break;
    out.push(xml.slice(bodyStart, c.index));
    pos = c.index + c[0].length;
  }
  return out;
}

/** Every value of a child element, with or without a namespace prefix. */
function tagValues(xml: string, name: string, prefix = "(?:[\\w-]+:)?"): string[] {
  return elements(xml, name, prefix).map((v) => unwrapCdata(v).trim());
}

function tagValue(xml: string, name: string, prefix?: string): string | null {
  return tagValues(xml, name, prefix).find((v) => v !== "") ?? null;
}

function attrOf(xml: string, tag: string, attr: string, where?: RegExp): string | null {
  const re = new RegExp(`<(?:[\\w-]+:)?${tag}\\b([^<>]{0,4000})>`, "gi");
  for (const m of xml.matchAll(re)) {
    const attrs = m[1] ?? "";
    if (where && !where.test(attrs)) continue;
    const a = new RegExp(`\\b${attr}\\s*=\\s*("([^"]*)"|'([^']*)')`, "i").exec(attrs);
    if (a) return decodeEntities(a[2] ?? a[3] ?? "");
  }
  return null;
}

/** Text of the first element carrying class `cls` that has a closing tag. */
function byClass(html: string, cls: string): string | null {
  const open = new RegExp(
    `<(\\w+)\\b[^<>]{0,4000}?\\bclass="[^"<>]{0,1000}?\\b${cls}\\b[^<>]{0,4000}>`,
    "gi",
  );
  const unclosed = new Set<string>();
  for (const m of html.matchAll(open)) {
    const tag = (m[1] ?? "").toLowerCase();
    if (unclosed.has(tag)) continue;
    const close = new RegExp(`</${tag}\\s*>`, "gi");
    close.lastIndex = m.index + m[0].length;
    const c = close.exec(html);
    if (!c) {
      unclosed.add(tag);
      continue;
    }
    return htmlToText(html.slice(m.index + m[0].length, c.index)) || null;
  }
  return null;
}

function datetimeByClass(html: string, cls: string): string | null {
  const m =
    new RegExp(
      `<\\w+[^<>]{0,4000}?class="[^"<>]{0,1000}?\\b${cls}\\b[^"<>]{0,1000}"[^<>]{0,4000}?(?:datetime|title)="([^"<>]+)"`,
      "i",
    ).exec(html) ??
    new RegExp(
      `<\\w+[^<>]{0,4000}?(?:datetime|title)="([^"<>]+)"[^<>]{0,4000}?class="[^"<>]{0,1000}?\\b${cls}\\b`,
      "i",
    ).exec(html);
  return m?.[1] ?? null;
}

export interface FeedOptions {
  sourceUrl: string;
}

/** Whether a body is an RSS or Atom document. */
export function isFeed(body: string): boolean {
  const head = body.slice(0, 2000);
  return /<rss\b|<feed\b[^>]*xmlns="http:\/\/www\.w3\.org\/2005\/Atom"|<rdf:RDF\b/i.test(head);
}

export function parseFeed(xml: string, opts: FeedOptions): RawEvent[] {
  const out: RawEvent[] = [];
  const blocks = [
    ...elements(xml, "item", "").map((body) => ({ atom: false, body })),
    ...elements(xml, "entry", "").map((body) => ({ atom: true, body })),
  ];
  for (const { atom, body } of blocks) {
    const link = atom
      ? (attrOf(body, "link", "href", /rel\s*=\s*["']alternate["']/i) ??
        attrOf(body, "link", "href"))
      : plain(tagValue(body, "link", ""));
    const guid = plain(tagValue(body, atom ? "id" : "guid", ""));
    const descHtml = decodeEntities(
      unwrapCdata(
        tagValue(body, "description", "") ??
          tagValue(body, "content", "") ??
          tagValue(body, "summary", "") ??
          "",
      ),
    );
    const start =
      plain(tagValue(body, "startdate", "ev:")) ||
      plain(tagValue(body, "start", "(?:localist:|[\\w-]+:)?")) ||
      plain(tagValue(body, "dtstart", "(?:[\\w-]+:)?")) ||
      datetimeByClass(descHtml, "dt-start") ||
      datetimeByClass(descHtml, "dtstart") ||
      "";
    if (!start) continue;
    const end =
      plain(tagValue(body, "enddate", "ev:")) ||
      plain(tagValue(body, "end", "(?:localist:|[\\w-]+:)?")) ||
      plain(tagValue(body, "dtend", "(?:[\\w-]+:)?")) ||
      datetimeByClass(descHtml, "dt-end") ||
      datetimeByClass(descHtml, "dtend") ||
      null;
    const location =
      plain(tagValue(body, "location", "(?:ev:|[\\w-]+:)?")) ||
      byClass(descHtml, "p-location") ||
      byClass(descHtml, "location") ||
      "";
    const descText =
      byClass(descHtml, "p-description") ??
      byClass(descHtml, "description") ??
      htmlToText(descHtml);
    const status = plain(tagValue(body, "status")).toLowerCase();
    const host = plain(tagValue(body, "organizer", "ev:")) || plain(tagValue(body, "host")) || null;
    const lat = Number(plain(tagValue(body, "lat", "geo:")) || NaN);
    const lng = Number(plain(tagValue(body, "long", "geo:")) || NaN);
    out.push({
      lane: "feed",
      uid: guid || link || null,
      title: plain(tagValue(body, "title", "")),
      description: descText,
      url: httpsUrl(link) ?? httpsUrl(guid),
      start,
      end,
      location,
      lat: Number.isFinite(lat) ? lat : null,
      lng: Number.isFinite(lng) ? lng : null,
      cancelled: status === "cancelled" || status === "canceled",
      categories: tagValues(body, "category", "").map(plain).filter(Boolean),
      host,
      imageUrl: httpsUrl(attrOf(body, "enclosure", "url")),
      sourceUrl: opts.sourceUrl,
    });
  }
  return out;
}
