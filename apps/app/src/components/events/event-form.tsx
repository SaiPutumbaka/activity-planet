import { forwardRef, useState, type ReactNode, type SelectHTMLAttributes } from "react";
import { Controller, useForm, useWatch } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";

import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { FieldSelect } from "@/components/ui/select";
import { Switch } from "@/components/ui/switch";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  eventErrorCode,
  eventErrorMessage,
  fieldForEventError,
  type EventFormField,
  type PostableHub,
} from "@/lib/events";
import {
  DURATIONS,
  MAX_CAPACITY,
  MAX_WEEKS,
  WEEKDAYS,
  durationLabel,
  eventFormSchema,
  weekdayOf,
  type EventArgsContext,
  type EventFormValues,
} from "./event-form-schema";
import { VenuePicker, type VenueValue } from "./venue-picker";

/**
 * One scrolling form for posting and editing a plan. The parent turns the values into RPC
 * arguments; an RPC error thrown from onSubmit lands on its field (fieldForEventError) or at
 * the bottom of the form.
 */
export interface EventFormProps {
  mode: "create" | "edit";
  initialValues: EventFormValues;
  hubs: PostableHub[];
  /** profiles.home_org_id is set: the Campus only switch makes sense. */
  canCampus: boolean;
  /** profiles.home_campus_id, tagged onto campus-only plans. */
  campusId: string | null;
  timeZone: string;
  /** Edit of a weekly occurrence: explains that saving detaches it from the series. */
  seriesNote?: string;
  submitLabel: string;
  onSubmit: (values: EventFormValues, ctx: EventArgsContext) => Promise<void>;
}

/** Fields rendered as text inputs, where a server error can sit under the control. */
const INPUT_FIELDS: ReadonlySet<EventFormField> = new Set([
  "hubId",
  "title",
  "description",
  "startsAt",
  "capacity",
  "minHeadcount",
  "locationText",
  "priceText",
  "externalUrl",
]);

