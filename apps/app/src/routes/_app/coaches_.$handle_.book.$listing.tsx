import { useMemo, useState } from "react";
import { Link, createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CalendarX, CircleAlert } from "lucide-react";
import { toast } from "sonner";
import {
  addDays,
  coachingErrorCode,
  coachingErrorMessage,
  dateKeyIn,
  formatPrice,
  groupSlotsByDay,
  listingShapeLabel,
  paymentLine,
  zoneShort,
  type PublicListing,
} from "@ap/core/coaching";

import { Note } from "@/components/coaching/parts";
import { GuidelinesSheet } from "@/components/events/guidelines-sheet";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { Chip } from "@/components/ui/chip";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  coaching,
  coachQuery,
  coachingKeys,
  refundPolicyUrl,
  slotsQuery,
  useCoachingConfig,
} from "@/lib/coaching";
import { viewerZone } from "@/lib/datetime";
import { acceptGuidelines } from "@/lib/events";
import { SITE_URL } from "@/lib/site";

/**
 * Request a time (design sections 4 and 15): slots come from coach_slots (the server's own
 * generator), shown in the viewer's zone with the coach's time beside them when it differs. The
 * Refund and Cancellation Policy is acknowledged on every request; the request is idempotent on
 * a client request id kept for this screen. With payments off, the requests-only note says how
 * payment works; "Pay after the coach confirms" only when the server says the listing is payable.
 */
export const Route = createFileRoute("/_app/coaches_/$handle_/book/$listing")({
  component: BookPage,
});

const WINDOW_DAYS = 14;

function BookPage() {
  const { handle, listing: listingId } = Route.useParams();
  const coach = useQuery(coachQuery(handle));
  const listing = coach.data?.listings.find((l) => l.id === listingId) ?? null;

  return (
    <>
      <TopBar title="Request a time" back />
      <main className="flex flex-col gap-5 pb-8 safe-px">
        {coach.isPending ? (
          <Skeleton className="mt-2 h-40" />
        ) : coach.isError || !listing || coach.data.own ? (
          <EmptyState
            icon={CircleAlert}
            title="This session isn't available"
            body={coach.isError ? coachingErrorMessage(coach.error) : "Pick another session."}
            action={
              <Link to="/coaches" className={buttonVariants({ variant: "secondary" })}>
                Find a coach
              </Link>
            }
          />
        ) : (
          <BookForm
            coachName={coach.data.first_name}
            coachHandle={coach.data.handle}
            coachZone={coach.data.timezone}
            listing={listing}
          />
        )}
      </main>
    </>
  );
}

