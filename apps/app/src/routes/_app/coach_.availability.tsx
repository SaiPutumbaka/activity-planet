import { useMemo, useState } from "react";
import { formatDayClock } from "@ap/core/locale";
import { VIEWER_PREFS } from "@/lib/units";
import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Plus, Trash } from "lucide-react";
import { toast } from "sonner";
import {
  WEEKDAYS,
  addDays,
  clockLabel,
  coachingErrorMessage,
  dateKeyIn,
  groupSlotsByDay,
  type AvailabilityRule,
} from "@ap/core/coaching";

import { Note, SectionTitle } from "@/components/coaching/parts";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Skeleton } from "@/components/ui/skeleton";
import {
  availabilityQuery,
  coaching,
  coachQuery,
  coachingKeys,
  exceptionsQuery,
  ownListingsQuery,
  slotsQuery,
} from "@/lib/coaching";
import { fromLocalDateTimeInputValue, viewerZone } from "@/lib/datetime";

const appRoute = getRouteApi("/_app");

/**
 * Weekly availability (design sections 3.4 and 15): windows in the coach's own zone (wall-clock,
 * so they hold across daylight-saving changes), dated exceptions, and a preview of the next two
 * weeks' open times from coach_slots, the same generator clients book from.
 */
export const Route = createFileRoute("/_app/coach_/availability")({
  component: AvailabilityPage,
});

function AvailabilityPage() {
  const { session, profile } = appRoute.useRouteContext();
  const userId = session.user.id;
  const coach = useQuery(coachQuery(profile.handle));
  const rules = useQuery(availabilityQuery(userId));
  return (
    <>
      <TopBar title="Availability" back />
      <main className="flex flex-col gap-6 pb-8 safe-px">
        {coach.isError ? (
          <FormError>{coachingErrorMessage(coach.error)}</FormError>
        ) : !coach.data || !rules.data ? (
          <Skeleton className="mt-2 h-60" />
        ) : (
          <>
            <WeeklyRules userId={userId} initial={rules.data} zone={coach.data.timezone} />
            <Exceptions userId={userId} zone={coach.data.timezone} />
            <Preview userId={userId} zone={coach.data.timezone} name={coach.data.first_name} />
          </>
        )}
      </main>
    </>
  );
}

