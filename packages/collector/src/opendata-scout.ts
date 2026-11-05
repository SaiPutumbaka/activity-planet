#!/usr/bin/env node
// Open-data scout (design 2.7): finds candidate event datasets for a region on the free, keyless
// catalogue APIs, for a person to read and add to data/opendata/.
//
//   pnpm --filter collector opendata scout --region atl
//   pnpm --filter collector opendata scout --lat 51.05 --lng -114.07 --radius-km 30 --label Calgary
//
// Socrata Discovery API (api.us.socrata.com and api.eu.socrata.com /api/catalog/v1): datasets
// whose name or tags say event, festival, special event or calendar; the catalogue has no place
// filter, so each candidate with a point column is asked one aggregate, count(*) inside the
// region's box (and the latest date of its first date column), on its own portal. ArcGIS Hub
// (hub.arcgis.com /api/search/v1, OGC API Records) filters by the region's box itself.
//
// Output: dataset ids, names, portals, column names, licence, update date and the two aggregates.
// These are public metadata, so the public log may show them. Row values are never requested or
// printed: the only row reads are count(*) and max(<date column>). Every request goes through the
// PoliteFetcher (robots.txt on the portals, one request per 2 seconds per host, the User-Agent,
// the denylist); the catalogue endpoints are the API lane. SOCRATA_APP_TOKEN, when set, is sent
// as X-App-Token and never printed.

import { parseArgs } from "node:util";
import { loadCities } from "./config.ts";
import type { Fetcher } from "./net/fetcher.ts";
import { PoliteFetcher } from "./net/fetcher.ts";
import { Denylist } from "./policy/denylist.ts";
import type { Region } from "./types.ts";

export const SOCRATA_CATALOGS = [
  "https://api.us.socrata.com/api/catalog/v1",
  "https://api.eu.socrata.com/api/catalog/v1",
];
export const HUB_SEARCH = "https://hub.arcgis.com/api/search/v1/collections/dataset/items";
export const TERMS = ["event", "festival", "special event", "calendar"];
const EVENT_WORD = /\b(events?|festivals?|special events?|calendars?)\b/i;
const ID4X4 = /^[a-z0-9]{4}-[a-z0-9]{4}$/;
const DOMAIN = /^[a-z0-9.-]{3,120}$/;

export interface ScoutRow {
  portal: "socrata" | "arcgis";
  id: string;
  name: string;
  domain: string;
  endpoint: string;
  columns: string[];
  licence: string | null;
  updated: string | null;
  inBox?: number | null;
  latest?: string | null;
}

/** [minLng, minLat, maxLng, maxLat] around a region's circle. */
export function regionBox(
  r: Pick<Region, "lat" | "lng" | "radiusKm">,
): [number, number, number, number] {
  const dLat = r.radiusKm / 111.32;
  const dLng = Math.min(
    180,
    r.radiusKm / (111.32 * Math.max(0.01, Math.cos((r.lat * Math.PI) / 180))),
  );
  const f = (x: number) => Math.round(x * 1000) / 1000;
  return [f(r.lng - dLng), f(r.lat - dLat), f(r.lng + dLng), f(r.lat + dLat)];
}

// Control characters never reach the log.
// eslint-disable-next-line no-control-regex
const CONTROL = /[\u0000-\u001f\u007f]+/g;
const clean = (v: unknown, max = 120): string =>
  typeof v === "string" ? v.replace(CONTROL, " ").trim().slice(0, max) : "";

export function socrataCatalogUrl(base: string, term: string, offset = 0): string {
  const u = new URL(base);
  u.searchParams.set("q", term);
  u.searchParams.set("only", "dataset");
  u.searchParams.set("limit", "100");
  u.searchParams.set("offset", String(offset));
  return u.toString();
}

/** Catalogue results that read as event datasets, with their column names and types. */
export function parseSocrataCatalog(body: string): (ScoutRow & { types: string[] })[] {
  const root = JSON.parse(body) as { results?: unknown };
  const out: (ScoutRow & { types: string[] })[] = [];
  for (const r of Array.isArray(root.results) ? root.results : []) {
    const o = (r ?? {}) as Record<string, unknown>;
    const res = (o.resource ?? {}) as Record<string, unknown>;
    const meta = (o.metadata ?? {}) as Record<string, unknown>;
    const cls = (o.classification ?? {}) as Record<string, unknown>;
    const id = clean(res.id, 9);
    const domain = clean(meta.domain, 120).toLowerCase();
    if (!ID4X4.test(id) || !DOMAIN.test(domain)) continue;
    const name = clean(res.name);
    const tags = [
      ...(Array.isArray(cls.tags) ? cls.tags : []),
      ...(Array.isArray(cls.domain_tags) ? cls.domain_tags : []),
    ].map((t) => clean(t, 40));
    if (!EVENT_WORD.test(name) && !tags.some((t) => EVENT_WORD.test(t))) continue;
    const columns = (Array.isArray(res.columns_field_name) ? res.columns_field_name : [])
      .map((c: unknown) => clean(c, 64))
      .slice(0, 60);
    const types = (Array.isArray(res.columns_datatype) ? res.columns_datatype : []).map(
      (c: unknown) => clean(c, 30).toLowerCase(),
    );
    out.push({
      portal: "socrata",
      id,
      name,
      domain,
      endpoint: `https://${domain}/resource/${id}.json`,
      columns,
      types,
      licence: clean(meta.license, 120) || null,
      updated: clean(res.updatedAt ?? res.data_updated_at, 10) || null,
    });
  }
  return out;
}

