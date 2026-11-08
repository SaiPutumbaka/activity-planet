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

/**
 * The published versions of the Terms of Service and the Privacy Policy (apps/web /terms and
 * /privacy show them). Bump one when its text changes; the app records the versions a member
 * accepted (accept_legal_terms, migration 77) when they finish onboarding.
 */
export const LEGAL_VERSIONS = {
  terms: "terms 2026-11.2",
  privacy: "privacy 2026-11.2",
} as const;
