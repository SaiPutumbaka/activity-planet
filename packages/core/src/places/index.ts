/**
 * Places for the home location (D-040), pure so they can be tested without a browser or a
 * database. Anyone, anywhere: a typed city is geocoded by Geoapify when the app has a key, and
 * matched against this starter list of major world cities otherwise.
 *
 *   searchStarterCities("lon")                       // [London]
 *   formatPlaceLabel({ name: "Austin", region: "Texas", country: "United States" })
 *                                                    // "Austin, Texas, United States"
 *   shortPlaceLabel("Austin, Texas, United States")  // "Austin"
 *   feedOriginLabel({ usingDevice: false, homeLabel: "Lisbon, Portugal" })   // "Lisbon"
 *   parseGeoPoint("0101000020E6100000...")            // { lat, lng } from PostgREST's EWKB hex
 */

export interface StarterCity {
  /** Stable, URL-safe id. */
  id: string;
  name: string;
  /** State, province or region, when it helps tell cities apart. */
  region?: string;
  country: string;
  /** ISO 3166-1 alpha-2. */
  countryCode: string;
  lat: number;
  lng: number;
  /** Other names people type ("NYC", "Bombay"). */
  aliases?: readonly string[];
}

/** The longest label profile_private.home_label accepts. */
export const MAX_PLACE_LABEL = 120;

/**
 * Major cities on every inhabited continent, with city-centre coordinates to two decimals (the
 * precision a home point is saved at). Atlanta is not here: the app offers it, with its
 * neighborhoods, from the areas table.
 */
