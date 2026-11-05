import { z } from "zod";

/**
 * The landing page's "This week near you" (RECS_DESIGN section 8). public_week_near rounds the
 * point to 0.1 degree itself; the browser and the /api/week route round too, so a finer point
 * never leaves the device and every city is one cached response.
 *
 *   roundLandingCoordinate(33.7490)      // 33.7
 *   landingPoint("33.749", "-84.388")    // { lat: 33.7, lng: -84.4 } | null
 *   parseWeekCards(rows)                 // WeekCard[]
 *   goingLabel("10+")                    // "10+ going"
 */

/** About 11 km. -0 comes back as 0. */
export function roundLandingCoordinate(value: number): number {
  const rounded = Math.round(value * 10) / 10;
  return Object.is(rounded, -0) ? 0 : rounded;
}

/** A point rounded to 0.1 degree, or null when either value is missing or not on Earth. */
export function landingPoint(
  lat: string | number | null | undefined,
  lng: string | number | null | undefined,
): { lat: number; lng: number } | null {
  if (lat == null || lng == null || lat === "" || lng === "") return null;
  const a = typeof lat === "number" ? lat : Number(lat);
  const b = typeof lng === "number" ? lng : Number(lng);
  if (!Number.isFinite(a) || !Number.isFinite(b)) return null;
  if (a < -90 || a > 90 || b < -180 || b > 180) return null;
  return { lat: roundLandingCoordinate(a), lng: roundLandingCoordinate(b) };
}

const nstr = z
  .string()
  .nullish()
  .catch(null)
  .transform((v) => v ?? null);

export const weekCardSchema = z.object({
  id: z.string().min(1),
  title: z.string(),
  hub: z
    .object({ name: z.string(), emoji: nstr, slug: nstr })
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  starts_at: z.string(),
  timezone: z.string().catch("America/New_York"),
  is_free: z.boolean().catch(false),
  price_text: nstr,
  going_bucket: z
    .enum(["3+", "10+"])
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  distance_band: nstr,
  is_imported: z.boolean().catch(false),
  source_name: nstr,
});
export type WeekCard = z.infer<typeof weekCardSchema>;

/** Every card that parses, at most 24 (the RPC's own cap). */
export function parseWeekCards(value: unknown): WeekCard[] {
  if (!Array.isArray(value)) return [];
  const out: WeekCard[] = [];
  for (const item of value) {
    const r = weekCardSchema.safeParse(item);
    if (r.success) out.push(r.data);
    if (out.length >= 24) break;
  }
  return out;
}

export function goingLabel(bucket: WeekCard["going_bucket"]): string | null {
  return bucket ? `${bucket} going` : null;
}

/** "Free", the host's price text, or null. */
export function priceLabel(card: Pick<WeekCard, "is_free" | "price_text">): string | null {
  if (card.is_free) return "Free";
  const t = card.price_text?.trim();
  return t ? t : null;
}

/**
 * The Georgia State not-affiliated line goes only on a card that names Georgia State (D-022,
 * D-035), the same check as the public event page.
 */
export function namesGeorgiaState(source: string | null | undefined): boolean {
  return /georgia state|\bgsu\b/i.test(source ?? "");
}

/** Shown when no city was picked and no location was shared. */
export const LANDING_FALLBACK_CITY = "Atlanta";
