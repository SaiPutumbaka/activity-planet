import { useMemo, useState } from "react";
import { createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";
import {
  addDays,
  coachingErrorMessage,
  currencyDigits,
  dateKeyIn,
  durationLabel,
  parsePrice,
  sessionTimeLabel,
  type ListingInput,
  type OwnListing,
} from "@ap/core/coaching";

import { Note, SectionTitle } from "@/components/coaching/parts";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { FieldTextArea } from "@/components/ui/textarea";
import { coaching, coachQuery, coachingKeys, ownListingsQuery, slotsQuery } from "@/lib/coaching";
import { fromLocalDateTimeInputValue, viewerZone } from "@/lib/datetime";
import { hubCatalogQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

/**
 * Create or edit a listing (design sections 3.3 and 15). Online + group is not offered in the form
 * (the server refuses it anyway: coach_listings_launch_shape). Price changes never touch existing
 * bookings. Group listings schedule their own sessions here.
 */
export const Route = createFileRoute("/_app/coach_/listings/$id")({
  component: ListingPage,
});

function ListingPage() {
  const { id } = Route.useParams();
  const { session, profile } = appRoute.useRouteContext();
  const listings = useQuery(ownListingsQuery(session.user.id));
  const coach = useQuery(coachQuery(profile.handle));
  const listing = id === "new" ? null : (listings.data?.find((l) => l.id === id) ?? null);
  const ready = listings.isSuccess && coach.isSuccess;
  return (
    <>
      <TopBar title={id === "new" ? "New listing" : "Listing"} back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {coach.isError ? (
          <FormError>{coachingErrorMessage(coach.error)}</FormError>
        ) : !ready ? (
          <Skeleton className="mt-2 h-60" />
        ) : id !== "new" && !listing ? (
          <FormError>This listing isn't available.</FormError>
        ) : (
          <ListingForm
            key={listing?.id ?? "new"}
            listing={listing}
            offersInPerson={coach.data.in_person}
            offersOnline={coach.data.online}
            coachZone={coach.data.timezone}
          />
        )}
      </main>
    </>
  );
}

const DURATIONS = [30, 45, 60, 75, 90, 120, 180];

function majorText(minor: number, currency: string): string {
  const d = currencyDigits(currency);
  const v = minor / 10 ** d;
  return Number.isInteger(v) ? String(v) : v.toFixed(d);
}

function ListingForm({
  listing,
  offersInPerson,
  offersOnline,
  coachZone,
}: {
  listing: OwnListing | null;
  offersInPerson: boolean;
  offersOnline: boolean;
  coachZone: string;
}) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  const catalog = useQuery(hubCatalogQuery);
  const [title, setTitle] = useState(listing?.title ?? "");
  const [description, setDescription] = useState(listing?.description ?? "");
  const [delivery, setDelivery] = useState<"in_person" | "online">(
    listing?.delivery ?? (offersInPerson ? "in_person" : "online"),
  );
  const [format, setFormat] = useState<"one_on_one" | "group">(listing?.format ?? "one_on_one");
  const [capacity, setCapacity] = useState(
    String(listing?.capacity && listing.capacity > 1 ? listing.capacity : 6),
  );
  const [duration, setDuration] = useState(listing?.duration_minutes ?? 60);
  const [currency, setCurrency] = useState(listing?.currency ?? "usd");
  const [price, setPrice] = useState(
    listing ? majorText(listing.price_minor, listing.currency) : "",
  );
  const [buffer, setBuffer] = useState(String(listing?.buffer_minutes ?? 0));
  const [notice, setNotice] = useState(String(listing?.min_notice_hours ?? 12));
  const [advance, setAdvance] = useState(String(listing?.max_advance_days ?? 60));
  const [step, setStep] = useState(String(listing?.slot_step_minutes ?? 30));
  const [autoConfirm, setAutoConfirm] = useState(listing?.auto_confirm ?? false);
  const [minAge, setMinAge] = useState(listing?.min_age ?? 18);
  const [hubId, setHubId] = useState(listing?.hub_id ?? "");
  const [meetingNote, setMeetingNote] = useState(listing?.meeting_note ?? "");
  const [onlineLink, setOnlineLink] = useState(listing?.online_link ?? "");
  const [error, setError] = useState<string | null>(null);

  const hubs = useMemo(() => {
    const sensitive = new Set(
      (catalog.data?.categories ?? []).filter((c) => c.is_sensitive).map((c) => c.slug),
    );
    return (catalog.data?.hubs ?? []).filter((h) => !sensitive.has(h.category_slug));
  }, [catalog.data]);

  const groupAllowed = delivery === "in_person";
  const effectiveFormat = groupAllowed ? format : "one_on_one";

  const save = useMutation({
    mutationFn: (input: ListingInput) => coaching.upsertListing(input),
    onSuccess: async (r) => {
      void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
      toast.success(listing ? "Listing saved." : "Listing created.");
      if (!listing)
        await navigate({ to: "/coach/listings/$id", params: { id: r.id }, replace: true });
    },
    onError: (err) => setError(coachingErrorMessage(err)),
  });
  const setStatus = useMutation({
    mutationFn: (s: "active" | "paused" | "archived") => coaching.setListingStatus(listing!.id, s),
    onSuccess: async (_r, s) => {
      void queryClient.invalidateQueries({ queryKey: coachingKeys.all });
      toast.success(
        s === "active"
          ? "Listing is bookable."
          : s === "paused"
            ? "Listing paused."
            : "Listing archived.",
      );
      if (s === "archived") await navigate({ to: "/coach" });
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  function submit() {
    setError(null);
    const cur = currency.trim().toLowerCase();
    if (!/^[a-z]{3}$/.test(cur)) {
      setError("Use a three-letter currency code, like USD, EUR or JPY.");
      return;
    }
    const minor = parsePrice(price || "0", cur);
    if (minor === null) {
      setError("Enter a price of 0 or more.");
      return;
    }
    save.mutate({
      ...(listing ? { id: listing.id } : {}),
      title: title.trim(),
      description: description.trim(),
      delivery,
      format: effectiveFormat,
      capacity: effectiveFormat === "group" ? Number(capacity) || 2 : 1,
      duration_minutes: duration,
      price_minor: minor,
      currency: cur,
      buffer_minutes: Number(buffer) || 0,
      min_notice_hours: Number(notice) || 12,
      max_advance_days: Number(advance) || 60,
      slot_step_minutes: Number(step) || 30,
      auto_confirm: autoConfirm,
      min_age: minAge,
      hub_id: hubId || null,
      meeting_note: meetingNote.trim(),
      online_link: onlineLink.trim() || null,
    });
  }

  return (
    <>
      <form
        className="flex flex-col gap-4 pt-2"
        onSubmit={(e) => {
          e.preventDefault();
          submit();
        }}
      >
        {listing?.moderation_state ? (
          <Note>Our moderators hid this listing. It isn&apos;t shown or bookable.</Note>
        ) : null}
        <Field
          label="Title"
          maxLength={80}
          placeholder="Tennis lesson, one hour"
          value={title}
          onChange={(e) => setTitle(e.target.value)}
        />
        <FieldTextArea
          label="Description"
          rows={4}
          maxLength={2000}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          hint="What a session covers and what to bring."
        />
        <div className="grid grid-cols-1 gap-3 min-[400px]:grid-cols-2">
          <FieldSelect
            label="Where"
            value={delivery}
            onChange={(e) => setDelivery(e.target.value as "in_person" | "online")}
          >
            <option value="in_person" disabled={!offersInPerson}>
              In person{offersInPerson ? "" : " (turn on in your profile)"}
            </option>
            <option value="online" disabled={!offersOnline}>
              Online{offersOnline ? "" : " (turn on in your profile)"}
            </option>
          </FieldSelect>
          <FieldSelect
            label="Format"
            value={effectiveFormat}
            onChange={(e) => setFormat(e.target.value as "one_on_one" | "group")}
            hint={groupAllowed ? undefined : "Online sessions are one-on-one."}
          >
            <option value="one_on_one">One-on-one</option>
            {groupAllowed ? <option value="group">Group</option> : null}
          </FieldSelect>
        </div>
        {effectiveFormat === "group" ? (
          <Field
            label="Group size"
            inputMode="numeric"
            value={capacity}
            onChange={(e) => setCapacity(e.target.value)}
            hint="2 to 50 people"
          />
        ) : null}
        <div className="grid grid-cols-1 gap-3 min-[400px]:grid-cols-2">
          <FieldSelect
            label="Length"
            value={String(duration)}
            onChange={(e) => setDuration(Number(e.target.value))}
          >
            {DURATIONS.map((d) => (
              <option key={d} value={d}>
                {durationLabel(d)}
              </option>
            ))}
          </FieldSelect>
          <div className="grid grid-cols-[1fr_5.5rem] gap-2">
            <Field
              label="Price"
              inputMode="decimal"
              placeholder="0"
              value={price}
              onChange={(e) => setPrice(e.target.value)}
            />
            <Field
              label="Currency"
              maxLength={3}
              value={currency}
              onChange={(e) => setCurrency(e.target.value)}
              autoCapitalize="none"
            />
          </div>
        </div>
        <Switch
          label="Confirm requests automatically"
          hint={
            effectiveFormat === "group"
              ? "Group seats are usually confirmed at once"
              : "Otherwise you confirm each request"
          }
          checked={autoConfirm}
          onCheckedChange={setAutoConfirm}
        />
        <details className="rounded-card border border-border px-4 py-3">
          <summary className="min-h-8 cursor-pointer text-[15px] font-semibold">
            More options
          </summary>
          <div className="flex flex-col gap-3 pt-3">
            <div className="grid grid-cols-2 gap-2">
              <Field
                label="Notice (hours)"
                inputMode="numeric"
                value={notice}
                onChange={(e) => setNotice(e.target.value)}
                hint="1 to 336"
              />
              <Field
                label="Book ahead (days)"
                inputMode="numeric"
                value={advance}
                onChange={(e) => setAdvance(e.target.value)}
                hint="1 to 180"
              />
              <Field
                label="Break after (min)"
                inputMode="numeric"
                value={buffer}
                onChange={(e) => setBuffer(e.target.value)}
                hint="0 to 120"
              />
              <FieldSelect
                label="Start times every"
                value={step}
                onChange={(e) => setStep(e.target.value)}
              >
                <option value="15">15 min</option>
                <option value="30">30 min</option>
                <option value="60">60 min</option>
              </FieldSelect>
            </div>
            <FieldSelect
              label="Ages"
              value={String(minAge)}
              onChange={(e) => setMinAge(Number(e.target.value))}
            >
              <option value="18">18+</option>
              <option value="21">21+</option>
            </FieldSelect>
            <FieldSelect
              label="Hub (optional)"
              value={hubId}
              onChange={(e) => setHubId(e.target.value)}
            >
              <option value="">None</option>
              {hubs.map((h) => (
                <option key={h.id} value={h.id}>
                  {h.emoji ? `${h.emoji} ` : ""}
                  {h.name}
                </option>
              ))}
            </FieldSelect>
          </div>
        </details>
        <FieldTextArea
          label={delivery === "online" ? "Joining notes (private)" : "Where to meet (private)"}
          rows={2}
          maxLength={500}
          value={meetingNote}
          onChange={(e) => setMeetingNote(e.target.value)}
          hint="Only confirmed clients see this. Pick a public place."
        />
        {delivery === "online" ? (
          <Field
            label="Call link (private)"
            type="url"
            placeholder="https://"
            value={onlineLink}
            onChange={(e) => setOnlineLink(e.target.value)}
          />
        ) : null}
        <FormError>{error}</FormError>
        <Button type="submit" size="lg" block loading={save.isPending}>
          {listing ? "Save listing" : "Create listing"}
        </Button>
      </form>

      {listing ? (
        <section className="flex flex-col gap-2">
          <SectionTitle>Status</SectionTitle>
          <p className="text-[15px] text-text-2">
            {listing.status === "active"
              ? "Bookable."
              : listing.status === "paused"
                ? "Paused: not shown or bookable."
                : "Archived."}
          </p>
          <div className="flex flex-wrap gap-2">
            {listing.status !== "active" ? (
              <Button
                variant="secondary"
                size="sm"
                loading={setStatus.isPending}
                onClick={() => setStatus.mutate("active")}
              >
                Make bookable
              </Button>
            ) : (
              <Button
                variant="secondary"
                size="sm"
                loading={setStatus.isPending}
                onClick={() => setStatus.mutate("paused")}
              >
                Pause
              </Button>
            )}
            <Button
              variant="danger"
              size="sm"
              disabled={setStatus.isPending}
              onClick={() => setStatus.mutate("archived")}
            >
              Archive
            </Button>
          </div>
        </section>
      ) : null}

      {listing && listing.format === "group" ? (
        <GroupSessions listing={listing} coachZone={coachZone} />
      ) : null}
    </>
  );
}

function GroupSessions({ listing, coachZone }: { listing: OwnListing; coachZone: string }) {
  const queryClient = useQueryClient();
  const zone = viewerZone();
  const [when, setWhen] = useState("");
  const from = dateKeyIn(new Date(), coachZone);
  const sessions = useQuery(slotsQuery(listing.id, from, addDays(from, 31)));
  const schedule = useMutation({
    mutationFn: () => {
      const iso = fromLocalDateTimeInputValue(when, coachZone);
      if (!iso) throw new Error("invalid_range");
      return coaching.scheduleGroupSession(listing.id, iso);
    },
    onSuccess: () => {
      setWhen("");
      toast.success("Session scheduled.");
      void queryClient.invalidateQueries({ queryKey: ["coaching", "slots", listing.id] });
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });
  return (
    <section className="flex flex-col gap-3">
      <SectionTitle>Group sessions</SectionTitle>
      <p className="text-[14px] text-text-2">
        Clients book seats in sessions you schedule. Times are in your zone (
        {coachZone.replace(/_/g, " ")}).
      </p>
      <div className="grid grid-cols-[1fr_auto] items-end gap-2">
        <Field
          label="Starts"
          type="datetime-local"
          value={when}
          onChange={(e) => setWhen(e.target.value)}
        />
        <Button loading={schedule.isPending} disabled={!when} onClick={() => schedule.mutate()}>
          Schedule
        </Button>
      </div>
      {(sessions.data ?? []).length === 0 ? (
        <p className="text-[14px] text-text-3">
          No upcoming sessions with open seats in the next month.
        </p>
      ) : (
        <ul className="flex flex-col gap-1.5">
          {(sessions.data ?? []).map((s) => (
            <li key={s.starts_at} className="flex justify-between gap-3 text-[14px]">
              <span>{sessionTimeLabel(s.starts_at, s.ends_at, zone, coachZone, "you")}</span>
              <span className="shrink-0 text-text-2">{s.seats_left} open</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
