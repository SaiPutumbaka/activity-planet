import { supabase } from "./supabase";

/**
 * The database row of a place opened from a static tile file (D-042 slice 11, migration 49).
 * Map pins read from a file are "o:<osm_ref>". Reports, corrections and "Start a plan here" need
 * a database id, so before acting:
 *   1. place_id_by_osm_ref: the row, while Postgres still has it;
 *   2. else the place-files Edge Function (POST place-files/place {osm_ref, tile}, signed in),
 *      which reads the tile's published file, checks its sha256 and asks place_from_file for the
 *      row (an ODbL import with no user id; a place a moderator hid or removed stays gone).
 * Any other id is returned as it is. Throws place_unavailable when no row can be had.
 */

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FILE_ID = /^o:([nwr][0-9]{1,15})$/;

export class PlaceUnavailableError extends Error {
  constructor(readonly reason: string) {
    super("place_unavailable");
  }
}

export function isFilePlaceId(id: string): boolean {
  return FILE_ID.test(id);
}

export async function placeRowId(id: string): Promise<string> {
  const ref = FILE_ID.exec(id)?.[1];
  if (!ref) return id;
  const found = await supabase.rpc("place_id_by_osm_ref", { p_osm_ref: ref });
  if (!found.error && typeof found.data === "string" && UUID.test(found.data)) return found.data;
  const { fileRowTile } = await import("./place-files");
  const tile = fileRowTile(ref);
  if (tile === null) throw new PlaceUnavailableError("not_loaded");
  const { data, error } = await supabase.functions.invoke<{ id?: string | null; reason?: string }>(
    "place-files/place",
    { body: { osm_ref: ref, tile } },
  );
  if (error) throw new PlaceUnavailableError("request_failed");
  if (typeof data?.id === "string" && UUID.test(data.id)) return data.id;
  throw new PlaceUnavailableError(typeof data?.reason === "string" ? data.reason : "unknown");
}

/**
 * A moderation card's "nearby on the map" from the static files (design §4.5: "three public
 * places within 150 m"): the published file holding the point (place_file_at), read through the
 * same cache as the map, up to three places within 150 m. [] while the app reads no files.
 */
export async function filePlacesNearPoint(
  lat: number,
  lng: number,
): Promise<import("./place-files").NearbyFilePlace[]> {
  const files = await import("./place-files");
  const base = files.placesBaseUrl();
  if (!base) return [];
  const { data, error } = await supabase.rpc("place_file_at", { p_lat: lat, p_lng: lng });
  const file = (error ? null : data) as { tile?: number; path?: string } | null;
  if (!file || typeof file.path !== "string" || !Number.isInteger(file.tile)) return [];
  const tile = files.decodeTileFile(await files.sharedLoader(base).load(file.path));
  files.rememberTile(tile.tile, tile.rows);
  return files.filePlacesNear({ lat, lng }, 150, tile.rows).slice(0, 3);
}
