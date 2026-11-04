import { useMemo, type ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronUp } from "lucide-react";

import { cn } from "@/lib/cn";
import { formatRelativeDay, formatTime } from "@/lib/datetime";
import {
  CELL_NOTE,
  cellLabel,
  countLine,
  distanceM,
  formatDistance,
  placeKindInfo,
  sortByDistance,
  type LngLat,
  type MapCell,
  type MapFeature,
  type MapView,
} from "@/lib/map";

import { MapAttribution } from "./attribution";
import { CellGlyph, PlaceGlyph, PlanGlyph, ShowGlyph } from "./glyphs";

export type PanelHeight = "peek" | "half" | "full";
const NEXT_HEIGHT: Record<PanelHeight, PanelHeight> = { peek: "half", half: "full", full: "peek" };

/**
 * The list (§9): the accessible alternative to the canvas, with every pin on the map in it,
 * sorted by distance from the map centre. A non-modal panel (not the <dialog> Sheet), so the map
 * stays usable behind it: peek, half and full heights from one handle button. In list view it is
 * the whole screen. The count line is aria-live, so a screen reader hears what a pan changed.
 */
export function ListPanel({
  view,
  origin,
  mode,
  height,
  onHeight,
  status,
  notices,
  timeZone,
  onSelectPlace,
  onSelectCell,
  onSelectEvent,
}: {
  view: MapView;
  origin: LngLat;
  /** "sheet" over the map, "screen" for the List view. */
  mode: "sheet" | "screen";
  height: PanelHeight;
  onHeight: (h: PanelHeight) => void;
  /** Replaces the count line while loading or on error. */
  status?: string;
  /** Empty and edge states, above the rows. */
  notices?: ReactNode;
  timeZone: string;
  onSelectPlace: (id: string) => void;
  onSelectCell: (key: string) => void;
  /**
   * Signed-out visitors: a plan or show row opens the map's read-only sheet instead of the event
   * page, which needs a session. Signed in, rows link straight to the event page.
   */
  onSelectEvent?: (id: string) => void;
}) {
  const places = useMemo(() => sortByDistance(view.places, origin), [view.places, origin]);
  const plans = useMemo(() => sortByDistance(view.plans, origin), [view.plans, origin]);
  const shows = useMemo(() => sortByDistance(view.shows, origin), [view.shows, origin]);
  const cells = useMemo(
    () =>
      sortByDistance(
        view.cells.map((c) => ({ ...c, ...c.center })),
        origin,
      ),
    [view.cells, origin],
  );
  const line = status ?? countLine(view);
  const sheet = mode === "sheet";

  return (
    <section
      aria-label="Places and plans in this area"
      className={cn(
        "flex min-h-0 flex-col bg-surface",
        sheet
          ? "absolute inset-x-0 bottom-0 z-10 rounded-t-card shadow-[var(--shadow-lift)] transition-[height] duration-200 ease-out-quart"
          : "h-full",
        sheet && height === "peek" && "h-[7.5rem]",
        sheet && height === "half" && "h-[48%]",
        sheet && height === "full" && "h-[calc(100%-0.5rem)]",
      )}
    >
      <div className="flex items-center gap-2 pt-1.5 pr-2 pl-4">
        <p aria-live="polite" className="min-w-0 flex-1 truncate py-2 text-[14px] font-semibold">
          {line}
        </p>
        {sheet ? (
          <button
            type="button"
            onClick={() => onHeight(NEXT_HEIGHT[height])}
            aria-expanded={height !== "peek"}
            aria-label={height === "full" ? "Shrink the list" : "Show more of the list"}
            className="flex size-11 shrink-0 items-center justify-center rounded-full text-text-2 hover:bg-surface-2"
          >
            <ChevronUp
              className={cn("size-5 transition-transform", height === "full" && "rotate-180")}
              aria-hidden="true"
            />
          </button>
        ) : null}
      </div>
      <div
        className={cn(
          "min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pb-4",
          sheet && height === "peek" && "overflow-hidden",
        )}
      >
        {notices}
        <Section title="Places" count={places.length}>
          {places.map((f) => (
            <PlaceRow key={f.id} f={f} origin={origin} onSelect={onSelectPlace} />
          ))}
        </Section>
        <Section title="Plans" count={plans.length + cells.length}>
          {plans.map((f) => (
            <EventRow
              key={f.id}
              f={f}
              origin={origin}
              timeZone={timeZone}
              onSelect={onSelectEvent}
            />
          ))}
          {cells.map((c) => (
            <CellRow key={c.key} cell={c} origin={origin} onSelect={onSelectCell} />
          ))}
        </Section>
        <Section title="Shows and games" count={shows.length}>
          {shows.map((f) => (
            <EventRow
              key={f.id}
              f={f}
              origin={origin}
              timeZone={timeZone}
              onSelect={onSelectEvent}
            />
          ))}
        </Section>
        <MapAttribution className="pt-4" geoapify={view.places.some((f) => f.geoapify)} />
      </div>
    </section>
  );
}

