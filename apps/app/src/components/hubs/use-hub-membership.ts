import { useMutation, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import {
  hubErrorMessage,
  hubKeys,
  joinHub,
  leaveHub,
  setHubNotify,
  type MemberCounts,
} from "@/lib/hubs";
import { myHubsQuery } from "@/lib/profile";

/**
 * What the optimistic my-hubs row needs: the columns myHubsQuery embeds from hubs, plus min_age
 * so the error map can say "21 and over" when the database refuses the insert.
 */
export interface MembershipHub {
  id: string;
  slug: string;
  name: string;
  emoji: string;
  category_slug: string;
  min_age: number;
}

/**
 * Join, leave and the notify switch as optimistic mutations over the my-hubs cache and every
 * cached member count. All three writes are idempotent on the server (a duplicate join is treated
 * as joined, a delete of nothing succeeds), so showing the result first is safe; an error rolls
 * the cache back and says why. Leaving offers Undo.
 */
export function useHubMembership(userId: string) {
  const queryClient = useQueryClient();
  const myHubsKey = myHubsQuery(userId).queryKey;

  function bumpCounts(hubId: string, delta: number) {
    queryClient.setQueriesData<MemberCounts>({ queryKey: hubKeys.memberCountsPrefix }, (old) =>
      old ? { ...old, [hubId]: Math.max(0, (old[hubId] ?? 0) + delta) } : old,
    );
  }

  function settle() {
    void queryClient.invalidateQueries({ queryKey: ["my-hubs"] });
    void queryClient.invalidateQueries({ queryKey: hubKeys.memberCountsPrefix });
  }

  const join = useMutation({
    mutationFn: (hub: MembershipHub) => joinHub(userId, hub.id),
    onMutate: async (hub) => {
      await queryClient.cancelQueries({ queryKey: myHubsKey });
      const previous = queryClient.getQueryData(myHubsKey);
      queryClient.setQueryData(myHubsKey, (old) =>
        old && !old.some((m) => m.hub_id === hub.id)
          ? [
              ...old,
              {
                hub_id: hub.id,
                notify: true,
                joined_at: new Date().toISOString(),
                hubs: {
                  id: hub.id,
                  slug: hub.slug,
                  name: hub.name,
                  emoji: hub.emoji,
                  category_slug: hub.category_slug,
                },
              },
            ]
          : old,
      );
      bumpCounts(hub.id, 1);
      return { previous };
    },
    onError: (err, hub, context) => {
      if (context?.previous) queryClient.setQueryData(myHubsKey, context.previous);
      bumpCounts(hub.id, -1);
      toast.error(hubErrorMessage(err, hub));
    },
    onSettled: settle,
  });

  const leave = useMutation({
    mutationFn: (hub: MembershipHub) => leaveHub(userId, hub.id),
    onMutate: async (hub) => {
      await queryClient.cancelQueries({ queryKey: myHubsKey });
      const previous = queryClient.getQueryData(myHubsKey);
      queryClient.setQueryData(myHubsKey, (old) => old?.filter((m) => m.hub_id !== hub.id));
      bumpCounts(hub.id, -1);
      return { previous };
    },
    onError: (err, hub, context) => {
      if (context?.previous) queryClient.setQueryData(myHubsKey, context.previous);
      bumpCounts(hub.id, 1);
      toast.error(hubErrorMessage(err, hub));
    },
    onSuccess: (_data, hub) => {
      toast(`Left ${hub.name}.`, { action: { label: "Undo", onClick: () => join.mutate(hub) } });
    },
    onSettled: settle,
  });

  const setNotify = useMutation({
    mutationFn: ({ hub, notify }: { hub: MembershipHub; notify: boolean }) =>
      setHubNotify(userId, hub.id, notify),
    onMutate: async ({ hub, notify }) => {
      await queryClient.cancelQueries({ queryKey: myHubsKey });
      const previous = queryClient.getQueryData(myHubsKey);
      queryClient.setQueryData(myHubsKey, (old) =>
        old?.map((m) => (m.hub_id === hub.id ? { ...m, notify } : m)),
      );
      return { previous };
    },
    onError: (err, { hub }, context) => {
      if (context?.previous) queryClient.setQueryData(myHubsKey, context.previous);
      toast.error(hubErrorMessage(err, hub));
    },
    onSettled: () => {
      void queryClient.invalidateQueries({ queryKey: ["my-hubs"] });
    },
  });

  return { join, leave, setNotify };
}
