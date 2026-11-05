// The venue_geocodes key (migration 63, import_location_key): sha256 hex of the location text
// lower-cased, every run of ASCII punctuation, symbols, spaces and controls turned into one space
// and trimmed, then "|", then the source region's latitude and longitude rounded to 0.1 degree
// half away from zero ("33.7,-84.4"; never "-0.0"). The SQL function and this one are tested on
// the same fixture strings (test/geocode.test.ts, supabase/tests/venue_geocoding.sql).

import { createHash } from "node:crypto";

/** The text part of the key. */
export function normalizeLocation(text: string): string {
  return (
    text
      .toLowerCase()
      // eslint-disable-next-line no-control-regex -- the SQL twin replaces the same ASCII range
      .replace(/[\x01-\x2f\x3a-\x40\x5b-\x60\x7b-\x7f]+/g, " ")
      .replace(/^ +| +$/g, "")
  );
}

/**
 * x rounded to one decimal as Postgres rounds numeric (half away from zero), from the shortest
 * decimal form of the double (what float8 to numeric gives), so 51.05 is 51.1, not 51.0.
 */
export function round1(x: number): string {
  const s = Math.abs(x).toPrecision(15);
  const [int = "0", frac = ""] = (s.includes("e") ? Math.abs(x).toFixed(10) : s).split(".");
  const first = Number(frac[0] ?? "0");
  const next = Number(frac[1] ?? "0");
  let tenths = Number(int) * 10 + first + (next >= 5 ? 1 : 0);
  if (tenths === 0) return "0.0";
  const sign = x < 0 ? "-" : "";
  const whole = Math.floor(tenths / 10);
  tenths %= 10;
  return `${sign}${whole}.${tenths}`;
}

/** The key, or null without a text. */
export function locationKey(location: string, region: { lat: number; lng: number }): string | null {
  if (location.trim() === "") return null;
  const raw = `${normalizeLocation(location)}|${round1(region.lat)},${round1(region.lng)}`;
  return createHash("sha256").update(raw, "utf8").digest("hex");
}
