import type { ReactNode } from "react";
import { Link } from "@tanstack/react-router";
import { ChevronRight, Info, Star } from "lucide-react";
import {
  bandLabel,
  bookingStatusLabel,
  formatPrice,
  ratingLabel,
  sessionTimeLabel,
  type BookingSummary,
  type CoachSearchRow,
} from "@ap/core/coaching";

import { Avatar } from "@/components/ui/avatar";
import { cn } from "@/lib/cn";
import { viewerZone } from "@/lib/datetime";

/** Section title used across the coaching screens (same type as the You tab's). */
export function SectionTitle({ children, id }: { children: ReactNode; id?: string }) {
  return (
    <h2 id={id} className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
      {children}
    </h2>
  );
}

/** A quiet note box (the requests-only note, safety notes). */
export function Note({ children, className }: { children: ReactNode; className?: string }) {
  return (
    <p
      className={cn(
        "flex gap-2 rounded-input bg-surface-2 px-4 py-3 text-[14px] text-text-2",
        className,
      )}
    >
      <Info className="mt-0.5 size-4 shrink-0 text-text-3" aria-hidden="true" />
      <span className="min-w-0">{children}</span>
    </p>
  );
}

export function Stars({ value, size = 14 }: { value: number; size?: number }) {
  return (
    <span className="inline-flex items-center gap-0.5" aria-label={`${value} out of 5 stars`}>
      {[1, 2, 3, 4, 5].map((n) => (
        <Star
          key={n}
          aria-hidden="true"
          style={{ width: size, height: size }}
          className={n <= Math.round(value) ? "fill-current text-text" : "text-border-strong"}
        />
      ))}
    </span>
  );
}

/** 1 to 5 stars as a radiogroup (the review form). */
export function StarInput({ value, onChange }: { value: number; onChange: (n: number) => void }) {
  return (
    <div role="radiogroup" aria-label="Rating" className="flex gap-1">
      {[1, 2, 3, 4, 5].map((n) => (
        <button
          key={n}
          type="button"
          role="radio"
          aria-checked={value === n}
          aria-label={`${n} star${n === 1 ? "" : "s"}`}
          onClick={() => onChange(n)}
          className="flex size-11 items-center justify-center rounded-full hover:bg-surface-2"
        >
          <Star
            aria-hidden="true"
            className={cn("size-7", n <= value ? "fill-current text-text" : "text-border-strong")}
          />
        </button>
      ))}
    </div>
  );
}

/** One coach in browse and in a hub's "Coaches in this hub". */
export function CoachCard({ coach }: { coach: CoachSearchRow }) {
  return (
    <Link
      to="/coaches/$handle"
      params={{ handle: coach.handle }}
      className="flex min-h-16 items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-2"
    >
      <Avatar src={coach.avatar_url} name={coach.first_name} size={48} />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[15px] font-semibold">{coach.first_name}</span>
        <span className="block truncate text-[14px] text-text-2">{coach.headline}</span>
        <span className="flex flex-wrap items-center gap-x-2 text-[13px] text-text-3">
          <span>{ratingLabel(coach.rating_avg, coach.rating_count)}</span>
          <span aria-hidden="true">·</span>
          <span>{bandLabel(coach.distance_band)}</span>
          {coach.area_label && coach.distance_band !== "online" ? (
            <span className="truncate">{coach.area_label}</span>
          ) : null}
        </span>
      </span>
      <span className="flex shrink-0 items-center gap-1 text-[14px] font-semibold">
        {coach.from_price_minor != null && coach.from_currency
          ? coach.from_price_minor === 0
            ? "Free"
            : `From ${formatPrice(coach.from_price_minor, coach.from_currency)}`
          : null}
        <ChevronRight className="size-4 text-text-3" aria-hidden="true" />
      </span>
    </Link>
  );
}

const STATUS_TONE: Record<string, string> = {
  requested: "text-text-2",
  confirmed: "text-going",
  completed: "text-text-2",
  cancelled: "text-danger",
  declined: "text-text-3",
  expired: "text-text-3",
  no_show: "text-danger",
};

/** A booking in the lists. */
export function BookingRow({ booking }: { booking: BookingSummary }) {
  const zone = viewerZone();
  return (
    <Link
      to="/bookings/$id"
      params={{ id: booking.id }}
      className="flex min-h-16 items-center gap-3 px-4 py-3 transition-colors hover:bg-surface-2"
    >
      <Avatar src={booking.other.avatar_url} name={booking.other.first_name} size={40} />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-[15px] font-semibold">{booking.title}</span>
        <span className="block truncate text-[13px] text-text-2">
          {booking.role === "coach" ? "With" : "Coach:"} {booking.other.first_name}
        </span>
        <span className="block text-[13px] text-text-2">
          {sessionTimeLabel(booking.starts_at, booking.ends_at, zone)}
        </span>
        <span className={cn("block text-[13px] font-semibold", STATUS_TONE[booking.status])}>
          {bookingStatusLabel(booking)}
        </span>
      </span>
      <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
    </Link>
  );
}

/** A divided card list. */
export function CardList({ children, label }: { children: ReactNode; label?: string }) {
  return (
    <ul
      aria-label={label}
      className="divide-y divide-border overflow-hidden rounded-card border border-border"
    >
      {children}
    </ul>
  );
}
