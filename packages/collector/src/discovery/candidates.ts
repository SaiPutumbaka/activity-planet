// Candidate calendar sites for a region (design 6.1): OpenStreetMap website tags on the region's
// places (the tile rows the place files are built from) and Wikidata official websites (P856) of
// event-type venues near it. One candidate per host (a leading www. dropped), so a library
// system or a city site with many parks is probed once. Only event-likely kinds; restaurants,
// shops, cafés and places of worship (D-041) never become candidates.

import type { Denylist } from "../policy/denylist.ts";
import type { Region } from "../types.ts";
import { haversineKm } from "../util/geo.ts";
import { fetchableUrl, siteOf } from "../util/url.ts";
import { keywordsFor, keywordStrength } from "./keywords.ts";

/**
 * Kind priors (design 6.3, "kind prior x 20") for the place kinds of extract_rules.json. Tuned
 * from the first staging numbers (COLLECTOR_COMPLETION.md 2.9): community 0.7 (best yield, 7 of
 * 30), cinema 0.15 (0 of 19: showtimes live on ticketing sites), school 0.5 (3 of 37); the rest
 * wait for a second region's data. Once a kind has LEARNED_MIN_PROBES probes worldwide, its learned
 * yield replaces the prior (learnedPrior).
 */
export const KIND_PRIOR: Record<string, number> = {
  library: 0.8,
  school: 0.5,
  arts_venue: 0.6,
  community: 0.7,
  attraction: 0.5,
  maker: 0.5,
  dance: 0.5,
  cinema: 0.15,
  sports_centre: 0.4,
  historic: 0.4,
  nature: 0.3,
  park: 0.3,
  market: 0.3,
  bar: 0.2,
  brewery: 0.2,
  nightlife: 0.2,
};

/** Wikidata classes for the around query (design 6.1 item 2), one P279 hop. */
export const WIKIDATA_CLASSES: Record<string, string> = {
  Q33506: "arts_venue", // museum
  Q7075: "library",
  Q24354: "arts_venue", // theatre building
  Q11635: "arts_venue", // theatre (organisation)
  Q3918: "school", // university
  Q189004: "school", // college
  Q1060829: "arts_venue", // concert hall
  Q167346: "attraction", // botanical garden
  Q22698: "park",
  Q515: "community", // city: city sites lead to parks and city calendars
  Q1093829: "community", // city of the United States
  Q2190251: "arts_venue", // arts centre
  Q11166728: "community", // community centre
};

export interface Candidate {
  url: string;
  host: string;
  origin: "osm" | "wikidata";
  name?: string;
  place_kind?: string;
  wikidata_id?: string;
  country?: string;
  /** Cheap score before any probe: kind prior, Wikidata, how many places link the host. */
  score: number;
  /** A deeper URL a place linked (an events page) worth reading after the homepage. */
  extra_urls?: string[];
  lat?: number;
  lng?: number;
  /** Places (or Wikidata items) that named this host. */
  places: number;
}

export function normalHost(host: string): string {
  return host
    .toLowerCase()
    .replace(/\.$/, "")
    .replace(/^www\./, "");
}

/** The candidate key and homepage for a website value, or null when it is unusable. */
export function siteUrl(website: string): { host: string; home: string; url: string } | null {
  const first = website.split(/[;\s]+/).find(Boolean) ?? "";
  // mailto:, tel: and other schemes without an authority are not websites.
  if (/^[a-z][a-z0-9+.-]*:(?!\/\/)/i.test(first)) return null;
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(first) ? first : `https://${first}`;
  const url = fetchableUrl(withScheme);
  if (!url) return null;
  const u = new URL(url);
  if (u.port && u.port !== "443") return null;
  const host = normalHost(u.hostname);
  if (!/^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/.test(host)) return null;
  return { host, home: `https://${u.hostname.toLowerCase()}/`, url };
}

/** Place tile ids (0.5 degree, row * 720 + column, migration 30) touching a region's circle. */
export function tilesForRegion(r: Pick<Region, "lat" | "lng" | "radiusKm">): number[] {
  const dLat = r.radiusKm / 111.0;
  const dLng = r.radiusKm / (111.32 * Math.max(0.05, Math.cos((r.lat * Math.PI) / 180)));
  const row = (lat: number) => Math.min(359, Math.max(0, Math.floor((lat + 90) / 0.5)));
  const col = (lng: number) => Math.min(719, Math.max(0, Math.floor((lng + 180) / 0.5)));
  const out: number[] = [];
  for (let y = row(r.lat - dLat); y <= row(r.lat + dLat); y++)
    for (let x = col(r.lng - dLng); x <= col(r.lng + dLng); x++) out.push(y * 720 + x);
  return out;
}

