"use client";

import { useState } from "react";
import { Loader2, LocateFixed } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";
import { getBrowserLocation, reverseGeocode, type Coordinates } from "@/lib/geo";

interface UseMyLocationButtonProps {
  onLocated: (coords: Coordinates, place: string | null) => void;
  label?: string;
}

/**
 * Shared "use my current location" affordance: reads the browser's
 * Geolocation API (no API key needed) and best-effort reverse-geocodes the
 * coordinates to a human-readable place name via OpenStreetMap's free
 * Nominatim service. Used on the profile editor and the create-event form.
 */
export function UseMyLocationButton({
  onLocated,
  label = "Use my current location",
}: UseMyLocationButtonProps) {
  const [isLocating, setIsLocating] = useState(false);

  async function handleClick() {
    setIsLocating(true);
    try {
      const coords = await getBrowserLocation();
      const place = await reverseGeocode(coords);
      onLocated(coords, place);
    } catch (error) {
      toast.error(
        error instanceof Error ? error.message : "Could not read your location.",
      );
    } finally {
      setIsLocating(false);
    }
  }

  return (
    <Button
      type="button"
      variant="outline"
      size="sm"
      onClick={handleClick}
      disabled={isLocating}
    >
      {isLocating ? (
        <Loader2 className="h-3.5 w-3.5 animate-spin" aria-hidden />
      ) : (
        <LocateFixed className="h-3.5 w-3.5" aria-hidden />
      )}
      {label}
    </Button>
  );
}
