import { useEffect, useRef } from "react";
import {
  Map as MapLibreMap,
  NavigationControl,
  type GeoJSONSource,
  type MapLayerMouseEvent,
} from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";

import { MAP_ICON_KEYS, PLACES_MIN_ZOOM, type BBox, type Camera, type MapView } from "@/lib/map";
import {
  HATCH_IMAGE,
  LAYER,
  MAP_FONT,
  MAP_STYLE_URLS,
  PIN_PALETTES,
  PIN_RATIO,
  PLAN_IMAGE,
  PLAN_IMPORTED_IMAGE,
  SHOW_IMAGE,
  SOURCE,
  cellsGeoJSON,
  drawHatch,
  drawPin,
  happeningsGeoJSON,
  placeImageId,
  placesGeoJSON,
} from "@/lib/map-style";
import type { ResolvedTheme } from "@/lib/theme";

import { PLACE_ICONS, PLAN_ICON, SHOW_ICON } from "./icons";

/**
 * The MapLibre canvas (D-038, §9 slice 8). Loaded with React.lazy from the map route only, so
 * maplibre-gl and its CSS live in this chunk and never in the main bundle. One map instance per
 * mount; a theme change swaps the style and re-adds the overlay on `style.load`.
 *
 * Overlay: two clustered GeoJSON sources (places, radius 48 to zoom 15; plans and shows), and the
 * approved-only cells as hatched, dashed squares labelled "N events in this area". Each type has
 * its own shape plus an icon (rounded square, teardrop, ticket), so nothing depends on colour.
 * Attribution is drawn by the route (always visible, no tap), so the built-in control is off.
 */
export interface MapCanvasProps {
  initial: Camera;
  theme: ResolvedTheme;
  /** Already filtered by layer and hub chips. */
  view: MapView;
  reducedMotion: boolean;
  /** A programmatic move (locate, a list row); `seq` makes repeats count. */
  focus: (Camera & { seq: number }) | null;
  onMove: (state: { bounds: BBox; camera: Camera }) => void;
  onSelectPlace: (id: string) => void;
  onSelectEvent: (id: string) => void;
  onSelectCell: (key: string) => void;
  /** WebGL or the style failed: the route falls back to the list. */
  onFailed: () => void;
  /** False while the List view covers the screen; the map stays alive and resizes on return. */
  visible: boolean;
}

const CANVAS_LABEL =
  "Map of places and plans. Arrow keys pan, plus and minus zoom. The list has everything shown here.";