/** A tile row as GET /collector/tiles/{id}/rows returns it (place_tile_file_page). */
export type TileRow = [
  string, // osm_ref
  number, // lng
  number, // lat
  string, // kind
  string | null, // name
  unknown, // rule_ids
  string | null, // address
  string | null, // locality
  string | null, // hours
  string | null, // website
  Record<string, unknown> | null, // tags
];

interface Acc {
  c: Candidate;
  kinds: Set<string>;
}

function better(a: Candidate, kind: string): boolean {
  return (KIND_PRIOR[kind] ?? 0) > (KIND_PRIOR[a.place_kind ?? ""] ?? 0);
}

/**
 * Whether a host is a government's own website: a .gov domain (or gov., gouv., gob., govt. under
 * a country code), a US locality domain (alpharetta.ga.us, co.dekalb.ga.us), or a first label
 * that says so (cityofmiltonga.us, townof..., roswellgov.com).
 */
export function isGovernmentHost(host: string): boolean {
  const h = normalHost(host);
  if (/\.gov$/.test(h) || /\.(?:gov|gouv|gob|govt)\.[a-z]{2}$/.test(h)) return true;
  if (/\.[a-z]{2}\.us$/.test(h)) return true;
  const first = h.split(".")[0] ?? "";
  return (
    /^(?:cityof|townof|villageof|countyof|boroughof)[a-z0-9-]/.test(first) ||
    /[a-z0-9]gov$/.test(first)
  );
}

/**
 * The kind a site is scored as. A government's site is a city (or county) site, "community", the
 * kind Wikidata's city classes map to: OpenStreetMap names it from the places it serves (a fire
 * museum makes mariettaga.gov an arts_venue, a park a park), but what it publishes is the city's
 * calendar, and city sites are the best-yielding kind (COLLECTOR_COMPLETION.md 2.9). A place kind
 * with a higher prior (a library system on a .gov) keeps its own.
 */
export function siteKind(host: string, kind: string | undefined): string | undefined {
  if (!isGovernmentHost(host)) return kind;
  return (KIND_PRIOR[kind ?? ""] ?? 0) >= (KIND_PRIOR.community ?? 0) ? kind : "community";
}

/**
 * Candidates from OSM tile rows inside the region: event-likely kinds with a website, one per
 * host. Denylisted hosts (Facebook pages and the like) are dropped and counted.
 */
export function osmCandidates(
  rows: TileRow[],
  region: Region,
  opts: { denylist: Denylist; country?: string | null; skipSites?: Set<string> },
): { candidates: Candidate[]; wikidataIds: Map<string, string>; dropped: Record<string, number> } {
  const by = new Map<string, Acc>();
  const dropped: Record<string, number> = {};
  const drop = (r: string) => (dropped[r] = (dropped[r] ?? 0) + 1);
  const wikidataIds = new Map<string, string>();
  for (const row of rows) {
    const [, lng, lat, kind, name, , , , , website, tags] = row;
    if (typeof website !== "string" || website === "") continue;
    if (!(kind in KIND_PRIOR)) continue;
    if (haversineKm(region.lat, region.lng, lat, lng) > region.radiusKm) continue;
    const s = siteUrl(website);
    if (!s) {
      drop("bad_url");
      continue;
    }
    if (opts.denylist.hostDenied(s.host)) {
      drop("denylisted");
      continue;
    }
    if (opts.skipSites?.has(siteOf(s.host))) {
      drop("known_source");
      continue;
    }
    const wd =
      typeof tags?.wikidata === "string" && /^Q[1-9][0-9]{0,11}$/.test(tags.wikidata)
        ? tags.wikidata
        : undefined;
    let a = by.get(s.host);
    if (!a) {
      a = {
        c: {
          url: s.home,
          host: s.host,
          origin: "osm",
          score: 0,
          places: 0,
          lat,
          lng,
          ...(opts.country ? { country: opts.country } : {}),
        },
        kinds: new Set(),
      };
      by.set(s.host, a);
    }
    const c = a.c;
    c.places++;
    a.kinds.add(kind);
    if (!c.place_kind || better(c, kind)) {
      c.place_kind = kind;
      if (name && name.length >= 2) c.name = name.slice(0, 80);
      c.lat = lat;
      c.lng = lng;
    } else if (!c.name && name && name.length >= 2) c.name = name.slice(0, 80);
    if (wd && !c.wikidata_id) {
      c.wikidata_id = wd;
      wikidataIds.set(wd, s.host);
    }
    if (s.url !== s.home && new URL(s.url).pathname !== "/") {
      c.extra_urls = [...new Set([...(c.extra_urls ?? []), s.url])].slice(0, 5);
    }
  }
  const candidates = [...by.values()].map(({ c }) => {
    const k = siteKind(c.host, c.place_kind);
    const out = k ? { ...c, place_kind: k } : { ...c };
    return { ...out, score: cheapScore(out) };
  });
  return { candidates, wikidataIds, dropped };
}