/** The first point-like column and the first date column of a Socrata dataset. */
export function socrataColumns(row: { columns: string[]; types: string[] }): {
  geo: string | null;
  date: string | null;
} {
  let geo: string | null = null;
  let date: string | null = null;
  row.columns.forEach((c, i) => {
    const t = row.types[i] ?? "";
    if (!geo && (t === "point" || t === "location")) geo = c;
    if (!date && (t === "calendar_date" || t === "floating_timestamp" || t === "fixed_timestamp"))
      date = c;
  });
  const ok = (c: string | null) => (c && /^[a-z_][a-z0-9_]{0,63}$/.test(c) ? c : null);
  return { geo: ok(geo), date: ok(date) };
}

/** count(*) inside the box and max(date), aggregates only. */
export function socrataAggregateUrl(
  endpoint: string,
  geo: string,
  date: string | null,
  box: [number, number, number, number],
): string {
  const [w, s, e, n] = box;
  const u = new URL(endpoint);
  u.searchParams.set("$select", date ? `count(*) as n, max(${date}) as latest` : "count(*) as n");
  u.searchParams.set("$where", `within_box(${geo}, ${n}, ${w}, ${s}, ${e})`);
  return u.toString();
}

export function parseAggregate(body: string): { n: number | null; latest: string | null } {
  const rows = JSON.parse(body) as unknown;
  const r = (Array.isArray(rows) ? rows[0] : null) as Record<string, unknown> | null;
  const n = r ? Number(r.n) : NaN;
  const latest = r && typeof r.latest === "string" ? r.latest.slice(0, 10) : null;
  return {
    n: Number.isFinite(n) ? n : null,
    latest: latest && /^\d{4}-\d{2}-\d{2}$/.test(latest) ? latest : null,
  };
}

export function hubSearchUrl(term: string, box: [number, number, number, number]): string {
  const u = new URL(HUB_SEARCH);
  u.searchParams.set("q", term);
  u.searchParams.set("bbox", box.join(","));
  u.searchParams.set("limit", "100");
  return u.toString();
}

/** Hub search results (OGC API Records features) that read as event layers. */
export function parseHubSearch(body: string): ScoutRow[] {
  const root = JSON.parse(body) as { features?: unknown };
  const out: ScoutRow[] = [];
  for (const f of Array.isArray(root.features) ? root.features : []) {
    const p = ((f ?? {}) as { properties?: Record<string, unknown> }).properties ?? {};
    const name = clean(p.title ?? p.name);
    const tags = (Array.isArray(p.tags) ? p.tags : []).map((t: unknown) => clean(t, 40));
    if (!EVENT_WORD.test(name) && !tags.some((t: string) => EVENT_WORD.test(t))) continue;
    const url = clean(p.url, 300);
    let endpoint = "";
    try {
      const u = new URL(url);
      if (u.protocol === "https:" && /\/(FeatureServer|MapServer)\/\d+$/i.test(u.pathname))
        endpoint = u.toString();
    } catch {
      endpoint = "";
    }
    const id = clean(p.id, 64);
    if (!id || !endpoint) continue;
    out.push({
      portal: "arcgis",
      id,
      name,
      domain: new URL(endpoint).hostname,
      endpoint,
      columns: [],
      licence: clean(p.license ?? p.licenseInfo, 120) || null,
      updated:
        typeof p.modified === "number"
          ? new Date(p.modified).toISOString().slice(0, 10)
          : clean(p.modified, 10) || null,
    });
  }
  return out;
}

/** One printable line per dataset: metadata and aggregates only. */
export function formatRow(r: ScoutRow): string {
  const q = (s: string | null | undefined) => JSON.stringify(s ?? "");
  return [
    `[scout] ${r.portal}`,
    `domain=${r.domain}`,
    `id=${r.id}`,
    `name=${q(r.name)}`,
    `endpoint=${r.endpoint}`,
    `columns=${r.columns.join(",")}`,
    `licence=${q(r.licence)}`,
    `updated=${r.updated ?? "-"}`,
    ...(r.inBox !== undefined ? [`in_box=${r.inBox ?? "-"}`, `latest=${r.latest ?? "-"}`] : []),
  ].join(" ");
}

