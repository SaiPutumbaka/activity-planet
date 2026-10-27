import { z } from "zod";

import {
  DEFAULT_TIMEZONE,
  fromLocalDateTimeInputValue,
  toLocalDateTimeInputValue,
} from "@/lib/datetime";
import type {
  CreateEventArgs,
  CreateEventSeriesArgs,
  EventDetail,
  UpdateEventArgs,
} from "@/lib/events";

/**
 * The post / edit form: its zod schema, defaults, and the converters to the RPC argument
 * shapes. Numbers stay strings in the form (what the inputs hold) and become numbers here.
 */
export const DURATIONS = [30, 60, 90, 120, 180, 240] as const;
export const WEEKDAYS = [
  "Sunday",
  "Monday",
  "Tuesday",
  "Wednesday",
  "Thursday",
  "Friday",
  "Saturday",
] as const;
export const DEFAULT_WEEKS = 8;
export const MAX_WEEKS = 52;
export const MAX_CAPACITY = 5000;

export function durationLabel(minutes: number): string {
  if (minutes < 60) return `${minutes} min`;
  const hours = minutes / 60;
  if (Number.isInteger(hours)) return `${hours} ${hours === 1 ? "hour" : "hours"}`;
  return `${hours.toFixed(1).replace(/\.0$/, "")} hours`;
}

const INT = /^\d+$/;
const TIME = /^\d{2}:\d{2}$/;

export const eventFormSchema = z
  .object({
    hubId: z.string().min(1, "Pick a hub."),
    title: z
      .string()
      .trim()
      .min(3, "Titles are 3 to 120 characters.")
      .max(120, "Titles are 3 to 120 characters."),
    description: z.string().trim().max(2000, "Descriptions are up to 2,000 characters."),
    /** "YYYY-MM-DDTHH:MM" from <input type="datetime-local">; ignored for a weekly series. */
    startsAt: z.string(),
    durationMinutes: z.string().regex(INT, "Pick how long it lasts."),
    repeatWeekly: z.boolean(),
    /** "0" (Sunday) to "6" */
    weekday: z.string(),
    /** "HH:MM" */
    startTime: z.string(),
    weeks: z.string(),
    locationMode: z.enum(["venue", "text"]),
    venueId: z.string().nullable(),
    venueName: z.string(),
    venueIsPublic: z.boolean(),
    locationText: z.string().trim().max(200, "Keep the meeting spot under 200 characters."),
    addressNote: z.string().trim().max(200, "Keep the note under 200 characters."),
    approvedOnly: z.boolean(),
    capacity: z.string().trim(),
    waitlistEnabled: z.boolean(),
    minHeadcount: z.string().trim(),
    is21: z.boolean(),
    campusOnly: z.boolean(),
    isFree: z.boolean(),
    priceText: z.string().trim().max(40, "Keep the price under 40 characters."),
    externalUrl: z.string().trim(),
  })
  .superRefine((v, ctx) => {
    if (v.repeatWeekly) {
      if (!TIME.test(v.startTime)) {
        ctx.addIssue({ code: "custom", path: ["startTime"], message: "Pick a start time." });
      }
      if (!INT.test(v.weeks) || Number(v.weeks) < 1 || Number(v.weeks) > MAX_WEEKS) {
        ctx.addIssue({
          code: "custom",
          path: ["weeks"],
          message: `Runs for 1 to ${MAX_WEEKS} weeks.`,
        });
      }
    } else if (fromLocalDateTimeInputValue(v.startsAt) === null) {
      ctx.addIssue({ code: "custom", path: ["startsAt"], message: "Pick a date and time." });
    }

    if (v.locationMode === "venue" ? !v.venueId : !v.locationText) {
      ctx.addIssue({
        code: "custom",
        path: ["locationText"],
        message: "Pick a place or describe where to meet.",
      });
    }
    if (v.locationMode === "venue" && !v.venueIsPublic && !v.approvedOnly) {
      ctx.addIssue({
        code: "custom",
        path: ["approvedOnly"],
        message: "This place is a private address, so it can only be shared after you approve.",
      });
    }

    const capacity = v.capacity ? Number(v.capacity) : null;
    if (v.capacity && (!INT.test(v.capacity) || capacity! < 1 || capacity! > MAX_CAPACITY)) {
      ctx.addIssue({
        code: "custom",
        path: ["capacity"],
        message: `Capacity is 1 to ${MAX_CAPACITY.toLocaleString("en-US")}.`,
      });
    }
    if (v.minHeadcount) {
      const n = Number(v.minHeadcount);
      if (!INT.test(v.minHeadcount) || n < 2 || n > MAX_CAPACITY) {
        ctx.addIssue({
          code: "custom",
          path: ["minHeadcount"],
          message: "At least 2 people.",
        });
      } else if (capacity !== null && n > capacity) {
        ctx.addIssue({
          code: "custom",
          path: ["minHeadcount"],
          message: "Can't be more than the capacity.",
        });
      }
    }
    if (!v.isFree && !v.priceText) {
      ctx.addIssue({
        code: "custom",
        path: ["priceText"],
        message: "Say what it costs, like $5 cover.",
      });
    }
    if (v.externalUrl && !/^https:\/\/\S+$/.test(v.externalUrl)) {
      ctx.addIssue({
        code: "custom",
        path: ["externalUrl"],
        message: "Links start with https://.",
      });
    }
    if (v.is21 && v.campusOnly) {
      ctx.addIssue({
        code: "custom",
        path: ["campusOnly"],
        message: "21+ plans live outside the campus space.",
      });
    }
  });