/** Probed and good candidates by place kind, across all regions (GET /collector/discovery/yield). */
export type KindYield = Record<string, { probed: number; good: number }>;

/** GET /collector/discovery/yield's kinds, checked: {kind: {probed, good}}. */
export function parseYield(body: unknown): KindYield {
  const kinds = (body as { kinds?: unknown } | null)?.kinds;
  const out: KindYield = {};
  if (kinds && typeof kinds === "object" && !Array.isArray(kinds))
    for (const [k, v] of Object.entries(kinds as Record<string, unknown>)) {
      const o = (v ?? {}) as Record<string, unknown>;
      if (/^[a-z0-9_]{1,40}$/.test(k) && typeof o.probed === "number" && typeof o.good === "number")
        out[k] = { probed: o.probed, good: o.good };
    }
  return out;
}

/** A kind's yield replaces its static prior once it has this many probes worldwide. */
export const LEARNED_MIN_PROBES = 30;
/**
 * A Wikidata item is worth +10, as much as the other two structural signals (many places name the
 * host, a place links its events page), and never more. COLLECTOR_COMPLETION.md 2.9 raised it to
 * +25 from the staging yield by origin (Wikidata 11 of 54 against OSM 15 of 226), but those 54
 * were the candidates the +10 had already ranked first, many of them city sites (a kind effect
 * the kind prior already counts). At +25 a Wikidata tag alone outranked every untagged host: on
 * the same Atlanta rows and Wikidata answers the gate's probed 150 found 18 calendars with items
 * against 23 at +10, and two seeds (a city site 26 places name, a theatre linking its events
 * page) fell from ranks 95 and 60 to 176 and 175, past the cap (run 42131965214).
 */
export const WIKIDATA_BONUS = 10;

/** The prior for a kind: max(0.1, (good + 1) / (probed + 5)) after 30 probes, else the static one. */
export function learnedPrior(kind: string | undefined, yields?: KindYield): number {
  const y = yields?.[kind ?? ""];
  if (y && y.probed >= LEARNED_MIN_PROBES) return Math.max(0.1, (y.good + 1) / (y.probed + 5));
  return KIND_PRIOR[kind ?? ""] ?? 0.3;
}

/**
 * The score from signals known before any request (design 6.3): kind prior x 20 (learned once
 * the kind has 30 probes), Wikidata +10, up to +10 for a host many places name (a city or park
 * system's site), and +10 when a place links an events page of it.
 */
export function cheapScore(
  c: Pick<Candidate, "place_kind" | "wikidata_id" | "places" | "extra_urls">,
  yields?: KindYield,
): number {
  const prior = learnedPrior(c.place_kind, yields) * 20;
  const wd = c.wikidata_id ? WIKIDATA_BONUS : 0;
  const many = Math.min(10, 2 * Math.max(0, c.places - 1));
  // A place whose own website link is an events page ("/content/shows-events") says it lists events.
  const events = (c.extra_urls ?? []).some((u) => keywordStrength(u, "", keywordsFor(null)) >= 3)
    ? 10
    : 0;
  return Math.round(prior + wd + many + events);
}

/** SPARQL: official websites (P856) of the given items. */
export function entitiesQuery(ids: string[]): string {
  return `SELECT ?item ?site WHERE { VALUES ?item { ${ids.map((i) => `wd:${i}`).join(" ")} } ?item wdt:P856 ?site . }`;
}

/** SPARQL: event-type venues with an official website within km of a point (design 6.1). */
export function aroundQuery(lat: number, lng: number, km: number): string {
  const classes = Object.keys(WIKIDATA_CLASSES)
    .map((q) => `wd:${q}`)
    .join(" ");
  return [
    "SELECT ?item ?site ?cls ?label ?cc ?loc WHERE {",
    "  SERVICE wikibase:around {",
    "    ?item wdt:P625 ?loc .",
    `    bd:serviceParam wikibase:center "Point(${lng.toFixed(4)} ${lat.toFixed(4)})"^^geo:wktLiteral .`,
    `    bd:serviceParam wikibase:radius "${km}" .`,
    "  }",
    "  ?item wdt:P856 ?site .",
    `  VALUES ?cls { ${classes} }`,
    "  ?item wdt:P31/wdt:P279? ?cls .",
    "  OPTIONAL { ?item wdt:P17/wdt:P297 ?cc . }",
    '  OPTIONAL { ?item rdfs:label ?label . FILTER(LANG(?label) = "en") }',
    "} LIMIT 2000",
  ].join("\n");
}

export const SPARQL_ENDPOINT = "https://query.wikidata.org/sparql";

export function sparqlUrl(query: string): string {
  return `${SPARQL_ENDPOINT}?format=json&query=${encodeURIComponent(query)}`;
}

