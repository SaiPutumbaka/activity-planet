// Adapters for the import-feed function (D-037): pure functions from a source payload to the
// item shape import_upsert_batch() takes. No network, no Deno APIs, so they run under
// `deno test` with fixture payloads. Every field is optional on the way in: a missing field
// gives a null or an empty value, and an item with no usable id, title, start or https link
// is left for the database to count as skipped (it applies the events constraints again).

export interface ImportItem {
  external_id: string;
  title: string;
  description: string;
  starts_at: string | null;
  ends_at: string | null;
  all_day: boolean;
  location: string;
  lat: number | null;
  lng: number | null;
  url: string | null;
  cover_url: string | null;
  is_free: boolean | null;
  price_text: string | null;
  categories: string[];
  host_org: string | null;
  open_to_public: boolean | null;
  cancelled: boolean;
  raw: Record<string, unknown>;
}

/** About 300 characters of verbatim excerpt (PLAN 4.4); the database caps at 2000. */
export const EXCERPT_CHARS = 300;

// ---------------------------------------------------------------------------
// Text helpers
// ---------------------------------------------------------------------------

const NAMED_ENTITIES: Record<string, string> = {
  amp: "&",
  lt: "<",
  gt: ">",
  quot: '"',
  apos: "'",
  nbsp: " ",
  rsquo: "’",
  lsquo: "‘",
  rdquo: "”",
  ldquo: "“",
  ndash: "–",
  mdash: "—",
  hellip: "…",
  middot: "·",
  bull: "•",
  eacute: "é",
  copy: "©",
  reg: "®",
  trade: "™",
};

export function decodeEntities(text: string): string {
  return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, code: string) => {
    if (code[0] === "#") {
      const n =
        code[1] === "x" || code[1] === "X"
          ? parseInt(code.slice(2), 16)
          : parseInt(code.slice(1), 10);
      return Number.isFinite(n) && n > 0 && n <= 0x10ffff ? String.fromCodePoint(n) : match;
    }
    return NAMED_ENTITIES[code.toLowerCase()] ?? match;
  });
}

/** HTML to plain text: block ends become line breaks, tags go, entities decode, runs of spaces collapse. */
export function htmlToText(html: string): string {
  const text = html
    .replace(/\r\n?/g, "\n")
    .replace(/<(script|style)\b[\s\S]*?<\/\1>/gi, " ")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|li|h[1-6]|tr)>/gi, "\n")
    .replace(/<[^>]+>/g, " ");
  return decodeEntities(text)
    .replace(/[ \t ]+/g, " ")
    .replace(/ *\n */g, "\n")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}

/** A verbatim prefix of at most max characters, cut at a word boundary, with an ellipsis. */
export function excerpt(text: string, max: number = EXCERPT_CHARS): string {
  const clean = text.trim();
  if (clean.length <= max) return clean;
  const cut = clean.slice(0, max - 1);
  const space = cut.lastIndexOf(" ");
  return `${(space > max * 0.6 ? cut.slice(0, space) : cut).trimEnd()}…`;
}

function str(value: unknown): string | null {
  if (typeof value === "string") {
    const t = value.trim();
    return t === "" ? null : t;
  }
  if (typeof value === "number" && Number.isFinite(value)) return String(value);
  return null;
}

function num(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() !== "") {
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  }
  return null;
}

/** Only https links survive (events_external_url_format, events_cover_url_format). */
export function httpsUrl(value: unknown): string | null {
  const s = str(value);
  if (!s) return null;
  try {
    const u = new URL(s);
    return u.protocol === "https:" ? u.toString() : null;
  } catch {
    return null;
  }
}

/** Any date string Date understands (ISO 8601, RFC 822) as ISO, else null. */
export function isoDate(value: unknown): string | null {
  const s = str(value);
  if (!s) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d.toISOString();
}

function names(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  const out: string[] = [];
  for (const v of value) {
    const n =
      typeof v === "string"
        ? str(v)
        : v && typeof v === "object"
          ? str((v as Record<string, unknown>).name)
          : null;
    if (n) out.push(n);
  }
  return out;
}

/**
 * Localist event types that are dates on the academic calendar (registration windows, last day
 * to withdraw), not things to go to; they are left out of the feed.
 */
const LOCALIST_SKIPPED_TYPES = /^academic calendar$/i;

const PUBLIC_AUDIENCE = /\b(public|everyone|all are welcome|open to all|community|general)\b/i;

// ---------------------------------------------------------------------------
// Localist /api/2/events
// ---------------------------------------------------------------------------

export interface LocalistPage {
  items: ImportItem[];
  page: number;
  totalPages: number;
}

/**
 * One page of Localist's /api/2/events. Each event instance in the window becomes its own
 * item (external id "<event id>:<instance id or start>"); private events are left out.
 * "Open to the public" is true only when an audience filter names the public.
 */
