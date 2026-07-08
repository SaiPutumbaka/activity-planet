"use client";

import dynamic from "next/dynamic";

import type { HubMapEvent } from "@/components/shared/hub-map";
import type { Hub } from "@/types/database";

// Leaflet touches `window` at import time, so it can only ever run in the
// browser — ssr: false requires this indirection through a Client Component
// (next/dynamic's ssr option isn't allowed directly inside a Server Component).
const HubMap = dynamic(
  () => import("@/components/shared/hub-map").then((mod) => mod.HubMap),
  {
    ssr: false,
    loading: () => (
      <div className="flex h-96 w-full items-center justify-center rounded-xl border text-sm text-muted-foreground">
        Loading map…
      </div>
    ),
  },
);

interface HubMapLoaderProps {
  hub: Hub;
  events: HubMapEvent[];
  userLocation: { latitude: number; longitude: number } | null;
}

export function HubMapLoader(props: HubMapLoaderProps) {
  return <HubMap {...props} />;
}
