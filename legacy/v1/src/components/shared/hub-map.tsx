"use client";

import L from "leaflet";
import "leaflet/dist/leaflet.css";
import { MapContainer, Marker, Popup, TileLayer } from "react-leaflet";

import type { Hub } from "@/types/database";

// Leaflet's default marker icon resolves its image URLs relative to the
// bundler's asset pipeline, which breaks under Next.js. Point it at the
// package's own CDN-hosted images instead — no local asset wiring needed.
type IconDefaultPrototype = { _getIconUrl?: unknown };
(L.Icon.Default.prototype as unknown as IconDefaultPrototype)._getIconUrl =
  undefined;
L.Icon.Default.mergeOptions({
  iconRetinaUrl:
    "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon-2x.png",
  iconUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-icon.png",
  shadowUrl: "https://unpkg.com/leaflet@1.9.4/dist/images/marker-shadow.png",
});

const YOU_ICON = L.divIcon({
  className: "",
  html:
    '<span style="display:block;width:14px;height:14px;border-radius:9999px;' +
    'background:hsl(var(--primary));border:2px solid white;' +
    'box-shadow:0 0 0 4px hsl(var(--primary) / 0.25)"></span>',
  iconSize: [14, 14],
});

// Geographic center of the contiguous U.S. — a reasonable default when
// neither the viewer nor any event has a known location yet.
const FALLBACK_CENTER: [number, number] = [39.8283, -98.5795];

const TIME_FORMAT = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

export interface HubMapEvent {
  id: string;
  title: string;
  eventTimestamp: string;
  attendeeCount: number;
  latitude: number;
  longitude: number;
}

interface HubMapProps {
  hub: Hub;
  events: HubMapEvent[];
  userLocation: { latitude: number; longitude: number } | null;
}

export function HubMap({ hub, events, userLocation }: HubMapProps) {
  const firstEvent = events[0];
  const center: [number, number] = userLocation
    ? [userLocation.latitude, userLocation.longitude]
    : firstEvent
      ? [firstEvent.latitude, firstEvent.longitude]
      : FALLBACK_CENTER;
  const zoom = userLocation || firstEvent ? 11 : 4;

  return (
    <div className="space-y-2">
      <div className="h-96 w-full overflow-hidden rounded-xl border">
        <MapContainer
          key={`${center[0]}-${center[1]}`}
          center={center}
          zoom={zoom}
          scrollWheelZoom={false}
          style={{ height: "100%", width: "100%" }}
        >
          <TileLayer
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors'
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
          />
          {userLocation ? (
            <Marker
              position={[userLocation.latitude, userLocation.longitude]}
              icon={YOU_ICON}
            >
              <Popup>You</Popup>
            </Marker>
          ) : null}
          {events.map((event) => (
            <Marker key={event.id} position={[event.latitude, event.longitude]}>
              <Popup>
                <p className="font-medium">{event.title}</p>
                <p className="text-xs text-muted-foreground">
                  {TIME_FORMAT.format(new Date(event.eventTimestamp))}
                </p>
                <p className="text-xs text-muted-foreground">
                  {event.attendeeCount} going
                </p>
              </Popup>
            </Marker>
          ))}
        </MapContainer>
      </div>
      <p className="text-xs text-muted-foreground">
        {userLocation
          ? `Showing ${hub} events near you.`
          : `Set your location in your profile to center this map on you. Showing every ${hub} event with a pinned location for now.`}
      </p>
    </div>
  );
}
