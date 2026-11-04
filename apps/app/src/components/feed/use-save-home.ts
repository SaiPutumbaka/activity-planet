import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import {
  areaErrorMessage,
  feedPrefsQuery,
  setHomeArea,
  setHomeLocation,
  type HomeChoice,
} from "@/lib/location";

export type SaveHomeInput =
  /** A new home; the radius stays what it is. */
  | { type: "place"; choice: HomeChoice; radiusKm: number }
  /** A new radius around the saved home. */
  | { type: "radius"; radiusKm: number };

/**
 * Saves the home location or the radius, then refreshes the saved home and the feed. A point goes
 * through set_home_location, a named area through set_home_area (both keep the radius); a radius
 * change re-saves the current home with the new radius. Shared by the Home location sheet and the
 * You tab.
 */
export function useSaveHome(userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: async (input: SaveHomeInput) => {
      if (input.type === "place") {
        const c = input.choice;
        if (c.kind === "point") await setHomeLocation(c.lat, c.lng, c.label);
        else await setHomeArea(c.areaId, input.radiusKm);
        return;
      }
      const prefs = await queryClient.ensureQueryData(feedPrefsQuery(userId));
      if (prefs.homeAreaId) await setHomeArea(prefs.homeAreaId, input.radiusKm);
      else if (prefs.homePoint)
        await setHomeLocation(
          prefs.homePoint.lat,
          prefs.homePoint.lng,
          prefs.homeLabel,
          input.radiusKm,
        );
      else throw new Error("home_required");
    },
    onSuccess: async (_data, input) => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: feedPrefsQuery(userId).queryKey }),
        queryClient.invalidateQueries({ queryKey: ["feed"] }),
      ]);
      if (input.type === "place")
        toast.success(
          input.choice.label
            ? `Home set to ${input.choice.label}.`
            : "Home set to your current location.",
        );
    },
    onError: (err) =>
      toast.error(
        err instanceof Error && err.message === "home_required"
          ? "Pick a place first, then a distance."
          : areaErrorMessage(err),
      ),
  });
}
