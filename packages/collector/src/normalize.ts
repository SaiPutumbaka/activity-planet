// RawEvent -> ImportItem within the events constraints import_upsert_batch() applies
// (supabase/migrations/*importer*.sql): title 3 to 120 after whitespace collapse, description
// at most 2000 (we keep a 280-character excerpt), https link required, ends_at always set
// (start + 2 h, or the end of the day for all-day items) and at most 3 days after starts_at,
// location at most 120, price text at most 40, external id 1 to 200. The database checks
// again; doing it here keeps the dry-run counts honest and the payload small.

import type { ImportItem, RawEvent, Region } from "./types.ts";
import { validPoint } from "./util/geo.ts";
import { clip, excerpt, oneLine, plain } from "./util/text.ts";
import { resolveTime, resolveZone } from "./util/time.ts";
import { httpsUrl, shortHash } from "./util/url.ts";

export const TITLE_MIN = 3;
export const TITLE_MAX = 120;
export const EXCERPT_MAX = 280;
export const DESCRIPTION_MAX = 2000;
export const LOCATION_MAX = 120;
export const PRICE_MAX = 40;
export const HOST_MAX = 120;
export const URL_MAX = 2000;
export const COVER_URL_MAX = 500;
export const EXTERNAL_ID_MAX = 200;
export const MAX_SPAN_MS = 3 * 24 * 3600 * 1000;
const DEFAULT_SPAN_MS = 2 * 3600 * 1000;
const ALL_DAY_SPAN_MS = 24 * 3600 * 1000 - 60 * 1000;

export type SkipReason =
  "title_too_short" | "no_start" | "no_https_url" | "longer_than_3_days" | "postponed";

export interface NormalizeContext {
  region: Region;
  attribution: string;
  /** Link used when the event has none of its own (the calendar page it is listed on). */
  fallbackUrl?: string | null;
  imagesLicensed?: boolean;
  /** Prepended to the external id, so ids from different feeds of one source cannot collide. */
  idPrefix?: string;
  hostOrg?: string | null;
  extraCategories?: string[];
}

export type NormalizeResult = { ok: true; item: ImportItem } | { ok: false; reason: SkipReason };

export function normalize(raw: RawEvent, ctx: NormalizeContext): NormalizeResult {
  if (raw.postponed) return { ok: false, reason: "postponed" };

  const title = oneLine(plain(raw.title));
  if (title.length < TITLE_MIN) return { ok: false, reason: "title_too_short" };

  const zone = resolveZone(raw.timezone) ?? resolveZone(ctx.region.timezone) ?? "UTC";
  const start = resolveTime(raw.start, zone);
  if (!start) return { ok: false, reason: "no_start" };
  const allDay = raw.allDay ?? start.dateOnly;

  let endMs: number | null = null;
  if (raw.end) {
    const end = resolveTime(raw.end, zone);
    if (end) endMs = end.dateOnly ? end.date.getTime() + ALL_DAY_SPAN_MS : end.date.getTime();
  }
  const startMs = start.date.getTime();
  if (endMs === null || endMs <= startMs)
    endMs = startMs + (allDay ? ALL_DAY_SPAN_MS : DEFAULT_SPAN_MS);
  if (endMs - startMs > MAX_SPAN_MS) return { ok: false, reason: "longer_than_3_days" };

  const url = httpsUrl(raw.url) ?? httpsUrl(ctx.fallbackUrl ?? null);
  if (!url || url.length > URL_MAX) return { ok: false, reason: "no_https_url" };

  const startsAt = new Date(startMs).toISOString();
  const baseId = raw.uid?.trim() || `${url}#${startsAt}`;
  let externalId = `${ctx.idPrefix ?? ""}${baseId}`;
  if (externalId.length > EXTERNAL_ID_MAX)
    externalId = `${ctx.idPrefix ?? ""}h:${shortHash(baseId, 40)}`;

  const cover = ctx.imagesLicensed ? httpsUrl(raw.imageUrl ?? null) : null;
  const point = validPoint(raw.lat, raw.lng);
  const categories = [
    ...new Set(
      [...(ctx.extraCategories ?? []), ...(raw.categories ?? [])]
        .map((c) => clip(oneLine(c), 60))
        .filter(Boolean),
    ),
  ].slice(0, 10);
  const host = oneLine(plain(raw.host ?? ctx.hostOrg ?? ""));
  const price = raw.priceText ? oneLine(raw.priceText) : "";

  return {
    ok: true,
    item: {
      external_id: externalId,
      title: clip(title, TITLE_MAX),
      description: excerpt(oneLine(plain(raw.description)), EXCERPT_MAX),
      starts_at: startsAt,
      ends_at: new Date(endMs).toISOString(),
      all_day: allDay,
      location: clip(oneLine(plain(raw.location)) || (raw.online ? "Online" : ""), LOCATION_MAX),
      lat: point ? raw.lat : null,
      lng: point ? raw.lng : null,
      url,
      cover_url: cover && cover.length <= COVER_URL_MAX ? cover : null,
      is_free: raw.isFree ?? null,
      price_text: price ? clip(price, PRICE_MAX) : null,
      categories,
      host_org: host ? clip(host, HOST_MAX) : null,
      open_to_public: null,
      cancelled: raw.cancelled === true,
      attribution: ctx.attribution,
      lane: raw.lane,
      raw: {
        lane: raw.lane,
        uid: raw.uid,
        source_url: raw.sourceUrl,
        start: raw.start,
        end: raw.end,
        timezone: raw.timezone ?? null,
        zone_used: zone,
        online: raw.online === true,
        attribution: ctx.attribution,
      },
    },
  };
}
