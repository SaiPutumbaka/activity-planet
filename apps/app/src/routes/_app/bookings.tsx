import { createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { CalendarDays } from "lucide-react";
import { z } from "zod";
import { coachingErrorMessage } from "@ap/core/coaching";

import { BookingRow, CardList } from "@/components/coaching/parts";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { SegmentedControl } from "@/components/ui/segmented";
import { Skeleton } from "@/components/ui/skeleton";
import {
  myBookingsQuery,
  myCoachStatusQuery,
  type BookingRole,
  type BookingScope,
} from "@/lib/coaching";

const appRoute = getRouteApi("/_app");

const searchSchema = z.object({
  role: z.enum(["client", "coach"]).optional(),
  scope: z.enum(["upcoming", "requests", "past"]).optional(),
});

/** My bookings (design section 15): as a client, and as a coach for coaches; Upcoming, Requests, Past. */
export const Route = createFileRoute("/_app/bookings")({
  validateSearch: searchSchema,
  component: BookingsPage,
});

const SCOPES: { value: BookingScope; label: string }[] = [
  { value: "upcoming", label: "Upcoming" },
  { value: "requests", label: "Requests" },
  { value: "past", label: "Past" },
];

function BookingsPage() {
  const { session } = appRoute.useRouteContext();
  const search = Route.useSearch();
  const navigate = useNavigate({ from: "/bookings" });
  const status = useQuery(myCoachStatusQuery(session.user.id));
  const isCoach = status.data != null;
  const role: BookingRole = isCoach ? (search.role ?? "client") : "client";
  const scope: BookingScope = search.scope ?? "upcoming";
  const list = useInfiniteQuery(myBookingsQuery(role, scope));
  const rows = list.data?.pages.flatMap((p) => p.items) ?? [];

  return (
    <>
      <TopBar title="Bookings" back />
      <main className="flex flex-col gap-4 pb-8 safe-px">
        {isCoach ? (
          <SegmentedControl
            label="Bookings as"
            value={role}
            onChange={(v) => void navigate({ search: (s) => ({ ...s, role: v }), replace: true })}
            options={[
              { value: "client", label: "As client" },
              { value: "coach", label: "As coach" },
            ]}
          />
        ) : null}
        <SegmentedControl
          label="Which bookings"
          value={scope}
          onChange={(v) => void navigate({ search: (s) => ({ ...s, scope: v }), replace: true })}
          options={SCOPES}
        />
        {list.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-16" />
            <Skeleton className="h-16" />
          </div>
        ) : list.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>{coachingErrorMessage(list.error)}</FormError>
            <Button variant="secondary" onClick={() => void list.refetch()}>
              Try again
            </Button>
          </div>
        ) : rows.length === 0 ? (
          <EmptyState
            icon={CalendarDays}
            title={
              scope === "requests"
                ? "No requests waiting"
                : scope === "upcoming"
                  ? "Nothing booked yet"
                  : "No past bookings"
            }
            body={role === "client" ? "Find a coach near you or online." : undefined}
            action={
              role === "client" ? (
                <Button variant="secondary" onClick={() => void navigate({ to: "/coaches" })}>
                  Find a coach
                </Button>
              ) : undefined
            }
          />
        ) : (
          <>
            <CardList label="Bookings">
              {rows.map((b) => (
                <li key={b.id}>
                  <BookingRow booking={b} />
                </li>
              ))}
            </CardList>
            {list.hasNextPage ? (
              <Button
                variant="secondary"
                loading={list.isFetchingNextPage}
                onClick={() => void list.fetchNextPage()}
              >
                Show more
              </Button>
            ) : null}
          </>
        )}
      </main>
    </>
  );
}
