import { z } from "zod";
import { stripControlChars } from "./sanitize";

export const RESERVED_HANDLES = new Set([
  "admin",
  "administrator",
  "support",
  "help",
  "activityplanet",
  "activity_planet",
  "moderator",
  "mod",
  "staff",
  "team",
  "official",
  "system",
  "root",
]);

export const handleSchema = z
  .string()
  .trim()
  .min(3, "Handles are at least 3 characters.")
  .max(24, "Handles are at most 24 characters.")
  .regex(/^[a-zA-Z0-9_]+$/, "Letters, numbers and underscores only.")
  .refine((v) => !RESERVED_HANDLES.has(v.toLowerCase()), "That handle is reserved.");

export const firstNameSchema = z
  .string()
  .transform(stripControlChars)
  .pipe(z.string().min(1, "Enter your first name.").max(40, "Keep it under 40 characters."));

export const bioSchema = z
  .string()
  .transform(stripControlChars)
  .pipe(z.string().max(280, "Keep your bio under 280 characters."));

/** Date of birth as YYYY-MM-DD. Validated as a real calendar date; the 18+ rule is applied separately. */
export const birthDateSchema = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "Use the date picker.")
  .refine((v) => {
    const [y, m, d] = v.split("-").map(Number) as [number, number, number];
    const date = new Date(Date.UTC(y, m - 1, d));
    return (
      date.getUTCFullYear() === y &&
      date.getUTCMonth() === m - 1 &&
      date.getUTCDate() === d &&
      y >= 1900
    );
  }, "That's not a real date.");

export const MINIMUM_AGE = 18;

/** Age in whole years on `today`, computed on calendar parts so timezones can't shift it by a day. */
export function ageOn(birthDate: string, today: Date = new Date()): number {
  const [y, m, d] = birthDate.split("-").map(Number) as [number, number, number];
  let age = today.getUTCFullYear() - y;
  const monthDiff = today.getUTCMonth() + 1 - m;
  if (monthDiff < 0 || (monthDiff === 0 && today.getUTCDate() < d)) age -= 1;
  return age;
}

export function meetsMinimumAge(birthDate: string, today?: Date): boolean {
  return ageOn(birthDate, today) >= MINIMUM_AGE;
}
