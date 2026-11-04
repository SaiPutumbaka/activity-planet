import { useState, useSyncExternalStore } from "react";
import { queryOptions, useQuery } from "@tanstack/react-query";
import { clampRadiusKm, roundPoint } from "@ap/core/feed";
import {
  feedOriginLabel,
  geoapifyCityToPlace,
  parseGeoPoint,
  type PlaceResult,
} from "@ap/core/places";
import type { Database } from "@ap/core/types";

import { supabase } from "./supabase";
import { geoapifyKey } from "./venues";

/**
 * Where the feed is centred (D-036, D-040). The saved home (a point anywhere in the world with a
 * label, or a named area) is the default origin; a device point is
 * used only after the person taps "Use my location", is rounded to two decimals (about 1 km),
 * lives in memory and sessionStorage for this tab, and is sent with each feed request without
 * ever being stored on the server. A denial is remembered in localStorage and the app never asks
 * again on its own (iOS can report "prompt" after a denial, so the browser's own state is not
 * trusted for this).
 *
 *   const origin = useFeedOrigin(userId)
 *   origin.label                 // "Lisbon" | "Midtown" | "Near you"
 *   origin.point                 // { lat, lng } | null: only when the device point is in use
 *   await origin.locate()          // "granted" | "denied" | "unavailable"
 *   origin.clearDevicePoint()      // back to the home area
 */

export type Area = Pick<
  Database["public"]["Tables"]["areas"]["Row"],
  "id" | "slug" | "name" | "kind" | "default_radius_km" | "sort" | "parent_id"
>;

/** Named areas (seeded cities and neighborhoods), in display order. Everyone can read areas. */
export const areasQuery = queryOptions({
  queryKey: ["areas"] as const,
  queryFn: async (): Promise<Area[]> => {
    const { data, error } = await supabase
      .from("areas")
      .select("id,slug,name,kind,default_radius_km,sort,parent_id")
      .order("sort")
      .order("name");
    if (error) throw error;
    return data;
  },
  staleTime: 60 * 60_000,
});

export interface FeedPrefs {
  /** profile_private.feed_radius_km, clamped to the allowed range. */
  radiusKm: number;
  /** profile_private.home_area_id: set when the home is a named area, else null. */
  homeAreaId: string | null;
  /** profile_private.home_label: what the person picked ("Lisbon, Portugal"); null for "my location". */
  homeLabel: string | null;
  /** profile_private.home_point, rounded to about 1 km; null when no home was saved. */
  homePoint: { lat: number; lng: number } | null;
}

/** The saved home and feed radius. All of it lives in profile_private, readable by the owner only. */
export const feedPrefsQuery = (userId: string) =>
  queryOptions({
    queryKey: ["feed-prefs", userId] as const,
    queryFn: async (): Promise<FeedPrefs> => {
      const { data, error } = await supabase
        .from("profile_private")
        .select("feed_radius_km,home_area_id,home_label,home_point")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      return {
        radiusKm: clampRadiusKm(data?.feed_radius_km),
        homeAreaId: data?.home_area_id ?? null,
        homeLabel: data?.home_label ?? null,
        homePoint: parseGeoPoint(data?.home_point),
      };
    },
    staleTime: 5 * 60_000,
  });

/** set_home_area: saves the home area and the radius (the area's default when none is given). */
export async function setHomeArea(areaId: string, radiusKm?: number): Promise<void> {
  const { error } = await supabase.rpc("set_home_area", {
    p_area_id: areaId,
    ...(radiusKm !== undefined ? { p_radius_km: radiusKm } : {}),
  });
  if (error) throw error;
}

/**
 * set_home_location: saves a home point anywhere in the world (rounded to about 1 km on the server)
 * with its label, clearing any home area. No radius keeps the saved one.
 */
export async function setHomeLocation(
  lat: number,
  lng: number,
  label: string | null,
  radiusKm?: number,
): Promise<void> {
  const { error } = await supabase.rpc("set_home_location", {
    p_lat: lat,
    p_lng: lng,
    ...(label ? { p_label: label } : {}),
    ...(radiusKm !== undefined ? { p_radius_km: radiusKm } : {}),
  });
  if (error) throw error;
}

/**
 * Up to eight cities and neighborhoods anywhere in the world for the home search, from Geoapify.
 * Empty without a key (the starter list is used then). Streets and venues are left out.
 */
