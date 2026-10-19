import { HUB_CATALOG } from "@/lib/hub-catalog";
import type { Hub } from "@/types/database";

// Derived from HUB_CATALOG (the single source of truth for hub content) —
// completeness against the Hub union is checked in scripts/verify-hub-catalog
// rather than by the type system, since hand-writing 100+ literal keys here
// would just duplicate hub-catalog.ts.
export const HUB_EMOJI = Object.fromEntries(
  HUB_CATALOG.flatMap((group) => group.hubs.map((h) => [h.name, h.emoji])),
) as Record<Hub, string>;

export function hubEmoji(category: string): string {
  return category in HUB_EMOJI ? HUB_EMOJI[category as Hub] : "📌";
}