export type EventFormValues = z.infer<typeof eventFormSchema>;

/** The next full hour at least an hour away, as a datetime-local value in the timezone. */
function suggestedStart(timeZone: string, now = new Date()): string {
  const next = new Date(now.getTime() + 60 * 60_000);
  next.setMinutes(0, 0, 0);
  next.setTime(next.getTime() + 60 * 60_000);
  return toLocalDateTimeInputValue(next, timeZone);
}

/** "0".."6" for the weekday of a datetime-local value in the timezone ("1" when it does not parse). */
export function weekdayOf(localValue: string, timeZone: string): string {
  const iso = fromLocalDateTimeInputValue(localValue, timeZone);
  if (!iso) return "1";
  const name = new Intl.DateTimeFormat("en-US", { timeZone, weekday: "long" }).format(
    new Date(iso),
  );
  const index = WEEKDAYS.findIndex((w) => w === name);
  return String(index === -1 ? 1 : index);
}

export function defaultEventFormValues(opts: {
  hubId: string;
  timeZone?: string;
}): EventFormValues {
  const timeZone = opts.timeZone ?? DEFAULT_TIMEZONE;
  const startsAt = suggestedStart(timeZone);
  return {
    hubId: opts.hubId,
    title: "",
    description: "",
    startsAt,
    durationMinutes: "120",
    repeatWeekly: false,
    weekday: weekdayOf(startsAt, timeZone),
    startTime: startsAt.slice(11, 16),
    weeks: String(DEFAULT_WEEKS),
    locationMode: "venue",
    venueId: null,
    venueName: "",
    venueIsPublic: true,
    locationText: "",
    addressNote: "",
    approvedOnly: false,
    capacity: "",
    waitlistEnabled: true,
    minHeadcount: "",
    is21: false,
    campusOnly: false,
    isFree: true,
    priceText: "",
    externalUrl: "",
  };
}

/** The form prefilled from an existing event (edit mode). The address comes with it when the host reads it. */
export function valuesFromEvent(event: EventDetail): EventFormValues {
  const address = event.event_addresses;
  const minutes = Math.round(
    (new Date(event.ends_at).getTime() - new Date(event.starts_at).getTime()) / 60_000,
  );
  const startsAt = toLocalDateTimeInputValue(event.starts_at, event.timezone);
  return {
    hubId: event.hub_id,
    title: event.title,
    description: event.description,
    startsAt,
    durationMinutes: String(minutes),
    repeatWeekly: false,
    weekday: weekdayOf(startsAt, event.timezone),
    startTime: startsAt.slice(11, 16),
    weeks: String(DEFAULT_WEEKS),
    locationMode: address?.venue_id ? "venue" : "text",
    venueId: address?.venue_id ?? null,
    venueName: address?.venues?.name ?? "",
    venueIsPublic: address?.venues?.is_public ?? true,
    locationText: address?.location_text ?? "",
    addressNote: address?.address_note ?? "",
    approvedOnly: event.address_visibility === "approved_only",
    capacity: event.capacity === null ? "" : String(event.capacity),
    waitlistEnabled: event.waitlist_enabled,
    minHeadcount: event.min_headcount === null ? "" : String(event.min_headcount),
    is21: event.min_age === 21,
    campusOnly: event.visibility === "campus",
    isFree: event.is_free,
    priceText: event.price_text ?? "",
    externalUrl: event.external_url ?? "",
  };
}

