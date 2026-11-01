import { LocateFixed, MapPin } from "lucide-react";
import { toast } from "sonner";
import { RADIUS_OPTIONS_KM } from "@ap/core/feed";

import { Button } from "@/components/ui/button";
import { Chip } from "@/components/ui/chip";
import { SegmentedControl } from "@/components/ui/segmented";
import { Sheet } from "@/components/ui/sheet";
import type { FeedOriginController } from "@/lib/location";

import { useSaveHomeArea } from "./use-save-home-area";

const RADIUS_OPTIONS = RADIUS_OPTIONS_KM.map((km) => ({
  value: String(km),
  label: `${km} km`,
}));

/**
 * Change where the feed is centred: a home area (Atlanta or a neighborhood), the radius, and
 * (on Home only) the optional device location, asked for only when the button is tapped.
 */
export function LocationSheet({
  open,
  onClose,
  userId,
  origin,
  radiusKm,
  showDevice = true,
}: {
  open: boolean;
  onClose: () => void;
  userId: string;
  origin: FeedOriginController;
  radiusKm: number;
  showDevice?: boolean;
}) {
  const save = useSaveHomeArea(userId);
  const usingDevice = origin.point !== null;
  const homeAreaId = origin.homeArea?.id ?? origin.defaultArea?.id ?? null;

  async function onLocate() {
    const result = await origin.locate();
    if (result === "granted") {
      toast.success("Showing plans near you.");
      onClose();
    } else if (result === "unavailable") {
      toast.error("Couldn't find your location. Pick an area instead.");
    }
  }

  return (
    <>
      <Sheet
        open={open}
        onClose={onClose}
        title="Where to look"
        footer={
          <Button variant="secondary" size="lg" block onClick={onClose}>
            Done
          </Button>
        }
      >
        <div className="flex flex-col gap-6 pt-1">
          {showDevice ? (
            <section className="flex flex-col gap-2">
              {usingDevice ? (
                <div className="flex items-center gap-3 rounded-input border border-border bg-surface-2 px-4 py-3">
                  <LocateFixed className="size-5 shrink-0 text-text-2" aria-hidden="true" />
                  <p className="min-w-0 flex-1 text-[15px] font-semibold">Using your location</p>
                  <Button variant="ghost" onClick={origin.clearDevicePoint}>
                    Stop
                  </Button>
                </div>
              ) : (
                <Button
                  variant="outline"
                  block
                  loading={origin.locating}
                  onClick={() => void onLocate()}
                >
                  <LocateFixed className="size-5" aria-hidden="true" />
                  Use my location
                </Button>
              )}
              <p className="text-[13px] text-text-2">
                {origin.denied && !usingDevice
                  ? "Location is turned off for this site. You can allow it in your browser settings, or pick an area below."
                  : "Only a rough spot (about 1 km), for this visit. It isn't saved."}
              </p>
            </section>
          ) : null}

          <section className="flex flex-col gap-2">
            <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              Home area
            </h3>
            <div className="flex flex-wrap gap-2">
              {origin.areas.map((a) => (
                <Chip
                  key={a.id}
                  selected={(!showDevice || !usingDevice) && a.id === origin.homeArea?.id}
                  leading={a.kind === "city" ? <MapPin className="size-4" /> : undefined}
                  disabled={save.isPending}
                  onClick={() => {
                    origin.clearDevicePoint();
                    if (a.id !== origin.homeArea?.id) save.mutate({ areaId: a.id });
                  }}
                >
                  {a.name}
                </Chip>
              ))}
            </div>
          </section>

          <section className="flex flex-col gap-2">
            <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              Distance
            </h3>
            <SegmentedControl
              value={String(radiusKm)}
              onChange={(v) => {
                if (homeAreaId) save.mutate({ areaId: homeAreaId, radiusKm: Number(v) });
              }}
              options={RADIUS_OPTIONS}
              label="Distance"
            />
            <p className="text-[13px] text-text-2">
              When there isn't much close by, Home looks a little further out.
            </p>
          </section>
        </div>
      </Sheet>
      <LocationHowToSheet open={origin.howToOpen} onClose={origin.closeHowTo} />
    </>
  );
}

/** Shown once after an iOS denial: the app can't re-ask, so it says where the switch is. */
export function LocationHowToSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="Location is off"
      footer={
        <Button variant="secondary" size="lg" block onClick={onClose}>
          Got it
        </Button>
      }
    >
      <ol className="flex list-decimal flex-col gap-2 pt-1 pl-5 text-[15px] text-text-2">
        <li>Open Settings, then Privacy &amp; Security, then Location Services.</li>
        <li>Turn Location Services on, then pick your browser (Safari Websites for Safari).</li>
        <li>Choose "While Using the App", come back and tap Use my location again.</li>
      </ol>
      <p className="pt-3 text-[13px] text-text-3">
        Or skip it: picking an area works just as well.
      </p>
    </Sheet>
  );
}
