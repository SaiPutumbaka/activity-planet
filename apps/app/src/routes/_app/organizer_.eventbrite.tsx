import { useEffect, useRef } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQueryClient } from "@tanstack/react-query";
import { BadgeCheck, CircleAlert } from "lucide-react";
import { z } from "zod";
import { organizerErrorMessage } from "@ap/core/organizer";

import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { eventbriteCallback, organizerKeys } from "@/lib/organizer";

const searchSchema = z.object({
  code: z.string().max(500).optional(),
  state: z.string().max(128).optional(),
  error: z.string().max(200).optional(),
});

/**
 * /organizer/eventbrite: where Eventbrite sends the organizer back (EVENTBRITE_REDIRECT_URI,
 * FOUNDER-TODO 20d). Hands the code and state to eventbrite-connect once; the state must be this
 * person's, unused and under 10 minutes old. The token stays in Supabase's vault.
 */
export const Route = createFileRoute("/_app/organizer_/eventbrite")({
  validateSearch: searchSchema,
  component: EventbriteReturnPage,
});

function EventbriteReturnPage() {
  const { code, state, error } = Route.useSearch();
  const queryClient = useQueryClient();
  const sent = useRef(false);
  const finish = useMutation({
    mutationFn: () => eventbriteCallback(code ?? "", state ?? ""),
    onSuccess: () => void queryClient.invalidateQueries({ queryKey: organizerKeys.all }),
  });
  useEffect(() => {
    if (sent.current || !code || !state) return;
    sent.current = true;
    finish.mutate();
  }, [code, state, finish]);

  const back = (
    <Link to="/organizer" className={buttonVariants({ variant: "secondary" })}>
      Organizer page
    </Link>
  );
  return (
    <>
      <TopBar title="Eventbrite" back />
      <main className="flex flex-col gap-5 pt-2 pb-8 safe-px">
        {error || !code || !state ? (
          <EmptyState
            icon={CircleAlert}
            title="Not connected"
            body="Eventbrite didn't finish the connection. Start again from your organizer page."
            action={back}
          />
        ) : finish.isSuccess ? (
          <EmptyState
            icon={BadgeCheck}
            title="Eventbrite connected"
            body="We read your live events every night and list them near people around you, linked back to Eventbrite."
            action={back}
          />
        ) : finish.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Not connected"
            body={organizerErrorMessage(finish.error)}
            action={back}
          />
        ) : (
          <ListSkeleton rows={1} rowClassName="h-24" />
        )}
      </main>
    </>
  );
}
