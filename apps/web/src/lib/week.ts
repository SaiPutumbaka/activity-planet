import { parseWeekCards, type WeekCard } from "@ap/core/recs";

import { createAnonServerClient } from "./supabase-server";

/**
 * "This week near you" for the landing page (RECS_DESIGN section 8): public_week_near as an
 * anonymous visitor. The point is already rounded to 0.1 degree by the caller; null means the
 * server's Atlanta default. Null result: the data could not be loaded (no keys in this build, or
 * the call failed), which the page shows as a quiet retry note rather than an empty week.
 *
 * Nothing about the request is read or logged: no IP, no headers, no geolocation.
 */
export async function getWeekNear(
  point: { lat: number; lng: number } | null,
): Promise<WeekCard[] | null> {
  let supabase;
  try {
    supabase = createAnonServerClient();
  } catch {
    return null;
  }
  const { data, error } = await supabase.rpc("public_week_near", {
    ...(point ? { p_lat: point.lat, p_lng: point.lng } : {}),
    p_limit: 12,
  });
  if (error) {
    console.error("public_week_near failed", error.code ?? "unknown");
    return null;
  }
  return parseWeekCards(data);
}
