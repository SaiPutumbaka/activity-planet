import { useState } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  Bell,
  CalendarClock,
  CalendarX,
  CircleCheck,
  Megaphone,
  MessageCircle,
  Settings,
  ShieldAlert,
  ShieldCheck,
  Sparkles,
  UserPlus,
  type LucideIcon,
} from "lucide-react";
import { toast } from "sonner";

import { MorningAfterSheet } from "@/components/events/morning-after-sheet";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import {
  POLL_MS,
  groupNotifications,
  inboxQuery,
  markNotificationsRead,
  notificationCopy,
  notificationKeys,
  notificationLink,
  opensAttendanceSheet,
  shortAgo,
  useNotificationsLive,
  type InboxItem,
  type NotificationKind,
} from "@/lib/notifications";

const appRoute = getRouteApi("/_app");

/**
 * Inbox (PLAN.md 4.9): the viewer's notifications in Today / Earlier. Tapping a row marks it
 * read and opens the plan, chapter or hub it is about; a "Did you go?" row (checkin_prompt)
 * opens the morning-after sheet while the plan's 7-day window is open. Live over Realtime, polled every minute
 * when that is down.
 */
export const Route = createFileRoute("/_app/inbox")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(inboxQuery(session.user.id));
  },
  component: InboxPage,
});

const ICONS: Record<NotificationKind, LucideIcon> = {
  rsvp_confirmed: CircleCheck,
  attendee_joined: UserPlus,
  waitlist_promoted: CircleCheck,
  rsvp_approved: CircleCheck,
  event_reminder_day: CalendarClock,
  event_reminder_2h: CalendarClock,
  event_cancelled: CalendarX,
  event_updated: CalendarClock,
  checkin_prompt: CircleCheck,
  hub_new_event: Sparkles,
  broadcast: Megaphone,
  chapter_claim_update: ShieldCheck,
  blocked_attendee: ShieldAlert,
  // Chat notices are left out of the inbox query (migration 58); listed for the type.
  message: MessageCircle,
  message_request: MessageCircle,
  // Coaching (migration 60); copy and links in lib/notifications.ts.
  booking_requested: CalendarClock,
  booking_confirmed: CircleCheck,
  booking_declined: CalendarX,
  booking_cancelled: CalendarX,
  booking_payment_due: CalendarClock,
  booking_reminder_day: CalendarClock,
  booking_reminder_2h: CalendarClock,
  booking_review_prompt: Sparkles,
  booking_no_show: ShieldAlert,
  review_received: Sparkles,
  review_reply: MessageCircle,
  coach_payout_action: ShieldCheck,
  // Collector health (migration 63): in-app only, moderators only.
  collector_alert: ShieldAlert,
  // Moderator alerts (migration 77).
  report_new: ShieldAlert,
  takedown_new: ShieldAlert,
  moderation_due: ShieldAlert,
  ops_alert: ShieldAlert,
};

function InboxPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const [attendance, setAttendance] = useState<{ eventId: string; title: string } | null>(null);
  const live = useNotificationsLive(userId);
  const inbox = useQuery({
    ...inboxQuery(userId),
    refetchInterval: live ? false : POLL_MS,
    refetchIntervalInBackground: false,
  });

  const refresh = () => queryClient.invalidateQueries({ queryKey: notificationKeys.all });

  const markAll = useMutation({
    mutationFn: () => markNotificationsRead(),
    onSuccess: () => void refresh(),
    onError: () => toast.error("Couldn't mark them read. Try again."),
  });

  const markOne = useMutation({
    mutationFn: (id: string) => markNotificationsRead([id]),
    onSuccess: () => void refresh(),
  });

  const items = inbox.data ?? [];
  const hasUnread = items.some((n) => !n.read_at);
  const now = new Date();
  const groups = groupNotifications(items, now);

  return (
    <>
      <TopBar
        title="Inbox"
        back
        actions={
          <>
            {hasUnread ? (
              <Button
                variant="ghost"
                size="sm"
                loading={markAll.isPending}
                onClick={() => markAll.mutate()}
              >
                Mark all read
              </Button>
            ) : null}
            <Link
              to="/you/notifications"
              aria-label="Notification settings"
              className={cn(
                buttonVariants({ variant: "secondary", size: "icon-sm" }),
                "rounded-full",
              )}
            >
              <Settings className="size-5" aria-hidden="true" />
            </Link>
          </>
        }
      />
      <main className="flex flex-col gap-5 pb-8 pt-2 safe-px">
        {inbox.isPending ? (
          <div className="flex flex-col gap-2" aria-busy="true">
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-16 rounded-card" />
          </div>
        ) : inbox.isError ? (
          <div className="flex flex-col gap-3">
            <FormError>Couldn't load your inbox. Check your connection and try again.</FormError>
            <Button variant="secondary" onClick={() => void inbox.refetch()}>
              Try again
            </Button>
          </div>
        ) : groups.length === 0 ? (
          <EmptyState
            icon={Bell}
            title="Nothing here yet"
            body="When someone joins your plan, a plan you're going to changes, or it's about to start, you'll see it here."
            action={
              <Link to="/" className={buttonVariants({ variant: "secondary" })}>
                Find a plan
              </Link>
            }
          />
        ) : (
          groups.map((g) => (
            <section key={g.key} className="flex flex-col gap-2" aria-label={g.title}>
              <h2 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
                {g.title}
              </h2>
              <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
                {g.items.map((n) => (
                  <InboxRow
                    key={n.id}
                    item={n}
                    now={now}
                    onOpen={() => {
                      if (!n.read_at) markOne.mutate(n.id);
                    }}
                    onAttendance={attendanceOpener(n, now, setAttendance)}
                  />
                ))}
              </ul>
            </section>
          ))
        )}
      </main>
      {attendance ? (
        <MorningAfterSheet
          open
          onClose={() => setAttendance(null)}
          eventId={attendance.eventId}
          title={attendance.title}
          userId={userId}
        />
      ) : null}
    </>
  );
}

function attendanceOpener(
  item: InboxItem,
  now: Date,
  open: (target: { eventId: string; title: string }) => void,
): (() => void) | undefined {
  const eventId = item.event_id;
  if (!eventId || !opensAttendanceSheet(item, now)) return undefined;
  return () => open({ eventId, title: item.payload.title ?? "Your plan" });
}

function InboxRow({
  item,
  now,
  onOpen,
  onAttendance,
}: {
  item: InboxItem;
  now: Date;
  onOpen: () => void;
  /** Set for a checkin_prompt in its window: the row opens the morning-after sheet. */
  onAttendance?: () => void;
}) {
  const copy = notificationCopy(item, now);
  const link = notificationLink(item);
  const Icon = ICONS[item.kind] ?? Bell;
  const unread = !item.read_at;

  const content = (
    <>
      <span
        aria-hidden="true"
        className="mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-full bg-surface-2 text-text-2"
      >
        <Icon className="size-[18px]" />
      </span>
      <span className="min-w-0 flex-1">
        <span className={cn("block text-[15px]", unread ? "font-semibold" : "font-medium")}>
          {copy.title}
        </span>
        {copy.body ? (
          <span className="line-clamp-2 block text-[13px] text-text-2">{copy.body}</span>
        ) : null}
      </span>
      <span className="flex shrink-0 flex-col items-end gap-1.5 pt-0.5">
        <span className="text-[12px] text-text-3 tabular">{shortAgo(item.created_at, now)}</span>
        {unread ? (
          <span className="size-2 rounded-full bg-primary" aria-label="Unread" role="img" />
        ) : null}
      </span>
    </>
  );

  const className = cn(
    "flex min-h-14 w-full items-start gap-3 px-4 py-3 text-left transition-colors hover:bg-surface-2",
    unread && "bg-primary-tint/40",
  );

  return (
    <li>
      {onAttendance ? (
        <button
          type="button"
          onClick={() => {
            onOpen();
            onAttendance();
          }}
          className={className}
        >
          {content}
        </button>
      ) : link ? (
        <Link {...link} onClick={onOpen} className={className}>
          {content}
        </Link>
      ) : (
        <button type="button" onClick={onOpen} className={className}>
          {content}
        </button>
      )}
    </li>
  );
}
