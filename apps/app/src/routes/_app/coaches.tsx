import { useMemo, useState } from "react";
import { createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useInfiniteQuery, useQuery } from "@tanstack/react-query";
import { GraduationCap, LocateFixed, Search } from "lucide-react";
import { z } from "zod";
import { coachingErrorMessage, parsePrice } from "@ap/core/coaching";
import { formatKm } from "@ap/core/locale";

import { CardList, CoachCard } from "@/components/coaching/parts";
import { CoachesForYou } from "@/components/recs/coaches-for-you";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Chip } from "@/components/ui/chip";
import { EmptyState } from "@/components/ui/empty-state";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { SegmentedControl } from "@/components/ui/segmented";
import { Skeleton } from "@/components/ui/skeleton";
import { coachSearchQuery, myCoachStatusQuery } from "@/lib/coaching";
import { useFeedOrigin } from "@/lib/location";
import { hubCatalogQuery } from "@/lib/profile";
import { DISTANCE_UNIT } from "@/lib/units";
import { useRecOrigin } from "@/lib/recs";
import { useDebouncedValue } from "@/lib/use-debounced-value";

const appRoute = getRouteApi("/_app");

const searchSchema = z.object({
  mode: z.enum(["near", "online"]).optional(),
  hub: z.string().optional(),
  q: z.string().optional(),
});

/**
 * Find a coach (design section 5): near you (the feed's origin and distance bands, never a
 * distance) or online from anywhere, by hub, by words and by a maximum price.
 */
export const Route = createFileRoute("/_app/coaches")({
  validateSearch: searchSchema,
  component: CoachesPage,
});

const RADII = [10, 25, 50] as const;

function CoachesPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const search = Route.useSearch();
  const navigate = useNavigate({ from: "/coaches" });
  const mode = search.mode ?? "near";
  const hubId = search.hub ?? "";
  const [radius, setRadius] = useState<number>(25);
  const [text, setText] = useState(search.q ?? "");
  const [maxPrice, setMaxPrice] = useState("");
  const [currency, setCurrency] = useState("usd");
  const q = useDebouncedValue(text, 350);
  const origin = useFeedOrigin(userId);
  const recOrigin = useRecOrigin(userId);
  const catalog = useQuery(hubCatalogQuery);
  const coachStatus = useQuery(myCoachStatusQuery(userId));

  const hubs = useMemo(() => {
    const sensitive = new Set(
      (catalog.data?.categories ?? []).filter((c) => c.is_sensitive).map((c) => c.slug),
    );
    return (catalog.data?.hubs ?? []).filter((h) => !sensitive.has(h.category_slug));
  }, [catalog.data]);

  const cur = currency.trim().toLowerCase();
  const max = maxPrice.trim() && /^[a-z]{3}$/.test(cur) ? parsePrice(maxPrice, cur) : null;
  const params = {
    delivery: mode === "online" ? ("online" as const) : ("in_person" as const),
    lat: mode === "near" ? (origin.point?.lat ?? null) : null,
    lng: mode === "near" ? (origin.point?.lng ?? null) : null,
    radiusKm: mode === "near" ? radius : null,
    hubId: hubId || null,
    query: q.trim() || null,
    maxPriceMinor: max,
    currency: max != null ? cur : null,
  };
  const results = useInfiniteQuery(coachSearchQuery(params));
  const rows = results.data?.pages.flat() ?? [];

  return (
    <>
      <TopBar title="Coaches" back />
      <main className="flex flex-col gap-4 pb-8 safe-px">
        <p className="pt-1 text-[14px] text-text-2">
          Book a session with a coach near you or online. Coaches set their own prices.
        </p>
        {q.trim() || hubId ? null : <CoachesForYou origin={recOrigin} />}
        <SegmentedControl
          label="Where"
          value={mode}
          onChange={(v) => void navigate({ search: (s) => ({ ...s, mode: v }), replace: true })}
          options={[
            { value: "near", label: "Near you" },
            { value: "online", label: "Online" },
          ]}
        />
        {mode === "near" ? (
          <div className="flex flex-wrap items-center gap-2">
            {RADII.map((r) => (
              <Chip key={r} selected={radius === r} onClick={() => setRadius(r)}>
                {formatKm(r, DISTANCE_UNIT)}
              </Chip>
            ))}
            <Button
              variant="ghost"
              size="sm"
              leading={<LocateFixed className="size-4" aria-hidden="true" />}
              loading={origin.locating}
              onClick={() => void origin.locate()}
            >
              {origin.point ? "Using your location" : `Around ${origin.label}`}
            </Button>
          </div>
        ) : null}
        <Field
          label="Search"
          type="search"
          placeholder="Tennis, climbing, guitar…"
          value={text}
          onChange={(e) => setText(e.target.value)}
          prefix={<Search className="size-4" aria-hidden="true" />}
        />
        <div className="grid grid-cols-1 gap-3 min-[400px]:grid-cols-2">
          <FieldSelect
            label="Hub"
            value={hubId}
            onChange={(e) =>
              void navigate({
                search: (s) => ({ ...s, hub: e.target.value || undefined }),
                replace: true,
              })
            }
          >
            <option value="">Any hub</option>
            {hubs.map((h) => (
              <option key={h.id} value={h.id}>
                {h.emoji ? `${h.emoji} ` : ""}
                {h.name}
              </option>
            ))}
          </FieldSelect>
          <div className="grid grid-cols-[1fr_5.5rem] gap-2">
            <Field
              label="Max price"
              inputMode="decimal"
              placeholder="Any"
              value={maxPrice}
              onChange={(e) => setMaxPrice(e.target.value)}
            />
            <Field
              label="Currency"
              maxLength={3}
              value={currency}
              onChange={(e) => setCurrency(e.target.value)}
              autoCapitalize="none"
            />
          </div>
        </div>

        {results.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-16" />
            <Skeleton className="h-16" />
            <Skeleton className="h-16" />
          </div>
        ) : results.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>{coachingErrorMessage(results.error)}</FormError>
            <Button variant="secondary" onClick={() => void results.refetch()}>
              Try again
            </Button>
          </div>
        ) : rows.length === 0 ? (
          <EmptyState
            icon={GraduationCap}
            title="No coaches here yet"
            body={
              mode === "near"
                ? "Try a wider distance, Online, or another hub."
                : "Try other words or another hub."
            }
          />
        ) : (
          <>
            <CardList label="Coaches">
              {rows.map((c) => (
                <li key={c.user_id}>
                  <CoachCard coach={c} />
                </li>
              ))}
            </CardList>
            {results.hasNextPage ? (
              <Button
                variant="secondary"
                loading={results.isFetchingNextPage}
                onClick={() => void results.fetchNextPage()}
              >
                Show more
              </Button>
            ) : null}
          </>
        )}

        {coachStatus.data === null ? (
          <Button variant="outline" onClick={() => void navigate({ to: "/coach" })}>
            Become a coach
          </Button>
        ) : null}
      </main>
    </>
  );
}
