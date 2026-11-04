import type { ResolvedTheme } from "./theme";
import { cellLabel, cellRing, placeKindInfo, type MapIconKey, type MapView } from "./map";

/**
 * Map styling (D-038, §9): the basemap style per theme, the pin artwork and the overlay GeoJSON.
 * Only types come from maplibre-gl here, so importing this file never pulls MapLibre into a
 * chunk; the canvas (components/map/map-canvas.tsx) is the only runtime importer.
 *
 * OpenFreeMap needs no key. Its styles are "liberty", "bright", "positron", "dark" and "fiord";
 * re-check the dark one once the host is reachable (§9, FOUNDER-TODO 14). Any provider can be
 * swapped in through the env, but its tile host must also be added to img-src in vite.config.ts.
 */
export const MAP_STYLE_URLS: Record<ResolvedTheme, string> = {
  light:
    (import.meta.env.VITE_MAP_STYLE_URL as string | undefined) ||
    "https://tiles.openfreemap.org/styles/positron",
  dark:
    (import.meta.env.VITE_MAP_STYLE_URL_DARK as string | undefined) ||
    "https://tiles.openfreemap.org/styles/dark",
};

/** A glyph stack OpenFreeMap serves; used for cluster counts and cell labels. */
export const MAP_FONT = ["Noto Sans Bold"];

export const SOURCE = {
  places: "ap-places",
  happenings: "ap-happenings",
  cells: "ap-cells",
} as const;

export const LAYER = {
  cellsFill: "ap-cells-fill",
  cellsLine: "ap-cells-line",
  cellsLabel: "ap-cells-label",
  placesCluster: "ap-places-cluster",
  placesCount: "ap-places-count",
  placesPin: "ap-places-pin",
  happenCluster: "ap-happen-cluster",
  happenCount: "ap-happen-count",
  happenPin: "ap-happen-pin",
} as const;

export interface PinPalette {
  surface: string;
  ink: string;
  muted: string;
  halo: string;
  plan: string;
  planInk: string;
  imported: string;
  importedInk: string;
  show: string;
  showInk: string;
  cell: string;
  clusterPlaces: string;
  clusterPlacesInk: string;
}

/** Hex values from packages/ui tokens.css (sun orange, hub violet, info grey-blue). */
export const PIN_PALETTES: Record<ResolvedTheme, PinPalette> = {
  light: {
    surface: "#ffffff",
    ink: "#0e0f11",
    muted: "#80858d",
    halo: "#ffffff",
    plan: "#f25c0a",
    planInk: "#0e0f11",
    imported: "#5b7a99",
    importedInk: "#ffffff",
    show: "#5e2bae",
    showInk: "#ffffff",
    cell: "#5e2bae",
    clusterPlaces: "#0e0f11",
    clusterPlacesInk: "#ffffff",
  },
  dark: {
    surface: "#141414",
    ink: "#f5f5f7",
    muted: "#a4a8ae",
    halo: "#000000",
    plan: "#ff7a33",
    planInk: "#0e0f11",
    imported: "#8aa6c2",
    importedInk: "#0e0f11",
    show: "#b48cf2",
    showInk: "#0e0f11",
    cell: "#b48cf2",
    clusterPlaces: "#f5f5f7",
    clusterPlacesInk: "#0e0f11",
  },
};

/* ------------------------------------------------------------------ */
/* Pin artwork                                                          */
/* ------------------------------------------------------------------ */

/** Canvas pixels per CSS pixel for the pin images (pixel ratio is capped at 2, §9). */
export const PIN_RATIO = 2;

export type PinShape = "place" | "place-generic" | "plan" | "plan-imported" | "show";

export function placeImageId(icon: MapIconKey, generic: boolean): string {
  return `ap-place-${icon}${generic ? "-g" : ""}`;
}
export const PLAN_IMAGE = "ap-plan";
export const PLAN_IMPORTED_IMAGE = "ap-plan-imported";
export const SHOW_IMAGE = "ap-show";
export const HATCH_IMAGE = "ap-hatch";

