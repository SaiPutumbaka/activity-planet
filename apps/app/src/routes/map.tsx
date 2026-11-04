import { Suspense, lazy, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Link, createFileRoute, redirect, useNavigate } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { List, LocateFixed, Map as MapIcon, SearchX } from "lucide-react";
import { z } from "zod";

import { MapAttribution } from "@/components/map/attribution";
import { ExploreSheet } from "@/components/map/explore-sheet";
import { HubChips } from "@/components/map/hub-chips";
import { LayerChips } from "@/components/map/layer-chips";
import { ListPanel, type PanelHeight } from "@/components/map/list-panel";
import { CellSheet, PlaceSheet } from "@/components/map/place-sheet";
import { ComingSoon } from "@/components/shell/coming-soon";
import { TabBar } from "@/components/shell/tab-bar";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Spinner } from "@/components/ui/spinner";
import { getSession } from "@/lib/auth";
import { cn } from "@/lib/cn";
import { useDevicePoint } from "@/lib/location";
import {
  EMPTY_VIEW,
  LOCATED_ZOOM,
  PLACES_MIN_ZOOM,
  WORLD_CAMERA,
  applyHubFilter,
  applyLayerFilter,
  bboxAround,
  bboxTooLargeForPlaces,
  isMapUnavailable,
  layersParam,
  mapInViewQuery,
  parseHubsParam,
  parseLayersParam,
  planHubRequest,
  readSavedCamera,
  saveCamera,
  snapBBox,
  viewerTimeZone,
  type BBox,
  type Camera,
  type ChipHub,
  type HubSelection,
  type MapLayer,
  type MapWhen,
} from "@/lib/map";
import { getProfile, hubCatalogQuery, myHubsQuery, type CatalogHub } from "@/lib/profile";
import { useResolvedTheme } from "@/lib/theme";
import { useDebouncedValue } from "@/lib/use-debounced-value";
import { prefersSaveData, supportsWebGL, useReducedMotion } from "@/lib/use-media";

/** MapLibre and its CSS load only here, after first paint (D-038, §9 load order). */
const MapCanvas = lazy(() => import("@/components/map/map-canvas"));

/**
 * `?hubs=<slug,slug>` selected hub chips (absent: All my hubs), `?layers=places,plans,shows`,
 * `?when=today|week|month`, `?lat&lng&z` a shared view, `?place=<id>` the open place card,
 * `?view=list|map`. The map never writes the viewer's position into the URL: a reload would put
 * it in the host's request logs, so the last view is kept on the device instead (lib/map.ts).
 */
const searchSchema = z.object({
  hubs: z.string().max(2000).optional().catch(undefined),
  layers: z.string().max(40).optional().catch(undefined),
  when: z.enum(["today", "week", "month"]).optional().catch(undefined),
  lat: z.number().min(-85).max(85).optional().catch(undefined),
  lng: z.number().min(-180).max(180).optional().catch(undefined),
  z: z.number().min(0).max(20).optional().catch(undefined),
  place: z.string().max(200).optional().catch(undefined),
  view: z.enum(["list", "map"]).optional().catch(undefined),
});

/**
 * The Map tab (HUB_MAP_DESIGN §9, slices 7 and 8): places for your hubs, plans and shows around
 * you, anywhere in the world. It takes the Chats slot in the tab bar until messaging ships.
 * Outside `/_app` on purpose: signed-out visitors see public places and public plans too (founder
 * answer), so the route only redirects someone who is signed in but has not finished onboarding.
 */
export const Route = createFileRoute("/map")({
  validateSearch: searchSchema,
  beforeLoad: async ({ context: { queryClient } }) => {
    const session = await getSession(queryClient);
    if (!session) return { session: null, profile: null };
    const profile = await getProfile(queryClient, session.user.id).catch(() => null);
    if (profile && !profile.deleted_at && !profile.onboarding_completed_at) {
      throw redirect({ to: "/onboarding", replace: true });
    }
    return { session, profile: profile && !profile.deleted_at ? profile : null };
  },
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(hubCatalogQuery);
    if (session) void queryClient.prefetchQuery(myHubsQuery(session.user.id));
  },
  component: MapPage,
});