// prettier-ignore
export const STARTER_CITIES: readonly StarterCity[] = [
  // North America
  { id: "new-york", name: "New York", region: "New York", country: "United States", countryCode: "US", lat: 40.71, lng: -74.01, aliases: ["NYC", "New York City", "Manhattan", "Brooklyn"] },
  { id: "los-angeles", name: "Los Angeles", region: "California", country: "United States", countryCode: "US", lat: 34.05, lng: -118.24, aliases: ["LA"] },
  { id: "chicago", name: "Chicago", region: "Illinois", country: "United States", countryCode: "US", lat: 41.88, lng: -87.63 },
  { id: "houston", name: "Houston", region: "Texas", country: "United States", countryCode: "US", lat: 29.76, lng: -95.37 },
  { id: "austin", name: "Austin", region: "Texas", country: "United States", countryCode: "US", lat: 30.27, lng: -97.74 },
  { id: "san-francisco", name: "San Francisco", region: "California", country: "United States", countryCode: "US", lat: 37.77, lng: -122.42, aliases: ["SF", "Bay Area"] },
  { id: "seattle", name: "Seattle", region: "Washington", country: "United States", countryCode: "US", lat: 47.61, lng: -122.33 },
  { id: "miami", name: "Miami", region: "Florida", country: "United States", countryCode: "US", lat: 25.76, lng: -80.19 },
  { id: "washington-dc", name: "Washington", region: "District of Columbia", country: "United States", countryCode: "US", lat: 38.91, lng: -77.04, aliases: ["DC", "Washington DC"] },
  { id: "boston", name: "Boston", region: "Massachusetts", country: "United States", countryCode: "US", lat: 42.36, lng: -71.06 },
  { id: "toronto", name: "Toronto", region: "Ontario", country: "Canada", countryCode: "CA", lat: 43.65, lng: -79.38 },
  { id: "vancouver", name: "Vancouver", region: "British Columbia", country: "Canada", countryCode: "CA", lat: 49.28, lng: -123.12 },
  { id: "montreal", name: "Montréal", region: "Quebec", country: "Canada", countryCode: "CA", lat: 45.5, lng: -73.57, aliases: ["Montreal"] },
  { id: "mexico-city", name: "Mexico City", country: "Mexico", countryCode: "MX", lat: 19.43, lng: -99.13, aliases: ["Ciudad de México", "CDMX"] },
  // South America
  { id: "sao-paulo", name: "São Paulo", country: "Brazil", countryCode: "BR", lat: -23.55, lng: -46.63 },
  { id: "rio-de-janeiro", name: "Rio de Janeiro", country: "Brazil", countryCode: "BR", lat: -22.91, lng: -43.17, aliases: ["Rio"] },
  { id: "buenos-aires", name: "Buenos Aires", country: "Argentina", countryCode: "AR", lat: -34.6, lng: -58.38 },
  { id: "bogota", name: "Bogotá", country: "Colombia", countryCode: "CO", lat: 4.71, lng: -74.07 },
  { id: "lima", name: "Lima", country: "Peru", countryCode: "PE", lat: -12.05, lng: -77.04 },
  // Europe
  { id: "london", name: "London", country: "United Kingdom", countryCode: "GB", lat: 51.51, lng: -0.13 },
  { id: "dublin", name: "Dublin", country: "Ireland", countryCode: "IE", lat: 53.35, lng: -6.26 },
  { id: "paris", name: "Paris", country: "France", countryCode: "FR", lat: 48.86, lng: 2.35 },
  { id: "berlin", name: "Berlin", country: "Germany", countryCode: "DE", lat: 52.52, lng: 13.4 },
  { id: "madrid", name: "Madrid", country: "Spain", countryCode: "ES", lat: 40.42, lng: -3.7 },
  { id: "barcelona", name: "Barcelona", country: "Spain", countryCode: "ES", lat: 41.39, lng: 2.17 },
  { id: "lisbon", name: "Lisbon", country: "Portugal", countryCode: "PT", lat: 38.72, lng: -9.14, aliases: ["Lisboa"] },
  { id: "rome", name: "Rome", country: "Italy", countryCode: "IT", lat: 41.9, lng: 12.5, aliases: ["Roma"] },
  { id: "amsterdam", name: "Amsterdam", country: "Netherlands", countryCode: "NL", lat: 52.37, lng: 4.9 },
  { id: "stockholm", name: "Stockholm", country: "Sweden", countryCode: "SE", lat: 59.33, lng: 18.07 },
  { id: "istanbul", name: "Istanbul", country: "Türkiye", countryCode: "TR", lat: 41.01, lng: 28.98 },
  // Africa and the Middle East
  { id: "cairo", name: "Cairo", country: "Egypt", countryCode: "EG", lat: 30.04, lng: 31.24 },
  { id: "lagos", name: "Lagos", country: "Nigeria", countryCode: "NG", lat: 6.52, lng: 3.38 },
  { id: "nairobi", name: "Nairobi", country: "Kenya", countryCode: "KE", lat: -1.29, lng: 36.82 },
  { id: "johannesburg", name: "Johannesburg", country: "South Africa", countryCode: "ZA", lat: -26.2, lng: 28.05, aliases: ["Joburg"] },
  { id: "dubai", name: "Dubai", country: "United Arab Emirates", countryCode: "AE", lat: 25.2, lng: 55.27 },
  // Asia
  { id: "mumbai", name: "Mumbai", region: "Maharashtra", country: "India", countryCode: "IN", lat: 19.08, lng: 72.88, aliases: ["Bombay"] },
  { id: "delhi", name: "Delhi", country: "India", countryCode: "IN", lat: 28.61, lng: 77.21, aliases: ["New Delhi"] },
  { id: "bengaluru", name: "Bengaluru", region: "Karnataka", country: "India", countryCode: "IN", lat: 12.97, lng: 77.59, aliases: ["Bangalore"] },
  { id: "singapore", name: "Singapore", country: "Singapore", countryCode: "SG", lat: 1.35, lng: 103.82 },
  { id: "bangkok", name: "Bangkok", country: "Thailand", countryCode: "TH", lat: 13.76, lng: 100.5 },
  { id: "jakarta", name: "Jakarta", country: "Indonesia", countryCode: "ID", lat: -6.21, lng: 106.85 },
  { id: "manila", name: "Manila", country: "Philippines", countryCode: "PH", lat: 14.6, lng: 120.98, aliases: ["Metro Manila"] },
  { id: "hong-kong", name: "Hong Kong", country: "Hong Kong", countryCode: "HK", lat: 22.32, lng: 114.17 },
  { id: "seoul", name: "Seoul", country: "South Korea", countryCode: "KR", lat: 37.57, lng: 126.98 },
  { id: "tokyo", name: "Tokyo", country: "Japan", countryCode: "JP", lat: 35.68, lng: 139.69 },
  // Oceania
  { id: "sydney", name: "Sydney", region: "New South Wales", country: "Australia", countryCode: "AU", lat: -33.87, lng: 151.21 },
  { id: "melbourne", name: "Melbourne", region: "Victoria", country: "Australia", countryCode: "AU", lat: -37.81, lng: 144.96 },
  { id: "auckland", name: "Auckland", country: "New Zealand", countryCode: "NZ", lat: -36.85, lng: 174.76 },
];

/** Lower case, accents removed, runs of space and punctuation collapsed: "São  Paulo" → "sao paulo". */
export function normalizePlaceText(value: string): string {
  return value
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, " ")
    .trim();
}

/**
 * "Name, Region, Country" from whatever parts exist: blanks dropped, whitespace collapsed, a part
 * repeated by the next one dropped ("Singapore, Singapore" is "Singapore"), at most 120 characters.
 */
export function formatPlaceLabel(parts: {
  name?: string | null;
  region?: string | null;
  country?: string | null;
}): string {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const raw of [parts.name, parts.region, parts.country]) {
    const part = (raw ?? "").replace(/\s+/g, " ").trim();
    if (!part) continue;
    const key = normalizePlaceText(part);
    if (seen.has(key)) continue;
    seen.add(key);
    out.push(part);
  }
  const label = out.join(", ");
  return label.length > MAX_PLACE_LABEL ? label.slice(0, MAX_PLACE_LABEL).trimEnd() : label;
}

/** The full label of a starter city. */
export function starterCityLabel(city: StarterCity): string {
  return formatPlaceLabel({ name: city.name, region: city.region, country: city.country });
}

/** The first part of a label, for tight spots like the feed chip: "Austin, Texas" → "Austin". */
export function shortPlaceLabel(label: string | null | undefined): string | null {
  const first = (label ?? "").split(",")[0]?.replace(/\s+/g, " ").trim();
  return first ? first : null;
}

