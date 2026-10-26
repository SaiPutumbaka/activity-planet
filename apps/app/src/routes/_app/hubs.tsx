import { useMemo, useState } from "react";
import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CircleAlert, Plus, SearchX } from "lucide-react";
import { toast } from "sonner";

import { HubBrowse } from "@/components/hubs/hub-browse";
import { HubRow } from "@/components/hubs/hub-row";
import { HubSearch } from "@/components/hubs/hub-search";
import { HubSettingsSheet } from "@/components/hubs/hub-settings-sheet";
import {
  HubsTabSkeleton,
  InlineError,
  ListSkeleton,
  SectionHeading,
} from "@/components/hubs/hub-states";
import { RequestHubSheet } from "@/components/hubs/request-hub-sheet";
import { useHubMembership } from "@/components/hubs/use-hub-membership";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import {
  groupHubsByCategory,
  hubMatches,
  hubMemberCountsQuery,
  joinBlockedReason,
  normalizeSearch,
  viewerAgeQuery,
} from "@/lib/hubs";
import { hubCatalogQuery, myHubsQuery, type CatalogHub } from "@/lib/profile";
import { useDebouncedValue } from "@/lib/use-debounced-value";

const appRoute = getRouteApi("/_app");

/**
 * The Hubs tab: search, the hubs you are in, the whole catalog by category, request a hub.
 * Tapping a chip joins or leaves straight away (optimistic, rolled back on error).
 */
export const Route = createFileRoute("/_app/hubs")({
  loader: ({ context: { queryClient } }) => {
    void queryClient.prefetchQuery(hubCatalogQuery);
  },
  component: HubsPage,
});