interface Binding {
  [k: string]: { value?: string } | undefined;
}

function bindings(body: string): Binding[] {
  try {
    const d = JSON.parse(body) as { results?: { bindings?: Binding[] } };
    return Array.isArray(d.results?.bindings) ? d.results.bindings : [];
  } catch {
    return [];
  }
}

const qid = (v: string | undefined) => /\/(Q[1-9][0-9]{0,11})$/.exec(v ?? "")?.[1];

/** Official websites from an entities query: item id to website. */
export function parseEntities(body: string): Map<string, string> {
  const out = new Map<string, string>();
  for (const b of bindings(body)) {
    const id = qid(b.item?.value);
    if (id && b.site?.value && !out.has(id)) out.set(id, b.site.value);
  }
  return out;
}

/** Venues from an around query, one per host, inside the region. */
export function parseAround(
  body: string,
  region: Region,
  opts: { denylist: Denylist; skipSites?: Set<string> },
): Candidate[] {
  const by = new Map<string, Candidate>();
  for (const b of bindings(body)) {
    const id = qid(b.item?.value);
    const s = b.site?.value ? siteUrl(b.site.value) : null;
    const cls = qid(b.cls?.value);
    if (!id || !s || !cls) continue;
    if (opts.denylist.hostDenied(s.host) || opts.skipSites?.has(siteOf(s.host))) continue;
    const m = /Point\(([-0-9.]+) ([-0-9.]+)\)/.exec(b.loc?.value ?? "");
    const lng = m ? Number(m[1]) : undefined;
    const lat = m ? Number(m[2]) : undefined;
    if (
      lat !== undefined &&
      lng !== undefined &&
      haversineKm(region.lat, region.lng, lat, lng) > region.radiusKm
    )
      continue;
    const kind = WIKIDATA_CLASSES[cls] ?? "community";
    const cc = b.cc?.value && /^[A-Z]{2}$/.test(b.cc.value) ? b.cc.value : undefined;
    const prev = by.get(s.host);
    if (prev) {
      prev.places++;
      if ((KIND_PRIOR[kind] ?? 0) > (KIND_PRIOR[prev.place_kind ?? ""] ?? 0))
        prev.place_kind = kind;
      continue;
    }
    const label = b.label?.value?.slice(0, 80);
    by.set(s.host, {
      url: s.home,
      host: s.host,
      origin: "wikidata",
      wikidata_id: id,
      place_kind: kind,
      score: 0,
      places: 1,
      ...(label && label.length >= 2 ? { name: label } : {}),
      ...(cc ? { country: cc } : {}),
      ...(lat !== undefined && lng !== undefined ? { lat, lng } : {}),
      ...(s.url !== s.home ? { extra_urls: [s.url] } : {}),
    });
  }
  return [...by.values()].map((c) => {
    const k = siteKind(c.host, c.place_kind);
    const out = k ? { ...c, place_kind: k } : c;
    return { ...out, score: cheapScore(out) };
  });
}

/**
 * One list per region: OSM candidates, then Wikidata ones on hosts OSM did not name. A host that
 * Wikidata confirms (the item an OSM place links has the same official website) keeps its OSM
 * origin and gains the Wikidata bonus. Best cheap score first, at most `max`.
 */
export function mergeCandidates(
  osm: Candidate[],
  entitySites: Map<string, string>,
  wikidataIds: Map<string, string>,
  around: Candidate[],
  max: number,
  yields?: KindYield,
): Candidate[] {
  const by = new Map(osm.map((c) => [c.host, { ...c }]));
  // An OSM place's Wikidata item names another official site: that site is a candidate too.
  for (const [id, website] of entitySites) {
    const s = siteUrl(website);
    if (!s) continue;
    const from = wikidataIds.get(id);
    const base = from ? by.get(from) : undefined;
    const have = by.get(s.host);
    if (have) {
      have.wikidata_id = have.wikidata_id ?? id;
      continue;
    }
    if (base)
      by.set(s.host, {
        url: s.home,
        host: s.host,
        origin: "wikidata",
        wikidata_id: id,
        place_kind: base.place_kind,
        name: base.name,
        country: base.country,
        lat: base.lat,
        lng: base.lng,
        places: 1,
        score: 0,
      });
  }
  for (const c of around) {
    const have = by.get(c.host);
    if (have) {
      have.wikidata_id = have.wikidata_id ?? c.wikidata_id;
      have.country = have.country ?? c.country;
      continue;
    }
    by.set(c.host, { ...c });
  }
  return [...by.values()]
    .map((c) => {
      const k = siteKind(c.host, c.place_kind);
      const out = k ? { ...c, place_kind: k } : c;
      return { ...out, score: cheapScore(out, yields) };
    })
    .sort((a, b) => b.score - a.score || a.host.localeCompare(b.host))
    .slice(0, Math.max(0, max));
}
