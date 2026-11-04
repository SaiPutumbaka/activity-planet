import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";

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
        Or skip it: searching for your city works just as well.
      </p>
    </Sheet>
  );
}