/**
 * What the feed chip says: "Near you" for a device point or when no label was saved (a saved
 * "Use my location"), else the first part of the saved label. Never a city the person didn't pick.
 */
export function feedOriginLabel(p: {
  usingDevice: boolean;
  homeLabel: string | null | undefined;
}): string {
  if (p.usingDevice) return "Near you";
  return shortPlaceLabel(p.homeLabel) ?? "Near you";
}

/**
 * How well `query` matches a name and its aliases: 3 for an exact match, 2 for a prefix, 1 for a
 * word prefix, 0 for none. Both sides are normalized, so accents and case don't matter.
 */
export function placeMatchScore(query: string, names: readonly string[]): number {
  const q = normalizePlaceText(query);
  if (!q) return 0;
  let best = 0;
  for (const raw of names) {
    const n = normalizePlaceText(raw);
    if (!n) continue;
    if (n === q) return 3;
    if (n.startsWith(q)) best = Math.max(best, 2);
    else if (n.split(" ").some((w) => w.startsWith(q)) || n.includes(` ${q}`))
      best = Math.max(best, 1);
  }
  return best;
}

/** Starter cities matching the query, best first then alphabetical; empty for an empty query. */
export function searchStarterCities(
  query: string,
  cities: readonly StarterCity[] = STARTER_CITIES,
  limit = 8,
): StarterCity[] {
  return cities
    .map((c) => ({ c, score: placeMatchScore(query, [c.name, ...(c.aliases ?? [])]) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score || a.c.name.localeCompare(b.c.name))
    .slice(0, limit)
    .map((x) => x.c);
}

/* ------------------------------------------------------------------ */
/* Geoapify city results                                                */
/* ------------------------------------------------------------------ */

/** The Geoapify autocomplete fields a city or neighborhood result needs. */
export interface GeoapifyCityFields {
  result_type?: string;
  name?: string;
  suburb?: string;
  district?: string;
  city?: string;
  county?: string;
  state?: string;
  country?: string;
  lat?: number;
  lon?: number;
  place_id?: string;
}

export interface PlaceResult {
  id: string;
  name: string;
  label: string;
  lat: number;
  lng: number;
}

/** Result types that name a city or a part of one. Streets, venues and addresses are left out. */
const CITY_TYPES = new Set(["city", "suburb", "district", "county"]);

/**
 * A Geoapify result as a home place, or null when it is not a city, town or neighborhood or has
 * no coordinates. A neighborhood keeps its city in the label: "Shoreditch, London, United Kingdom".
 */
export function geoapifyCityToPlace(r: GeoapifyCityFields): PlaceResult | null {
  if (typeof r.lat !== "number" || typeof r.lon !== "number" || !r.place_id) return null;
  if (!Number.isFinite(r.lat) || !Number.isFinite(r.lon)) return null;
  if (r.result_type && !CITY_TYPES.has(r.result_type)) return null;
  const local = r.result_type === "city" ? undefined : (r.suburb ?? r.district);
  const name = (r.name ?? local ?? r.city ?? r.county ?? "").trim();
  if (!name) return null;
  const middle = r.result_type === "city" ? r.state : (r.city ?? r.county ?? r.state);
  const label = formatPlaceLabel({ name, region: middle, country: r.country });
  return { id: r.place_id, name, label, lat: r.lat, lng: r.lon };
}

/* ------------------------------------------------------------------ */
/* Reading a saved point                                                */
/* ------------------------------------------------------------------ */

/**
 * A PostGIS point as { lat, lng }. PostgREST returns a geography column as hex EWKB
 * ("0101000020E6100000" + x + y); GeoJSON ({ type: "Point", coordinates: [lng, lat] }) is
 * accepted too. Anything else, or a point off the globe, is null.
 */
export function parseGeoPoint(value: unknown): { lat: number; lng: number } | null {
  let lng: number | undefined;
  let lat: number | undefined;
  if (typeof value === "string") {
    const hex = value.trim();
    if (!/^[0-9a-fA-F]+$/.test(hex) || hex.length % 2 !== 0 || hex.length < 42) return null;
    const bytes = new Uint8Array(hex.length / 2);
    for (let i = 0; i < bytes.length; i++) bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
    const view = new DataView(bytes.buffer);
    const little = bytes[0] === 1;
    const type = view.getUint32(1, little);
    if ((type & 0xff) !== 1) return null; // not a Point
    let offset = 5;
    if (type & 0x20000000) offset += 4; // SRID
    if (bytes.length < offset + 16) return null;
    lng = view.getFloat64(offset, little);
    lat = view.getFloat64(offset + 8, little);
  } else if (
    value &&
    typeof value === "object" &&
    (value as { type?: unknown }).type === "Point" &&
    Array.isArray((value as { coordinates?: unknown }).coordinates)
  ) {
    const [x, y] = (value as { coordinates: unknown[] }).coordinates;
    if (typeof x === "number" && typeof y === "number") {
      lng = x;
      lat = y;
    }
  }
  if (lat === undefined || lng === undefined) return null;
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  return { lat, lng };
}