export default function MapCanvas(props: MapCanvasProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const iconsRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<MapLibreMap | null>(null);
  const themeRef = useRef<ResolvedTheme>(props.theme);
  const propsRef = useRef(props);
  useEffect(() => {
    propsRef.current = props;
  });

  // Create the map once.
  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;
    let map: MapLibreMap;
    const p = propsRef.current;
    try {
      map = new MapLibreMap({
        container,
        style: MAP_STYLE_URLS[p.theme],
        center: [p.initial.lng, p.initial.lat],
        zoom: p.initial.zoom,
        attributionControl: false,
        pixelRatio: Math.min(window.devicePixelRatio || 1, 2),
        fadeDuration: p.reducedMotion ? 0 : 300,
        maxPitch: 0,
        dragRotate: false,
        pitchWithRotate: false,
        touchPitch: false,
      });
    } catch {
      p.onFailed();
      return;
    }
    mapRef.current = map;
    map.touchZoomRotate.disableRotation();
    map.keyboard.disableRotation();
    map.addControl(new NavigationControl({ showCompass: false }), "top-right");
    const canvas = map.getCanvas();
    canvas.setAttribute("aria-label", CANVAS_LABEL);
    canvas.setAttribute("role", "application");

    let installSeq = 0;
    let loaded = false;
    const install = async () => {
      const seq = ++installSeq;
      const theme = themeRef.current;
      try {
        await addImages(map, theme, iconsRef.current);
      } catch {
        /* a missing icon only blanks that pin */
      }
      if (seq !== installSeq || !map.style) return;
      addOverlay(map, theme);
      setData(map, propsRef.current.view);
    };
    map.on("style.load", () => void install());

    const emitMove = () => {
      const b = map.getBounds();
      const c = map.getCenter();
      propsRef.current.onMove({
        bounds: { west: b.getWest(), south: b.getSouth(), east: b.getEast(), north: b.getNorth() },
        camera: { lng: c.lng, lat: c.lat, zoom: map.getZoom() },
      });
    };
    map.on("load", () => {
      loaded = true;
      emitMove();
    });
    map.on("moveend", emitMove);
    map.on("error", (e) => {
      // Tile hiccups are normal; only a style that never loaded means there is no map.
      if (!loaded && !map.isStyleLoaded() && /style/i.test(String(e.error?.message ?? ""))) {
        propsRef.current.onFailed();
      }
    });
    canvas.addEventListener("webglcontextlost", () => propsRef.current.onFailed());

    const pick = (e: MapLayerMouseEvent) => e.features?.[0]?.properties as Record<string, unknown>;
    map.on("click", LAYER.placesPin, (e) => {
      const id = pick(e)?.id;
      if (typeof id === "string") propsRef.current.onSelectPlace(id);
    });
    map.on("click", LAYER.happenPin, (e) => {
      const id = pick(e)?.id;
      if (typeof id === "string") propsRef.current.onSelectEvent(id);
    });
    map.on("click", LAYER.cellsFill, (e) => {
      // A pin drawn over a cell wins.
      const hits = map.queryRenderedFeatures(e.point, {
        layers: [LAYER.placesPin, LAYER.happenPin],
      });
      if (hits.length) return;
      const key = pick(e)?.key;
      if (typeof key === "string") propsRef.current.onSelectCell(key);
    });
    const expand = (sourceId: string) => async (e: MapLayerMouseEvent) => {
      const f = e.features?.[0];
      const clusterId = f?.properties?.cluster_id as number | undefined;
      if (clusterId === undefined || f?.geometry.type !== "Point") return;
      const source = map.getSource<GeoJSONSource>(sourceId);
      if (!source) return;
      const zoom = await source.getClusterExpansionZoom(clusterId);
      const center = f.geometry.coordinates as [number, number];
      if (propsRef.current.reducedMotion) map.jumpTo({ center, zoom });
      else map.easeTo({ center, zoom });
    };
    map.on("click", LAYER.placesCluster, (e) => void expand(SOURCE.places)(e));
    map.on("click", LAYER.happenCluster, (e) => void expand(SOURCE.happenings)(e));
    for (const id of [
      LAYER.placesPin,
      LAYER.happenPin,
      LAYER.cellsFill,
      LAYER.placesCluster,
      LAYER.happenCluster,
    ]) {
      map.on("mouseenter", id, () => (canvas.style.cursor = "pointer"));
      map.on("mouseleave", id, () => (canvas.style.cursor = ""));
    }

    return () => {
      installSeq++;
      map.remove();
      mapRef.current = null;
    };
  }, []);

  // New data: replace the three sources' contents (the style keeps the layers).
  useEffect(() => {
    const map = mapRef.current;
    if (map) setData(map, props.view);
  }, [props.view]);

  // Theme: swap the basemap; style.load re-adds the images and overlay in the new palette.
  useEffect(() => {
    const map = mapRef.current;
    if (!map || themeRef.current === props.theme) return;
    themeRef.current = props.theme;
    map.setStyle(MAP_STYLE_URLS[props.theme], { diff: false });
  }, [props.theme]);

  useEffect(() => {
    if (props.visible) mapRef.current?.resize();
  }, [props.visible]);

  // Programmatic moves jump instead of flying under prefers-reduced-motion (§9).
  const focusSeq = props.focus?.seq;
  useEffect(() => {
    const map = mapRef.current;
    const f = propsRef.current.focus;
    if (!map || !f) return;
    const opts = { center: [f.lng, f.lat] as [number, number], zoom: f.zoom };
    if (propsRef.current.reducedMotion) map.jumpTo(opts);
    else map.flyTo({ ...opts, speed: 1.6 });
  }, [focusSeq]);

  return (
    <>
      <div ref={containerRef} className="absolute inset-0" />
      {/* The lucide icons, rendered once to read their SVG markup for the pin images. */}
      <div ref={iconsRef} hidden aria-hidden="true">
        {MAP_ICON_KEYS.map((key) => {
          const Icon = PLACE_ICONS[key];
          return <Icon key={key} data-icon={key} width={24} height={24} strokeWidth={2.2} />;
        })}
        <PLAN_ICON data-icon="plan" width={24} height={24} strokeWidth={2.2} />
        <SHOW_ICON data-icon="show" width={24} height={24} strokeWidth={2.2} />
      </div>
    </>
  );
}

