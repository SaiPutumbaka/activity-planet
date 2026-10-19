const EARTH_RADIUS_MILES = 3958.8;

function toRadians(degrees: number): number {
  return (degrees * Math.PI) / 180;
}

/**
 * Great-circle distance between two coordinates, in miles. Used to sort
 * events and people by proximity — good enough at city/regional scale
 * without needing a PostGIS extension.
 */
export function distanceMiles(
  from: { latitude: number; longitude: number },
  to: { latitude: number; longitude: number },
): number {
  const dLat = toRadians(to.latitude - from.latitude);
  const dLon = toRadians(to.longitude - from.longitude);
  const lat1 = toRadians(from.latitude);
  const lat2 = toRadians(to.latitude);

  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLon / 2) ** 2;
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

  return EARTH_RADIUS_MILES * c;
}

export function formatDistance(miles: number): string {
  if (miles < 0.1) {
    return "Nearby";
  }
  if (miles < 10) {
    return `${miles.toFixed(1)} mi away`;
  }
  return `${Math.round(miles)} mi away`;
}

export interface Coordinates {
  latitude: number;
  longitude: number;
}

/**
 * Wraps the browser Geolocation API in a promise. Client-side only — callers
 * must guard for `navigator.geolocation` support before calling.
 */
export function getBrowserLocation(): Promise<Coordinates> {
  return new Promise((resolve, reject) => {
    if (typeof navigator === "undefined" || !navigator.geolocation) {
      reject(new Error("Location isn't available in this browser."));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (position) => {
        resolve({
          latitude: position.coords.latitude,
          longitude: position.coords.longitude,
        });
      },
      (error) => {
        reject(new Error(error.message || "Could not read your location."));
      },
      { enableHighAccuracy: false, timeout: 10_000, maximumAge: 60_000 },
    );
  });
}

interface NominatimReverseResponse {
  display_name?: string;
  address?: {
    city?: string;
    town?: string;
    village?: string;
    state?: string;
    country?: string;
  };
}

/**
 * Best-effort reverse geocoding via OpenStreetMap's free Nominatim API — no
 * API key required. Used only to prefill a human-readable location string;
 * failures are non-fatal, the caller falls back to raw coordinates.
 */
export async function reverseGeocode(
  coords: Coordinates,
): Promise<string | null> {
  try {
    const url = new URL("https://nominatim.openstreetmap.org/reverse");
    url.searchParams.set("format", "jsonv2");
    url.searchParams.set("lat", String(coords.latitude));
    url.searchParams.set("lon", String(coords.longitude));
    url.searchParams.set("zoom", "10");

    const response = await fetch(url.toString(), {
      headers: { Accept: "application/json" },
    });
    if (!response.ok) {
      return null;
    }
    const data = (await response.json()) as NominatimReverseResponse;
    const place =
      data.address?.city ?? data.address?.town ?? data.address?.village;
    if (place && data.address?.state) {
      return `${place}, ${data.address.state}`;
    }
    return data.display_name ?? null;
  } catch {
    return null;
  }
}