/** Size in CSS pixels of each shape's image. */
export const PIN_SIZE: Record<PinShape, { w: number; h: number }> = {
  place: { w: 30, h: 30 },
  "place-generic": { w: 28, h: 28 },
  plan: { w: 30, h: 38 },
  "plan-imported": { w: 30, h: 38 },
  show: { w: 38, h: 28 },
};

function shapePath(ctx: CanvasRenderingContext2D, shape: PinShape) {
  const { w, h } = PIN_SIZE[shape];
  ctx.beginPath();
  if (shape === "place" || shape === "place-generic") {
    // Rounded square.
    ctx.roundRect(2, 2, w - 4, h - 4, 8);
  } else if (shape === "plan" || shape === "plan-imported") {
    // Teardrop: a circle over the top, a point at the bottom (the anchor).
    const r = 13;
    ctx.arc(w / 2, r + 2, r, Math.PI * 0.75, Math.PI * 0.25, false);
    ctx.lineTo(w / 2, h - 1.5);
    ctx.closePath();
  } else {
    // Ticket: a rounded rectangle with a half-circle notch on each short side.
    const x0 = 2;
    const y0 = 3;
    const x1 = w - 2;
    const y1 = h - 3;
    const cy = h / 2;
    const rr = 4;
    const n = 4.5;
    ctx.moveTo(x0 + rr, y0);
    ctx.lineTo(x1 - rr, y0);
    ctx.arcTo(x1, y0, x1, y0 + rr, rr);
    ctx.lineTo(x1, cy - n);
    ctx.arc(x1, cy, n, -Math.PI / 2, Math.PI / 2, true);
    ctx.lineTo(x1, y1 - rr);
    ctx.arcTo(x1, y1, x1 - rr, y1, rr);
    ctx.lineTo(x0 + rr, y1);
    ctx.arcTo(x0, y1, x0, y1 - rr, rr);
    ctx.lineTo(x0, cy + n);
    ctx.arc(x0, cy, n, Math.PI / 2, -Math.PI / 2, true);
    ctx.lineTo(x0, y0 + rr);
    ctx.arcTo(x0, y0, x0 + rr, y0, rr);
    ctx.closePath();
  }
}

function shapeColors(shape: PinShape, p: PinPalette) {
  switch (shape) {
    case "place":
      return { fill: p.surface, stroke: p.ink, icon: p.ink, dashed: false };
    case "place-generic":
      return { fill: p.surface, stroke: p.muted, icon: p.muted, dashed: true };
    case "plan":
      return { fill: p.plan, stroke: p.halo, icon: p.planInk, dashed: false };
    case "plan-imported":
      return { fill: p.imported, stroke: p.halo, icon: p.importedInk, dashed: false };
    case "show":
      return { fill: p.show, stroke: p.halo, icon: p.showInk, dashed: false };
  }
}

/** Where the icon sits inside each shape, in CSS pixels. */
function iconBox(shape: PinShape): { x: number; y: number; size: number } {
  const { w, h } = PIN_SIZE[shape];
  if (shape === "plan" || shape === "plan-imported") return { x: w / 2 - 8, y: 7, size: 16 };
  if (shape === "show") return { x: w / 2 - 7.5, y: h / 2 - 7.5, size: 15 };
  const size = shape === "place-generic" ? 14 : 16;
  return { x: w / 2 - size / 2, y: h / 2 - size / 2, size };
}

async function svgImage(svg: string, color: string): Promise<HTMLImageElement> {
  const img = new Image();
  img.src = `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg.replaceAll("currentColor", color))}`;
  await img.decode();
  return img;
}

/**
 * Draws one pin: the shape (fill, outline; dashed for a generic spot) and a lucide icon in it.
 * `iconSvg` is the icon's serialized <svg> with `currentColor` strokes.
 */
