import { z } from "zod";

/**
 * Shapes of the recommendation RPC results (migration 67, docs/design/recommendations/RECS_DESIGN.md
 * sections 5 to 8). The generated types call every jsonb answer `Json`; these give the reasons,
 * the prefs and the landing cards their real shape. Unknown extra keys are dropped; a malformed
 * optional field falls back to null, and a reason with an unknown code is dropped by parseReasons.
 */

const nstr = z
  .string()
  .nullish()
  .catch(null)
  .transform((v) => v ?? null);
const nint = z
  .number()
  .int()
  .nullish()
  .catch(null)
  .transform((v) => v ?? null);
/** Postgres numeric comes back as a number or a string. */
const nnumeric = z
  .union([z.number(), z.string()])
  .nullish()
  .catch(null)
  .transform((v) => {
    if (v == null) return null;
    const n = typeof v === "number" ? v : Number.parseFloat(v);
    return Number.isFinite(n) ? n : null;
  });
const count = z
  .number()
  .int()
  .nonnegative()
  .catch(0)
  .nullish()
  .transform((v) => v ?? 0);

/* ------------------------------------------------------------------ */
/* Reasons (section 5.1)                                                */
/* ------------------------------------------------------------------ */

export const WHEN_VALUES = ["tonight", "today", "tomorrow", "this_weekend"] as const;
const text = z.string().trim().min(1).max(200);

export const reasonSchema = z.discriminatedUnion("code", [
  z.object({ code: z.literal("people_met_going"), n: z.number().int().positive() }),
  z.object({ code: z.literal("like_hub"), hub_name: text }),
  z.object({ code: z.literal("like_plan"), title: text }),
  z.object({ code: z.literal("in_your_hub"), hub_name: text }),
  z.object({ code: z.literal("same_hub"), hub_name: text }),
  z.object({ code: z.literal("when"), when: z.enum(WHEN_VALUES) }),
  z.object({ code: z.literal("near"), band: text }),
  z.object({ code: z.literal("free") }),
  z.object({ code: z.literal("popular") }),
  z.object({ code: z.literal("from_source"), source_name: text }),
  z.object({ code: z.literal("teaches_your_hub"), hub_name: text }),
  z.object({ code: z.literal("online") }),
  z.object({ code: z.literal("rated"), avg: z.coerce.number().min(0).max(5), n: z.number().int() }),
  z.object({ code: z.literal("went_to_same"), title: text }),
  z.object({ code: z.literal("same_chapter"), chapter_name: text }),
  z.object({ code: z.literal("going_to_same"), title: text }),
  z.object({ code: z.literal("nearby_plans"), n: z.number().int().positive() }),
  z.object({ code: z.literal("coming_up") }),
]);
export type Reason = z.infer<typeof reasonSchema>;
export type ReasonCode = Reason["code"];

/** The server's reasons array; anything that is not a known, well-formed reason is dropped. */
export function parseReasons(value: unknown): Reason[] {
  if (!Array.isArray(value)) return [];
  const out: Reason[] = [];
  for (const item of value) {
    const r = reasonSchema.safeParse(item);
    if (r.success) out.push(r.data);
  }
  return out;
}

const reasons = z.unknown().transform(parseReasons);

/* ------------------------------------------------------------------ */
/* Rows                                                                 */
/* ------------------------------------------------------------------ */

/** recs_for_you and recs_similar_events: the feed_events_v2 columns a card shows, plus reasons. */
export const recEventSchema = z.object({
  id: z.string().min(1),
  kind: z.string(),
  hub_id: nstr,
  hub_slug: nstr,
  hub_name: nstr,
  hub_emoji: nstr,
  series_id: nstr,
  title: z.string(),
  cover_url: nstr,
  starts_at: z.string(),
  ends_at: z.string(),
  timezone: z.string().catch("America/New_York"),
  capacity: nint,
  is_free: z.boolean().catch(false),
  price_text: nstr,
  location_hint: nstr,
  going_count: count,
  source_name: nstr,
  distance_band: nstr,
  is_imported: z.boolean().catch(false),
  reasons,
  rank: count,
});
export type RecEvent = z.infer<typeof recEventSchema>;

/** recs_hubs. */
export const recHubSchema = z.object({
  id: z.string().min(1),
  slug: z.string().min(1),
  name: z.string(),
  emoji: nstr,
  category_slug: nstr,
  member_count: count,
  nearby_plans: count,
  reasons,
  rank: count,
});
export type RecHub = z.infer<typeof recHubSchema>;

/** recs_coaches. */
export const recCoachSchema = z.object({
  user_id: z.string().min(1),
  handle: z.string().min(1),
  first_name: z.string(),
  avatar_url: nstr,
  headline: nstr,
  area_label: nstr,
  distance_band: nstr,
  rating_avg: nnumeric,
  rating_count: count,
  from_price_minor: nint,
  from_currency: nstr,
  reasons,
  rank: count,
});
export type RecCoach = z.infer<typeof recCoachSchema>;

/** recs_people: never a score, a hub, an RSVP or a location. */
export const recPersonSchema = z.object({
  user_id: z.string().min(1),
  handle: nstr,
  first_name: z.string(),
  avatar_url: nstr,
  reasons,
  rank: count,
});
export type RecPerson = z.infer<typeof recPersonSchema>;

/** my_recommendation_prefs and set_recommendation_prefs. Missing means on. */
export const recPrefsSchema = z.object({
  personalize: z.boolean().catch(true).default(true),
  people_suggestions: z.boolean().catch(true).default(true),
});
export type RecPrefs = z.infer<typeof recPrefsSchema>;

export function parseRecPrefs(value: unknown): RecPrefs {
  const r = recPrefsSchema.safeParse(value ?? {});
  return r.success ? r.data : { personalize: true, people_suggestions: true };
}

/** Parses every row it can and drops the rest, so one bad row never empties a row of cards. */
export function parseRows<T>(schema: z.ZodType<T>, value: unknown): T[] {
  if (!Array.isArray(value)) return [];
  const out: T[] = [];
  for (const item of value) {
    const r = schema.safeParse(item);
    if (r.success) out.push(r.data);
  }
  return out;
}
