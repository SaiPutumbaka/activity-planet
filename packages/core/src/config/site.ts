/**
 * Where the public site (apps/web) and the product app (apps/app) are served, until the final
 * domain exists. Each app reads its own env var (VITE_SITE_URL, NEXT_PUBLIC_SITE_URL,
 * NEXT_PUBLIC_APP_URL) and falls back to these through resolveUrl, so the fallback lives here once.
 */
export const DEFAULT_SITE_URL = "https://activity-planet.vercel.app";
export const DEFAULT_APP_URL = "https://activity-planet-app.vercel.app";

/** The first non-empty candidate without its trailing slash, else the fallback. */
export function resolveUrl(fallback: string, ...candidates: (string | null | undefined)[]): string {
  const found = candidates.find((c) => typeof c === "string" && c.trim() !== "");
  return (found ?? fallback).trim().replace(/\/+$/, "");
}
