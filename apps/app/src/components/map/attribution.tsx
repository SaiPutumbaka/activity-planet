import { cn } from "@/lib/cn";

/**
 * ODbL and tile attribution (§8, D-038): "© OpenStreetMap contributors" linking to the copyright
 * page, plus OpenMapTiles and OpenFreeMap. Always visible, never behind a tap (OSMF attribution
 * guideline), on the map and under the list alike, since the places themselves are OSM data.
 */
export function MapAttribution({ className }: { className?: string }) {
  const link = "underline decoration-text-3/50 underline-offset-2 hover:text-text";
  return (
    <p className={cn("text-[11px] leading-[14px] text-text-2", className)}>
      <a
        href="https://www.openstreetmap.org/copyright"
        target="_blank"
        rel="noopener noreferrer"
        className={link}
      >
        © OpenStreetMap contributors
      </a>
      {" · "}
      <a
        href="https://openmaptiles.org/"
        target="_blank"
        rel="noopener noreferrer"
        className={link}
      >
        OpenMapTiles
      </a>
      {" · "}
      <a href="https://openfreemap.org/" target="_blank" rel="noopener noreferrer" className={link}>
        OpenFreeMap
      </a>
    </p>
  );
}
