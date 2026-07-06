import { z } from "zod";

import { HUBS } from "@/types/database";

/**
 * Strips ASCII control characters, keeping tab (9), newline (10), and
 * carriage return (13), which are legitimate in multi-line descriptions.
 * Combined with React's output escaping and Supabase's parameterized
 * queries, this is the input-sanitization layer for event text.
 */
function isControlChar(codePoint: number): boolean {
  if (codePoint === 9 || codePoint === 10 || codePoint === 13) {
    return false;
  }
  return codePoint < 32 || codePoint === 127;
}

function stripControlChars(value: string): string {
  let result = "";
  for (const char of value) {
    if (!isControlChar(char.codePointAt(0) ?? 0)) {
      result += char;
    }
  }
  return result;
}

export const createEventSchema = z.object({
  title: z
    .string()
    .trim()
    .min(3, "Title must be at least 3 characters.")
    .max(100, "Title must be at most 100 characters.")
    .transform(stripControlChars),
  description: z
    .string()
    .trim()
    .max(2000, "Description must be at most 2,000 characters.")
    .transform(stripControlChars),
  category: z.enum(HUBS, "Pick a category."),
  location: z
    .string()
    .trim()
    .min(2, "Location must be at least 2 characters.")
    .max(200, "Location must be at most 200 characters.")
    .transform(stripControlChars),
  eventTimestamp: z
    .string()
    .min(1, "Pick a date and time.")
    .refine(
      (value) => !Number.isNaN(Date.parse(value)),
      "Enter a valid date and time.",
    )
    .refine(
      (value) => Date.parse(value) > Date.now() - 60_000,
      "The event must be in the future.",
    ),
});

export type CreateEventInput = z.input<typeof createEventSchema>;

export const rsvpSchema = z.object({
  eventId: z.uuid(),
  attend: z.boolean(),
});

export const deleteEventSchema = z.object({
  eventId: z.uuid(),
});
