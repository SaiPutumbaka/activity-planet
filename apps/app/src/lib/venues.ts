import { queryOptions } from "@tanstack/react-query";
import type { Database, Json } from "@ap/core/types";

import { isFilePlaceId, placeRowId } from "./file-place-row";
import { isNamedPlace } from "./geo-place";
import { supabase } from "./supabase";

/**
 * Places. Public venues are searchable by name; every new place goes through upsert_venue,
 * which keeps it private (someone's home) unless is_public: true is passed (D-038; a geocoder
 * place_id no longer implies public). When VITE_GEOAPIFY_KEY is set, the address sub-form offers
 * Geoapify suggestions that fill lat/lng/place_id.
 *
 *   useQuery(venueSearchQuery("piedmont"))   // public venues, name ilike
 *   useQuery(geoapifyQuery("25 park pl"))    // [] when the key is absent
 *   await upsertVenue({ name, address_line1, city, state, postal_code, is_public })
 */
export type Venue = Database["public"]["Tables"]["venues"]["Row"];

/** upsert_venue(p_args). The row is private unless is_public is true. */
export type UpsertVenueArgs = {
  name: string;
  address_line1?: string;
  address_line2?: string;
  city?: string;
  state?: string;
  postal_code?: string;
  country?: string;
  lat?: number | null;
  lng?: number | null;
  place_id?: string | null;
  campus_id?: string | null;
  is_public?: boolean;
};