export async function drawPin(
  shape: PinShape,
  iconSvg: string,
  palette: PinPalette,
): Promise<ImageData> {
  const { w, h } = PIN_SIZE[shape];
  const canvas = document.createElement("canvas");
  canvas.width = w * PIN_RATIO;
  canvas.height = h * PIN_RATIO;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("2D canvas unavailable");
  ctx.scale(PIN_RATIO, PIN_RATIO);
  const c = shapeColors(shape, palette);
  ctx.shadowColor = "rgba(14,15,17,0.25)";
  ctx.shadowBlur = 3;
  ctx.shadowOffsetY = 1;
  shapePath(ctx, shape);
  ctx.fillStyle = c.fill;
  ctx.fill();
  ctx.shadowColor = "transparent";
  ctx.lineWidth = 2;
  ctx.strokeStyle = c.stroke;
  ctx.setLineDash(c.dashed ? [3, 2.5] : []);
  ctx.stroke();
  const box = iconBox(shape);
  const icon = await svgImage(iconSvg, c.icon);
  ctx.drawImage(icon, box.x, box.y, box.size, box.size);
  return ctx.getImageData(0, 0, canvas.width, canvas.height);
}

/** The diagonal hatch that fills approved-only cells (a pattern, so it reads without colour). */
export function drawHatch(palette: PinPalette): ImageData {
  const s = 10;
  const canvas = document.createElement("canvas");
  canvas.width = s * PIN_RATIO;
  canvas.height = s * PIN_RATIO;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("2D canvas unavailable");
  ctx.scale(PIN_RATIO, PIN_RATIO);
  ctx.strokeStyle = palette.cell;
  ctx.globalAlpha = 0.45;
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  // Three strokes so the pattern tiles seamlessly at the corners.
  ctx.moveTo(-1, s + 1);
  ctx.lineTo(s + 1, -1);
  ctx.moveTo(-1, 1);
  ctx.lineTo(1, -1);
  ctx.moveTo(s - 1, s + 1);
  ctx.lineTo(s + 1, s - 1);
  ctx.stroke();
  return ctx.getImageData(0, 0, canvas.width, canvas.height);
}

/* ------------------------------------------------------------------ */
/* Overlay data                                                         */
/* ------------------------------------------------------------------ */

/** Just enough GeoJSON typing for the overlay sources (the geojson types are not a direct dep). */
interface Point {
  type: "Point";
  coordinates: [number, number];
}
interface Polygon {
  type: "Polygon";
  coordinates: [number, number][][];
}
interface Feature<G, P> {
  type: "Feature";
  geometry: G;
  properties: P;
}
export interface FeatureCollection<G, P> {
  type: "FeatureCollection";
  features: Feature<G, P>[];
}

export interface PinProps {
  id: string;
  kind: "place" | "plan" | "show";
  icon: string;
  name: string;
  pending: boolean;
}

export interface CellProps {
  key: string;
  label: string;
}

export function placesGeoJSON(view: Pick<MapView, "places">): FeatureCollection<Point, PinProps> {
  return {
    type: "FeatureCollection",
    features: view.places.map((f): Feature<Point, PinProps> => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [f.lng, f.lat] },
      properties: {
        id: f.id,
        kind: "place",
        icon: placeImageId(placeKindInfo(f.type).icon, f.generic),
        name: f.name,
        pending: f.pending,
      },
    })),
  };
}

export function happeningsGeoJSON(
  view: Pick<MapView, "plans" | "shows">,
): FeatureCollection<Point, PinProps> {
  return {
    type: "FeatureCollection",
    features: [...view.plans, ...view.shows].map((f): Feature<Point, PinProps> => ({
      type: "Feature",
      geometry: { type: "Point", coordinates: [f.lng, f.lat] },
      properties: {
        id: f.id,
        kind: f.kind === "show" ? "show" : "plan",
        icon: f.kind === "show" ? SHOW_IMAGE : f.imported ? PLAN_IMPORTED_IMAGE : PLAN_IMAGE,
        name: f.name,
        pending: false,
      },
    })),
  };
}

/** Approved-only cells as polygons: shaded squares, never points (D-038). */
export function cellsGeoJSON(view: Pick<MapView, "cells">): FeatureCollection<Polygon, CellProps> {
  return {
    type: "FeatureCollection",
    features: view.cells.map((c): Feature<Polygon, CellProps> => ({
      type: "Feature",
      geometry: { type: "Polygon", coordinates: [cellRing(c.center)] },
      properties: { key: c.key, label: cellLabel(c.count) },
    })),
  };
}