function Section({
  title,
  count,
  children,
}: {
  title: string;
  count: number;
  children: ReactNode;
}) {
  if (count === 0) return null;
  return (
    <section className="pt-3">
      <h3 className="pb-1 text-[13px] font-bold tracking-wide text-text-2 uppercase">
        {title} <span className="tabular">({count})</span>
      </h3>
      <ul className="flex flex-col">{children}</ul>
    </section>
  );
}

const rowClass =
  "flex min-h-14 w-full items-center gap-3 rounded-tile px-1 py-2 text-left hover:bg-surface-2 [content-visibility:auto] [contain-intrinsic-size:auto_56px]";

function Distance({ from, to }: { from: LngLat; to: LngLat }) {
  return (
    <span className="shrink-0 text-[13px] text-text-3 tabular">
      {formatDistance(distanceM(from, to))}
    </span>
  );
}

function PlaceRow({
  f,
  origin,
  onSelect,
}: {
  f: MapFeature;
  origin: LngLat;
  onSelect: (id: string) => void;
}) {
  const kind = placeKindInfo(f.type).label;
  return (
    <li>
      <button type="button" className={rowClass} onClick={() => onSelect(f.id)}>
        <PlaceGlyph kind={f.type} generic={f.generic} pending={f.pending} />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[15px] font-semibold">{f.name}</span>
          <span className="block truncate text-[13px] text-text-2">
            {kind}
            {f.generic ? " · General spot" : ""}
            {f.pending ? " · Waiting for review" : ""}
            {f.private && !f.pending ? " · Only you" : ""}
          </span>
        </span>
        <Distance from={origin} to={f} />
      </button>
    </li>
  );
}

function when(d: Date | null, timeZone: string): string {
  if (!d) return "";
  return `${formatRelativeDay(d, timeZone)} · ${formatTime(d, timeZone)}`;
}

function EventRow({
  f,
  origin,
  timeZone,
  onSelect,
}: {
  f: MapFeature;
  origin: LngLat;
  timeZone: string;
  onSelect?: (id: string) => void;
}) {
  const meta = [
    when(f.startsAt, timeZone),
    f.kind === "plan" && f.imported ? "Listed from a feed" : "",
    f.free ? "Free" : "",
    f.adultsOnly ? "21+" : "",
  ]
    .filter(Boolean)
    .join(" · ");
  const body = (
    <>
      {f.kind === "show" ? <ShowGlyph /> : <PlanGlyph imported={f.imported} />}
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[15px] font-semibold">{f.name}</span>
        {meta ? <span className="block truncate text-[13px] text-text-2">{meta}</span> : null}
      </span>
      <Distance from={origin} to={f} />
    </>
  );
  return (
    <li>
      {onSelect ? (
        <button type="button" className={rowClass} onClick={() => onSelect(f.id)}>
          {body}
        </button>
      ) : (
        <Link to="/events/$id" params={{ id: f.id }} className={rowClass}>
          {body}
        </Link>
      )}
    </li>
  );
}

function CellRow({
  cell,
  origin,
  onSelect,
}: {
  cell: MapCell;
  origin: LngLat;
  onSelect: (key: string) => void;
}) {
  return (
    <li>
      <button type="button" className={rowClass} onClick={() => onSelect(cell.key)}>
        <CellGlyph />
        <span className="min-w-0 flex-1">
          <span className="block truncate text-[15px] font-semibold">{cellLabel(cell.count)}</span>
          <span className="block truncate text-[13px] text-text-2">{CELL_NOTE}</span>
        </span>
        <span className="shrink-0 text-[13px] text-text-3 tabular">
          ~{formatDistance(distanceM(origin, cell.center))}
        </span>
      </button>
    </li>
  );
}