export async function geoapifyCitySearch(
  text: string,
  signal?: AbortSignal,
): Promise<PlaceResult[]> {
  if (!geoapifyKey) return [];
  const url = new URL("https://api.geoapify.com/v1/geocode/autocomplete");
  url.searchParams.set("text", text);
  url.searchParams.set("limit", "10");
  url.searchParams.set("format", "json");
  const lang = typeof navigator !== "undefined" ? navigator.language?.slice(0, 2) : "";
  if (lang && /^[a-z]{2}$/.test(lang)) url.searchParams.set("lang", lang);
  url.searchParams.set("apiKey", geoapifyKey);
  const res = await fetch(url, { signal });
  if (!res.ok) throw new Error(`City lookup failed (${res.status}).`);
  const body = (await res.json()) as { results?: Parameters<typeof geoapifyCityToPlace>[0][] };
  const seen = new Set<string>();
  return (body.results ?? [])
    .flatMap((r) => {
      const place = geoapifyCityToPlace(r);
      if (!place || seen.has(place.label)) return [];
      seen.add(place.label);
      return [place];
    })
    .slice(0, 8);
}

export const citySearchQuery = (text: string) => {
  const q = text.trim();
  return queryOptions({
    queryKey: ["geoapify-city", q.toLowerCase()] as const,
    queryFn: ({ signal }) => geoapifyCitySearch(q, signal),
    enabled: geoapifyKey !== null && q.length >= 3,
    staleTime: 10 * 60_000,
    retry: 0,
  });
};

/**
 * A home the person picked: a point anywhere (a searched city, or their rough position, which has
 * no label) or one of the named areas. Saved by complete_onboarding, set_home_location or
 * set_home_area.
 */
export type HomeChoice =
  | { kind: "point"; key: string; lat: number; lng: number; label: string | null }
  | { kind: "area"; key: string; areaId: string; label: string };

/** What the person sees for a choice: its label, or the rough-position wording. */
export function homeChoiceLabel(choice: HomeChoice): string {
  return choice.label ?? "Your current location";
}

/** Whether city search goes to Geoapify (true) or to the built-in starter list (false). */
export const hasCitySearch = geoapifyKey !== null;

const AREA_MESSAGES: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  area_required: "Pick an area.",
  area_not_found: "That area isn't available anymore. Pick another one.",
  radius_out_of_range: "Pick a distance between 1 and 50 km.",
  profile_missing: "Your profile is missing. Sign in again.",
  invalid_coordinates: "That place couldn't be found. Pick another one.",
  label_too_long: "That place name is too long. Pick another one.",
  location_conflict: "Pick one place.",
};

export function areaErrorMessage(err: unknown): string {
  const message =
    typeof err === "object" && err && "message" in err && typeof err.message === "string"
      ? err.message.trim()
      : "";
  if (AREA_MESSAGES[message]) return AREA_MESSAGES[message];
  if (/Failed to fetch|NetworkError|Load failed/i.test(message))
    return "Couldn't reach the server. Check your connection and try again.";
  return "Couldn't save that. Try again.";
}

/* ------------------------------------------------------------------ */
/* Device point: an in-memory store mirrored to sessionStorage           */
/* ------------------------------------------------------------------ */

export interface DevicePoint {
  lat: number;
  lng: number;
}

const SESSION_KEY = "ap-feed-device-point";
const DENIED_KEY = "ap-geo-denied";
const listeners = new Set<() => void>();

function readSessionPoint(): DevicePoint | null {
  try {
    const raw = sessionStorage.getItem(SESSION_KEY);
    if (!raw) return null;
    const v = JSON.parse(raw) as { lat?: unknown; lng?: unknown };
    if (typeof v.lat !== "number" || typeof v.lng !== "number") return null;
    return roundPoint(v.lat, v.lng);
  } catch {
    return null;
  }
}

function readDenied(): boolean {
  try {
    return localStorage.getItem(DENIED_KEY) === "1";
  } catch {
    return false;
  }
}

let devicePoint: DevicePoint | null = typeof window === "undefined" ? null : readSessionPoint();
let denied: boolean = typeof window === "undefined" ? false : readDenied();

function emit() {
  listeners.forEach((l) => l());
}

function setDevicePoint(point: DevicePoint | null) {
  devicePoint = point;
  try {
    if (point) sessionStorage.setItem(SESSION_KEY, JSON.stringify(point));
    else sessionStorage.removeItem(SESSION_KEY);
  } catch {
    /* storage unavailable: the point still lives in memory for this page */
  }
  emit();
}

function setDenied(value: boolean) {
  denied = value;
  try {
    if (value) localStorage.setItem(DENIED_KEY, "1");
    else localStorage.removeItem(DENIED_KEY);
  } catch {
    /* storage unavailable: remembered for this page only */
  }
  emit();
}

/**
 * Forgets the device point and the remembered denial, in memory and in storage. Called on sign-out
 * and account deletion so the next person on this browser starts from their own home area.
 */
export function clearFeedLocation(): void {
  devicePoint = null;
  denied = false;
  try {
    sessionStorage.removeItem(SESSION_KEY);
  } catch {
    /* storage unavailable */
  }
  try {
    localStorage.removeItem(DENIED_KEY);
    // The Map tab's last view (lib/map.ts saveCamera) is about as revealing as the device point.
    localStorage.removeItem("ap-map-view");
  } catch {
    /* storage unavailable */
  }
  emit();
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  return () => listeners.delete(cb);
}

