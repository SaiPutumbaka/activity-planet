import { DEFAULT_SITE_URL, resolveUrl } from "@ap/core/site";

/** Where the public site (apps/web) is served: share pages, legal pages, guidelines. */
export const SITE_URL = resolveUrl(
  DEFAULT_SITE_URL,
  import.meta.env.VITE_SITE_URL as string | undefined,
);
