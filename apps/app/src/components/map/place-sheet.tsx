import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Clock, ExternalLink, Globe, MapPin, Navigation, Pencil } from "lucide-react";

import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { formatRelativeDay, formatTime } from "@/lib/datetime";
import {
  CELL_NOTE,
  cellLabel,
  detectPlatform,
  directionsUrl,
  isMapUnavailable,
  osmEditUrl,
  placeDetailQuery,
  placeKindInfo,
  sourceLine,
  type ChipHub,
  type MapCell,
  type MapFeature,
} from "@/lib/map";

import { PlaceGlyph, PlanGlyph, ShowGlyph } from "./glyphs";

/**
 * A link to an event page. The page lives under /_app and needs a session, so a signed-out
 * visitor goes to sign-in first and comes back to the event afterwards.
 */
function EventLink({
  id,
  signedIn,
  className,
  children,
}: {
  id: string;
  signedIn: boolean;
  className?: string;
  children: ReactNode;
}) {
  return signedIn ? (
    <Link to="/events/$id" params={{ id }} className={className}>
      {children}
    </Link>
  ) : (
    <Link to="/auth/sign-in" search={{ next: `/events/${id}` }} className={className}>
      {children}
    </Link>
  );
}

function platform() {
  if (typeof navigator === "undefined") return "other" as const;
  return detectPlatform(navigator.userAgent, navigator.maxTouchPoints, navigator.platform);
}

/**
 * A place's card (§9, the existing Sheet): name, kind, hubs, the address for public places only,
 * hours as text (no "Open now" yet), website, the §8 source line, directions in the device's own
 * maps app, and "Improve it on OpenStreetMap" for OSM places. Corrections, reports and "Start a
 * plan here" with the place prefilled come with slices 9 and 11.
 */