export function EventForm({
  mode,
  initialValues,
  hubs,
  canCampus,
  campusId,
  timeZone,
  seriesNote,
  submitLabel,
  onSubmit,
}: EventFormProps) {
  const [formError, setFormError] = useState<string | null>(null);
  const form = useForm<EventFormValues>({
    resolver: zodResolver(eventFormSchema),
    defaultValues: initialValues,
  });
  const { register, control, setValue, setError, handleSubmit, formState } = form;
  const { errors, isSubmitting } = formState;
  const w = useWatch({ control });

  const hub = hubs.find((h) => h.id === w.hubId);
  const forceIs21 = hub?.min_age === 21;
  const hubIsCampus = hub?.scope === "campus";
  const is21 = Boolean(w.is21) || forceIs21;
  const privateVenue =
    w.locationMode === "venue" && Boolean(w.venueId) && w.venueIsPublic === false;
  const hasCapacity = Boolean(w.capacity);
  const repeat = mode === "create" && Boolean(w.repeatWeekly);

  const venueValue: VenueValue = {
    locationMode: w.locationMode ?? "venue",
    venueId: w.venueId ?? null,
    venueName: w.venueName ?? "",
    venueIsPublic: w.venueIsPublic ?? true,
    locationText: w.locationText ?? "",
  };

  function setVenue(next: VenueValue) {
    const opts = { shouldDirty: true, shouldValidate: formState.isSubmitted };
    setValue("locationMode", next.locationMode, opts);
    setValue("venueId", next.venueId, opts);
    setValue("venueName", next.venueName, opts);
    setValue("venueIsPublic", next.venueIsPublic, opts);
    setValue("locationText", next.locationText, opts);
    // A private address can only be shared after approval; the database refuses anything else.
    if (next.locationMode === "venue" && next.venueId && !next.venueIsPublic) {
      setValue("approvedOnly", true, opts);
    }
  }

  async function submit(values: EventFormValues) {
    setFormError(null);
    try {
      await onSubmit(values, { campusId, forceIs21, timeZone });
    } catch (err) {
      const field = fieldForEventError(eventErrorCode(err));
      const message = eventErrorMessage(err);
      if (field && INPUT_FIELDS.has(field)) setError(field, { message }, { shouldFocus: true });
      else setFormError(message);
    }
  }

  const durationOptions: number[] = DURATIONS.includes(
    Number(w.durationMinutes) as (typeof DURATIONS)[number],
  )
    ? [...DURATIONS]
    : [...DURATIONS, Number(w.durationMinutes) || 60].sort((a, b) => a - b);

  return (
    <form onSubmit={handleSubmit(submit)} className="flex flex-col gap-7 pb-32" noValidate>
      <Section title="What">
        {mode === "create" ? (
          <FieldSelect label="Hub" {...register("hubId")} error={errors.hubId?.message}>
            {hubs.map((h) => (
              <option key={h.id} value={h.id}>
                {h.emoji} {h.name}
              </option>
            ))}
          </FieldSelect>
        ) : hub ? (
          <ReadOnlyRow label="Hub" value={`${hub.emoji} ${hub.name}`} />
        ) : null}
        <Field
          label="Title"
          placeholder="Pickup basketball at the Rec"
          maxLength={120}
          autoComplete="off"
          {...register("title")}
          error={errors.title?.message}
        />
        <FieldTextArea
          label="Details (optional)"
          placeholder="What to bring, skill level, how to find the group."
          rows={4}
          maxLength={2000}
          {...register("description")}
          error={errors.description?.message}
        />
      </Section>

      <Section title="When">
        {seriesNote ? <p className="text-[13px] text-text-2">{seriesNote}</p> : null}
        {mode === "create" ? (
          <Controller
            control={control}
            name="repeatWeekly"
            render={({ field }) => (
              <Switch
                label="Repeat weekly"
                hint="Same day and time every week. Each week is its own plan to join."
                checked={field.value}
                onCheckedChange={(on) => {
                  field.onChange(on);
                  if (on && w.startsAt) {
                    setValue("weekday", weekdayOf(w.startsAt, timeZone));
                    setValue("startTime", w.startsAt.slice(11, 16));
                  }
                }}
              />
            )}
          />
        ) : null}
        {repeat ? (
          <>
            <div className="grid grid-cols-2 gap-3">
              <FieldSelect label="Every" {...register("weekday")} error={errors.weekday?.message}>
                {WEEKDAYS.map((name, i) => (
                  <option key={name} value={String(i)}>
                    {name}
                  </option>
                ))}
              </FieldSelect>
              <Field
                label="At"
                type="time"
                step={300}
                {...register("startTime")}
                error={errors.startTime?.message}
              />
            </div>
            <div className="grid grid-cols-2 gap-3">
              <DurationSelect
                options={durationOptions}
                {...register("durationMinutes")}
                error={errors.durationMinutes?.message}
              />
              <Field
                label="For how many weeks"
                type="number"
                inputMode="numeric"
                min={1}
                max={MAX_WEEKS}
                {...register("weeks")}
                error={errors.weeks?.message}
              />
            </div>
            <p className="text-[13px] text-text-2">
              The first one is the next {WEEKDAYS[Number(w.weekday)] ?? "week"} at that time; the
              next eight weeks are posted now and more follow as they come up.
            </p>
          </>
        ) : (
          <div className="grid grid-cols-[1fr_auto] gap-3">
            <Field
              label="Starts"
              type="datetime-local"
              step={300}
              {...register("startsAt")}
              error={errors.startsAt?.message}
            />
            <DurationSelect
              options={durationOptions}
              className="w-[132px]"
              {...register("durationMinutes")}
              error={errors.durationMinutes?.message}
            />
          </div>
        )}
      </Section>

      <Section title="Where">
        <VenuePicker
          value={venueValue}
          onChange={setVenue}
          error={errors.locationText?.message}
          disabled={isSubmitting}
        />
        <Field
          label="Note for guests (optional)"
          placeholder="Meet by the north gate, buzz 4B"
          maxLength={200}
          autoComplete="off"
          {...register("addressNote")}
          error={errors.addressNote?.message}
        />
        <Controller
          control={control}
          name="approvedOnly"
          render={({ field }) => (
            <Switch
              label="Share the exact address only with people I approve"
              hint={
                privateVenue
                  ? "This place is a private address, so this stays on. Everyone else sees the rough area until you approve them."
                  : "Everyone sees the rough area; the street address goes only to people you approve."
              }
              checked={privateVenue || field.value}
              onCheckedChange={field.onChange}
              disabled={privateVenue}
            />
          )}
        />
        <SwitchError message={errors.approvedOnly?.message} />
      </Section>

      <Section title="Who can come">
        <div className="grid grid-cols-2 gap-3">
          <Field
            label="Capacity (optional)"
            type="number"
            inputMode="numeric"
            min={1}
            max={MAX_CAPACITY}
            placeholder="No limit"
            {...register("capacity")}
            error={errors.capacity?.message}
          />
          <Field
            label="Happens if at least"
            type="number"
            inputMode="numeric"
            min={2}
            max={MAX_CAPACITY}
            placeholder="Any number"
            hint="People join"
            {...register("minHeadcount")}
            error={errors.minHeadcount?.message}
          />
        </div>
        {hasCapacity ? (
          <Controller
            control={control}
            name="waitlistEnabled"
            render={({ field }) => (
              <Switch
                label="Waitlist when full"
                hint="People move up automatically when someone leaves."
                checked={field.value}
                onCheckedChange={field.onChange}
              />
            )}
          />
        ) : null}
        {forceIs21 ? (
          <p className="text-[13px] text-text-2">This hub is 21+, so this plan is 21+.</p>
        ) : hubIsCampus ? null : (
          <Controller
            control={control}
            name="is21"
            render={({ field }) => (
              <Switch
                label="21+ only"
                hint="Checked against everyone's date of birth. 21+ plans stay out of the campus space."
                checked={field.value}
                onCheckedChange={(on) => {
                  field.onChange(on);
                  if (on) setValue("campusOnly", false);
                }}
              />
            )}
          />
        )}
        {canCampus ? (
          <Controller
            control={control}
            name="campusOnly"
            render={({ field }) => (
              <Switch
                label="Campus only"
                hint={
                  is21
                    ? "21+ plans live outside the campus space."
                    : "Only verified students of your campus see it and can join."
                }
                checked={field.value && !is21}
                onCheckedChange={field.onChange}
                disabled={is21}
              />
            )}
          />
        ) : null}
        <SwitchError message={errors.campusOnly?.message ?? errors.is21?.message} />
      </Section>

      <Section title="Cost and links">
        <Controller
          control={control}
          name="isFree"
          render={({ field }) => (
            <Switch label="Free to join" checked={field.value} onCheckedChange={field.onChange} />
          )}
        />
        {w.isFree === false ? (
          <Field
            label="What it costs"
            placeholder="$5 cover, bring $10 for court fees"
            maxLength={40}
            autoComplete="off"
            {...register("priceText")}
            error={errors.priceText?.message}
          />
        ) : null}
        <Field
          label="Link (optional)"
          type="url"
          inputMode="url"
          placeholder="https://"
          autoComplete="off"
          autoCapitalize="none"
          {...register("externalUrl")}
          error={errors.externalUrl?.message}
        />
      </Section>

      <div className="fixed inset-x-0 bottom-[calc(3.5rem+env(safe-area-inset-bottom,0px))] z-20 border-t border-border bg-surface">
        <div className="mx-auto flex max-w-lg flex-col gap-3 px-4 py-3">
          <FormError>{formError}</FormError>
          <Button type="submit" size="lg" block loading={isSubmitting}>
            {submitLabel}
          </Button>
        </div>
      </div>
    </form>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="flex flex-col gap-4">
      <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">{title}</h3>
      {children}
    </section>
  );
}

function ReadOnlyRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[14px] font-semibold">{label}</span>
      <p className="flex h-12 items-center rounded-input border border-border bg-surface-2 px-4 text-[16px] text-text-2">
        {value}
      </p>
    </div>
  );
}

function SwitchError({ message }: { message?: string }) {
  if (!message) return null;
  return (
    <p role="alert" className="-mt-2 text-[13px] font-medium text-danger">
      {message}
    </p>
  );
}

const DurationSelect = forwardRef<
  HTMLSelectElement,
  SelectHTMLAttributes<HTMLSelectElement> & { options: number[]; error?: string }
>(function DurationSelect({ options, error, ...rest }, ref) {
  return (
    <FieldSelect ref={ref} label="Lasts" error={error} {...rest}>
      {options.map((m) => (
        <option key={m} value={String(m)}>
          {durationLabel(m)}
        </option>
      ))}
    </FieldSelect>
  );
});
