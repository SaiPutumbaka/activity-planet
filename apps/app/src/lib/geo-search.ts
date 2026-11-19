import { supabase } from "./supabase";

/**
 * Address and city autocomplete through the geo-search Edge Function (migration 80). The
 * Geoapify key lives only on the server; the function needs the signed-in member's session,
 * caps searches per member and per day, caches answers and returns only the fields the app reads.
 * When the project has no Geoapify key the function answers { enabled: false }: from then on this
 * tab stops asking and callers fall back (the starter city list, typed addresses).
 *
 *   const { enabled, results } = await geoSearch("city", "lisb", { lang: "pt" })
 *   geoSearchAvailable()   // false once the server said it has no key
 */
export type GeoSearchKind = "address" | "city";

/** The Geoapify fields geo-search returns (supabase/functions/geo-search/search.ts FIELDS). */
export interface GeoSearchResult {
  formatted?: string;
  name?: string;
  address_line1?: string;
  housenumber?: string;
  result_type?: string;
  suburb?: string;
  district?: string;
  city?: string;
  county?: string;
  state_code?: string;
  state?: string;
  postcode?: string;
  country_code?: string;
  country?: string;
  lat?: number;
  lon?: number;
  place_id?: string;
}

export interface GeoSearchAnswer {
  enabled: boolean;
  results: GeoSearchResult[];
}

let serverOff = false;

/** False once geo-search said this project has no Geoapify key (for this tab). */
export function geoSearchAvailable(): boolean {
  return !serverOff;
}

/** Test hook: forget what the server said. */
export function resetGeoSearchAvailability(): void {
  serverOff = false;
}

/** Reads the function's answer; anything unexpected is treated as no results. */
export function parseGeoSearchAnswer(data: unknown): GeoSearchAnswer {
  if (!data || typeof data !== "object") return { enabled: true, results: [] };
  const d = data as { enabled?: unknown; results?: unknown };
  const enabled = d.enabled !== false;
  const results = Array.isArray(d.results)
    ? (d.results.filter((r) => r && typeof r === "object") as GeoSearchResult[])
    : [];
  return { enabled, results };
}

export async function geoSearch(
  kind: GeoSearchKind,
  text: string,
  opts: {
    bias?: { lat: number; lng: number } | null;
    lang?: string | null;
    signal?: AbortSignal;
  } = {},
): Promise<GeoSearchAnswer> {
  if (serverOff) return { enabled: false, results: [] };
  const body: Record<string, unknown> = { kind, text };
  if (opts.bias) body.bias = { lat: opts.bias.lat, lng: opts.bias.lng };
  if (opts.lang) body.lang = opts.lang;
  const { data, error } = await supabase.functions.invoke("geo-search", {
    body,
    ...(opts.signal ? { signal: opts.signal } : {}),
  });
  if (error) {
    const status = (error as { context?: { status?: number } }).context?.status;
    throw new Error(
      status === 429 ? "Too many searches today. Type the address instead." : "Lookup failed.",
    );
  }
  const answer = parseGeoSearchAnswer(data);
  if (!answer.enabled) serverOff = true;
  return answer;
}