function BookForm({
  coachName,
  coachHandle,
  coachZone,
  listing,
}: {
  coachName: string;
  coachHandle: string;
  coachZone: string;
  listing: PublicListing;
}) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const config = useCoachingConfig();
  const zone = viewerZone();
  const [offset, setOffset] = useState(0);
  const from = addDays(dateKeyIn(new Date(), coachZone), offset);
  const to = addDays(from, WINDOW_DAYS - 1);
  const slots = useQuery(slotsQuery(listing.id, from, to));
  const days = useMemo(
    () => groupSlotsByDay(slots.data ?? [], zone, coachZone, coachName),
    [slots.data, zone, coachZone, coachName],
  );
  const [dayKey, setDayKey] = useState<string | null>(null);
  const day = days.find((d) => d.key === dayKey) ?? days[0] ?? null;
  const [startsAt, setStartsAt] = useState<string | null>(null);
  const [note, setNote] = useState("");
  const [ack, setAck] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [requestId] = useState(() => crypto.randomUUID());
  const [gated, setGated] = useState(false);
  const [accepting, setAccepting] = useState(false);
  const zonesDiffer =
    zoneShort(new Date().toISOString(), zone) !== zoneShort(new Date().toISOString(), coachZone);

  const send = useMutation({
    mutationFn: () =>
      coaching.requestBooking({
        listingId: listing.id,
        startsAt: startsAt!,
        note: note.trim(),
        policyVersion: config.data!.policy_version,
        requestId,
      }),
    onSuccess: async (r) => {
      void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
      toast.success(
        r.status === "confirmed"
          ? "You're booked."
          : `Request sent. ${coachName} will confirm or decline.`,
      );
      await navigate({ to: "/bookings/$id", params: { id: r.id }, replace: true });
    },
    onError: (err) => {
      const code = coachingErrorCode(err);
      if (code === "guidelines_required") {
        setGated(true);
        return;
      }
      if (code === "slot_unavailable" || code === "full") {
        setStartsAt(null);
        void slots.refetch();
      }
      setError(coachingErrorMessage(err));
    },
  });

  async function acceptAndRetry() {
    setAccepting(true);
    try {
      await acceptGuidelines();
      void queryClient.invalidateQueries({ queryKey: ["profile"] });
      setGated(false);
      send.mutate();
    } catch (err) {
      toast.error(coachingErrorMessage(err));
    } finally {
      setAccepting(false);
    }
  }

  return (
    <>
      <section className="flex flex-col gap-1 pt-2">
        <p className="text-[18px] font-bold">{listing.title}</p>
        <p className="text-[14px] text-text-2">
          {listingShapeLabel(listing)} · with {coachName}
        </p>
        <p className="text-[16px] font-bold">
          {formatPrice(listing.price_minor, listing.currency)}
        </p>
      </section>

      <section className="flex flex-col gap-3" aria-labelledby="pick-time">
        <div className="flex items-baseline justify-between gap-2">
          <h2 id="pick-time" className="text-[17px] font-bold">
            Pick a time
          </h2>
          <span className="text-[13px] text-text-3">
            Your time ({zoneShort(new Date().toISOString(), zone)})
          </span>
        </div>
        {zonesDiffer ? (
          <p className="text-[13px] text-text-2">
            {coachName} is in {coachZone.replace(/_/g, " ")}. Times show in your zone, with{" "}
            {coachName}&apos;s time beside them.
          </p>
        ) : null}
        {slots.isPending ? (
          <Skeleton className="h-24" />
        ) : slots.isError ? (
          <FormError>{coachingErrorMessage(slots.error)}</FormError>
        ) : days.length === 0 ? (
          <EmptyState
            icon={CalendarX}
            title="No open times in these two weeks"
            body="Try the next two weeks, or message the coach."
          />
        ) : (
          <>
            <div
              className="-mx-4 flex gap-2 overflow-x-auto px-4 pb-1"
              role="group"
              aria-label="Day"
            >
              {days.map((d) => (
                <Chip
                  key={d.key}
                  selected={day?.key === d.key}
                  onClick={() => {
                    setDayKey(d.key);
                    setStartsAt(null);
                  }}
                >
                  {d.label}
                </Chip>
              ))}
            </div>
            {day ? (
              <ul className="grid grid-cols-2 gap-2 min-[400px]:grid-cols-3" aria-label="Times">
                {day.slots.map((s) => (
                  <li key={s.starts_at}>
                    <button
                      type="button"
                      aria-pressed={startsAt === s.starts_at}
                      onClick={() => {
                        setStartsAt(s.starts_at);
                        setError(null);
                      }}
                      className={
                        "flex min-h-11 w-full flex-col items-center justify-center rounded-control border px-2 py-1.5 text-[15px] font-semibold " +
                        (startsAt === s.starts_at
                          ? "border-transparent bg-primary-tint text-primary-text"
                          : "border-border hover:bg-surface-2")
                      }
                    >
                      {s.label}
                      {s.coachLabel ? (
                        <span className="text-[11px] font-medium text-text-2">{s.coachLabel}</span>
                      ) : null}
                      {listing.format === "group" ? (
                        <span className="text-[11px] font-medium text-text-2">
                          {s.seats_left} {s.seats_left === 1 ? "spot" : "spots"} left
                        </span>
                      ) : null}
                    </button>
                  </li>
                ))}
              </ul>
            ) : null}
          </>
        )}
        <div className="flex gap-2">
          {offset > 0 ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => setOffset((o) => Math.max(0, o - WINDOW_DAYS))}
            >
              Earlier
            </Button>
          ) : null}
          {offset + WINDOW_DAYS < listing.max_advance_days ? (
            <Button
              variant="ghost"
              size="sm"
              onClick={() => {
                setOffset((o) => o + WINDOW_DAYS);
                setDayKey(null);
                setStartsAt(null);
              }}
            >
              Next two weeks
            </Button>
          ) : null}
        </div>
      </section>

      <form
        className="flex flex-col gap-4"
        onSubmit={(e) => {
          e.preventDefault();
          setError(null);
          if (startsAt && ack && config.data) send.mutate();
        }}
      >
        <FieldTextArea
          label="Note for the coach (optional)"
          rows={3}
          maxLength={500}
          value={note}
          onChange={(e) => setNote(e.target.value)}
          hint="Your level, what you'd like to work on. Only the coach sees it."
        />
        <Note>
          {config.isPending
            ? "Checking how payment works…"
            : paymentLine(listing, config.paymentsEnabled, coachName)}
        </Note>
        <label className="flex items-start gap-3 text-[14px]">
          <input
            type="checkbox"
            className="mt-0.5 size-5 shrink-0 accent-primary"
            checked={ack}
            onChange={(e) => setAck(e.target.checked)}
          />
          <span>
            I&apos;ve read the{" "}
            <a
              href={refundPolicyUrl(SITE_URL)}
              target="_blank"
              rel="noreferrer"
              className="font-semibold text-link underline-offset-2 hover:underline"
            >
              Refund and Cancellation Policy
            </a>
            : cancel at least 24 hours before for a full refund, later for half.
          </span>
        </label>
        <FormError>{error}</FormError>
        <Button
          type="submit"
          size="lg"
          block
          loading={send.isPending}
          disabled={!startsAt || !ack || !config.data}
        >
          {listing.auto_confirm ? "Book" : "Send request"}
        </Button>
        <p className="text-[12px] text-text-3">
          Meet in public places. Sending a request opens a chat with {coachName}.{" "}
          <Link
            to="/coaches/$handle"
            params={{ handle: coachHandle }}
            className="font-semibold underline-offset-2 hover:underline"
          >
            Back to {coachName}&apos;s page
          </Link>
        </p>
      </form>

      <GuidelinesSheet
        open={gated}
        onClose={() => setGated(false)}
        onAccept={() => void acceptAndRetry()}
        accepting={accepting}
      />
    </>
  );
}