/** iPhone and iPad, including iPadOS that reports itself as a Mac. */
export function isIos(): boolean {
  if (typeof navigator === "undefined") return false;
  return (
    /iPad|iPhone|iPod/.test(navigator.userAgent) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  );
}

export type LocationResult = "granted" | "denied" | "unavailable";

/**
 * Asks the browser once, only because the person tapped. Coarse on purpose: no GPS, a fix up to
 * ten minutes old is fine, and it gives up after eight seconds.
 */
export function requestRoughPosition(): Promise<{
  result: LocationResult;
  point: DevicePoint | null;
}> {
  if (typeof navigator === "undefined" || !("geolocation" in navigator)) {
    return Promise.resolve({ result: "unavailable", point: null });
  }
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const point = roundPoint(pos.coords.latitude, pos.coords.longitude);
        if (!point) {
          resolve({ result: "unavailable", point: null });
          return;
        }
        setDenied(false);
        resolve({ result: "granted", point });
      },
      (err) => {
        if (err.code === 1) {
          setDenied(true);
          setDevicePoint(null);
          resolve({ result: "denied", point: null });
          return;
        }
        resolve({ result: "unavailable", point: null });
      },
      { enableHighAccuracy: false, maximumAge: 600_000, timeout: 8_000 },
    );
  });
}

/** The rough position as this visit's feed origin (Home's "Use my location"); never saved. */
async function requestDevicePoint(): Promise<LocationResult> {
  const { result, point } = await requestRoughPosition();
  if (point) setDevicePoint(point);
  return result;
}

/** Whether the person said no to location before (remembered on this browser). */
export function useLocationDenied(): boolean {
  return useSyncExternalStore(
    subscribe,
    () => denied,
    () => false,
  );
}

/**
 * The device point and the denial flag without the feed's home-location queries, for screens that
 * also work signed out (the Map tab). Same store as useFeedOrigin, so a point given on one screen
 * is used on the other.
 */
export function useDevicePoint(): {
  point: DevicePoint | null;
  denied: boolean;
  locate: () => Promise<LocationResult>;
} {
  const point = useSyncExternalStore(
    subscribe,
    () => devicePoint,
    () => null,
  );
  const isDenied = useLocationDenied();
  return { point, denied: isDenied, locate: requestDevicePoint };
}

export type FeedOrigin =
  { kind: "device"; point: DevicePoint } | { kind: "area"; area: Area | null };

export interface FeedOriginController {
  origin: FeedOrigin;
  /** The device point when it is the origin; what the feed sends as p_lat/p_lng. */
  point: DevicePoint | null;
  /** "Near you" for a device point or an unlabeled home, else the saved label's first part. */
  label: string;
  /** The saved home as a full label for the You tab; null when nothing was saved. */
  homeLabel: string | null;
  /** The saved home point (about 1 km), when there is one. */
  homePoint: DevicePoint | null;
  /** The saved home area, when the home is a named area. */
  homeArea: Area | null;
  areas: Area[];
  /** The person said no before; the button explains instead of acting surprised. */
  denied: boolean;
  /** The geolocation request is in flight. */
  locating: boolean;
  /** A denial on iOS opens the how-to sheet; this flag drives it. */
  howToOpen: boolean;
  closeHowTo: () => void;
  locate: () => Promise<LocationResult>;
  clearDevicePoint: () => void;
}

export function useFeedOrigin(userId: string): FeedOriginController {
  const prefs = useQuery(feedPrefsQuery(userId));
  const areas = useQuery(areasQuery);
  const point = useSyncExternalStore(
    subscribe,
    () => devicePoint,
    () => null,
  );
  const isDenied = useSyncExternalStore(
    subscribe,
    () => denied,
    () => false,
  );
  const [locating, setLocating] = useState(false);
  const [howToOpen, setHowToOpen] = useState(false);

  const list = areas.data ?? [];
  const homeArea = list.find((a) => a.id === prefs.data?.homeAreaId) ?? null;
  const homeLabel = prefs.data?.homeLabel ?? homeArea?.name ?? null;

  async function locate(): Promise<LocationResult> {
    setLocating(true);
    try {
      const result = await requestDevicePoint();
      if (result === "denied" && isIos()) setHowToOpen(true);
      return result;
    } finally {
      setLocating(false);
    }
  }

  const origin: FeedOrigin = point ? { kind: "device", point } : { kind: "area", area: homeArea };

  return {
    origin,
    point,
    label: feedOriginLabel({ usingDevice: point !== null, homeLabel }),
    homeLabel,
    homePoint: prefs.data?.homePoint ?? null,
    homeArea,
    areas: list,
    denied: isDenied,
    locating,
    howToOpen,
    closeHowTo: () => setHowToOpen(false),
    locate,
    clearDevicePoint: () => setDevicePoint(null),
  };
}
