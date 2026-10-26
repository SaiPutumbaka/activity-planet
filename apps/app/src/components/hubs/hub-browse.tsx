import type { HubSection, MemberCounts } from "@/lib/hubs";
import type { CatalogHub } from "@/lib/profile";

import { HubChip } from "./hub-chip";

/** The catalog as category headers with hub chips. Tapping a chip joins or leaves. */
export function HubBrowse({
  sections,
  counts,
  joinedIds,
  onToggle,
}: {
  sections: HubSection[];
  /** Undefined while loading. hub_member_counts omits hubs with nobody in them, so missing = 0. */
  counts: MemberCounts | undefined;
  joinedIds: ReadonlySet<string>;
  onToggle: (hub: CatalogHub) => void;
}) {
  return (
    <div className="flex flex-col gap-6">
      {sections.map(({ category, hubs }) => (
        <section key={category.slug} aria-labelledby={`hub-category-${category.slug}`}>
          <h4
            id={`hub-category-${category.slug}`}
            className="mb-2 flex items-baseline gap-2 text-[13px] font-bold tracking-[0.08em] text-text-3 uppercase"
          >
            {category.name}
            <span className="font-medium tracking-normal normal-case tabular">{hubs.length}</span>
          </h4>
          <div className="flex flex-wrap gap-2">
            {hubs.map((hub) => (
              <HubChip
                key={hub.id}
                hub={hub}
                count={counts ? (counts[hub.id] ?? 0) : undefined}
                joined={joinedIds.has(hub.id)}
                onClick={() => onToggle(hub)}
              />
            ))}
          </div>
        </section>
      ))}
    </div>
  );
}
