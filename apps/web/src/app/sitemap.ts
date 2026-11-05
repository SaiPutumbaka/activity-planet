import type { MetadataRoute } from "next";

import { siteUrl } from "@/lib/site";

/**
 * /sitemap.xml: the site's standing pages. Share pages (/e/[id]) are reached by their links and
 * are not listed; there is no public index of plans to enumerate them from.
 */
export default function sitemap(): MetadataRoute.Sitemap {
  const site = siteUrl();
  return [
    { url: site, changeFrequency: "weekly", priority: 1 },
    { url: `${site}/account/delete`, changeFrequency: "yearly", priority: 0.3 },
    { url: `${site}/map-data`, changeFrequency: "yearly", priority: 0.3 },
    { url: `${site}/safety`, changeFrequency: "monthly", priority: 0.5 },
    { url: `${site}/support`, changeFrequency: "monthly", priority: 0.4 },
    { url: `${site}/guidelines`, changeFrequency: "monthly", priority: 0.4 },
    { url: `${site}/coach-terms`, changeFrequency: "monthly", priority: 0.3 },
    { url: `${site}/refund-policy`, changeFrequency: "monthly", priority: 0.3 },
    { url: `${site}/safety/intimate-images`, changeFrequency: "yearly", priority: 0.3 },
    { url: `${site}/bot`, changeFrequency: "monthly", priority: 0.3 },
    { url: `${site}/bot/remove`, changeFrequency: "yearly", priority: 0.3 },
  ];
}
