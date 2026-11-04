import { useId } from "react";

import { cn } from "@/lib/cn";
import { placeKindInfo, type MapLayer } from "@/lib/map";

import { PLACE_ICONS, PLAN_ICON, PLAN_IMPORTED_ICON, SHOW_ICON } from "./icons";

/**
 * The map's pin shapes, small, for the list rows and the layer chips, so a row and its pin look
 * alike: rounded square (place; a corner dot for a general spot, dashed for one waiting for
 * review), teardrop (plan; a feed icon and a double ring when imported), ticket (show and game),
 * hatched dashed square (approximate area). Shape plus icon, never colour alone.
 */

export function PlaceGlyph({
  kind,
  generic = false,
  pending = false,
}: {
  kind: string;
  generic?: boolean;
  pending?: boolean;
}) {
  const Icon = PLACE_ICONS[placeKindInfo(kind).icon];
  const isGeneric = generic && !pending;
  return (
    <span
      aria-hidden="true"
      className={cn(
        "relative flex size-9 shrink-0 items-center justify-center rounded-[10px] border-2 bg-surface",
        pending
          ? "border-dashed border-text text-text"
          : isGeneric
            ? "border-text-3 text-text-2"
            : "border-text text-text",
      )}
    >
      <Icon className="size-[18px]" strokeWidth={2.2} />
      {isGeneric ? (
        <span className="absolute -top-1 -right-1 size-2.5 rounded-full border-2 border-surface bg-text-3" />
      ) : null}
    </span>
  );
}

export function PlanGlyph({
  imported = false,
  small = false,
}: {
  imported?: boolean;
  small?: boolean;
}) {
  const size = small ? 16 : 30;
  return (
    <span
      aria-hidden="true"
      className="relative flex shrink-0 items-start justify-center"
      style={{ width: small ? 16 : 36, height: small ? 18 : 36 }}
    >
      <svg width={size} height={size * 1.25} viewBox="0 0 30 38" className="block">
        <path
          d="M15 36.5 L5.8 24.2 A13 13 0 1 1 24.2 24.2 Z"
          className={imported ? "fill-[#5b7a99]" : "fill-primary"}
          stroke="var(--color-surface)"
          strokeWidth="2"
        />
        {imported && !small ? (
          <circle cx="15" cy="15" r="9.5" fill="none" stroke="white" strokeWidth="1.25" />
        ) : null}
      </svg>
      {small ? null : imported ? (
        <PLAN_IMPORTED_ICON
          className="absolute top-[8.5px] size-[13px] text-white"
          strokeWidth={2.6}
        />
      ) : (
        <PLAN_ICON className="absolute top-[7px] size-4 text-on-primary" strokeWidth={2.4} />
      )}
    </span>
  );
}

export function ShowGlyph({ small = false }: { small?: boolean }) {
  return (
    <span
      aria-hidden="true"
      className="relative flex shrink-0 items-center justify-center"
      style={{ width: small ? 18 : 36, height: small ? 14 : 36 }}
    >
      <svg width={small ? 18 : 34} height={small ? 13 : 25} viewBox="0 0 38 28" className="block">
        <path
          d="M6 3 H32 A4 4 0 0 1 36 7 V9.5 A4.5 4.5 0 0 0 36 18.5 V21 A4 4 0 0 1 32 25 H6 A4 4 0 0 1 2 21 V18.5 A4.5 4.5 0 0 0 2 9.5 V7 A4 4 0 0 1 6 3 Z"
          className="fill-hub-violet"
          stroke="var(--color-surface)"
          strokeWidth="2"
        />
      </svg>
      {small ? null : <SHOW_ICON className="absolute size-[15px] text-white" strokeWidth={2.4} />}
    </span>
  );
}

export function CellGlyph() {
  const id = useId();
  return (
    <svg aria-hidden="true" width="36" height="36" viewBox="0 0 36 36" className="shrink-0">
      <defs>
        <pattern
          id={id}
          width="6"
          height="6"
          patternUnits="userSpaceOnUse"
          patternTransform="rotate(45)"
        >
          <line
            x1="0"
            y1="0"
            x2="0"
            y2="6"
            className="stroke-hub-violet"
            strokeWidth="2"
            strokeOpacity="0.5"
          />
        </pattern>
      </defs>
      <rect
        x="3"
        y="3"
        width="30"
        height="30"
        rx="4"
        fill={`url(#${id})`}
        className="stroke-hub-violet"
        strokeWidth="1.5"
        strokeDasharray="4 3"
      />
    </svg>
  );
}

/** The small shape in each layer chip. */
export function LayerGlyph({ layer }: { layer: MapLayer }) {
  if (layer === "plans") return <PlanGlyph small />;
  if (layer === "shows") return <ShowGlyph small />;
  return (
    <span aria-hidden="true" className="block size-3.5 rounded-[4px] border-2 border-current" />
  );
}
