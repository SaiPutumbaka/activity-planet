import { queryOptions } from "@tanstack/react-query";

import type { MapLayer } from "./map";
import { supabase } from "./supabase";

/**
 * Shows and games (D-041 slice 10). Ticketed listings (Ticketmaster, SeatGeek) are
 * `listing_kind = 'show'` and get their own "Shows and games" feed row and map layer. Until the
 * API keys exist there are none, so both stay hidden: `shows_available()` (migration 35, anon
 * and signed in) is true while any published public show has not ended. One cached boolean; a
 * failed check counts as "none" so nothing empty ever shows.
 */
export const showsAvailableQuery = queryOptions({
  queryKey: ["shows", "available"] as const,
  queryFn: async () => {
    const { data, error } = await supabase.rpc("shows_available");
    if (error) throw error;
    return data === true;
  },
  staleTime: 10 * 60_000,
  retry: false,
});

/**
 * The map layers to leave out of the layer chips: "shows" while no show exists anywhere and the
 * current view has none either (the view counts too, so a show that just appeared is never
 * behind a hidden chip).
 */
export function hiddenMapLayers(available: boolean | undefined, showsInView: number): MapLayer[] {
  return available === true || showsInView > 0 ? [] : ["shows"];
}