function WeeklyRules({
  userId,
  initial,
  zone,
}: {
  userId: string;
  initial: AvailabilityRule[];
  zone: string;
}) {
  const queryClient = useQueryClient();
  const [rules, setRules] = useState<AvailabilityRule[]>(initial);
  const [error, setError] = useState<string | null>(null);
  const save = useMutation({
    mutationFn: () => coaching.setAvailability(rules),
    onSuccess: () => {
      toast.success("Availability saved.");
      void queryClient.invalidateQueries({ queryKey: coachingKeys.availability(userId) });
      void queryClient.invalidateQueries({ queryKey: ["coaching", "slots"] });
    },
    onError: (err) => setError(coachingErrorMessage(err)),
  });
  const update = (i: number, patch: Partial<AvailabilityRule>) =>
    setRules((l) => l.map((r, j) => (j === i ? { ...r, ...patch } : r)));

  return (
    <section className="flex flex-col gap-3 pt-2" aria-labelledby="weekly">
      <SectionTitle id="weekly">Weekly times</SectionTitle>
      <p className="text-[14px] text-text-2">
        In your time zone, {zone.replace(/_/g, " ")}. Clients see them in theirs.
      </p>
      {rules.length === 0 ? <p className="text-[15px] text-text-3">No weekly times yet.</p> : null}
      <ul className="flex flex-col gap-3">
        {rules.map((r, i) => (
          <li key={i} className="grid grid-cols-[1fr_auto] items-end gap-2">
            <div className="grid grid-cols-3 gap-2">
              <FieldSelect
                label="Day"
                value={String(r.weekday)}
                onChange={(e) => update(i, { weekday: Number(e.target.value) })}
              >
                {WEEKDAYS.map((d) => (
                  <option key={d.value} value={d.value}>
                    {d.short}
                  </option>
                ))}
              </FieldSelect>
              <Field
                label="From"
                type="time"
                value={r.start}
                onChange={(e) => update(i, { start: e.target.value })}
              />
              <Field
                label="To"
                type="time"
                value={r.end}
                onChange={(e) => update(i, { end: e.target.value })}
              />
            </div>
            <Button
              variant="ghost"
              size="icon"
              aria-label={`Remove ${clockLabel(r.start)} window`}
              onClick={() => setRules((l) => l.filter((_x, j) => j !== i))}
            >
              <Trash className="size-4" aria-hidden="true" />
            </Button>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap gap-2">
        <Button
          variant="secondary"
          size="sm"
          leading={<Plus className="size-4" aria-hidden="true" />}
          disabled={rules.length >= 50}
          onClick={() =>
            setRules((l) => [
              ...l,
              {
                weekday: l[l.length - 1]?.weekday ?? 1,
                start: "09:00",
                end: "12:00",
                listing_id: null,
              },
            ])
          }
        >
          Add a window
        </Button>
      </div>
      <FormError>{error}</FormError>
      <Button
        size="lg"
        block
        loading={save.isPending}
        onClick={() => {
          setError(null);
          save.mutate();
        }}
      >
        Save weekly times
      </Button>
    </section>
  );
}

function Exceptions({ userId, zone }: { userId: string; zone: string }) {
  const queryClient = useQueryClient();
  const list = useQuery(exceptionsQuery(userId));
  const [kind, setKind] = useState<"unavailable" | "available">("unavailable");
  const [start, setStart] = useState("");
  const [end, setEnd] = useState("");
  const viewer = viewerZone();
  const fmt = (iso: string) => formatDayClock(iso, zone, VIEWER_PREFS);
  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: coachingKeys.exceptions(userId) });
    void queryClient.invalidateQueries({ queryKey: ["coaching", "slots"] });
  };
  const add = useMutation({
    mutationFn: () => {
      const s = fromLocalDateTimeInputValue(start, zone);
      const e = fromLocalDateTimeInputValue(end, zone);
      if (!s || !e) throw new Error("invalid_range");
      return coaching.addException({ kind, starts_at: s, ends_at: e, note: "" });
    },
    onSuccess: () => {
      setStart("");
      setEnd("");
      toast.success(kind === "unavailable" ? "Time off added." : "Extra time added.");
      refresh();
    },
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });
  const remove = useMutation({
    mutationFn: (id: string) => coaching.removeException(id),
    onSuccess: refresh,
    onError: (err) => toast.error(coachingErrorMessage(err)),
  });

  return (
    <section className="flex flex-col gap-3" aria-labelledby="exceptions">
      <SectionTitle id="exceptions">Time off and extra times</SectionTitle>
      <FieldSelect
        label="Kind"
        value={kind}
        onChange={(e) => setKind(e.target.value as "unavailable" | "available")}
      >
        <option value="unavailable">Not available (time off)</option>
        <option value="available">Extra time I'm available</option>
      </FieldSelect>
      <div className="grid grid-cols-1 gap-2 min-[400px]:grid-cols-2">
        <Field
          label="From"
          type="datetime-local"
          value={start}
          onChange={(e) => setStart(e.target.value)}
        />
        <Field
          label="To"
          type="datetime-local"
          value={end}
          onChange={(e) => setEnd(e.target.value)}
        />
      </div>
      {viewer !== zone ? (
        <p className="text-[13px] text-text-3">These times are in {zone.replace(/_/g, " ")}.</p>
      ) : null}
      <Button
        variant="secondary"
        className="self-start"
        loading={add.isPending}
        disabled={!start || !end}
        onClick={() => add.mutate()}
      >
        Add
      </Button>
      {(list.data ?? []).length > 0 ? (
        <ul className="flex flex-col gap-1.5">
          {(list.data ?? []).map((e) => (
            <li key={e.id} className="flex items-center justify-between gap-2 text-[14px]">
              <span className="min-w-0">
                <span className="font-semibold">{e.kind === "unavailable" ? "Off" : "Extra"}</span>{" "}
                {fmt(e.starts_at)} to {fmt(e.ends_at)}
              </span>
              <Button
                variant="ghost"
                size="icon-sm"
                aria-label="Remove"
                onClick={() => remove.mutate(e.id)}
              >
                <Trash className="size-4" aria-hidden="true" />
              </Button>
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}

function Preview({ userId, zone, name }: { userId: string; zone: string; name: string }) {
  const listings = useQuery(ownListingsQuery(userId));
  const one = useMemo(
    () => (listings.data ?? []).filter((l) => l.format === "one_on_one" && l.status !== "archived"),
    [listings.data],
  );
  const [pick, setPick] = useState<string>("");
  const listingId = pick || one[0]?.id || "";
  const from = dateKeyIn(new Date(), zone);
  const slots = useQuery({
    ...slotsQuery(listingId, from, addDays(from, 13)),
    enabled: Boolean(listingId),
  });
  const days = groupSlotsByDay(slots.data ?? [], zone, zone, name);

  return (
    <section className="flex flex-col gap-3" aria-labelledby="preview">
      <SectionTitle id="preview">Next two weeks</SectionTitle>
      {one.length === 0 ? (
        <Note>Add a one-on-one listing to preview the times clients can book.</Note>
      ) : (
        <>
          {one.length > 1 ? (
            <FieldSelect
              label="Listing"
              value={listingId}
              onChange={(e) => setPick(e.target.value)}
            >
              {one.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.title}
                </option>
              ))}
            </FieldSelect>
          ) : null}
          {slots.isPending ? (
            <Skeleton className="h-20" />
          ) : days.length === 0 ? (
            <p className="text-[15px] text-text-3">No open times. Save weekly times above.</p>
          ) : (
            <ul className="flex flex-col gap-2" aria-label="Open times">
              {days.map((d) => (
                <li key={d.key} className="text-[14px]">
                  <span className="font-semibold">{d.label}:</span>{" "}
                  <span className="text-text-2">
                    {d.slots.length} {d.slots.length === 1 ? "start" : "starts"},{" "}
                    {d.slots[0]!.label} to {d.slots[d.slots.length - 1]!.label}
                  </span>
                </li>
              ))}
            </ul>
          )}
        </>
      )}
    </section>
  );
}