function HubsPage() {
  const { session, profile } = appRoute.useRouteContext();
  const userId = session.user.id;
  const catalog = useQuery(hubCatalogQuery);
  const myHubs = useQuery(myHubsQuery(userId));
  const viewerAge = useQuery(viewerAgeQuery);
  const hubIds = useMemo(() => catalog.data?.hubs.map((h) => h.id) ?? [], [catalog.data]);
  const counts = useQuery({ ...hubMemberCountsQuery(hubIds), enabled: hubIds.length > 0 });
  const membership = useHubMembership(userId);

  const [query, setQuery] = useState("");
  const needle = useDebouncedValue(normalizeSearch(query), 200);
  const [settingsHubId, setSettingsHubId] = useState<string | null>(null);
  const [requestOpen, setRequestOpen] = useState(false);

  const hubsById = useMemo(
    () => new Map((catalog.data?.hubs ?? []).map((h) => [h.id, h])),
    [catalog.data],
  );
  const categoriesBySlug = useMemo(
    () => new Map((catalog.data?.categories ?? []).map((c) => [c.slug, c])),
    [catalog.data],
  );
  const joinedIds = useMemo(() => new Set((myHubs.data ?? []).map((m) => m.hub_id)), [myHubs.data]);

  // Joined hubs in join order, filtered by the search like everything else.
  const yourHubs = useMemo(() => {
    const out: { hub: CatalogHub; notify: boolean }[] = [];
    for (const m of myHubs.data ?? []) {
      const hub = hubsById.get(m.hub_id);
      if (!hub) continue;
      if (!hubMatches(hub, categoriesBySlug.get(hub.category_slug)?.name ?? "", needle)) continue;
      out.push({ hub, notify: m.notify });
    }
    return out;
  }, [myHubs.data, hubsById, categoriesBySlug, needle]);

  const sections = useMemo(() => groupHubsByCategory(catalog.data, needle), [catalog.data, needle]);
  const resultCount = sections.reduce((n, s) => n + s.hubs.length, 0);
  const hubCount = catalog.data?.hubs.length ?? 0;
  const noResults = needle !== "" && sections.length === 0;

  function toggle(hub: CatalogHub) {
    if (joinedIds.has(hub.id)) {
      membership.leave.mutate(hub);
      return;
    }
    const blocked = joinBlockedReason(hub, {
      homeOrgId: profile.home_org_id,
      viewerAge: viewerAge.data,
    });
    if (blocked) {
      toast(blocked);
      return;
    }
    membership.join.mutate(hub);
  }

  const settingsHub = settingsHubId ? (hubsById.get(settingsHubId) ?? null) : null;
  const settingsNotify = settingsHubId
    ? (myHubs.data?.find((m) => m.hub_id === settingsHubId)?.notify ?? true)
    : true;

  function countFor(hubId: string): number | undefined {
    return counts.data ? (counts.data[hubId] ?? 0) : undefined;
  }

  return (
    <>
      <TopBar title="Hubs" />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        <HubSearch value={query} onChange={setQuery} total={hubCount} />

        {catalog.isPending ? (
          <HubsTabSkeleton />
        ) : catalog.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't load hubs"
            body="Check your connection and try again."
            action={
              <Button
                variant="secondary"
                onClick={() => {
                  void catalog.refetch();
                }}
              >
                Try again
              </Button>
            }
          />
        ) : noResults ? (
          <EmptyState
            icon={SearchX}
            title={`No hub matches “${query.trim()}”`}
            body="Ask for it and we'll add it to the catalog."
            action={
              <Button variant="secondary" onClick={() => setRequestOpen(true)}>
                Request a hub
              </Button>
            }
          />
        ) : (
          <>
            {!needle || yourHubs.length > 0 ? (
              <section className="flex flex-col gap-3" aria-labelledby="your-hubs">
                <SectionHeading
                  id="your-hubs"
                  title="Your hubs"
                  trailing={myHubs.data ? String(joinedIds.size) : undefined}
                />
                {myHubs.isPending ? (
                  <ListSkeleton rows={3} />
                ) : myHubs.isError ? (
                  <InlineError
                    message="Couldn't load your hubs."
                    onRetry={() => {
                      void myHubs.refetch();
                    }}
                  />
                ) : yourHubs.length === 0 ? (
                  <p className="text-[14px] text-text-2">
                    You're not in any hub yet. Tap one below to join it.
                  </p>
                ) : (
                  <div className="divide-y divide-border rounded-card border border-border bg-surface">
                    {yourHubs.map(({ hub, notify }) => {
                      const category = categoriesBySlug.get(hub.category_slug);
                      return (
                        <HubRow
                          key={hub.id}
                          hub={hub}
                          categoryName={category?.name ?? ""}
                          colorKey={category?.color_key}
                          count={countFor(hub.id)}
                          notify={notify}
                          onMore={() => setSettingsHubId(hub.id)}
                        />
                      );
                    })}
                  </div>
                )}
              </section>
            ) : null}

            <section className="flex flex-col gap-3" aria-labelledby="browse-hubs">
              <SectionHeading
                id="browse-hubs"
                title={needle ? "Results" : "Browse"}
                trailing={
                  needle
                    ? `${resultCount} ${resultCount === 1 ? "hub" : "hubs"}`
                    : `${hubCount} hubs in ${catalog.data.categories.length} categories`
                }
              />
              <HubBrowse
                sections={sections}
                counts={counts.data}
                joinedIds={joinedIds}
                onToggle={toggle}
              />
            </section>

            <button
              type="button"
              onClick={() => setRequestOpen(true)}
              className="flex min-h-16 w-full items-center gap-3 rounded-card border border-dashed border-border-strong px-4 text-left transition-colors hover:bg-surface-2"
            >
              <span className="flex size-11 shrink-0 items-center justify-center rounded-tile bg-surface-2 text-text-2">
                <Plus className="size-5" aria-hidden="true" />
              </span>
              <span className="min-w-0">
                <span className="block text-[15px] font-semibold">Request a hub</span>
                <span className="block text-[13px] text-text-2">
                  Can't find it? Ask and we'll add it.
                </span>
              </span>
            </button>
          </>
        )}
      </main>

      <HubSettingsSheet
        hub={settingsHub}
        notify={settingsNotify}
        open={settingsHub !== null}
        onClose={() => setSettingsHubId(null)}
        onNotifyChange={(notify) => {
          if (settingsHub) membership.setNotify.mutate({ hub: settingsHub, notify });
        }}
        onLeave={() => {
          if (settingsHub) membership.leave.mutate(settingsHub);
          setSettingsHubId(null);
        }}
      />
      <RequestHubSheet
        open={requestOpen}
        onClose={() => setRequestOpen(false)}
        hubNameBySlug={(slug) => catalog.data?.hubs.find((h) => h.slug === slug)?.name}
      />
    </>
  );
}
