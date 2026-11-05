import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { CalendarClock, ChevronRight } from "lucide-react";
import { bookingStatusLabel, dayIn, timeIn } from "@ap/core/coaching";

import { bookingWithQuery } from "@/lib/coaching";
import { viewerZone } from "@/lib/datetime";

/**
 * The DM header's next booking with the other person (design section 6, my_bookings_with):
 * "Tennis, one hour · Sat, Nov 7 10:00 AM". Nothing when there is none.
 */
export function NextBookingBanner({ userId }: { userId: string }) {
  const next = useQuery(bookingWithQuery(userId));
  const b = next.data;
  if (!b) return null;
  const zone = viewerZone();
  return (
    <Link
      to="/bookings/$id"
      params={{ id: b.id }}
      className="mx-3 mt-1 flex shrink-0 items-center gap-2 rounded-input bg-surface-2 px-3 py-2 text-[13px]"
    >
      <CalendarClock className="size-4 shrink-0 text-text-3" aria-hidden="true" />
      <span className="min-w-0 flex-1 truncate">
        <span className="font-semibold">{b.title}</span> · {dayIn(b.starts_at, zone)}{" "}
        {timeIn(b.starts_at, zone)} · {bookingStatusLabel(b)}
      </span>
      <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
    </Link>
  );
}