export function parseLocalistPage(payload: unknown): LocalistPage {
  const root = (payload && typeof payload === "object" ? payload : {}) as Record<string, unknown>;
  const pageInfo = (root.page && typeof root.page === "object" ? root.page : {}) as Record<
    string,
    unknown
  >;
  const page = num(pageInfo.current) ?? 1;
  const totalPages = num(pageInfo.total) ?? 1;
  const items: ImportItem[] = [];

  const events = Array.isArray(root.events) ? root.events : [];
  for (const wrapper of events) {
    const e = (
      wrapper && typeof wrapper === "object" && "event" in wrapper
        ? (wrapper as Record<string, unknown>).event
        : wrapper
    ) as Record<string, unknown> | null;
    if (!e || typeof e !== "object") continue;
    if (e.private === true) continue;
    const id = str(e.id);
    if (!id) continue;

    const filters = (e.filters && typeof e.filters === "object" ? e.filters : {}) as Record<
      string,
      unknown
    >;
    const categories: string[] = [];
    let audience: string[] | null = null;
    for (const [key, value] of Object.entries(filters)) {
      const list = names(value);
      if (/audience/i.test(key)) audience = [...(audience ?? []), ...list];
      else categories.push(...list);
    }
    categories.push(...names(e.tags), ...names(e.keywords));
    if (names(filters.event_types).some((t) => LOCALIST_SKIPPED_TYPES.test(t))) continue;
    const departments = names(e.departments);
    const openToPublic = audience === null ? null : audience.some((a) => PUBLIC_AUDIENCE.test(a));

    const geo = (e.geo && typeof e.geo === "object" ? e.geo : {}) as Record<string, unknown>;
    const location =
      [str(e.location_name) ?? str(e.location), str(e.room_number)].filter(Boolean).join(", ") ||
      str(e.address) ||
      (str(e.experience) === "virtual" ? "Online" : "");
    const description =
      str(e.description_text) ?? (str(e.description) ? htmlToText(String(e.description)) : "");
    const url = httpsUrl(e.localist_url) ?? httpsUrl(e.url) ?? httpsUrl(e.ticket_url);
    const free = typeof e.free === "boolean" ? e.free : null;
    const cost = str(e.ticket_cost);
    const status = str(e.status)?.toLowerCase() ?? null;

    const instances = Array.isArray(e.event_instances) ? e.event_instances : [];
    for (const wrap of instances) {
      const inst = (
        wrap && typeof wrap === "object" && "event_instance" in wrap
          ? (wrap as Record<string, unknown>).event_instance
          : wrap
      ) as Record<string, unknown> | null;
      if (!inst || typeof inst !== "object") continue;
      const start = isoDate(inst.start);
      if (!start) continue;
      const instanceId = str(inst.id) ?? start;
      items.push({
        external_id: `${id}:${instanceId}`,
        title: decodeEntities(str(e.title) ?? ""),
        description: excerpt(description),
        starts_at: start,
        ends_at: isoDate(inst.end),
        all_day: inst.all_day === true,
        location,
        lat: num(geo.latitude),
        lng: num(geo.longitude),
        url,
        cover_url: httpsUrl(e.photo_url),
        is_free: free,
        price_text: free === false && cost ? cost.slice(0, 40) : null,
        categories,
        host_org: departments[0] ?? str(e.group_name),
        open_to_public: openToPublic,
        cancelled: status === "cancelled" || status === "canceled",
        raw: {
          id: e.id,
          instance_id: inst.id ?? null,
          title: e.title ?? null,
          localist_url: e.localist_url ?? null,
          url: e.url ?? null,
          ticket_url: e.ticket_url ?? null,
          start: inst.start ?? null,
          end: inst.end ?? null,
          all_day: inst.all_day ?? null,
          location_name: e.location_name ?? null,
          room_number: e.room_number ?? null,
          address: e.address ?? null,
          geo: { latitude: geo.latitude ?? null, longitude: geo.longitude ?? null },
          experience: e.experience ?? null,
          status: e.status ?? null,
          free: e.free ?? null,
          ticket_cost: e.ticket_cost ?? null,
          photo_url: e.photo_url ?? null,
          departments,
          filters: Object.fromEntries(Object.entries(filters).map(([k, v]) => [k, names(v)])),
          updated_at: e.updated_at ?? null,
          description_text: description.slice(0, 1000),
        },
      });
    }
  }
  return { items, page, totalPages };
}

// ---------------------------------------------------------------------------
// Campus Labs Engage events.rss
// ---------------------------------------------------------------------------

function unwrapCdata(text: string): string {
  return text.replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g, "$1");
}

/** Every value of a child element, with or without a namespace prefix. */
function tagValues(xml: string, name: string): string[] {
  const re = new RegExp(
    `<(?:[\\w-]+:)?${name}\\b[^>]*?(?:/>|>([\\s\\S]*?)</(?:[\\w-]+:)?${name}>)`,
    "gi",
  );
  const out: string[] = [];
  for (const m of xml.matchAll(re)) out.push(unwrapCdata(m[1] ?? "").trim());
  return out;
}

