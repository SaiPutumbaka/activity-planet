// Lane 1: free official APIs. Each adapter turns a region into request URLs and a response into
// RawEvents; the collector fetches through the PoliteFetcher with api: true (the denylist's
// apiAllow entry is the only way onto these hosts). Without its key an adapter is disabled and
// the run carries on (D-040: keys come later as TICKETMASTER_API_KEY and SEATGEEK_CLIENT_ID).

import type { RawEvent, Region } from "../types.ts";
import { geohash } from "../util/geo.ts";
import { htmlToText, num, str } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";

type Obj = Record<string, unknown>;
const obj = (v: unknown): Obj =>
  v && typeof v === "object" && !Array.isArray(v) ? (v as Obj) : {};
const arr = (v: unknown): unknown[] => (Array.isArray(v) ? v : []);

export interface ApiWindow {
  start: Date;
  end: Date;
}

export interface ApiPage {
  events: RawEvent[];
  /** The next page's URL, or null when this was the last (or the paging cap is reached). */
  next: string | null;
  /**
   * More pages exist than the paging cap reads: the set is a sample, so an event missing from it
   * may still be listed and must not count as missed (D-042 slice 10).
   */
  truncated?: boolean;
}

export interface ApiAdapter {
  id: string;
  name: string;
  attribution: string;
  /** Environment variable holding the key; the adapter is off when it is unset or empty. */
  envKey: string;
  /** Most pages one region's query reads (the region's share of the daily call budget). */
  maxPages: number;
  firstUrl(region: Region, window: ApiWindow, key: string): string;
  parse(body: string, requestUrl: string): ApiPage;
}

/**
 * "From €25": the lowest price in the currency the API gives (Ticketmaster prices outside the US
 * are not in dollars). A missing or malformed code is read as US dollars, both APIs' default.
 */
export function fromPrice(min: number | null, currency?: string | null): string | null {
  if (min === null || !Number.isFinite(min) || min < 0) return null;
  const code = currency && /^[A-Za-z]{3}$/.test(currency) ? currency.toUpperCase() : "USD";
  try {
    const f = new Intl.NumberFormat("en", {
      style: "currency",
      currency: code,
      currencyDisplay: "narrowSymbol",
      maximumFractionDigits: 0,
      minimumFractionDigits: 0,
    });
    return `From ${f.format(Math.round(min))}`;
  } catch {
    return `From $${Math.round(min)}`;
  }
}

