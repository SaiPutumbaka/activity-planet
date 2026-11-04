// schema.org Event data, from JSON-LD blocks or microdata items, to RawEvents. Reads facts
// only (name, dates, place, status, offers, organizer, link); the description is cut to a short
// excerpt later. Handles @graph, top-level arrays, @id references, Event subtypes, Place with
// PostalAddress or text address, GeoCoordinates, VirtualPlace and attendance modes, offers and
// AggregateOffer, eventStatus.

import type { RawEvent } from "../types.ts";
import { htmlToText, num, str } from "../util/text.ts";
import { httpsUrl } from "../util/url.ts";

type Obj = Record<string, unknown>;

const NON_EVENT = /^(BroadcastEvent|OnDemandEvent|PublicationEvent|DeliveryEvent|UserInteraction)$/;

function types(o: Obj): string[] {
  const t = o["@type"];
  const list = Array.isArray(t) ? t : [t];
  return list
    .map((x) =>
      typeof x === "string"
        ? x.replace(/^https?:\/\/(www\.)?schema\.org\//i, "").replace(/^schema:/, "")
        : "",
    )
    .filter(Boolean);
}

function isEvent(o: Obj): boolean {
  return types(o).some(
    (t) => (/Event$/.test(t) && !NON_EVENT.test(t)) || t === "Festival" || t === "Hackathon",
  );
}

function asArray(v: unknown): unknown[] {
  return v === undefined || v === null ? [] : Array.isArray(v) ? v : [v];
}

function firstStr(v: unknown): string | null {
  for (const x of asArray(v)) {
    const s = str(x);
    if (s) return s;
    if (x && typeof x === "object") {
      const inner = str((x as Obj)["@value"]) ?? str((x as Obj).name);
      if (inner) return inner;
    }
  }
  return null;
}

/** JSON-LD text, tolerant of HTML comments, CDATA wrappers and trailing commas. */
export function parseJsonLdBlock(text: string): unknown[] {
  const cleaned = text
    .replace(/^\s*<!--/, "")
    .replace(/-->\s*$/, "")
    .replace(/^\s*\/\/\s*<!\[CDATA\[/, "")
    .replace(/\/\/\s*\]\]>\s*$/, "")
    .trim();
  if (!cleaned) return [];
  for (const candidate of [cleaned, cleaned.replace(/,\s*([}\]])/g, "$1")]) {
    try {
      return asArray(JSON.parse(candidate));
    } catch {
      // try the next form
    }
  }
  return [];
}

/** Every node of a JSON tree that is an object, with @graph and nesting walked. */
function collect(roots: unknown[]): { events: Obj[]; byId: Map<string, Obj> } {
  const events: Obj[] = [];
  const byId = new Map<string, Obj>();
  const seen = new Set<unknown>();
  const visit = (v: unknown, depth: number) => {
    if (depth > 12 || v === null || typeof v !== "object" || seen.has(v)) return;
    seen.add(v);
    if (Array.isArray(v)) {
      v.forEach((x) => visit(x, depth + 1));
      return;
    }
    const o = v as Obj;
    const id = str(o["@id"]);
    if (id && Object.keys(o).length > 1) byId.set(id, o);
    if (isEvent(o)) events.push(o);
    for (const [k, child] of Object.entries(o)) {
      if (k === "@context") continue;
      visit(child, depth + 1);
    }
  };
  roots.forEach((r) => visit(r, 0));
  return { events, byId };
}

function deref(v: unknown, byId: Map<string, Obj>): unknown {
  if (v && typeof v === "object" && !Array.isArray(v)) {
    const o = v as Obj;
    const id = str(o["@id"]);
    if (id && Object.keys(o).length === 1) return byId.get(id) ?? o;
  }
  return v;
}

interface Place {
  text: string;
  lat: number | null;
  lng: number | null;
  online: boolean;
}

function addressText(a: unknown): string {
  if (typeof a === "string") return a.trim();
  if (!a || typeof a !== "object") return "";
  const o = a as Obj;
  return [o.streetAddress, o.addressLocality, o.addressRegion]
    .map((x) => firstStr(x))
    .filter(Boolean)
    .join(", ");
}

function placeOf(location: unknown, byId: Map<string, Obj>): Place {
  const out: Place = { text: "", lat: null, lng: null, online: false };
  const parts: string[] = [];
  let physical = false;
  for (const raw of asArray(location)) {
    const l = deref(raw, byId);
    if (typeof l === "string") {
      parts.push(l.trim());
      physical = true;
      continue;
    }
    if (!l || typeof l !== "object") continue;
    const o = l as Obj;
    const t = types(o);
    if (t.includes("VirtualPlace") || t.includes("VirtualLocation")) {
      out.online = true;
      continue;
    }
    if (t.includes("PostalAddress")) {
      parts.push(addressText(o));
      physical = true;
      continue;
    }
    physical = true;
    const name = firstStr(o.name);
    const addr = addressText(deref(o.address, byId));
    parts.push([name, addr && addr !== name ? addr : ""].filter(Boolean).join(", "));
    const geo = deref(o.geo, byId) as Obj | undefined;
    if (geo && typeof geo === "object" && out.lat === null) {
      out.lat = num(geo.latitude);
      out.lng = num(geo.longitude);
    }
    if (out.lat === null) {
      out.lat = num(o.latitude);
      out.lng = num(o.longitude);
    }
  }
  out.text = parts.filter(Boolean).join("; ");
  if (!physical && out.online) out.text = "Online";
  return out;
}

