// geo-search logic, kept free of Supabase imports so it can be unit tested (search_test.ts).
//
// One request: { kind: "address" | "city", text, bias?: { lat, lng }, lang? }.
//   address  up to five Geoapify autocomplete results anywhere (D-040), ranked near bias
//   city     up to ten results for the home search (the app keeps cities and neighborhoods)
// The answer keeps only the fields the app reads (FIELDS), never Geoapify's whole record.

export type Kind = "address" | "city";

export interface GeoRequest {
  kind: Kind;
  text: string;
  bias: { lat: number; lng: number } | null;
  lang: string | null;
}

/** The Geoapify fields the app's mappers read (lib/venues.ts, @ap/core/places). */
export const FIELDS = [
  "formatted",
  "name",
  "address_line1",
  "housenumber",
  "result_type",
  "suburb",
  "district",
  "city",
  "county",
  "state_code",
  "state",
  "postcode",
  "country_code",
  "country",
  "place_id",
] as const;

export type GeoResult = Partial<Record<(typeof FIELDS)[number], string>> & {
  lat: number;
  lon: number;
  place_id: string;
};

export const AUTOCOMPLETE_URL = "https://api.geoapify.com/v1/geocode/autocomplete";

/** The request body, or an error code. Text is trimmed, collapsed and lowercased for the key. */
export function parseRequest(body: unknown): GeoRequest | { error: string } {
  if (!body || typeof body !== "object") return { error: "invalid_body" };
  const b = body as Record<string, unknown>;
  const kind = b.kind;
  if (kind !== "address" && kind !== "city") return { error: "invalid_kind" };
  const text = typeof b.text === "string" ? b.text.replace(/\s+/g, " ").trim() : "";
  const min = kind === "address" ? 4 : 3;
  if (text.length < min || text.length > 120) return { error: "invalid_text" };
  let bias: GeoRequest["bias"] = null;
  if (b.bias !== undefined && b.bias !== null) {
    const o = b.bias as Record<string, unknown>;
    const lat = Number(o?.lat);
    const lng = Number(o?.lng);
    if (
      !Number.isFinite(lat) ||
      !Number.isFinite(lng) ||
      Math.abs(lat) > 90 ||
      Math.abs(lng) > 180
    ) {
      return { error: "invalid_bias" };
    }
    // About 1 km: enough to rank nearby results, and the cache key does not hold a precise point.
    bias = { lat: Math.round(lat * 100) / 100, lng: Math.round(lng * 100) / 100 };
  }
  const lang = typeof b.lang === "string" && /^[a-z]{2}$/.test(b.lang) ? b.lang : null;
  return { kind, text, bias: kind === "address" ? bias : null, lang };
}

/** sha256 hex of the normalized request: the cache key (no user in it). */
export async function cacheKey(r: GeoRequest): Promise<string> {
  const norm = JSON.stringify([
    r.kind,
    r.text.toLowerCase(),
    r.bias?.lat ?? null,
    r.bias?.lng ?? null,
    r.lang,
  ]);
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(norm));
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, "0")).join("");
}

/** The Geoapify URL for a request (the key goes in last). */
export function geoapifyUrl(r: GeoRequest, apiKey: string): URL {
  const u = new URL(AUTOCOMPLETE_URL);
  u.searchParams.set("text", r.text);
  u.searchParams.set("limit", r.kind === "address" ? "5" : "10");
  u.searchParams.set("format", "json");
  if (r.bias) u.searchParams.set("bias", `proximity:${r.bias.lng},${r.bias.lat}`);
  if (r.lang) u.searchParams.set("lang", r.lang);
  u.searchParams.set("apiKey", apiKey);
  return u;
}

/** True for a well-formed Geoapify answer: an object with a results array. */
export function wellFormed(body: unknown): boolean {
  return (
    !!body && typeof body === "object" && Array.isArray((body as { results?: unknown }).results)
  );
}

/** Geoapify's results trimmed to FIELDS; a result without a point or place_id is dropped. */
export function pickResults(body: unknown): GeoResult[] {
  const results = (body as { results?: unknown })?.results;
  if (!Array.isArray(results)) return [];
  const out: GeoResult[] = [];
  for (const r of results.slice(0, 10)) {
    if (!r || typeof r !== "object") continue;
    const o = r as Record<string, unknown>;
    if (typeof o.lat !== "number" || typeof o.lon !== "number") continue;
    if (!Number.isFinite(o.lat) || !Number.isFinite(o.lon)) continue;
    if (typeof o.place_id !== "string" || !o.place_id) continue;
    const pick: Record<string, unknown> = { lat: o.lat, lon: o.lon };
    for (const f of FIELDS) {
      const v = o[f];
      if (typeof v === "string" && v) pick[f] = v.slice(0, 300);
    }
    out.push(pick as GeoResult);
  }
  return out;
}

export interface Deps {
  /** Geoapify's server key, or null: then every answer is { enabled: false }. */
  apiKey: string | null;
  /** The signed-in member's id from the verified token, or null. */
  userId: (token: string) => Promise<string | null>;
  take: (
    userId: string,
    key: string,
  ) => Promise<{ allowed: boolean; cached?: unknown; limit?: string }>;
  store: (key: string, results: GeoResult[]) => Promise<void>;
  fetch: (url: URL) => Promise<Response>;
}

export interface Answer {
  status: number;
  body: Record<string, unknown>;
}

/** One request, start to finish. */
export async function handle(token: string | null, body: unknown, deps: Deps): Promise<Answer> {
  if (!token) return { status: 401, body: { error: "missing_token" } };
  const userId = await deps.userId(token);
  if (!userId) return { status: 401, body: { error: "invalid_token" } };
  // No key: the app falls back to its starter list of cities and to typed addresses.
  if (!deps.apiKey) return { status: 200, body: { enabled: false, results: [] } };
  const req = parseRequest(body);
  if ("error" in req) return { status: 400, body: { error: req.error } };
  const key = await cacheKey(req);
  let grant;
  try {
    grant = await deps.take(userId, key);
  } catch {
    return { status: 500, body: { error: "rpc_failed" } };
  }
  if (!grant.allowed) {
    if (grant.limit === "user_not_found") return { status: 403, body: { error: "user_not_found" } };
    return {
      status: 429,
      body: { error: "too_many_searches", limit: grant.limit === "global" ? "global" : "user" },
    };
  }
  if (Array.isArray(grant.cached)) {
    return { status: 200, body: { enabled: true, results: grant.cached, cached: true } };
  }
  let res: Response;
  try {
    res = await deps.fetch(geoapifyUrl(req, deps.apiKey));
  } catch {
    return { status: 502, body: { error: "lookup_failed" } };
  }
  if (!res.ok) {
    await res.body?.cancel();
    return { status: 502, body: { error: "lookup_failed", upstream: res.status } };
  }
  const raw: unknown = await res.json().catch(() => null);
  // A 200 that is not JSON or has no results array is an upstream fault, not "nothing found":
  // answer 502 and cache nothing, so one bad answer is not served to everyone for 30 days.
  if (!wellFormed(raw))
    return { status: 502, body: { error: "lookup_failed", upstream: res.status } };
  const results = pickResults(raw);
  // Only non-empty answers are cached: an empty one may be a passing upstream hiccup, and the
  // next member's search simply asks again (still counted against both daily limits).
  if (results.length > 0) {
    try {
      await deps.store(key, results);
    } catch {
      // A failed cache write still answers.
    }
  }
  return { status: 200, body: { enabled: true, results } };
}
