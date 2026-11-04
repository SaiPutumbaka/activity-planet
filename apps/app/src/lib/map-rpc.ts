import type { MapAdapter, MapInViewArgs, PlacesInViewArgs } from "./map";
import { MapUnavailableError, isMissingRpc } from "./map";
import { supabase } from "./supabase";

/**
 * The real map adapter: `map_in_view`, `places_in_view` and `place_detail` (HUB_MAP_DESIGN §5;
 * migrations 29, 30 and 32) through PostgREST, typed against packages/core/src/types/database.ts.
 * A null `p_hub_ids` is left out so the server's default applies (the viewer's joined hubs, or
 * every specific hub signed out); PostgREST cannot tell an explicit null from a missing argument
 * in the generated types.
 */

interface RpcResult {
  data: unknown;
  error: { code?: string; message?: string; details?: string } | null;
  status?: number;
}

function unwrap({ data, error, status }: RpcResult): unknown {
  if (isMissingRpc(error, status)) throw new MapUnavailableError();
  if (error) throw Object.assign(new Error(error.message ?? "Map request failed"), error);
  return data;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function hubArg(ids: string[] | null): { p_hub_ids?: string[] } {
  return ids === null ? {} : { p_hub_ids: ids };
}

export const rpcMapAdapter: MapAdapter = {
  async mapInView({ p_hub_ids, ...args }: MapInViewArgs) {
    return unwrap(await supabase.rpc("map_in_view", { ...args, ...hubArg(p_hub_ids) }));
  },
  async placesInView({ p_hub_ids, ...args }: PlacesInViewArgs) {
    return unwrap(await supabase.rpc("places_in_view", { ...args, ...hubArg(p_hub_ids) }));
  },
  async placeDetail(id: string) {
    // ?place= comes from the URL: anything but a uuid would be a 22P02 error, not "not found".
    if (!UUID.test(id)) return null;
    const r = await supabase.rpc("place_detail", { p_id: id });
    // place_not_found (P0002): a place the viewer cannot see, or one that is gone.
    if (r.error?.code === "P0002") return null;
    return unwrap(r);
  },
};