function svgFor(root: HTMLElement | null, key: string): string {
  const el = root?.querySelector(`[data-icon="${key}"]`);
  return el ? new XMLSerializer().serializeToString(el) : "";
}

async function addImages(map: MapLibreMap, theme: ResolvedTheme, icons: HTMLElement | null) {
  const palette = PIN_PALETTES[theme];
  const jobs: Promise<void>[] = [];
  const add = (id: string, make: () => Promise<ImageData> | ImageData) => {
    if (map.hasImage(id)) return;
    jobs.push(
      Promise.resolve(make()).then((img) => {
        if (!map.hasImage(id)) map.addImage(id, img, { pixelRatio: PIN_RATIO });
      }),
    );
  };
  for (const key of MAP_ICON_KEYS) {
    const svg = svgFor(icons, key);
    add(placeImageId(key, false), () => drawPin("place", svg, palette));
    add(placeImageId(key, true), () => drawPin("place-generic", svg, palette));
  }
  add(PLAN_IMAGE, () => drawPin("plan", svgFor(icons, "plan"), palette));
  add(PLAN_IMPORTED_IMAGE, () => drawPin("plan-imported", svgFor(icons, "plan"), palette));
  add(SHOW_IMAGE, () => drawPin("show", svgFor(icons, "show"), palette));
  add(HATCH_IMAGE, () => drawHatch(palette));
  await Promise.allSettled(jobs);
}