export function PlaceSheet({
  placeId,
  hubs,
  signedIn,
  timeZone,
  onClose,
}: {
  placeId: string | null;
  hubs: readonly ChipHub[];
  signedIn: boolean;
  timeZone: string;
  onClose: () => void;
}) {
  const detail = useQuery({ ...placeDetailQuery(placeId ?? ""), enabled: Boolean(placeId) });
  const d = detail.data;
  const hubList = d ? hubs.filter((h) => d.hubIds.includes(h.id)) : [];
  const firstJoined = hubList.find((h) => h.joined);

  return (
    <Sheet open={Boolean(placeId)} onClose={onClose} title={d?.name ?? "Place"}>
      {detail.isPending ? (
        <div className="flex flex-col gap-3 pt-2" aria-busy="true">
          <Skeleton className="h-5 w-40" />
          <Skeleton className="h-4 w-56" />
          <Skeleton className="h-11 w-full" />
        </div>
      ) : !d ? (
        <p className="pt-2 text-text-2">
          {detail.error && isMapUnavailable(detail.error)
            ? "Place details arrive with the map."
            : "This place isn't available any more."}
        </p>
      ) : (
        <div className="flex flex-col gap-4 pt-1">
          <div className="flex items-center gap-3">
            <PlaceGlyph kind={d.kind} generic={d.generic} />
            <div className="min-w-0">
              <p className="text-[15px] font-semibold">{placeKindInfo(d.kind).label}</p>
              <p className="text-[13px] text-text-2">
                {[d.generic ? "General spot" : "", d.adultsOnly ? "21+ at venue" : ""]
                  .filter(Boolean)
                  .join(" · ") || sourceLine(d)}
              </p>
            </div>
          </div>

          {hubList.length ? (
            <ul className="flex flex-wrap gap-1.5" aria-label="Hubs">
              {hubList.map((h) => (
                <li
                  key={h.id}
                  className="rounded-control bg-surface-2 px-2.5 py-1 text-[13px] font-semibold"
                >
                  <span aria-hidden="true">{h.emoji} </span>
                  {h.name}
                </li>
              ))}
            </ul>
          ) : null}

          <dl className="flex flex-col gap-2 text-[15px]">
            {d.address ? (
              <Detail icon={MapPin} label="Address">
                {d.address}
              </Detail>
            ) : null}
            {d.hours ? (
              <Detail icon={Clock} label="Hours">
                <span className="break-words">{d.hours}</span>
              </Detail>
            ) : null}
            {d.website ? (
              <Detail icon={Globe} label="Website">
                <a
                  href={d.website}
                  target="_blank"
                  rel="noopener noreferrer nofollow"
                  className="break-all text-link underline-offset-2 hover:underline"
                >
                  {d.website.replace(/^https?:\/\//, "").replace(/\/$/, "")}
                </a>
              </Detail>
            ) : null}
          </dl>

          <div className="flex flex-wrap gap-2">
            <a
              href={directionsUrl({ lng: d.lng, lat: d.lat, name: d.name }, platform())}
              target="_blank"
              rel="noopener noreferrer"
              className={buttonVariants({ variant: "primary", size: "md" })}
            >
              <Navigation className="size-[18px]" aria-hidden="true" />
              Directions
            </a>
            {signedIn && firstJoined ? (
              <Link
                to="/post"
                search={{ hub: firstJoined.slug }}
                className={buttonVariants({ variant: "secondary", size: "md" })}
              >
                Start a plan here
              </Link>
            ) : null}
          </div>
          <p className="text-[12px] text-text-3">
            Directions open in your phone's maps app. Your location isn't sent to us.
          </p>

          {d.plansHere.length ? (
            <section>
              <h3 className="pb-1 text-[13px] font-bold tracking-wide text-text-2 uppercase">
                Plans here
              </h3>
              <ul>
                {d.plansHere.map((p) => (
                  <li key={p.id}>
                    <EventLink
                      id={p.id}
                      signedIn={signedIn}
                      className="flex min-h-11 items-center justify-between gap-3 rounded-tile px-1 hover:bg-surface-2"
                    >
                      <span className="truncate font-semibold">{p.title}</span>
                      {p.startsAt ? (
                        <span className="shrink-0 text-[13px] text-text-2">
                          {formatRelativeDay(p.startsAt, timeZone)} ·{" "}
                          {formatTime(p.startsAt, timeZone)}
                        </span>
                      ) : null}
                    </EventLink>
                  </li>
                ))}
              </ul>
              {signedIn ? null : (
                <p className="pt-1 text-[13px] text-text-3">Sign in to see these plans.</p>
              )}
            </section>
          ) : null}

          <div className="flex flex-col gap-1 border-t border-border pt-3 text-[13px] text-text-2">
            <p>{sourceLine(d)}</p>
            {d.source === "osm" && d.osmRef ? (
              <a
                href={osmEditUrl(d.osmRef)}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1 text-link underline-offset-2 hover:underline"
              >
                <Pencil className="size-3.5" aria-hidden="true" />
                Improve it on OpenStreetMap
                <ExternalLink className="size-3.5" aria-hidden="true" />
              </a>
            ) : null}
          </div>
        </div>
      )}
    </Sheet>
  );
}

function Detail({
  icon: Icon,
  label,
  children,
}: {
  icon: typeof MapPin;
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-start gap-3">
      <dt className="pt-0.5 text-text-2">
        <Icon className="size-[18px]" aria-hidden="true" />
        <span className="sr-only">{label}</span>
      </dt>
      <dd className="min-w-0 flex-1">{children}</dd>
    </div>
  );
}

/**
 * Approved-only events in one 0.1-degree area (D-038): never a pin, never an address; each opens
 * its event page, where the host's approval rules apply.
 */
export function CellSheet({
  cell,
  signedIn,
  timeZone,
  onClose,
}: {
  cell: MapCell | null;
  signedIn: boolean;
  timeZone: string;
  onClose: () => void;
}) {
  return (
    <Sheet open={Boolean(cell)} onClose={onClose} title={cell ? cellLabel(cell.count) : ""}>
      {cell ? (
        <div className="flex flex-col gap-3 pt-1">
          <p className="text-[15px] text-text-2">
            {CELL_NOTE}. The shaded square is about 11 km across; the spot can be anywhere in it.
          </p>
          <ul>
            {cell.events.map((e) => (
              <li key={e.id}>
                <EventLink
                  id={e.id}
                  signedIn={signedIn}
                  className={cn(
                    "flex min-h-12 items-center justify-between gap-3 rounded-tile px-1 hover:bg-surface-2",
                  )}
                >
                  <span className="truncate font-semibold">{e.name}</span>
                  {e.startsAt ? (
                    <span className="shrink-0 text-[13px] text-text-2">
                      {formatRelativeDay(e.startsAt, timeZone)} · {formatTime(e.startsAt, timeZone)}
                    </span>
                  ) : null}
                </EventLink>
              </li>
            ))}
          </ul>
          {signedIn || cell.events.length === 0 ? null : (
            <p className="text-[13px] text-text-3">Sign in to see these plans and ask to join.</p>
          )}
          {cell.events.length < cell.count ? (
            <p className="text-[13px] text-text-3">
              {cell.count - cell.events.length} more you can't see from here.
            </p>
          ) : null}
          <Button variant="secondary" onClick={onClose}>
            Close
          </Button>
        </div>
      ) : null}
    </Sheet>
  );
}

/**
 * A plan or show for a signed-out visitor (founder answer: they see public plans): what the map
 * already knows about it, from the map data only, and a clear way to sign in for the rest. The
 * event page itself needs a session, so tapping a pin no longer bounces silently to sign-in.
 */
export function EventSheet({
  event,
  timeZone,
  onClose,
}: {
  event: MapFeature | null;
  timeZone: string;
  onClose: () => void;
}) {
  const kindLine = !event
    ? ""
    : event.kind === "show"
      ? "Show or game"
      : event.imported
        ? "Plan · listed from a feed"
        : "Plan";
  return (
    <Sheet open={Boolean(event)} onClose={onClose} title={event?.name ?? "Plan"}>
      {event ? (
        <div className="flex flex-col gap-4 pt-1">
          <div className="flex items-center gap-3">
            {event.kind === "show" ? <ShowGlyph /> : <PlanGlyph imported={event.imported} />}
            <div className="min-w-0">
              <p className="text-[15px] font-semibold">{kindLine}</p>
              {event.startsAt ? (
                <p className="text-[13px] text-text-2">
                  {formatRelativeDay(event.startsAt, timeZone)} ·{" "}
                  {formatTime(event.startsAt, timeZone)}
                </p>
              ) : null}
            </div>
          </div>
          <p className="text-[15px] text-text-2">
            Sign in to see this plan: who is going, the details and how to join.
          </p>
          <div className="flex flex-wrap gap-2">
            <Link
              to="/auth/sign-in"
              search={{ next: `/events/${event.id}` }}
              className={buttonVariants({ variant: "primary", size: "md" })}
            >
              Sign in to see this plan
            </Link>
            <a
              href={directionsUrl({ lng: event.lng, lat: event.lat, name: event.name }, platform())}
              target="_blank"
              rel="noopener noreferrer"
              className={buttonVariants({ variant: "secondary", size: "md" })}
            >
              <Navigation className="size-[18px]" aria-hidden="true" />
              Directions
            </a>
          </div>
          <p className="text-[12px] text-text-3">
            Directions open in your phone's maps app. Your location isn't sent to us.
          </p>
        </div>
      ) : null}
    </Sheet>
  );
}
