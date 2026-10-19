import { HUBS, type Hub } from "@/types/database";

function slugify(name: string): string {
  return name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

// Computed once at module load rather than hand-maintained — with 100+
// hubs, a manual slug Record would be a lot of typing and an easy place for
// drift. Slugify is deterministic and stays backward-compatible with the
// original 8 hubs' URLs (e.g. "TV Shows" -> "tv-shows").
const SLUG_BY_HUB = new Map<Hub, string>(HUBS.map((hub) => [hub, slugify(hub)]));
const HUB_BY_SLUG = new Map<string, Hub>(
  HUBS.map((hub) => [slugify(hub), hub]),
);

export function hubToSlug(hub: Hub): string {
  return SLUG_BY_HUB.get(hub) ?? slugify(hub);
}

export function slugToHub(slug: string): Hub | undefined {
  return HUB_BY_SLUG.get(slug);
}
