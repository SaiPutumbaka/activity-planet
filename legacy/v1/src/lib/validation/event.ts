import { z } from "zod";

import { stripControlChars } from "@/lib/validation/sanitize";
import { HUBS } from "@/types/database";

const latitudeSchema = z.number().min(-90).max(90);
const longitudeSchema = z.number().min(-180).max(180);

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
  // Optional: captured client-side via the Geolocation API so the event can
  // appear on the hub map and factor into "near you" sorting on Home.
  latitude: latitudeSchema.optional(),
  longitude: longitudeSchema.optional(),
});

export type CreateEventInput = z.input<typeof createEventSchema>;

export const rsvpSchema = z.object({
  eventId: z.uuid(),
  attend: z.boolean(),
});

export const deleteEventSchema = z.object({
  eventId: z.uuid(),
});
