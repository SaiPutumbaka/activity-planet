import { useState, type ReactNode } from "react";
import { Link, createFileRoute } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, ExternalLink, MapPin, MessageCircle, ShieldCheck } from "lucide-react";
import { toast } from "sonner";
import {
  PAYMENT_STATE_LABELS,
  bookingStatusLabel,
  bookingTimeline,
  coachingErrorMessage,
  formatPrice,
  requestsOnlyNote,
  sessionTimeLabel,
  type BookingDetail,
} from "@ap/core/coaching";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { Note, SectionTitle, StarInput, Stars } from "@/components/coaching/parts";
import { ReportSheet } from "@/components/safety/report-form";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Field } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  bookingQuery,
  coaching,
  coachingKeys,
  refundPolicyUrl,
  useCoachingConfig,
} from "@/lib/coaching";
import { viewerZone } from "@/lib/datetime";
import { SITE_URL } from "@/lib/site";

/**
 * One booking for either party (design sections 3.6, 3.7 and 15): what, when (the viewer's zone,
 * the coach's beside it), the state with every timestamp, the meeting place or call link once
 * confirmed, and the actions get_booking's can_* flags allow. Cancel shows the refund the
 * policy gives now. Pay appears only with payments on and the booking due.
 */
export const Route = createFileRoute("/_app/bookings_/$id")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(bookingQuery(params.id));
  },
  component: BookingPage,
});

function BookingPage() {
  const { id } = Route.useParams();
  const booking = useQuery(bookingQuery(id));
  return (
    <>
      <TopBar title="Booking" back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {booking.isPending ? (
          <div className="flex flex-col gap-3 pt-2" aria-busy="true">
            <Skeleton className="h-24" />
            <Skeleton className="h-16" />
          </div>
        ) : booking.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="This booking isn't available"
            body={coachingErrorMessage(booking.error)}
            action={
              <Link to="/bookings" className={buttonVariants({ variant: "secondary" })}>
                My bookings
              </Link>
            }
          />
        ) : (
          <BookingContent b={booking.data} />
        )}
      </main>
    </>
  );
}

type Confirmable = "decline" | "cancel" | "no_show" | "coach_no_show" | null;