function tagValue(xml: string, name: string): string | null {
  return tagValues(xml, name).find((v) => v !== "") ?? null;
}

function attrValue(xml: string, tag: string, attr: string): string | null {
  const m = new RegExp(`<(?:[\\w-]+:)?${tag}\\b[^>]*\\b${attr}\\s*=\\s*"([^"]*)"`, "i").exec(xml);
  return m ? decodeEntities(m[1]) : null;
}

/** Text of an element carrying a class (hCalendar markup in the description). */
function byClass(html: string, cls: string): string | null {
  const m = new RegExp(
    `<(\\w+)[^>]*class="[^"]*\\b${cls}\\b[^"]*"[^>]*>([\\s\\S]*?)</\\1>`,
    "i",
  ).exec(html);
  return m ? htmlToText(m[2]) || null : null;
}

function datetimeByClass(html: string, cls: string): string | null {
  const m =
    new RegExp(`<\\w+[^>]*class="[^"]*\\b${cls}\\b[^"]*"[^>]*datetime="([^"]+)"`, "i").exec(html) ??
    new RegExp(`<\\w+[^>]*datetime="([^"]+)"[^>]*class="[^"]*\\b${cls}\\b`, "i").exec(html);
  return m ? isoDate(m[1]) : null;
}

/** Decoded text of an element; escaped HTML inside it is decoded first, then stripped. */
function textOf(value: string | null): string {
  if (!value) return "";
  const decoded = decodeEntities(value);
  return /<[a-z!/][^>]*>/i.test(decoded)
    ? htmlToText(decoded)
    : decoded.replace(/\s+/g, " ").trim();
}

/**
 * Engage's syndication feed: RSS 2.0 items with start, end, location and host as plain child
 * elements on current tenants, or hCalendar markup (dt-start, dt-end, p-location) inside the
 * description on older ones. Both are read; the plain elements win.
 */
export function parseEngageRss(xml: string): ImportItem[] {
  const items: ImportItem[] = [];
  for (const m of xml.matchAll(/<item\b[^>]*>([\s\S]*?)<\/item>/gi)) {
    const block = m[1];
    const link = textOf(tagValue(block, "link"));
    const guid = textOf(tagValue(block, "guid"));
    const idFromUrl = /\/event(?:s)?\/(\d+)/i.exec(link || guid)?.[1] ?? null;
    const externalId = idFromUrl ?? (guid || link);
    if (!externalId) continue;

    const descriptionHtml = decodeEntities(unwrapCdata(tagValue(block, "description") ?? ""));
    const descriptionText =
      byClass(descriptionHtml, "p-description") ??
      byClass(descriptionHtml, "description") ??
      htmlToText(descriptionHtml);

    const start =
      isoDate(textOf(tagValue(block, "start"))) ??
      datetimeByClass(descriptionHtml, "dt-start") ??
      datetimeByClass(descriptionHtml, "dtstart");
    const end =
      isoDate(textOf(tagValue(block, "end"))) ??
      datetimeByClass(descriptionHtml, "dt-end") ??
      datetimeByClass(descriptionHtml, "dtend");
    const location =
      textOf(tagValue(block, "location")) ||
      byClass(descriptionHtml, "p-location") ||
      byClass(descriptionHtml, "location") ||
      "";
    const author = textOf(tagValue(block, "author"));
    const host =
      textOf(tagValue(block, "host")) ||
      /\(([^)]+)\)\s*$/.exec(author)?.[1]?.trim() ||
      (author && !author.includes("@") ? author : "") ||
      null;
    const categories = tagValues(block, "category").map(textOf).filter(Boolean);
    const status = textOf(tagValue(block, "status")).toLowerCase();
    const title = textOf(tagValue(block, "title"));
    const cover = httpsUrl(attrValue(block, "enclosure", "url"));

    items.push({
      external_id: externalId.slice(0, 200),
      title,
      description: excerpt(descriptionText),
      starts_at: start,
      ends_at: end,
      all_day: false,
      location,
      lat: null,
      lng: null,
      url: httpsUrl(link) ?? httpsUrl(guid),
      cover_url: cover,
      is_free: null,
      price_text: null,
      categories,
      host_org: host,
      open_to_public: null,
      cancelled: status === "cancelled" || status === "canceled",
      raw: {
        guid: guid || null,
        link: link || null,
        title,
        start: textOf(tagValue(block, "start")) || null,
        end: textOf(tagValue(block, "end")) || null,
        location: location || null,
        host,
        author: author || null,
        categories,
        status: status || null,
        enclosure: cover,
        pubDate: textOf(tagValue(block, "pubDate")) || null,
        description_text: descriptionText.slice(0, 1000),
      },
    });
  }
  return items;
}
