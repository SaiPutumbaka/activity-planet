import { Chip } from "@/components/ui/chip";
import {
  LAYER_LABELS,
  MAP_LAYERS,
  WHEN_OPTIONS,
  toggleLayer,
  type MapLayer,
  type MapWhen,
} from "@/lib/map";

import { LayerGlyph } from "./glyphs";

/**
 * Layer chips (Places, Plans, Shows and games; at least one stays on) and the time chips (Today,
 * This week, 30 days). Both filter locally or re-key one request; nothing here asks for location.
 */
export function LayerChips({
  layers,
  onLayers,
  when,
  onWhen,
}: {
  layers: readonly MapLayer[];
  onLayers: (next: MapLayer[]) => void;
  when: MapWhen;
  onWhen: (next: MapWhen) => void;
}) {
  return (
    <div className="no-scrollbar -mx-4 flex items-center gap-2 overflow-x-auto px-4 py-0.5">
      <div role="group" aria-label="Show on the map" className="flex gap-2">
        {MAP_LAYERS.map((layer) => (
          <Chip
            key={layer}
            selected={layers.includes(layer)}
            onClick={() => onLayers(toggleLayer(layers, layer))}
            leading={<LayerGlyph layer={layer} />}
            className="h-8 px-2.5 text-[13px]"
          >
            {LAYER_LABELS[layer]}
          </Chip>
        ))}
      </div>
      <span aria-hidden="true" className="h-5 w-px shrink-0 bg-border" />
      <div role="group" aria-label="When" className="flex gap-2">
        {WHEN_OPTIONS.map((o) => (
          <Chip
            key={o.value}
            selected={when === o.value}
            onClick={() => onWhen(o.value)}
            className="h-8 px-2.5 text-[13px]"
          >
            {o.label}
          </Chip>
        ))}
      </div>
    </div>
  );
}