function BookingContent({ b }: { b: BookingDetail }) {
  const queryClient = useQueryClient();
  const config = useCoachingConfig();
  const zone = viewerZone();
  const openChat = useOpenChat();
  const [asking, setAsking] = useState<Confirmable>(null);
  const [reportOpen, setReportOpen] = useState(false);
  const [meetingOpen, setMeetingOpen] = useState(false);
  const [contestOpen, setContestOpen] = useState(false);
  const coachName = b.role === "client" ? b.other.first_name : "you";

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
  };
  const act = useMutation({
    mutationFn: async (what: string) => {
      switch (what) {
        case "confirm":
          return coaching.confirm(b.id);
        case "decline":
          return coaching.decline(b.id);
        case "cancel":
          return coaching.cancel(b.id);
        case "complete":
          return coaching.complete(b.id);
        case "no_show":
          return coaching.markNoShow(b.id);
        case "coach_no_show":
          return coaching.reportCoachNoShow(b.id);
        case "pay":
          return coaching.checkout(b.id);
      }
      return null;
    },
    onSuccess: (r, what) => {
      setAsking(null);
      refresh();
      if (what === "pay") {
        const url = (r as { url?: string } | null)?.url;
        if (url) window.location.assign(url);
        return;
      }
      const done: Record<string, string> = {
        confirm: "Confirmed. It's on both your schedules.",
        decline: "Request declined.",
        cancel: "Booking cancelled.",
        complete: "Marked as done.",
        no_show: "Marked as missed.",
        coach_no_show: "Reported. The coach can contest it within 48 hours.",
      };
      toast.success(done[what] ?? "Done.");
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  const priceText = formatPrice(b.price_minor, b.currency);
  const offPlatform = b.payment_mode === "off_platform";
  const refundNow = b.refund_if_cancelled_now ?? 0;

  return (
    <>
      <section className="flex flex-col gap-1 pt-2">
        <p className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
          {bookingStatusLabel(b)}
        </p>
        <h2 className="text-[22px] font-extrabold tracking-tight">{b.title}</h2>
        <p className="text-[15px] text-text-2">
          {sessionTimeLabel(
            b.starts_at,
            b.ends_at,
            zone,
            b.coach_timezone,
            b.role === "client" ? b.other.first_name : "you",
          )}
        </p>
        <p className="text-[15px] text-text-2">
          {b.delivery === "online" ? "Online" : "In person"}
          {b.format === "group" ? " · Group" : " · One-on-one"}
        </p>
      </section>

      <section className="flex items-center gap-3">
        <Avatar src={b.other.avatar_url} name={b.other.first_name} size={44} />
        <div className="min-w-0 flex-1">
          <p className="text-[13px] text-text-3">{b.role === "client" ? "Coach" : "Client"}</p>
          {b.role === "client" && b.other.handle ? (
            <Link
              to="/coaches/$handle"
              params={{ handle: b.other.handle }}
              className="text-[16px] font-semibold underline-offset-2 hover:underline"
            >
              {b.other.first_name}
            </Link>
          ) : (
            <p className="text-[16px] font-semibold">{b.other.first_name}</p>
          )}
        </div>
        {b.can_message && b.other.user_id ? (
          <Button
            variant="secondary"
            size="sm"
            leading={<MessageCircle className="size-4" aria-hidden="true" />}
            loading={openChat.isPending}
            onClick={() => openChat.mutate({ kind: "dm", userId: b.other.user_id! })}
          >
            Message
          </Button>
        ) : null}
      </section>

      <section className="flex flex-col gap-2">
        <SectionTitle>Price</SectionTitle>
        <p className="text-[18px] font-bold">{priceText}</p>
        {offPlatform ? (
          <Note>{requestsOnlyNote(b.role === "client" ? b.other.first_name : "your client")}</Note>
        ) : b.payment_mode === "stripe" ? (
          <p className="text-[14px] text-text-2">
            {PAYMENT_STATE_LABELS[b.payment_state]}
            {b.refunded_minor > 0 ? ` · ${formatPrice(b.refunded_minor, b.currency)} refunded` : ""}
          </p>
        ) : null}
        {config.paymentsEnabled && b.can_pay ? (
          <Button
            size="lg"
            block
            loading={act.isPending && act.variables === "pay"}
            onClick={() => act.mutate("pay")}
          >
            Pay {priceText}
          </Button>
        ) : null}
      </section>

      {b.status === "confirmed" ? (
        <section className="flex flex-col gap-2">
          <SectionTitle>{b.delivery === "online" ? "How to join" : "Where to meet"}</SectionTitle>
          {b.meeting_note ? (
            <p className="flex gap-2 whitespace-pre-line text-[15px]">
              <MapPin className="mt-0.5 size-4 shrink-0 text-text-3" aria-hidden="true" />
              {b.meeting_note}
            </p>
          ) : (
            <p className="text-[15px] text-text-2">
              {b.role === "coach"
                ? "Add where to meet or a call link."
                : `${coachName} hasn't added details yet. Message them to agree.`}
            </p>
          )}
          {b.online_link ? (
            <a
              href={b.online_link}
              target="_blank"
              rel="noreferrer noopener"
              className="inline-flex items-center gap-1 text-[15px] font-semibold text-link underline-offset-2 hover:underline"
            >
              Open the call link <ExternalLink className="size-4" aria-hidden="true" />
            </a>
          ) : null}
          {b.can_set_meeting ? (
            <Button
              variant="secondary"
              size="sm"
              className="self-start"
              onClick={() => setMeetingOpen(true)}
            >
              Edit details
            </Button>
          ) : null}
        </section>
      ) : null}

      {b.client_note ? (
        <section className="flex flex-col gap-1">
          <SectionTitle>{b.role === "coach" ? "Note from your client" : "Your note"}</SectionTitle>
          <p className="whitespace-pre-line text-[15px] text-text-2">{b.client_note}</p>
        </section>
      ) : null}

      <div className="flex flex-col gap-2">
        {b.can_confirm ? (
          <Button
            size="lg"
            block
            loading={act.isPending && act.variables === "confirm"}
            onClick={() => act.mutate("confirm")}
          >
            Confirm
          </Button>
        ) : null}
        {b.can_decline ? (
          <Button variant="secondary" block onClick={() => setAsking("decline")}>
            Decline
          </Button>
        ) : null}
        {b.can_complete ? (
          <Button
            size="lg"
            block
            loading={act.isPending && act.variables === "complete"}
            onClick={() => act.mutate("complete")}
          >
            Mark as done
          </Button>
        ) : null}
        {b.can_mark_no_show ? (
          <Button variant="secondary" block onClick={() => setAsking("no_show")}>
            Client didn&apos;t come
          </Button>
        ) : null}
        {b.can_report_no_show ? (
          <Button variant="secondary" block onClick={() => setAsking("coach_no_show")}>
            Coach didn&apos;t come
          </Button>
        ) : null}
        {b.can_contest ? (
          <Button variant="secondary" block onClick={() => setContestOpen(true)}>
            I was there: contest this
          </Button>
        ) : null}
        {b.can_cancel && !(b.role === "coach" && b.status === "requested") ? (
          <Button variant="danger" block onClick={() => setAsking("cancel")}>
            Cancel booking
          </Button>
        ) : null}
      </div>

      {b.review || b.can_review ? <ReviewBlock b={b} onSaved={refresh} /> : null}

      <section className="flex flex-col gap-2">
        <SectionTitle>Timeline</SectionTitle>
        <ol className="flex flex-col gap-1.5">
          {bookingTimeline(b).map((t) => (
            <li key={t.key} className="flex justify-between gap-3 text-[14px]">
              <span>{t.label}</span>
              <span className="shrink-0 text-text-2">
                {new Intl.DateTimeFormat("en-US", {
                  timeZone: zone,
                  month: "short",
                  day: "numeric",
                  hour: "numeric",
                  minute: "2-digit",
                }).format(new Date(t.at))}
              </span>
            </li>
          ))}
        </ol>
        {b.status === "requested" && b.expires_at ? (
          <p className="text-[13px] text-text-3">
            The request expires if it isn&apos;t answered by{" "}
            {new Intl.DateTimeFormat("en-US", {
              timeZone: zone,
              weekday: "short",
              hour: "numeric",
              minute: "2-digit",
            }).format(new Date(b.expires_at))}
            .
          </p>
        ) : null}
      </section>

      <Note>
        <span className="inline-flex items-center gap-1 font-semibold text-text">
          <ShieldCheck className="size-4" aria-hidden="true" /> Meet in public places.
        </span>{" "}
        Tell someone where you&apos;re going.{" "}
        <a
          href={`${SITE_URL}/safety`}
          target="_blank"
          rel="noreferrer"
          className="font-semibold text-link underline-offset-2 hover:underline"
        >
          Safety Center
        </a>
        {" · "}
        <a
          href={refundPolicyUrl(SITE_URL)}
          target="_blank"
          rel="noreferrer"
          className="font-semibold text-link underline-offset-2 hover:underline"
        >
          Refund Policy
        </a>
      </Note>

      <Button
        variant="ghost"
        size="sm"
        className="self-start text-text-2"
        aria-haspopup="dialog"
        onClick={() => setReportOpen(true)}
      >
        Report a problem
      </Button>

      <ConfirmSheet
        what={asking}
        b={b}
        refundNow={refundNow}
        loading={act.isPending}
        onCancel={() => setAsking(null)}
        onConfirm={() => asking && act.mutate(asking)}
      />
      <MeetingSheet
        open={meetingOpen}
        b={b}
        onClose={() => setMeetingOpen(false)}
        onSaved={refresh}
      />
      <ContestSheet
        open={contestOpen}
        b={b}
        onClose={() => setContestOpen(false)}
        onSaved={refresh}
      />
      <ReportSheet
        open={reportOpen}
        onClose={() => setReportOpen(false)}
        kind="booking"
        targetId={b.id}
      />
    </>
  );
}

function ConfirmSheet({
  what,
  b,
  refundNow,
  loading,
  onCancel,
  onConfirm,
}: {
  what: Confirmable;
  b: BookingDetail;
  refundNow: number;
  loading: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  const copy: Record<
    Exclude<Confirmable, null>,
    { title: string; body: ReactNode; cta: string }
  > = {
    decline: {
      title: "Decline this request?",
      body: `${b.other.first_name} is told the request wasn't accepted.`,
      cta: "Decline",
    },
    cancel: {
      title: "Cancel this booking?",
      body:
        b.status !== "confirmed"
          ? "Your request is withdrawn. Nothing was charged."
          : b.role === "coach"
            ? `${b.other.first_name} is told, and the Refund Policy gives them a full refund (${formatPrice(b.price_minor, b.currency)}).`
            : b.payment_mode === "stripe"
              ? `Under the Refund Policy you get ${formatPrice(refundNow, b.currency)} back now.`
              : `Under the Refund Policy, ${refundNow >= b.price_minor ? "cancelling now means you shouldn't owe anything" : `the expectation is a refund of ${formatPrice(refundNow, b.currency)}`}. Payment is arranged directly with ${b.other.first_name}.`,
      cta: "Cancel booking",
    },
    no_show: {
      title: "Mark your client as absent?",
      body: "They can contest it within 48 hours. A moderator decides contested ones.",
      cta: "Mark absent",
    },
    coach_no_show: {
      title: "Report that the coach didn't come?",
      body: "The coach can contest it within 48 hours. A moderator decides contested ones.",
      cta: "Report",
    },
  };
  const c = what ? copy[what] : null;
  return (
    <Sheet
      open={what !== null}
      onClose={onCancel}
      title={c?.title}
      footer={
        <div className="grid grid-cols-2 gap-2">
          <Button variant="secondary" size="lg" onClick={onCancel} disabled={loading}>
            Back
          </Button>
          <Button variant="danger" size="lg" loading={loading} onClick={onConfirm}>
            {c?.cta}
          </Button>
        </div>
      }
    >
      <p className="text-[15px] text-text-2">{c?.body}</p>
    </Sheet>
  );
}

function MeetingSheet({
  open,
  b,
  onClose,
  onSaved,
}: {
  open: boolean;
  b: BookingDetail;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [note, setNote] = useState(b.meeting_note ?? "");
  const [link, setLink] = useState(b.online_link ?? "");
  const save = useMutation({
    mutationFn: () => coaching.setMeeting(b.id, note.trim(), link.trim() || null),
    onSuccess: () => {
      toast.success("Saved. Only the two of you see this.");
      onSaved();
      onClose();
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });
  return (
    <Sheet open={open} onClose={onClose} title="Meeting details">
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          save.mutate();
        }}
      >
        <FieldTextArea
          label="Where to meet"
          rows={3}
          maxLength={500}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          hint="A public place. Only you and your client see this."
        />
        <Field
          label="Call link (optional)"
          type="url"
          placeholder="https://"
          value={link}
          onChange={(e) => setLink(e.target.value)}
        />
        <Button type="submit" size="lg" block loading={save.isPending}>
          Save
        </Button>
      </form>
    </Sheet>
  );
}

function ContestSheet({
  open,
  b,
  onClose,
  onSaved,
}: {
  open: boolean;
  b: BookingDetail;
  onClose: () => void;
  onSaved: () => void;
}) {
  const [note, setNote] = useState("");
  const save = useMutation({
    mutationFn: () => coaching.contestNoShow(b.id, note.trim()),
    onSuccess: () => {
      toast.success("Sent to our moderators. We aim to decide within 24 hours.");
      onSaved();
      onClose();
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });
  return (
    <Sheet open={open} onClose={onClose} title="Contest the missed session">
      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          save.mutate();
        }}
      >
        <FieldTextArea
          label="What happened"
          rows={4}
          maxLength={1000}
          value={note}
          onChange={(e) => setNote(e.target.value)}
        />
        <Button type="submit" size="lg" block loading={save.isPending}>
          Send to moderators
        </Button>
      </form>
    </Sheet>
  );
}

function ReviewBlock({ b, onSaved }: { b: BookingDetail; onSaved: () => void }) {
  const [rating, setRating] = useState(b.review?.rating ?? 0);
  const [body, setBody] = useState(b.review?.body ?? "");
  const [editing, setEditing] = useState(!b.review);
  const save = useMutation({
    mutationFn: () => coaching.writeReview(b.id, rating, body.trim()),
    onSuccess: () => {
      toast.success("Thanks for your review.");
      setEditing(false);
      onSaved();
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  return (
    <section className="flex flex-col gap-2" aria-labelledby="review-title">
      <SectionTitle id="review-title">
        {b.role === "client" ? "Your review" : "Their review"}
      </SectionTitle>
      {b.review && !editing ? (
        <>
          <Stars value={b.review.rating} size={18} />
          {b.review.body ? (
            <p className="whitespace-pre-line text-[15px]">{b.review.body}</p>
          ) : null}
          {b.review.reply ? (
            <p className="ml-4 border-l-2 border-border pl-3 text-[14px] text-text-2">
              {b.review.reply}
            </p>
          ) : null}
          {b.can_review ? (
            <Button
              variant="ghost"
              size="sm"
              className="self-start"
              onClick={() => setEditing(true)}
            >
              Edit review
            </Button>
          ) : null}
        </>
      ) : b.can_review ? (
        <form
          className="flex flex-col gap-3"
          onSubmit={(e) => {
            e.preventDefault();
            if (rating > 0) save.mutate();
          }}
        >
          <StarInput value={rating} onChange={setRating} />
          <FieldTextArea
            label="Tell others how it went (optional)"
            rows={3}
            maxLength={1000}
            value={body}
            onChange={(e) => setBody(e.target.value)}
            hint="Public on the coach's page. No links. You can edit it for 7 days."
          />
          <Button
            type="submit"
            className="self-start"
            loading={save.isPending}
            disabled={rating === 0}
          >
            Post review
          </Button>
        </form>
      ) : null}
    </section>
  );
}
