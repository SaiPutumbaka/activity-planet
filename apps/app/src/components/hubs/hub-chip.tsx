import { Chip } from "@/components/ui/chip";
import { formatMembers } from "@/lib/hubs";
import type { CatalogHub } from "@/lib/profile";

import { HubBadges } from "./hub-badges";

/**
 * One hub in the Browse grid: emoji, name, live member count and the 21+/Campus badges. Pressed
 * means joined (aria-pressed from Chip). 44 px tall for the tap-target rule.
 */
export function HubChip({
  hub,
  count,
  joined,
  onClick,
}: {
  hub: CatalogHub;
  /** Undefined while the counts are loading. */
  count: number | undefined;
  joined: boolean;
  onClick: () => void;
}) {
  const label = [
    hub.name,
    formatMembers(count),
    hub.min_age > 18 ? `${hub.min_age} and over` : "",
    hub.scope === "campus" ? "campus hub" : "",
  ]
    .filter(Boolean)
    .join(", ");

  return (
    <Chip
      selected={joined}
      leading={hub.emoji}
      onClick={onClick}
      aria-label={label}
      className="h-11 max-w-full px-3.5"
    >
      <span className="min-w-0 truncate">{hub.name}</span>
      {count !== undefined ? (
        <span className="text-[12px] font-medium text-text-3 tabular">{count}</span>
      ) : null}
      <HubBadges minAge={hub.min_age} scope={hub.scope} />
    </Chip>
  );
}
