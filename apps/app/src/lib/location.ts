import { useState, useSyncExternalStore } from "react";
import { queryOptions, useQuery } from "@tanstack/react-query";
import { clampRadiusKm, roundPoint } from "@ap/core/feed";
import type { Database } from "@ap/core/types";

import { supabase } from "./supabase";

/**
 * Where the feed is centred (D-036). The saved home area is the default origin; a device point is
 * used only after the person taps "Use my location", is rounded to two decimals (about 1 km),
 * lives in memory and sessionStorage for this tab, and is sent with each feed request without
 * ever being stored on the server. A denial is remembered in localStorage and the app never asks
 * again on its own (iOS can report "prompt" after a denial, so the browser's own state is not
 * trusted for this).
 *
 *   const origin = useFeedOrigin(userId)
 *   origin.label                 // "Midtown" | "Near you" | "Atlanta"
 *   origin.point                 // { lat, lng } | null: only when the device point is in use
 *   await origin.locate()          // "granted" | "denied" | "unavailable"
 *   origin.clearDevicePoint()      // back to the home area
 */

export type Area = Pick<
  Database["public"]["Tables"]["areas"]["Row"],
  "id" | "slug" | "name" | "kind" | "default_radius_km" | "sort"
>;

/** Atlanta and its neighborhoods, in their display order. Everyone can read areas. */
export const areasQuery = queryOptions({
  queryKey: ["areas"] as const,
  queryFn: async (): Promise<Area[]> => {
    const { data, error } = await supabase
      .from("areas")
      .select("id,slug,name,kind,default_radius_km,sort")
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
  /** profile_private.home_area_id: null before onboarding (the feed then uses Atlanta). */
  homeAreaId: string | null;
}

/** The saved home area and feed radius. Both live in profile_private, readable by the owner only. */
export const feedPrefsQuery = (userId: string) =>
  queryOptions({
    queryKey: ["feed-prefs", userId] as const,
    queryFn: async (): Promise<FeedPrefs> => {
      const { data, error } = await supabase
        .from("profile_private")
        .select("feed_radius_km,home_area_id")
        .eq("user_id", userId)
        .maybeSingle();
      if (error) throw error;
      return {
        radiusKm: clampRadiusKm(data?.feed_radius_km),
        homeAreaId: data?.home_area_id ?? null,
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

/** join_area_waitlist: "tell me when you reach my city". */
export async function joinAreaWaitlist(city: string): Promise<void> {
  const { error } = await supabase.rpc("join_area_waitlist", { p_city: city.trim() });
  if (error) throw error;
}

const AREA_MESSAGES: Record<string, string> = {
  not_authenticated: "Your session ended. Sign in again.",
  area_required: "Pick an area.",
  area_not_found: "That area isn't available anymore. Pick another one.",
  radius_out_of_range: "Pick a distance between 1 and 50 km.",
  profile_missing: "Your profile is missing. Sign in again.",
  city_length: "Enter a city name (2 to 80 characters).",
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
function requestDevicePoint(): Promise<LocationResult> {
  if (typeof navigator === "undefined" || !("geolocation" in navigator)) {
    return Promise.resolve("unavailable");
  }
  return new Promise((resolve) => {
    navigator.geolocation.getCurrentPosition(
      (pos) => {
        const point = roundPoint(pos.coords.latitude, pos.coords.longitude);
        if (!point) {
          resolve("unavailable");
          return;
        }
        setDenied(false);
        setDevicePoint(point);
        resolve("granted");
      },
      (err) => {
        if (err.code === 1) {
          setDenied(true);
          setDevicePoint(null);
          resolve("denied");
          return;
        }
        resolve("unavailable");
      },
      { enableHighAccuracy: false, maximumAge: 600_000, timeout: 8_000 },
    );
  });
}

/**
 * The device point and the denial flag without the feed's home-area queries, for screens that also
 * work signed out (the Map tab). Same store as useFeedOrigin, so a point given on one screen is
 * used on the other.
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
  const isDenied = useSyncExternalStore(
    subscribe,
    () => denied,
    () => false,
  );
  return { point, denied: isDenied, locate: requestDevicePoint };
}

export type FeedOrigin =
  { kind: "device"; point: DevicePoint } | { kind: "area"; area: Area | null };

export interface FeedOriginController {
  origin: FeedOrigin;
  /** The device point when it is the origin; what the feed sends as p_lat/p_lng. */
  point: DevicePoint | null;
  /** "Near you", the home area's name, or "Atlanta" before areas load. */
  label: string;
  homeArea: Area | null;
  /** The area set_home_area falls back to when the profile has none (Atlanta). */
  defaultArea: Area | null;
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
  const defaultArea = list.find((a) => a.slug === "atlanta") ?? null;
  const homeArea = list.find((a) => a.id === prefs.data?.homeAreaId) ?? defaultArea;

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
    label: point ? "Near you" : (homeArea?.name ?? "Atlanta"),
    homeArea,
    defaultArea,
    areas: list,
    denied: isDenied,
    locating,
    howToOpen,
    closeHowTo: () => setHowToOpen(false),
    locate,
    clearDevicePoint: () => setDevicePoint(null),
  };
}
