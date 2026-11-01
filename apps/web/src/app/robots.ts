import type { MetadataRoute } from "next";

import { siteUrl } from "@/lib/site";

/**
 * /robots.txt. Everything public may be crawled except the API; preview deployments ask to be
 * left out entirely so a branch build never competes with the real site in search.
 */
export default function robots(): MetadataRoute.Robots {
  const site = siteUrl();
  if (process.env.VERCEL_ENV === "preview") {
    return { rules: { userAgent: "*", disallow: "/" } };
  }
  return {
    rules: { userAgent: "*", allow: "/", disallow: "/api/" },
    sitemap: `${site}/sitemap.xml`,
  };
}
