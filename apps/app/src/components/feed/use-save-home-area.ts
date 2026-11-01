import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { areaErrorMessage, feedRadiusQuery, setHomeArea } from "@/lib/location";
import { profileQuery } from "@/lib/profile";

/**
 * Saves the home area and radius through set_home_area, then refreshes the profile, the saved
 * radius and the feed. Shared by the Home location sheet and the You tab rows.
 */
export function useSaveHomeArea(userId: string) {
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: ({ areaId, radiusKm }: { areaId: string; radiusKm?: number }) =>
      setHomeArea(areaId, radiusKm),
    onSuccess: async () => {
      await Promise.all([
        queryClient.invalidateQueries({ queryKey: profileQuery(userId).queryKey }),
        queryClient.invalidateQueries({ queryKey: feedRadiusQuery(userId).queryKey }),
        queryClient.invalidateQueries({ queryKey: ["feed"] }),
      ]);
    },
    onError: (err) => toast.error(areaErrorMessage(err)),
  });
}