export async function upsertVenue(args: UpsertVenueArgs): Promise<Venue> {
  const { data, error } = await supabase.rpc("upsert_venue", { p_args: args as Json });
  if (error) throw error;
  return data;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * A place id from the map: a uuid, or "o:<osm_ref>" for a place read from a static file, which
 * gets its database row first (D-042 slice 11; an ODbL import with no user id, never a venue).
 * Null when it is neither or no row can be had.
 */
async function rowIdOrNull(id: string): Promise<string | null> {
  if (UUID.test(id)) return id;
  if (!isFilePlaceId(id)) return null;
  try {
    const row = await placeRowId(id);
    return UUID.test(row) ? row : null;
  } catch {
    return null;
  }
}

/**
 * "Start a plan here" (`/post?place=<id>`, migration 33): the public venue that is this map
 * place, made from the place's public facts the first time. Null when the id is not a uuid or the
 * place is not an active public place the viewer can see (place_not_found).
 */
export async function venueForPlace(id: string): Promise<Venue | null> {
  const placeId = await rowIdOrNull(id);
  if (!placeId) return null;
  const { data, error } = await supabase.rpc("venue_for_place", { p_place_id: placeId });
  if (error?.code === "P0002") return null;
  if (error) throw error;
  return data;
}

/** What "Start a plan here" shows before posting: the place's public venue, if it has one yet. */
export interface PlaceVenuePreview {
  placeId: string;
  /** The existing public venue, or null when venue_for_place will make one on posting. */
  venueId: string | null;
  name: string;
}

/**
 * The read-only lookup for `/post?place=<id>` (venue_preview_for_place, migration 36): creates
 * nothing, so opening or prefetching the link never makes a venue in the viewer's name. Null on
 * the same cases as venueForPlace.
 */
export async function placeVenuePreview(id: string): Promise<PlaceVenuePreview | null> {
  const placeId = await rowIdOrNull(id);
  if (!placeId) return null;
  const { data, error } = await supabase.rpc("venue_preview_for_place", { p_place_id: placeId });
  if (error?.code === "P0002") return null;
  if (error) throw error;
  const row = (data ?? {}) as { place_id?: string; venue_id?: string | null; name?: string };
  if (!row.place_id) return null;
  return { placeId: row.place_id, venueId: row.venue_id ?? null, name: row.name ?? "" };
}

export const placeVenuePreviewQuery = (placeId: string) =>
  queryOptions({
    queryKey: ["venues", "place-preview", placeId] as const,
    queryFn: () => placeVenuePreview(placeId),
    staleTime: 60_000,
    retry: 1,
  });

/** The form's venue id for a map place that has no venue yet; resolved on posting. */
const PLACE_VENUE_PREFIX = "place:";

export function placeVenueToken(placeId: string): string {
  return `${PLACE_VENUE_PREFIX}${placeId}`;
}

/** The place id of a placeVenueToken, else null (a real venue id). */
export function placeFromVenueToken(venueId: string | null | undefined): string | null {
  return venueId?.startsWith(PLACE_VENUE_PREFIX) ? venueId.slice(PLACE_VENUE_PREFIX.length) : null;
}

const VENUE_SEARCH_SELECT =
  "id,name,address_line1,address_line2,city,state,postal_code,is_public,place_id" as const;

/** Escapes the LIKE wildcards in a person's search text. */
function escapeLike(value: string): string {
  return value.replace(/[\\%_]/g, (c) => `\\${c}`);
}

/** Public venues whose name contains the text (two characters or more). */
export const venueSearchQuery = (text: string) => {
  const q = text.trim();
  return queryOptions({
    queryKey: ["venues", "search", q.toLowerCase()] as const,
    queryFn: async () => {
      const { data, error } = await supabase
        .from("venues")
        .select(VENUE_SEARCH_SELECT)
        .eq("is_public", true)
        .ilike("name", `%${escapeLike(q)}%`)
        .order("name")
        .limit(8);
      if (error) throw error;
      return data;
    },
    enabled: q.length >= 2,
    staleTime: 60_000,
  });
};

export type VenueSearchResult = Pick<
  Venue,
  | "id"
  | "name"
  | "address_line1"
  | "address_line2"
  | "city"
  | "state"
  | "postal_code"
  | "is_public"
  | "place_id"
>;

/** One line of address for lists and the event page: "25 Park Pl, Atlanta, GA 30303". */
export function formatVenueAddress(v: {
  address_line1: string;
  address_line2?: string;
  city: string;
  state: string;
  postal_code: string;
}): string {
  const street = [v.address_line1, v.address_line2].filter(Boolean).join(", ");
  const cityState = [v.city, [v.state, v.postal_code].filter(Boolean).join(" ")]
    .filter(Boolean)
    .join(", ");
  return [street, cityState].filter(Boolean).join(", ");
}

/* ------------------------------------------------------------------ */
/* Geoapify autocomplete (optional)                                    */
/* ------------------------------------------------------------------ */

export const geoapifyKey = (import.meta.env.VITE_GEOAPIFY_KEY as string | undefined) || null;

export interface GeoSuggestion {
  label: string;
  name: string;
  address_line1: string;
  city: string;
  state: string;
  postal_code: string;
  country: string;
  lat: number;
  lng: number;
  place_id: string;
  /** A park, café, venue or named building, not a street address (lib/geo-place.ts). */
  namedPlace: boolean;
}

interface GeoapifyResult {
  formatted?: string;
  name?: string;
  address_line1?: string;
  housenumber?: string;
  result_type?: string;
  city?: string;
  state_code?: string;
  state?: string;
  postcode?: string;
  country_code?: string;
  lat?: number;
  lon?: number;
  place_id?: string;
}

/** A point to rank nearby suggestions first (the host's saved home); none means no bias. */
export type GeoBias = { lat: number; lng: number } | null;

/**
 * Up to five address suggestions anywhere in the world (D-040), ranked near `bias` when given.
 * Empty without a key.
 */
export async function geoapifyAutocomplete(
  text: string,
  bias: GeoBias = null,
  signal?: AbortSignal,
): Promise<GeoSuggestion[]> {
  if (!geoapifyKey) return [];
  const url = new URL("https://api.geoapify.com/v1/geocode/autocomplete");
  url.searchParams.set("text", text);
  url.searchParams.set("limit", "5");
  if (bias) url.searchParams.set("bias", `proximity:${bias.lng},${bias.lat}`);
  url.searchParams.set("format", "json");
  url.searchParams.set("apiKey", geoapifyKey);
  const res = await fetch(url, { signal });
  if (!res.ok) throw new Error(`Address lookup failed (${res.status}).`);
  const body = (await res.json()) as { results?: GeoapifyResult[] };
  return (body.results ?? []).flatMap((r) => {
    if (typeof r.lat !== "number" || typeof r.lon !== "number" || !r.place_id) return [];
    return [
      {
        label: r.formatted ?? r.address_line1 ?? "",
        name: r.name ?? r.address_line1 ?? "",
        address_line1: r.address_line1 ?? "",
        city: r.city ?? "",
        state: r.state_code ?? r.state ?? "",
        postal_code: r.postcode ?? "",
        country: (r.country_code ?? "").toUpperCase(),
        lat: r.lat,
        lng: r.lon,
        place_id: r.place_id,
        namedPlace: isNamedPlace(r),
      },
    ];
  });
}

export const geoapifyQuery = (text: string, bias: GeoBias = null) => {
  const q = text.trim();
  return queryOptions({
    queryKey: ["geoapify", q.toLowerCase(), bias?.lat ?? null, bias?.lng ?? null] as const,
    queryFn: ({ signal }) => geoapifyAutocomplete(q, bias, signal),
    enabled: geoapifyKey !== null && q.length >= 4,
    staleTime: 5 * 60_000,
    retry: 0,
  });
};