function MapPage() {
  const { session, profile } = Route.useRouteContext();
  const signedIn = Boolean(session && profile);
  return (
    <div
      className={cn(
        "mx-auto flex max-w-lg flex-col",
        signedIn ? "h-[calc(100dvh-3.5rem-env(safe-area-inset-bottom,0px))]" : "h-dvh",
      )}
    >
      <MapScreen userId={signedIn ? (session?.user.id ?? null) : null} />
      {signedIn ? <TabBar /> : null}
    </div>
  );
}

function initialCamera(
  search: { lat?: number; lng?: number; z?: number },
  device: { lat: number; lng: number } | null,
): { camera: Camera; located: boolean } {
  if (search.lat !== undefined && search.lng !== undefined) {
    return {
      camera: { lat: search.lat, lng: search.lng, zoom: search.z ?? LOCATED_ZOOM },
      located: true,
    };
  }
  if (device) return { camera: { ...device, zoom: LOCATED_ZOOM }, located: true };
  const saved = readSavedCamera();
  if (saved) return { camera: saved, located: true };
  return { camera: WORLD_CAMERA, located: false };
}

function viewportBBox(c: Camera): BBox {
  const w = typeof window === "undefined" ? 400 : Math.min(window.innerWidth, 512);
  const h = typeof window === "undefined" ? 600 : Math.max(240, window.innerHeight - 220);
  return bboxAround(c, c.zoom, w, h);
}

