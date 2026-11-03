import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { areaErrorMessage, feedPrefsQuery, setHomeArea } from "@/lib/location";

/**
 * Saves the home area and radius through set_home_area (no radius means the area's default), then
 * refreshes the saved home area and radius and the feed. Shared by the Home location sheet and the You tab rows.
 */
export function useSaveHomeArea(userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ areaId, radiusKm }: { areaId: string; radiusKm?: number }) =>
      setHomeArea(areaId, radiusKm),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: feedPrefsQuery(userId).queryKey }),
        queryClient.invalidateQueries({ queryKey: ["feed"] }),
      ]);
    },
    onError: (err) => toast.error(areaErrorMessage(err)),
  });
}
