import { Plus } from "lucide-react";

import { Chip } from "@/components/ui/chip";
import { cn } from "@/lib/cn";
import { categoryTone } from "@/lib/hubs";
import { genericSpotsOn, toggleHubChip, type ChipHub, type HubSelection } from "@/lib/map";

/**
 * Hub filter chips (§9): "All my hubs" plus one chip per joined hub (and any hub previewed through
 * "+ Explore"). The default is the viewer's joined hubs. Exactly one selected chip turns on that
 * hub's general spots (cafés, parks, libraries), and the row says so.
 */
export function HubChips({
  hubs,
  selection,
  onChange,
  eventsOnly,
  onExplore,
  signedIn,
}: {
  hubs: readonly ChipHub[];
  selection: HubSelection;
  onChange: (next: HubSelection) => void;
  /** Hub ids with no places (`place_mode = 'none'`). */
  eventsOnly: ReadonlySet<string>;
  onExplore: () => void;
  signedIn: boolean;
}) {
  const hasJoined = hubs.some((h) => h.joined);
  const generic = genericSpotsOn(selection, hubs);
  const selectedOne = selection?.length === 1 ? hubs.find((h) => h.id === selection[0]) : null;

  return (
    <div className="flex flex-col gap-1">
      <div
        role="group"
        aria-label="Hubs"
        className="no-scrollbar -mx-4 flex gap-2 overflow-x-auto px-4 py-0.5"
      >
        {signedIn && hasJoined ? (
          <Chip selected={selection === null} onClick={() => onChange(null)}>
            All my hubs
          </Chip>
        ) : null}
        {hubs.map((hub) => {
          const selected = selection?.includes(hub.id) ?? false;
          const noPlaces = eventsOnly.has(hub.id);
          return (
            <Chip
              key={hub.id}
              selected={selected}
              onClick={() => onChange(toggleHubChip(selection, hub.id))}
              leading={
                <span
                  aria-hidden="true"
                  className={cn(
                    "-ml-1 flex size-6 items-center justify-center rounded-full text-[13px]",
                    categoryTone(hub.colorKey),
                  )}
                >
                  {hub.emoji}
                </span>
              }
            >
              {hub.name}
              {noPlaces ? (
                <span className="text-[12px] font-medium text-text-3">Events only</span>
              ) : null}
              {!hub.joined ? <span className="sr-only">(previewing)</span> : null}
            </Chip>
          );
        })}
        <Chip onClick={onExplore} leading={<Plus className="size-4" aria-hidden="true" />}>
          {signedIn && hasJoined ? "Explore" : "Pick hubs"}
        </Chip>
      </div>
      {generic && selectedOne ? (
        <p className="text-[13px] text-text-2">
          Showing general spots too: cafés, parks and libraries that suit {selectedOne.name}.
        </p>
      ) : null}
    </div>
  );
}
