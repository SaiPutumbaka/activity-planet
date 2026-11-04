import { useState } from "react";
import { LocateFixed, MapPin } from "lucide-react";
import { toast } from "sonner";
import { RADIUS_OPTIONS_KM } from "@ap/core/feed";

import { Button } from "@/components/ui/button";
import { SegmentedControl } from "@/components/ui/segmented";
import { Sheet } from "@/components/ui/sheet";
import type { FeedOriginController } from "@/lib/location";

import { HomePicker } from "./home-picker";
import { LocationHowToSheet } from "./location-how-to";
import { useSaveHome } from "./use-save-home";

const RADIUS_OPTIONS = RADIUS_OPTIONS_KM.map((km) => ({
  value: String(km),
  label: `${km} km`,
}));

/**
 * Change where the feed is centred: the home location (anywhere: your rough position or a searched
 * city, saved with set_home_location, or a named area), the radius, and (on Home only) this
 * visit's device location, asked for only when the button is tapped and never saved.
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
  const save = useSaveHome(userId);
  const usingDevice = origin.point !== null;
  const [changing, setChanging] = useState(false);
  const hasHome = origin.homeLabel !== null || origin.homePoint !== null;
  const homeText = origin.homeLabel ?? (origin.homePoint ? "Your location (about 1 km)" : null);

  async function onLocate() {
    const result = await origin.locate();
    if (result === "granted") {
      toast.success("Showing plans near you.");
      onClose();
    } else if (result === "unavailable") {
      toast.error("Couldn't find your location. Search for your city instead.");
    }
  }

  function close() {
    setChanging(false);
    onClose();
  }

  return (
    <>
      <Sheet
        open={open}
        onClose={close}
        title="Where to look"
        footer={
          <Button variant="secondary" size="lg" block onClick={close}>
            Done
          </Button>
        }
      >
        <div className="flex flex-col gap-6 pt-1">
          {showDevice ? (
            <section className="flex flex-col gap-2">
              <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
                Right now
              </h3>
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
                  ? "Location is turned off for this site. You can allow it in your browser settings, or set your home below."
                  : "Only a rough spot (about 1 km), for this visit. It isn't saved."}
              </p>
            </section>
          ) : null}

          <section className="flex flex-col gap-2">
            <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              Home location
            </h3>
            <div className="flex items-center gap-3 rounded-input border border-border px-4 py-3">
              <MapPin className="size-5 shrink-0 text-text-2" aria-hidden="true" />
              <p className="min-w-0 flex-1 truncate text-[15px] font-semibold">
                {homeText ?? "Not set yet"}
              </p>
              {!changing ? (
                <Button variant="ghost" onClick={() => setChanging(true)}>
                  {hasHome ? "Change" : "Set"}
                </Button>
              ) : null}
            </div>
            {changing ? (
              <HomePicker
                selectedKey={null}
                busy={save.isPending}
                autoFocus
                locateLabel={showDevice ? "Set home to my location" : "Use my location"}
                onPick={(choice) => {
                  save.mutate(
                    { type: "place", choice, radiusKm },
                    {
                      onSuccess: () => {
                        origin.clearDevicePoint();
                        setChanging(false);
                      },
                    },
                  );
                }}
              />
            ) : (
              <p className="text-[13px] text-text-2">
                Home shows plans around here first. Not shown on your profile.
              </p>
            )}
          </section>

          <section className="flex flex-col gap-2">
            <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
              Distance
            </h3>
            <SegmentedControl
              value={String(radiusKm)}
              onChange={(v) => save.mutate({ type: "radius", radiusKm: Number(v) })}
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
