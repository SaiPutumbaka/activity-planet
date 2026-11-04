import {
  BookOpen,
  CalendarDays,
  Coffee,
  Dumbbell,
  Gamepad2,
  Goal,
  MapPin,
  Mountain,
  Music,
  Palette,
  Rss,
  Store,
  Ticket,
  Trees,
  Users,
  Volleyball,
  Waves,
  type LucideIcon,
} from "lucide-react";

import type { MapIconKey } from "@/lib/map";

/** One lucide icon per place kind group; the canvas draws the same ones into its pins. */
export const PLACE_ICONS: Record<MapIconKey, LucideIcon> = {
  court: Volleyball,
  field: Goal,
  store: Store,
  meet: Users,
  park: Trees,
  cafe: Coffee,
  library: BookOpen,
  gym: Dumbbell,
  studio: Palette,
  games: Gamepad2,
  music: Music,
  water: Waves,
  trail: Mountain,
  place: MapPin,
};

export const PLAN_ICON: LucideIcon = CalendarDays;
/** A plan listed from a feed (D-037): its own icon, not just another colour. */
export const PLAN_IMPORTED_ICON: LucideIcon = Rss;
export const SHOW_ICON: LucideIcon = Ticket;
