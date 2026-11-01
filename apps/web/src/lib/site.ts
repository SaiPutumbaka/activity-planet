import { DEFAULT_APP_URL, DEFAULT_SITE_URL, resolveUrl } from "@ap/core/site";

/**
 * This site's origin, for metadataBase, robots, the sitemap and absolute share and calendar URLs:
 * NEXT_PUBLIC_SITE_URL, else the Vercel production host, else the shared fallback.
 */
export function siteUrl(): string {
  const vercel = process.env.VERCEL_PROJECT_PRODUCTION_URL;
  return resolveUrl(
    DEFAULT_SITE_URL,
    process.env.NEXT_PUBLIC_SITE_URL,
    vercel ? `https://${vercel}` : null,
  );
}

/** Where the product app is served; the share page's primary call to action deep-links into it. */
export const APP_URL = resolveUrl(DEFAULT_APP_URL, process.env.NEXT_PUBLIC_APP_URL);

/** iOS bundle id and Android package of the Capacitor build (FOUNDER-TODO item 4). */
export const NATIVE_APP_ID = "app.activityplanet.mobile";
