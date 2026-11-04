// RSS 2.0 and Atom feeds whose entries are events. An entry counts only when it carries an
// event time: the RSS event module (ev:startdate, ev:enddate, ev:location), Engage-style
// <start>/<end>/<location>, xCal-ish <dtstart>, Localist-style <localist:start>, or hCalendar
// markup (dt-start, dtstart) in the description. pubDate and updated are publication times,
// never event times, so news feeds yield nothing.

import type { RawEvent } from "../types.ts";
import { decodeEntities, htmlToText, plain } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";

function unwrapCdata(text: string): string {
  return text.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
}

/** Every value of a child element, with or without a namespace prefix. */
function tagValues(xml: string, name: string, prefix = "(?:[\\w-]+:)?"): string[] {
  const re = new RegExp(`<${prefix}${name}\\b[^>]*?(?:/>|>([\\s\\S]*?)</${prefix}${name}>)`, "gi");
  const out: string[] = [];
  for (const m of xml.matchAll(re)) out.push(unwrapCdata(m[1] ?? "").trim());
  return out;
}

function tagValue(xml: string, name: string, prefix?: string): string | null {
  return tagValues(xml, name, prefix).find((v) => v !== "") ?? null;
}

function attrOf(xml: string, tag: string, attr: string, where?: RegExp): string | null {
  const re = new RegExp(`<(?:[\\w-]+:)?${tag}\\b([^>]*)>`, "gi");
  for (const m of xml.matchAll(re)) {
    const attrs = m[1] ?? "";
    if (where && !where.test(attrs)) continue;
    const a = new RegExp(`\\b${attr}\\s*=\\s*("([^"]*)"|'([^']*)')`, "i").exec(attrs);
    if (a) return decodeEntities(a[2] ?? a[3] ?? "");
  }
  return null;
}

function byClass(html: string, cls: string): string | null {
  const m = new RegExp(
    `<(\\w+)[^>]*class="[^"]*\\b${cls}\\b[^"]*"[^>]*>([\\s\\S]*?)</\\1>`,
    "i",
  ).exec(html);
  return m ? htmlToText(m[2] ?? "") || null : null;
}

function datetimeByClass(html: string, cls: string): string | null {
  const m =
    new RegExp(
      `<\\w+[^>]*class="[^"]*\\b${cls}\\b[^"]*"[^>]*(?:datetime|title)="([^"]+)"`,
      "i",
    ).exec(html) ??
    new RegExp(`<\\w+[^>]*(?:datetime|title)="([^"]+)"[^>]*class="[^"]*\\b${cls}\\b`, "i").exec(
      html,
    );
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
    ...[...xml.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)].map((m) => ({
      atom: false,
      body: m[1] ?? "",
    })),
    ...[...xml.matchAll(/<entry\b[^>]*>([\s\S]*?)<\/entry>/gi)].map((m) => ({
      atom: true,
      body: m[1] ?? "",
    })),
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
