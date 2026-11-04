import type { MapAdapter, MapInViewArgs, PlacesInViewArgs } from "./map";
import { MapUnavailableError, isMissingRpc } from "./map";
import { supabase } from "./supabase";

/**
 * The real map adapter: the three §5 RPCs through PostgREST.
 *
 * TODO(map-rpc): `map_in_view`, `places_in_view` and `place_detail` are not in
 * packages/core/src/types/database.ts yet (slice 6), so the calls go through an untyped `rpc`.
 * Once the migration lands and the types are regenerated, delete `untypedRpc` and call
 * `supabase.rpc("map_in_view", args)` directly so the argument names are checked.
 */

interface RpcError {
  code?: string;
  message?: string;
  details?: string;
}

type UntypedRpc = (
  fn: string,
  args: Record<string, unknown>,
) => PromiseLike<{ data: unknown; error: RpcError | null; status?: number }>;

const untypedRpc = supabase.rpc.bind(supabase) as unknown as UntypedRpc;

async function call(fn: string, args: Record<string, unknown>): Promise<unknown> {
  const { data, error, status } = await untypedRpc(fn, args);
  if (isMissingRpc(error, status)) throw new MapUnavailableError();
  if (error) throw Object.assign(new Error(error.message ?? "Map request failed"), error);
  return data;
}

export const rpcMapAdapter: MapAdapter = {
  mapInView: (args: MapInViewArgs) => call("map_in_view", { ...args }),
  placesInView: (args: PlacesInViewArgs) => call("places_in_view", { ...args }),
  placeDetail: (id: string) => call("place_detail", { p_id: id }),
};
