import { z } from "zod";

import { HUBS } from "@/types/database";

/**
 * Mirrors the check constraints in supabase/migrations/0001_initial_schema.sql
 * (username 3–24 chars alphanumeric/underscore, university 2–120 chars,
 * max 8 hubs). Inputs are trimmed here — the only "sanitization" text needs
 * beyond React's output escaping and Postgres's parameterized queries.
 */
export const onboardingSchema = z.object({
  username: z
    .string()
    .trim()
    .regex(
      /^[a-zA-Z0-9_]{3,24}$/,
      "3–24 characters. Letters, numbers, and underscores only.",
    ),
  // Optional: non-students can leave this blank.
  organization: z
    .string()
    .trim()
    .max(120, "Organization must be at most 120 characters."),
  selectedHobbies: z
    .array(z.enum(HUBS))
    .min(1, "Pick at least one hub to get started.")
    .max(8),
});

export type OnboardingInput = z.infer<typeof onboardingSchema>;