/** "2026-11-04T05:00:00Z": Ticketmaster rejects fractional seconds. */
function tmTime(d: Date): string {
  return d.toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Ticketmaster allows size * page < 1000, so five pages of 200 is the most one query gives. */
const TM_PAGE_SIZE = 200;
const TM_MAX_PAGES = 5;

export const ticketmaster: ApiAdapter = {
  id: "ticketmaster",
  name: "Ticketmaster",
  attribution: "Event data from the Ticketmaster Discovery API (ticketmaster.com).",
  envKey: "TICKETMASTER_API_KEY",
  maxPages: TM_MAX_PAGES,
  firstUrl(region, window, key) {
    const u = new URL("https://app.ticketmaster.com/discovery/v2/events.json");
    u.searchParams.set("apikey", key);
    u.searchParams.set("geoPoint", geohash(region.lat, region.lng, 7));
    u.searchParams.set("radius", String(Math.ceil(region.radiusKm)));
    u.searchParams.set("unit", "km");
    u.searchParams.set("startDateTime", tmTime(window.start));
    u.searchParams.set("endDateTime", tmTime(window.end));
    u.searchParams.set("size", String(TM_PAGE_SIZE));
    u.searchParams.set("page", "0");
    u.searchParams.set("sort", "date,asc");
    // Every locale: the default ("en") leaves out events listed only in the local language
    // (a German venue's "de" listings). No countryCode: geoPoint and radius work worldwide, and a
    // country filter would drop the other side of a border inside the radius.
    u.searchParams.set("locale", "*");
    return u.toString();
  },
  parse(body, requestUrl) {
    const root = obj(JSON.parse(body));
    const events: RawEvent[] = [];
    for (const raw of arr(obj(root._embedded).events)) {
      const e = obj(raw);
      const dates = obj(e.dates);
      const start = obj(dates.start);
      const end = obj(dates.end);
      const venue = obj(arr(obj(e._embedded).venues)[0]);
      const loc = obj(venue.location);
      const startValue =
        str(start.dateTime) ??
        (str(start.localDate) && str(start.localTime)
          ? `${str(start.localDate)}T${str(start.localTime)}`
          : str(start.localDate));
      // test: Ticketmaster's own test listings, never real events.
      if (!startValue || start.dateTBD === true || e.test === true) continue;
      const status = str(obj(dates.status).code)?.toLowerCase() ?? "";
      const price = obj(arr(e.priceRanges)[0]);
      const min = num(price.min);
      const cls = obj(arr(e.classifications)[0]);
      const categories = [str(obj(cls.segment).name), str(obj(cls.genre).name)].filter(
        (c): c is string => Boolean(c) && c !== "Undefined",
      );
      events.push({
        lane: "api",
        uid: str(e.id),
        title: str(e.name) ?? "",
        description: htmlToText(str(e.info) ?? str(e.description) ?? ""),
        url: httpsUrl(e.url),
        start: startValue,
        end: str(end.dateTime) ?? null,
        allDay: !str(start.dateTime) && !str(start.localTime),
        timezone: str(dates.timezone) ?? str(venue.timezone),
        location: [str(venue.name), str(obj(venue.address).line1), str(obj(venue.city).name)]
          .filter(Boolean)
          .join(", "),
        lat: num(loc.latitude),
        lng: num(loc.longitude),
        cancelled: status === "cancelled" || status === "canceled",
        postponed: status === "postponed",
        isFree: null,
        priceText: fromPrice(min, str(price.currency)),
        categories,
        host: null,
        imageUrl: null,
        sourceUrl: "https://app.ticketmaster.com/discovery/v2/events.json",
      });
    }
    const page = obj(root.page);
    const number = num(page.number) ?? 0;
    const total = num(page.totalPages) ?? 1;
    let next: string | null = null;
    if (number + 1 < total && number + 1 < TM_MAX_PAGES) {
      const u = new URL(requestUrl);
      u.searchParams.set("page", String(number + 1));
      next = u.toString();
    }
    return { events, next, truncated: next === null && number + 1 < total };
  },
};

const SG_PAGE_SIZE = 100;
const SG_MAX_PAGES = 10;

export const seatgeek: ApiAdapter = {
  id: "seatgeek",
  name: "SeatGeek",
  attribution: "Event data from the SeatGeek Platform API (seatgeek.com).",
  envKey: "SEATGEEK_CLIENT_ID",
  maxPages: SG_MAX_PAGES,
  firstUrl(region, window, key) {
    const u = new URL("https://api.seatgeek.com/2/events");
    u.searchParams.set("client_id", key);
    u.searchParams.set("lat", region.lat.toFixed(4));
    u.searchParams.set("lon", region.lng.toFixed(4));
    u.searchParams.set("range", `${Math.ceil(region.radiusKm / 1.609344)}mi`);
    u.searchParams.set("datetime_utc.gte", window.start.toISOString().slice(0, 19));
    u.searchParams.set("datetime_utc.lte", window.end.toISOString().slice(0, 19));
    u.searchParams.set("per_page", String(SG_PAGE_SIZE));
    u.searchParams.set("page", "1");
    u.searchParams.set("sort", "datetime_utc.asc");
    return u.toString();
  },
  parse(body, requestUrl) {
    const root = obj(JSON.parse(body));
    const events: RawEvent[] = [];
    for (const raw of arr(root.events)) {
      const e = obj(raw);
      if (e.date_tbd === true || e.datetime_tbd === true) continue;
      const venue = obj(e.venue);
      const loc = obj(venue.location);
      const utc = str(e.datetime_utc);
      const lowest = num(obj(e.stats).lowest_price);
      const status = str(e.status)?.toLowerCase() ?? "";
      events.push({
        lane: "api",
        uid: str(e.id),
        title: str(e.title) ?? str(e.short_title) ?? "",
        description: htmlToText(str(e.description) ?? ""),
        url: httpsUrl(e.url),
        // datetime_utc has no zone suffix but is UTC.
        start: utc ? `${utc}Z` : (str(e.datetime_local) ?? ""),
        end: null,
        allDay: e.time_tbd === true,
        timezone: str(venue.timezone),
        location: [str(venue.name), str(venue.address), str(venue.city)].filter(Boolean).join(", "),
        lat: num(loc.lat),
        lng: num(loc.lon),
        cancelled: status === "cancelled" || status === "canceled",
        postponed: status === "postponed",
        isFree: null,
        priceText: fromPrice(lowest, "USD"),
        categories: arr(e.taxonomies)
          .map((t) => str(obj(t).name))
          .filter((t): t is string => Boolean(t))
          .map((t) => t.replace(/_/g, " ")),
        host: null,
        imageUrl: null,
        sourceUrl: "https://api.seatgeek.com/2/events",
      });
    }
    const meta = obj(root.meta);
    const page = num(meta.page) ?? 1;
    const per = num(meta.per_page) ?? SG_PAGE_SIZE;
    const total = num(meta.total) ?? 0;
    let next: string | null = null;
    if (page * per < total && page < SG_MAX_PAGES) {
      const u = new URL(requestUrl);
      u.searchParams.set("page", String(page + 1));
      next = u.toString();
    }
    return { events, next, truncated: next === null && page * per < total };
  },
};

export const API_ADAPTERS: ApiAdapter[] = [ticketmaster, seatgeek];

/** The adapters whose key is set, with the key. Never logs the key. */
export function enabledAdapters(
  env: Record<string, string | undefined>,
  adapters: ApiAdapter[] = API_ADAPTERS,
): { adapter: ApiAdapter; key: string }[] {
  return adapters
    .map((adapter) => ({ adapter, key: (env[adapter.envKey] ?? "").trim() }))
    .filter((a) => a.key !== "");
}

/** A URL safe to print: API keys and client ids replaced. */
export function redactUrl(url: string): string {
  try {
    const u = new URL(url);
    for (const k of [
      "apikey",
      "api_key",
      "client_id",
      "client_secret",
      "key",
      "token",
      "$$app_token",
    ]) {
      if (u.searchParams.has(k)) u.searchParams.set(k, "REDACTED");
    }
    return u.toString();
  } catch {
    return "(bad url)";
  }
}

/** The API endpoints' hosts: their requests are limited by the day's call budget instead. */
export const API_HOSTS: ReadonlySet<string> = new Set(["app.ticketmaster.com", "api.seatgeek.com"]);

/**
 * Calls to ask the day's budget for: every region's full paging (regions x maxPages), at most
 * 1000 (collector_api_budget_take's largest request, D-042 slice 10).
 */
export function callsWanted(adapter: Pick<ApiAdapter, "maxPages">, regions: number): number {
  return Math.min(1000, Math.max(0, regions) * adapter.maxPages);
}

/**
 * The calls file `regions budget take` writes: {day, calls: {<adapter id>: n}}. Anything that is
 * not a whole number from 0 to 1000 counts as 0, so a bad file sends no API request.
 */
export function readApiBudget(file: unknown): Record<string, number> {
  const calls = obj(obj(file).calls);
  const out: Record<string, number> = {};
  for (const a of API_ADAPTERS) {
    const n = calls[a.id];
    out[a.id] = typeof n === "number" && Number.isInteger(n) && n >= 0 && n <= 1000 ? n : 0;
  }
  return out;
}
