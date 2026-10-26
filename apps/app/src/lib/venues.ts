import { queryOptions } from "@tanstack/react-query";
import type { Database, Json } from "@ap/core/types";

import { supabase } from "./supabase";

/**
 * Places. Public venues are searchable by name; a hand-typed place goes through upsert_venue,
 * which keeps it private (someone's home) unless the host marks it public. When
 * VITE_GEOAPIFY_KEY is set, the address sub-form offers Geoapify suggestions that fill
 * lat/lng/place_id, and a geocoded place is public by default.
 *
 *   useQuery(venueSearchQuery("piedmont"))   // public venues, name ilike
 *   useQuery(geoapifyQuery("25 park pl"))    // [] when the key is absent
 *   await upsertVenue({ name, address_line1, city, state, postal_code, is_public })
 */
export type Venue = Database["public"]["Tables"]["venues"]["Row"];

/** upsert_venue(p_args). Without place_id the row is private unless is_public is true. */
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
}

interface GeoapifyResult {
  formatted?: string;
  name?: string;
  address_line1?: string;
  city?: string;
  state_code?: string;
  state?: string;
  postcode?: string;
  country_code?: string;
  lat?: number;
  lon?: number;
  place_id?: string;
}

/** Up to five US address suggestions biased to downtown Atlanta. Empty without a key. */
export async function geoapifyAutocomplete(
  text: string,
  signal?: AbortSignal,
): Promise<GeoSuggestion[]> {
  if (!geoapifyKey) return [];
  const url = new URL("https://api.geoapify.com/v1/geocode/autocomplete");
  url.searchParams.set("text", text);
  url.searchParams.set("limit", "5");
  url.searchParams.set("filter", "countrycode:us");
  url.searchParams.set("bias", "proximity:-84.3880,33.7490");
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
        country: (r.country_code ?? "us").toUpperCase(),
        lat: r.lat,
        lng: r.lon,
        place_id: r.place_id,
      },
    ];
  });
}

export const geoapifyQuery = (text: string) => {
  const q = text.trim();
  return queryOptions({
    queryKey: ["geoapify", q.toLowerCase()] as const,
    queryFn: ({ signal }) => geoapifyAutocomplete(q, signal),
    enabled: geoapifyKey !== null && q.length >= 4,
    staleTime: 5 * 60_000,
    retry: 0,
  });
};
