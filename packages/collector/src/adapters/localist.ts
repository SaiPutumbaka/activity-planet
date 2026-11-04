// Localist calendars publish a documented, read-only JSON API with no key:
// https://<calendar>/api/2/events (developer.localist.com/doc/api; "authentication is optional
// to read data"). A `localist` seed reads it instead of crawling the calendar's HTML, which
// costs one request per 100 events and never touches the calendar's action pages. Requests go
// through the normal web politeness (robots.txt, 2 s spacing), not the API lane.
// Same field rules as supabase/functions/import-feed/adapters.ts parseLocalistPage().

import type { RawEvent, Seed } from "../types.ts";
import { htmlToText, str, num } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";

type Obj = Record<string, unknown>;

export const LOCALIST_PAGE_SIZE = 100;
/** At most this many API pages per seed per run (10,000 events). */
export const LOCALIST_MAX_PAGES = 100;

/** Event types that are academic-calendar dates (deadlines, no-class days), not outings. */
const SKIPPED_TYPES = /^academic calendar(?: & deadlines)?$|^deadlines?$/i;

/** The API root for a seed URL: the calendar's own https origin + /api/2/events. */
export function localistEventsUrl(seed: Seed, days: number, page: number): string {
  const origin = new URL(seed.url).origin;
  const u = new URL(`${origin}/api/2/events`);
  // A seed may pin filters (type=, group_id=, …) in its own query string.
  for (const [k, v] of new URL(seed.url).searchParams) u.searchParams.append(k, v);
  u.searchParams.set("days", String(Math.max(1, Math.min(370, Math.round(days)))));
  u.searchParams.set("pp", String(LOCALIST_PAGE_SIZE));
  u.searchParams.set("page", String(page));
  return u.toString();
}

function obj(v: unknown): Obj {
  return v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {};
}

function names(v: unknown): string[] {
  if (!Array.isArray(v)) return [];
  const out: string[] = [];
  for (const x of v) {
    const n = typeof x === "string" ? str(x) : str(obj(x).name);
    if (n) out.push(n);
  }
  return out;
}

export interface LocalistParsed {
  events: RawEvent[];
  page: number;
  totalPages: number;
}

export function parseLocalist(body: string, sourceUrl: string): LocalistParsed {
  const root = obj(JSON.parse(body) as unknown);
  const pageInfo = obj(root.page);
  const page = num(pageInfo.current) ?? 1;
  const totalPages = num(pageInfo.total) ?? 1;
  const events: RawEvent[] = [];
  for (const wrapper of Array.isArray(root.events) ? root.events : []) {
    const w = obj(wrapper);
    const e = obj("event" in w ? w.event : w);
    if (e.private === true) continue;
    const id = str(e.id);
    if (!id) continue;
    const filters = obj(e.filters);
    if (names(filters.event_types).some((t) => SKIPPED_TYPES.test(t))) continue;
    const categories: string[] = [];
    for (const [key, value] of Object.entries(filters))
      if (!/audience/i.test(key)) categories.push(...names(value));
    categories.push(...names(e.tags), ...names(e.keywords));
    const geo = obj(e.geo);
    const location =
      [str(e.location_name) ?? str(e.location), str(e.room_number)].filter(Boolean).join(", ") ||
      str(e.address) ||
      "";
    const experience = str(e.experience)?.toLowerCase() ?? null;
    const description =
      str(e.description_text) ?? (str(e.description) ? htmlToText(String(e.description)) : "");
    const url = httpsUrl(e.localist_url) ?? httpsUrl(e.url) ?? httpsUrl(e.ticket_url);
    const free = typeof e.free === "boolean" ? e.free : null;
    const cost = str(e.ticket_cost);
    const status = str(e.status)?.toLowerCase() ?? null;
    for (const iw of Array.isArray(e.event_instances) ? e.event_instances : []) {
      const i = obj(iw);
      const inst = obj("event_instance" in i ? i.event_instance : i);
      const start = str(inst.start);
      if (!start) continue;
      const allDay = inst.all_day === true;
      events.push({
        lane: "feed",
        uid: `${id}:${str(inst.id) ?? start}`,
        title: htmlToText(str(e.title) ?? ""),
        description,
        url,
        start: allDay ? start.slice(0, 10) : start,
        end: allDay ? null : str(inst.end),
        allDay,
        location: location || (experience === "virtual" ? "Online" : ""),
        lat: num(geo.latitude),
        lng: num(geo.longitude),
        online: experience === "virtual",
        cancelled: status === "cancelled" || status === "canceled",
        isFree: free,
        priceText: free === false && cost ? cost : null,
        categories,
        host: names(e.departments)[0] ?? str(e.group_name),
        imageUrl: httpsUrl(e.photo_url),
        sourceUrl,
      });
    }
  }
  return { events, page, totalPages };
}
