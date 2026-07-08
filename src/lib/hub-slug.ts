import { HUBS, type Hub } from "@/types/database";

/**
 * Explicit kebab-case slugs (rather than encodeURIComponent(hub)) so hub
 * URLs stay clean — /hubs/tv-shows instead of /hubs/TV%20Shows.
 */
const HUB_SLUGS: Record<Hub, string> = {
  "College Campus Life": "college-campus-life",
  Basketball: "basketball",
  Pickleball: "pickleball",
  Anime: "anime",
  "TV Shows": "tv-shows",
  Movies: "movies",
  "Ping Pong": "ping-pong",
  Pool: "pool",
};

const SLUG_TO_HUB: Record<string, Hub> = Object.fromEntries(
  HUBS.map((hub) => [HUB_SLUGS[hub], hub]),
);

export function hubToSlug(hub: Hub): string {
  return HUB_SLUGS[hub];
}

export function slugToHub(slug: string): Hub | undefined {
  return SLUG_TO_HUB[slug];
}