function offersOf(
  offers: unknown,
  byId: Map<string, Obj>,
): { isFree: boolean | null; priceText: string | null } {
  let low: number | null = null;
  let currency: string | null = null;
  let any = false;
  for (const raw of asArray(offers)) {
    const o = deref(raw, byId);
    if (!o || typeof o !== "object") continue;
    const offer = o as Obj;
    const price = num(offer.price) ?? num(offer.lowPrice);
    const cur = firstStr(offer.priceCurrency);
    if (price !== null) {
      any = true;
      if (low === null || price < low) {
        low = price;
        currency = cur;
      }
    } else if (/free/i.test(firstStr(offer.price) ?? "")) {
      any = true;
      low = low ?? 0;
    }
  }
  if (!any || low === null) return { isFree: null, priceText: null };
  if (low === 0) return { isFree: true, priceText: null };
  const amount = Number.isInteger(low) ? String(low) : low.toFixed(2);
  const priceText =
    currency === "USD" || currency === null ? `$${amount}` : `${amount} ${currency}`;
  return { isFree: false, priceText: asArray(offers).length > 1 ? `From ${priceText}` : priceText };
}

const SUBTYPE_CATEGORY: Record<string, string> = {
  MusicEvent: "Music",
  SportsEvent: "Sports",
  EducationEvent: "Education",
  ExhibitionEvent: "Exhibition",
  Festival: "Festival",
  FoodEvent: "Food",
  LiteraryEvent: "Literary",
  ScreeningEvent: "Film",
  TheaterEvent: "Theater",
  DanceEvent: "Dance",
  ComedyEvent: "Comedy",
  ChildrensEvent: "Kids",
  SocialEvent: "Social",
  VisualArtsEvent: "Visual arts",
  BusinessEvent: "Business",
  Hackathon: "Tech",
};

export interface SchemaOptions {
  pageUrl: string;
}

function toRaw(o: Obj, byId: Map<string, Obj>, opts: SchemaOptions): RawEvent | null {
  const start = firstStr(o.startDate);
  if (!start) return null;
  const place = placeOf(o.location, byId);
  const mode = (firstStr(o.eventAttendanceMode) ?? "").replace(/^.*\//, "");
  const status = asArray(o.eventStatus)
    .map((s) => (typeof s === "string" ? s : (firstStr((s as Obj)?.["@id"]) ?? "")))
    .join(" ");
  const id = str(o["@id"]);
  const url =
    httpsUrl(firstStr(o.url), opts.pageUrl) ??
    (id && /^https:/.test(id) && !id.includes("#") ? id : null);
  const organizer = deref(asArray(o.organizer)[0], byId);
  const host =
    typeof organizer === "string"
      ? organizer
      : organizer && typeof organizer === "object"
        ? firstStr((organizer as Obj).name)
        : null;
  const { isFree, priceText } =
    o.isAccessibleForFree === true || o.isAccessibleForFree === "true"
      ? { isFree: true, priceText: null }
      : offersOf(o.offers, byId);
  const image = asArray(o.image)[0];
  const imageUrl =
    typeof image === "string"
      ? image
      : image && typeof image === "object"
        ? firstStr((image as Obj).url)
        : null;
  const online = mode === "OnlineEventAttendanceMode" || (place.online && place.text === "Online");
  const categories = types(o)
    .map((t) => SUBTYPE_CATEGORY[t])
    .filter((c): c is string => Boolean(c));
  return {
    lane: "page",
    uid: id,
    title: htmlToText(firstStr(o.name) ?? ""),
    description: htmlToText(firstStr(o.description) ?? ""),
    url: url ?? httpsUrl(opts.pageUrl),
    start,
    end: firstStr(o.endDate),
    location: place.text || (online ? "Online" : ""),
    lat: place.lat,
    lng: place.lng,
    online,
    cancelled: /EventCancelled/i.test(status),
    postponed: /EventPostponed/i.test(status),
    isFree,
    priceText,
    categories,
    host,
    imageUrl: httpsUrl(imageUrl, opts.pageUrl),
    sourceUrl: opts.pageUrl,
  };
}

/** Events in parsed JSON-LD documents (or microdata items in the same shape). */
export function schemaEvents(roots: unknown[], opts: SchemaOptions): RawEvent[] {
  const { events, byId } = collect(roots);
  const out: RawEvent[] = [];
  for (const e of events) {
    const raw = toRaw(e, byId, opts);
    if (raw) out.push(raw);
  }
  return out;
}

export function jsonLdEvents(blocks: string[], opts: SchemaOptions): RawEvent[] {
  return schemaEvents(blocks.flatMap(parseJsonLdBlock), opts);
}