export interface EventArgsContext {
  /** profiles.home_campus_id; the campus a campus-only plan is tagged to. */
  campusId: string | null;
  /** The hub is 21+ or the hub rules force the flag on. */
  forceIs21: boolean;
  timeZone: string;
}

/** Every patchable key, computed from the form; the diff for update_event is taken on these. */
type EventPatch = Required<
  Pick<
    UpdateEventArgs,
    | "title"
    | "description"
    | "starts_at"
    | "ends_at"
    | "timezone"
    | "min_age"
    | "visibility"
    | "campus_id"
    | "capacity"
    | "waitlist_enabled"
    | "min_headcount"
    | "is_free"
    | "price_text"
    | "venue_id"
    | "location_text"
    | "address_note"
    | "address_visibility"
    | "external_url"
  >
>;

function toPatch(v: EventFormValues, ctx: EventArgsContext): EventPatch {
  const startsAt = fromLocalDateTimeInputValue(v.startsAt, ctx.timeZone) ?? "";
  const endsAt = startsAt
    ? new Date(new Date(startsAt).getTime() + Number(v.durationMinutes) * 60_000).toISOString()
    : "";
  const is21 = v.is21 || ctx.forceIs21;
  // The rule the Campus only switch shows: a 21+ plan (by choice or by hub) is never campus.
  const campusOnly = v.campusOnly && !is21;
  return {
    title: v.title,
    description: v.description,
    starts_at: startsAt,
    ends_at: endsAt,
    timezone: ctx.timeZone,
    min_age: is21 ? 21 : 18,
    visibility: campusOnly ? "campus" : "public",
    campus_id: campusOnly ? ctx.campusId : null,
    capacity: v.capacity ? Number(v.capacity) : null,
    waitlist_enabled: v.waitlistEnabled,
    min_headcount: v.minHeadcount ? Number(v.minHeadcount) : null,
    is_free: v.isFree,
    price_text: v.isFree ? null : v.priceText,
    venue_id: v.locationMode === "venue" ? v.venueId : null,
    location_text: v.locationMode === "text" ? v.locationText : "",
    address_note: v.addressNote,
    address_visibility: v.approvedOnly ? "approved_only" : "public",
    external_url: v.externalUrl || null,
  };
}

export function toCreateEventArgs(v: EventFormValues, ctx: EventArgsContext): CreateEventArgs {
  return { hub_id: v.hubId, kind: "member", ...toPatch(v, ctx) };
}

export function toCreateEventSeriesArgs(
  v: EventFormValues,
  ctx: EventArgsContext,
): CreateEventSeriesArgs {
  // A series has no starts_at / ends_at: the weekday, time and length below define every week.
  const { starts_at, ends_at, ...rest } = toPatch(v, ctx);
  void starts_at;
  void ends_at;
  return {
    hub_id: v.hubId,
    kind: "member",
    ...rest,
    weekday: Number(v.weekday),
    start_time: v.startTime,
    duration_minutes: Number(v.durationMinutes),
    max_occurrences: Number(v.weeks),
  };
}

/** Only the keys that changed since the form was prefilled. Empty when nothing did. */
export function toUpdateEventArgs(
  initial: EventFormValues,
  v: EventFormValues,
  ctx: EventArgsContext,
): UpdateEventArgs {
  const before = toPatch(initial, ctx);
  const after = toPatch(v, ctx);
  const patch: Record<string, unknown> = {};
  for (const key of Object.keys(after) as (keyof EventPatch)[]) {
    if (!Object.is(before[key], after[key])) patch[key] = after[key];
  }
  // starts_at goes only when it changed: update_event re-checks starts_in_past on any starts_at
  // it receives, which would refuse a length change on a plan that is already running. It
  // validates ends_at > starts_at on the merged row, so a lone ends_at is safe.
  delete patch.timezone;
  return patch as UpdateEventArgs;
}