function addOverlay(map: MapLibreMap, theme: ResolvedTheme) {
  const p = PIN_PALETTES[theme];
  const empty = { type: "FeatureCollection" as const, features: [] };
  if (!map.getSource(SOURCE.cells)) map.addSource(SOURCE.cells, { type: "geojson", data: empty });
  if (!map.getSource(SOURCE.places)) {
    map.addSource(SOURCE.places, {
      type: "geojson",
      data: empty,
      cluster: true,
      clusterRadius: 48,
      clusterMaxZoom: 15,
    });
  }
  if (!map.getSource(SOURCE.happenings)) {
    map.addSource(SOURCE.happenings, {
      type: "geojson",
      data: empty,
      cluster: true,
      clusterRadius: 40,
      clusterMaxZoom: 14,
    });
  }
  const has = (id: string) => Boolean(map.getLayer(id));

  // Approved-only cells: hatch fill plus a dashed outline, so they read as an area, not a spot.
  if (!has(LAYER.cellsFill)) {
    map.addLayer({
      id: LAYER.cellsFill,
      type: "fill",
      source: SOURCE.cells,
      paint: { "fill-pattern": HATCH_IMAGE, "fill-opacity": 0.9 },
    });
  }
  if (!has(LAYER.cellsLine)) {
    map.addLayer({
      id: LAYER.cellsLine,
      type: "line",
      source: SOURCE.cells,
      paint: { "line-color": p.cell, "line-width": 1.5, "line-dasharray": [3, 2] },
    });
  }
  if (!has(LAYER.cellsLabel)) {
    map.addLayer({
      id: LAYER.cellsLabel,
      type: "symbol",
      source: SOURCE.cells,
      minzoom: 8,
      layout: {
        "text-field": ["get", "label"],
        "text-font": MAP_FONT,
        "text-size": 12,
        "text-max-width": 8,
      },
      paint: { "text-color": p.ink, "text-halo-color": p.halo, "text-halo-width": 1.5 },
    });
  }

  // Places: hidden below PLACES_MIN_ZOOM (the route shows "Zoom in to see places" there).
  if (!has(LAYER.placesCluster)) {
    map.addLayer({
      id: LAYER.placesCluster,
      type: "circle",
      source: SOURCE.places,
      minzoom: PLACES_MIN_ZOOM,
      filter: ["has", "point_count"],
      paint: {
        "circle-color": p.clusterPlaces,
        "circle-radius": ["step", ["get", "point_count"], 15, 20, 19, 100, 24],
        "circle-stroke-color": p.halo,
        "circle-stroke-width": 2,
      },
    });
  }
  if (!has(LAYER.placesCount)) {
    map.addLayer({
      id: LAYER.placesCount,
      type: "symbol",
      source: SOURCE.places,
      minzoom: PLACES_MIN_ZOOM,
      filter: ["has", "point_count"],
      layout: {
        "text-field": ["get", "point_count_abbreviated"],
        "text-font": MAP_FONT,
        "text-size": 13,
        "text-allow-overlap": true,
      },
      paint: { "text-color": p.clusterPlacesInk },
    });
  }
  if (!has(LAYER.placesPin)) {
    map.addLayer({
      id: LAYER.placesPin,
      type: "symbol",
      source: SOURCE.places,
      minzoom: PLACES_MIN_ZOOM,
      filter: ["!", ["has", "point_count"]],
      layout: {
        "icon-image": ["get", "icon"],
        "icon-allow-overlap": true,
        "icon-ignore-placement": true,
      },
      paint: { "icon-opacity": ["case", ["get", "pending"], 0.55, 1] },
    });
  }

  // Plans and shows, over places.
  if (!has(LAYER.happenCluster)) {
    map.addLayer({
      id: LAYER.happenCluster,
      type: "circle",
      source: SOURCE.happenings,
      filter: ["has", "point_count"],
      paint: {
        "circle-color": p.plan,
        "circle-radius": ["step", ["get", "point_count"], 15, 20, 19, 100, 24],
        "circle-stroke-color": p.halo,
        "circle-stroke-width": 2,
      },
    });
  }
  if (!has(LAYER.happenCount)) {
    map.addLayer({
      id: LAYER.happenCount,
      type: "symbol",
      source: SOURCE.happenings,
      filter: ["has", "point_count"],
      layout: {
        "text-field": ["get", "point_count_abbreviated"],
        "text-font": MAP_FONT,
        "text-size": 13,
        "text-allow-overlap": true,
      },
      paint: { "text-color": p.planInk },
    });
  }
  if (!has(LAYER.happenPin)) {
    map.addLayer({
      id: LAYER.happenPin,
      type: "symbol",
      source: SOURCE.happenings,
      filter: ["!", ["has", "point_count"]],
      layout: {
        "icon-image": ["get", "icon"],
        "icon-anchor": ["case", ["==", ["get", "kind"], "plan"], "bottom", "center"],
        "icon-allow-overlap": true,
        "icon-ignore-placement": true,
      },
    });
  }
}

function setData(map: MapLibreMap, view: MapView) {
  map.getSource<GeoJSONSource>(SOURCE.places)?.setData(placesGeoJSON(view));
  map.getSource<GeoJSONSource>(SOURCE.happenings)?.setData(happeningsGeoJSON(view));
  map.getSource<GeoJSONSource>(SOURCE.cells)?.setData(cellsGeoJSON(view));
}
