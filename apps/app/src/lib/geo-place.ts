/**
 * Whether a Geoapify autocomplete result is a named place (a park, café, venue or a named
 * building) rather than a street address. Only a named place may default to "Public place"; a
 * street address is somebody's home as often as not, so it starts private and the host is asked
 * (D-038). Kept free of imports so it can be unit tested.
 */
export interface GeoapifyPlaceFields {
  result_type?: string;
  name?: string;
  address_line1?: string;
  housenumber?: string;
}

/** Result types that describe an area or a road, never one place. */
const AREA_TYPES = new Set([
  "street",
  "postcode",
  "suburb",
  "district",
  "city",
  "county",
  "state",
  "country",
  "unknown",
]);

export function isNamedPlace(r: GeoapifyPlaceFields): boolean {
  if (r.result_type === "amenity") return true;
  if (r.result_type && AREA_TYPES.has(r.result_type)) return false;
  const name = r.name?.trim();
  if (!name) return false;
  // A named place's address_line1 is its name; an address result's "name", when present, is the
  // street line, which starts with the house number.
  if (r.housenumber && name.startsWith(r.housenumber)) return false;
  if (/^\d/.test(name)) return false;
  return true;
}