export async function scout(o: {
  region: Pick<Region, "lat" | "lng" | "radiusKm">;
  fetcher: Pick<Fetcher, "get">;
  appToken?: string;
  maxProbes?: number;
}): Promise<{ rows: ScoutRow[]; counts: Record<string, number> }> {
  const box = regionBox(o.region);
  const counts: Record<string, number> = {
    catalog_calls: 0,
    catalog_failed: 0,
    aggregates: 0,
    aggregate_failed: 0,
  };
  const rows = new Map<string, ScoutRow & { types?: string[] }>();
  const headers = o.appToken ? { "X-App-Token": o.appToken } : undefined;
  for (const base of SOCRATA_CATALOGS) {
    for (const term of TERMS) {
      counts.catalog_calls!++;
      const res = await o.fetcher.get(socrataCatalogUrl(base, term), {
        api: true,
        accept: "application/json",
      });
      if (!res.ok) {
        counts.catalog_failed!++;
        continue;
      }
      try {
        for (const r of parseSocrataCatalog(res.body)) rows.set(`${r.domain}/${r.id}`, r);
      } catch {
        counts.catalog_failed!++;
      }
    }
  }
  // One aggregate per Socrata candidate with a point column, on its own portal.
  let probes = 0;
  for (const r of rows.values()) {
    if (r.portal !== "socrata" || !r.types) continue;
    const { geo, date } = socrataColumns({ columns: r.columns, types: r.types });
    if (!geo || probes >= (o.maxProbes ?? 25)) {
      r.inBox = null;
      continue;
    }
    probes++;
    counts.aggregates!++;
    const res = await o.fetcher.get(socrataAggregateUrl(r.endpoint, geo, date, box), {
      accept: "application/json",
      ...(headers ? { headers } : {}),
    });
    if (!res.ok) {
      counts.aggregate_failed!++;
      r.inBox = null;
      continue;
    }
    try {
      const a = parseAggregate(res.body);
      r.inBox = a.n;
      r.latest = a.latest;
    } catch {
      counts.aggregate_failed!++;
      r.inBox = null;
    }
  }
  for (const term of TERMS) {
    counts.catalog_calls!++;
    const res = await o.fetcher.get(hubSearchUrl(term, box), {
      api: true,
      accept: "application/json",
    });
    if (!res.ok) {
      counts.catalog_failed!++;
      continue;
    }
    try {
      for (const r of parseHubSearch(res.body)) rows.set(`${r.domain}/${r.id}`, r);
    } catch {
      counts.catalog_failed!++;
    }
  }
  // Socrata datasets with nothing inside the box are left out; those not asked are kept.
  const out = [...rows.values()]
    .filter((r) => r.portal === "arcgis" || r.inBox === null || (r.inBox ?? 0) > 0)
    .map(({ types: _t, ...r }) => {
      void _t;
      return r;
    })
    .sort(
      (a, b) =>
        (b.inBox ?? 0) - (a.inBox ?? 0) ||
        a.domain.localeCompare(b.domain) ||
        a.id.localeCompare(b.id),
    );
  counts.datasets = out.length;
  return { rows: out, counts };
}

async function main(argv: string[]): Promise<number> {
  const [command, ...rest] = argv;
  const { values } = parseArgs({
    args: rest,
    options: {
      region: { type: "string" },
      lat: { type: "string" },
      lng: { type: "string" },
      "radius-km": { type: "string" },
      label: { type: "string" },
    },
    allowPositionals: false,
  });
  if (command !== "scout") {
    console.error(
      "usage: opendata scout (--region <city id> | --lat N --lng N --radius-km N) (see src/opendata-scout.ts)",
    );
    return 2;
  }
  let region: Pick<Region, "lat" | "lng" | "radiusKm"> & { label: string };
  if (values.region) {
    const c = loadCities().find((x) => x.region.id === values.region);
    if (!c) throw new Error(`unknown region ${values.region}`);
    region = c.region;
  } else {
    const lat = Number(values.lat);
    const lng = Number(values.lng);
    const radiusKm = Number(values["radius-km"] ?? "30");
    if (
      !(lat >= -90 && lat <= 90) ||
      !(lng >= -180 && lng <= 180) ||
      !(radiusKm > 0 && radiusKm <= 300)
    )
      throw new Error("--lat, --lng and --radius-km (1..300) are required without --region");
    region = { lat, lng, radiusKm, label: (values.label ?? "region").slice(0, 60) };
  }
  const fetcher = new PoliteFetcher({ denylist: Denylist.load(), maxRequestsFor: () => 200 });
  const token = (process.env.SOCRATA_APP_TOKEN ?? "").trim();
  const { rows, counts } = await scout({ region, fetcher, ...(token ? { appToken: token } : {}) });
  console.log(
    `[scout] region=${region.label} socrata_app_token=${token ? "set" : "unset"} ${JSON.stringify(counts)}`,
  );
  for (const r of rows) console.log(formatRow(r));
  return 0;
}

if (process.argv[1] && import.meta.url.endsWith(process.argv[1].split("/").pop() ?? "")) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (err: unknown) => {
      console.error(err instanceof Error ? err.message : String(err));
      process.exit(1);
    },
  );
}