function MapScreen({ userId }: { userId: string | null }) {
  const search = Route.useSearch();
  const navigate = useNavigate({ from: "/map" });
  const theme = useResolvedTheme();
  const reducedMotion = useReducedMotion();
  const device = useDevicePoint();
  const timeZone = useMemo(() => viewerTimeZone(), []);
  const signedIn = userId !== null;

  // Camera and bbox. The list loads from the computed bbox before MapLibre exists.
  const [start] = useState(() => initialCamera(search, device.point));
  const [camera, setCamera] = useState<Camera>(start.camera);
  const [located, setLocated] = useState(start.located);
  const [bbox, setBBox] = useState<BBox>(() => viewportBBox(start.camera));
  const settled = useDebouncedValue(bbox, 300);
  const snapped = useMemo(() => snapBBox(settled), [settled]);
  const [focus, setFocus] = useState<(Camera & { seq: number }) | null>(null);
  const [locating, setLocating] = useState(false);
  const wantDeviceFocus = useRef(false);

  // Screen mode: the list by default with Save-Data or without WebGL (§9).
  const [webgl] = useState(() => supportsWebGL());
  const [mapFailed, setMapFailed] = useState(false);
  const [listByDefault] = useState(() => prefersSaveData() || !webgl);
  const canMap = webgl && !mapFailed;
  const listView =
    !canMap || search.view === "list" || (search.view === undefined && listByDefault);
  const [painted, setPainted] = useState(false);
  useEffect(() => {
    const id = requestAnimationFrame(() => requestAnimationFrame(() => setPainted(true)));
    return () => cancelAnimationFrame(id);
  }, []);
  // Mounted the first time the map is shown after first paint, then kept for the visit.
  const [mapMounted, setMapMounted] = useState(false);
  if (painted && canMap && !listView && !mapMounted) setMapMounted(true);
  const [panel, setPanel] = useState<PanelHeight>("peek");

  // Hubs: joined (signed in) plus any picked through Explore, which live in ?hubs.
  const myHubs = useQuery({ ...myHubsQuery(userId ?? ""), enabled: signedIn });
  const catalog = useQuery(hubCatalogQuery);
  const selectedSlugs = parseHubsParam(search.hubs);
  const catalogBySlug = useMemo(
    () => new Map((catalog.data?.hubs ?? []).map((h) => [h.slug, h] as const)),
    [catalog.data],
  );
  const categoryBySlug = useMemo(
    () => new Map((catalog.data?.categories ?? []).map((c) => [c.slug, c] as const)),
    [catalog.data],
  );
  const chipHubs = useMemo((): ChipHub[] => {
    const toChip = (
      h: { id: string; slug: string; name: string; emoji: string; category_slug: string },
      joined: boolean,
    ): ChipHub => {
      const cat = categoryBySlug.get(h.category_slug);
      return {
        id: h.id,
        slug: h.slug,
        name: h.name,
        emoji: h.emoji,
        colorKey: cat?.color_key ?? null,
        sensitive: cat?.is_sensitive ?? false,
        joined,
      };
    };
    const joined = (myHubs.data ?? []).flatMap((m) => (m.hubs ? [toChip(m.hubs, true)] : []));
    const joinedSlugs = new Set(joined.map((h) => h.slug));
    const explored = (selectedSlugs ?? []).flatMap((slug) => {
      if (joinedSlugs.has(slug)) return [];
      const h = catalogBySlug.get(slug);
      return h ? [toChip(h, false)] : [];
    });
    return [...joined, ...explored];
    // selectedSlugs is derived from search.hubs each render; key on the string.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [myHubs.data, catalogBySlug, categoryBySlug, search.hubs]);
  const selection: HubSelection = useMemo(() => {
    if (!selectedSlugs) return null;
    const ids = selectedSlugs.flatMap((s) => {
      const h = chipHubs.find((c) => c.slug === s);
      return h ? [h.id] : [];
    });
    return ids.length ? ids : null;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search.hubs, chipHubs]);
  const plan = useMemo(() => planHubRequest(selection, chipHubs), [selection, chipHubs]);

  const layers = parseLayersParam(search.layers);
  const when: MapWhen = search.when ?? "week";
  const hubsReady = (!signedIn || !myHubs.isPending) && (!selectedSlugs || !catalog.isPending);

  const query = useQuery({
    ...mapInViewQuery({ bbox: snapped, hubIds: plan.hubIds, generic: plan.generic, when }),
    enabled: hubsReady,
  });
  const unavailable = query.isError && isMapUnavailable(query.error);

  const placesHidden = camera.zoom < PLACES_MIN_ZOOM || bboxTooLargeForPlaces(snapped);
  const view = useMemo(() => {
    const filtered = applyLayerFilter(
      applyHubFilter(query.data ?? EMPTY_VIEW, plan.localFilter),
      layers,
    );
    return placesHidden ? { ...filtered, places: [] } : filtered;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query.data, plan.localFilter, search.layers, placesHidden]);
  const eventsOnly = useMemo(() => new Set(query.data?.eventsOnlyHubIds ?? []), [query.data]);

  // Locate: only on tap, coarse, never stored on the server (D-036 rules, lib/location.ts).
  async function locate() {
    setLocating(true);
    wantDeviceFocus.current = true;
    try {
      const r = await device.locate();
      if (r !== "granted") wantDeviceFocus.current = false;
    } finally {
      setLocating(false);
    }
  }
  useEffect(() => {
    if (!wantDeviceFocus.current || !device.point) return;
    wantDeviceFocus.current = false;
    const c = { ...device.point, zoom: LOCATED_ZOOM };
    setLocated(true);
    setCamera(c);
    setBBox(viewportBBox(c));
    saveCamera(c);
    setFocus((f) => ({ ...c, seq: (f?.seq ?? 0) + 1 }));
  }, [device.point]);

  function onMove(s: { bounds: BBox; camera: Camera }) {
    setCamera(s.camera);
    setBBox(s.bounds);
    if (s.camera.zoom >= 3) {
      setLocated(true);
      saveCamera(s.camera);
    }
  }

  function setSearch(patch: Partial<z.infer<typeof searchSchema>>) {
    void navigate({ search: (prev) => ({ ...prev, ...patch }), replace: true });
  }
  function onHubSelection(next: HubSelection) {
    const slugs = next?.flatMap((id) => {
      const h = chipHubs.find((c) => c.id === id);
      return h ? [h.slug] : [];
    });
    setSearch({ hubs: slugs?.length ? slugs.join(",") : undefined });
  }
  function onLayers(next: MapLayer[]) {
    setSearch({ layers: layersParam(next) });
  }
  const [exploreOpen, setExploreOpen] = useState(false);
  function onExplorePick(h: CatalogHub) {
    setExploreOpen(false);
    setSearch({ hubs: h.slug });
  }
  const [cellKey, setCellKey] = useState<string | null>(null);
  const openCell = view.cells.find((c) => c.key === cellKey) ?? null;

  const toggleView = canMap ? (
    <Button
      variant="secondary"
      size="sm"
      className="rounded-full"
      onClick={() => setSearch({ view: listView ? "map" : "list" })}
      leading={
        listView ? (
          <MapIcon className="size-4" aria-hidden="true" />
        ) : (
          <List className="size-4" aria-hidden="true" />
        )
      }
    >
      {listView ? "Map" : "List"}
    </Button>
  ) : null;
  const signIn = signedIn ? null : (
    <Link
      to="/auth/sign-in"
      search={{ next: "/map" }}
      className={buttonVariants({ variant: "primary", size: "sm" })}
    >
      Sign in
    </Link>
  );

  if (unavailable) {
    return (
      <>
        <TopBar title="Map" actions={signIn} />
        <ComingSoon
          icon={MapIcon}
          title="The map is almost here"
          body="Courts, stores and club spots for your hubs, plus plans and shows nearby, wherever you are. It's being set up now."
        />
      </>
    );
  }

  // Empty and edge states (§9), shown above the list rows.
  const selectedOne = selection?.length === 1 ? chipHubs.find((h) => h.id === selection[0]) : null;
  const nothing =
    !query.isPending &&
    view.places.length + view.plans.length + view.shows.length + view.cells.length === 0;
  const notices: ReactNode[] = [];
  if (query.isError) {
    notices.push(
      <Notice
        key="error"
        action={
          <Button size="sm" variant="secondary" onClick={() => void query.refetch()}>
            Try again
          </Button>
        }
      >
        Couldn't load this area. Check your connection.
      </Notice>,
    );
  }
  if (!located) {
    notices.push(
      <Notice
        key="locate"
        action={
          <Button
            size="sm"
            variant="secondary"
            loading={locating}
            onClick={() => void locate()}
            leading={<LocateFixed className="size-4" aria-hidden="true" />}
          >
            Use my location
          </Button>
        }
      >
        {device.denied
          ? "Location is off for this site. Move the map to your area instead."
          : "See what's near you, or move the map to any city."}
      </Notice>,
    );
  }
  if (signedIn && myHubs.isSuccess && !chipHubs.some((h) => h.joined)) {
    notices.push(
      <Notice
        key="join"
        action={
          <Link to="/hubs" className={buttonVariants({ variant: "secondary", size: "sm" })}>
            Browse hubs
          </Link>
        }
      >
        Join a few hubs to see their places here. Public plans nearby still show.
      </Notice>,
    );
  }
  if (!signedIn && chipHubs.length === 0) {
    notices.push(
      <Notice
        key="pick"
        action={
          <Button size="sm" variant="secondary" onClick={() => setExploreOpen(true)}>
            Pick hubs
          </Button>
        }
      >
        Pick a hub to see its places. Public plans nearby show either way.
      </Notice>,
    );
  }
  if (layers.includes("places") && placesHidden && plan.hubIds.length > 0) {
    notices.push(<Notice key="zoom">Zoom in to see places.</Notice>);
  }
  if (selectedOne && eventsOnly.has(selectedOne.id)) {
    notices.push(
      <Notice key="events-only">
        {selectedOne.name} is events only: no places, just its plans.
      </Notice>,
    );
  }
  if (query.data?.mapping && !placesHidden) {
    notices.push(
      <Notice key="mapping">
        We're mapping this area. Courts and stores usually appear within a day. Public plans still
        show.
      </Notice>,
    );
  }
  if (query.data?.truncated && !placesHidden) {
    notices.push(
      <Notice key="truncated">
        Showing some of the places here. Zoom in or pick one hub to see them all.
      </Notice>,
    );
  }
  if (nothing && !query.isError && located) {
    notices.push(
      <EmptyState
        key="empty"
        icon={SearchX}
        title="Nothing here yet"
        body={
          when === "month"
            ? "Try moving the map or picking another hub."
            : "Try 30 days, or move the map."
        }
        className="py-6"
      />,
    );
  }

  const status = query.isPending ? "Loading this area…" : undefined;

  return (
    <>
      <TopBar
        title="Map"
        actions={
          <>
            {toggleView}
            {signIn}
          </>
        }
      />
      <div className="flex flex-col gap-2 pb-2 safe-px">
        <HubChips
          hubs={chipHubs}
          selection={selection}
          onChange={onHubSelection}
          eventsOnly={eventsOnly}
          onExplore={() => setExploreOpen(true)}
          signedIn={signedIn}
        />
        <LayerChips
          layers={layers}
          onLayers={onLayers}
          when={when}
          onWhen={(w) => setSearch({ when: w === "week" ? undefined : w })}
        />
      </div>

      <div className="relative min-h-0 flex-1 overflow-hidden border-t border-border">
        {mapMounted ? (
          <div
            className={cn("absolute inset-0", listView && "invisible")}
            aria-hidden={listView || undefined}
          >
            <Suspense fallback={<MapLoading />}>
              <MapCanvas
                initial={camera}
                theme={theme}
                view={view}
                reducedMotion={reducedMotion}
                focus={focus}
                visible={!listView}
                onMove={onMove}
                onSelectPlace={(id) => setSearch({ place: id })}
                onSelectEvent={(id) => void navigate({ to: "/events/$id", params: { id } })}
                onSelectCell={setCellKey}
                onFailed={() => setMapFailed(true)}
              />
            </Suspense>
            {!listView ? (
              <>
                <div className="pointer-events-none absolute top-2 left-2 z-[5] max-w-[70%] rounded-[8px] bg-surface/85 px-2 py-1 backdrop-blur">
                  <div className="pointer-events-auto">
                    <MapAttribution />
                  </div>
                </div>
                <button
                  type="button"
                  onClick={() => void locate()}
                  aria-label="Show where I am"
                  className="absolute top-[78px] right-2.5 z-[5] flex size-[29px] items-center justify-center rounded-[4px] bg-surface text-text shadow-[0_0_0_2px_rgb(0_0_0/0.1)]"
                >
                  {locating ? (
                    <Spinner className="size-4" />
                  ) : (
                    <LocateFixed className="size-4" aria-hidden="true" />
                  )}
                </button>
                {layers.includes("places") && placesHidden && plan.hubIds.length > 0 ? (
                  <p className="pointer-events-none absolute inset-x-0 bottom-[8.25rem] z-[5] mx-auto w-fit rounded-control bg-toast px-3 py-1.5 text-[13px] font-semibold text-on-toast">
                    Zoom in to see places
                  </p>
                ) : null}
              </>
            ) : null}
          </div>
        ) : !listView ? (
          <MapLoading />
        ) : null}

        <ListPanel
          view={view}
          origin={camera}
          mode={listView ? "screen" : "sheet"}
          height={panel}
          onHeight={setPanel}
          status={status}
          notices={
            notices.length ? <div className="flex flex-col gap-2 pt-1">{notices}</div> : null
          }
          timeZone={timeZone}
          onSelectPlace={(id) => setSearch({ place: id })}
          onSelectCell={setCellKey}
        />
      </div>

      <PlaceSheet
        placeId={search.place ?? null}
        hubs={chipHubs}
        signedIn={signedIn}
        timeZone={timeZone}
        onClose={() => setSearch({ place: undefined })}
      />
      <CellSheet cell={openCell} timeZone={timeZone} onClose={() => setCellKey(null)} />
      <ExploreSheet
        open={exploreOpen}
        onClose={() => setExploreOpen(false)}
        hubs={catalog.data?.hubs ?? []}
        categories={catalog.data?.categories ?? []}
        loading={catalog.isPending}
        onPick={onExplorePick}
      />
    </>
  );
}

function MapLoading() {
  return (
    <div className="absolute inset-0 flex items-start justify-center bg-surface-2 pt-16 text-text-3">
      <Spinner className="size-6" label="Loading the map" />
    </div>
  );
}

function Notice({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-2 rounded-tile bg-surface-2 px-3 py-2.5 text-[14px] text-text-2">
      <p className="min-w-0 flex-1 basis-48">{children}</p>
      {action}
    </div>
  );
}
