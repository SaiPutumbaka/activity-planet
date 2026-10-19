"use client";

import { useTransition } from "react";
import {
  CalendarClock,
  Check,
  EllipsisVertical,
  Loader2,
  MapPin,
  Trash2,
  Users,
} from "lucide-react";
import { toast } from "sonner";

import { deleteEventAction, rsvpAction } from "@/actions/events";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Card,
  CardContent,
  CardFooter,
  CardHeader,
} from "@/components/ui/card";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { hubEmoji } from "@/lib/hubs";
import type { FeedEvent } from "@/types/events";

const TIME_FORMAT = new Intl.DateTimeFormat("en-US", {
  weekday: "short",
  month: "short",
  day: "numeric",
  hour: "numeric",
  minute: "2-digit",
});

export function EventCard({ event }: { event: FeedEvent }) {
  const [isPending, startTransition] = useTransition();

  function toggleRsvp() {
    startTransition(async () => {
      const result = await rsvpAction({
        eventId: event.id,
        attend: !event.joined,
      });
      if (result.status === "error") {
        toast.error(result.message);
      }
    });
  }

  function deleteEvent() {
    startTransition(async () => {
      const result = await deleteEventAction({ eventId: event.id });
      if (result.status === "error") {
        toast.error(result.message);
      } else {
        toast.success("Event deleted.");
      }
    });
  }

  return (
    <Card>
      <CardHeader className="flex-row items-start justify-between space-y-0 pb-3">
        <Badge variant="secondary" className="gap-1">
          <span aria-hidden>{hubEmoji(event.category)}</span>
          {event.category}
        </Badge>
        {event.isMine ? (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button
                variant="ghost"
                size="icon"
                className="-mr-2 -mt-2 h-8 w-8"
                aria-label="Event options"
              >
                <EllipsisVertical className="h-4 w-4" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem
                onClick={deleteEvent}
                className="text-destructive focus:text-destructive"
              >
                <Trash2 className="h-4 w-4" aria-hidden />
                Delete event
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        ) : null}
      </CardHeader>
      <CardContent className="space-y-3">
        <h3 className="text-lg font-semibold leading-tight">{event.title}</h3>
        {event.description ? (
          <p className="line-clamp-2 whitespace-pre-line text-sm text-muted-foreground">
            {event.description}
          </p>
        ) : null}
        <div className="space-y-1.5 text-sm text-muted-foreground">
          <p className="flex items-center gap-2">
            <CalendarClock className="h-4 w-4 shrink-0" aria-hidden />
            <time dateTime={event.eventTimestamp} suppressHydrationWarning>
              {TIME_FORMAT.format(new Date(event.eventTimestamp))}
            </time>
          </p>
          <p className="flex items-center gap-2">
            <MapPin className="h-4 w-4 shrink-0" aria-hidden />
            <span className="truncate">{event.location}</span>
          </p>
        </div>
      </CardContent>
      <CardFooter className="justify-between gap-3">
        <div className="min-w-0 text-sm text-muted-foreground">
          <p className="truncate">by @{event.creatorUsername}</p>
          <p className="flex items-center gap-1">
            <Users className="h-3.5 w-3.5" aria-hidden />
            {event.attendeeCount} going
          </p>
        </div>
        <Button
          onClick={toggleRsvp}
          disabled={isPending}
          variant={event.joined ? "secondary" : "default"}
          className="shrink-0"
        >
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          ) : event.joined ? (
            <Check className="h-4 w-4" aria-hidden />
          ) : null}
          {event.joined ? "Joined" : "Join"}
        </Button>
      </CardFooter>
    </Card>
  );
}
