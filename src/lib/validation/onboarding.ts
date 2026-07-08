import { z } from "zod";

import {
  organizationSchema,
  selectedHobbiesSchema,
  usernameSchema,
} from "@/lib/validation/profile";

/**
 * Mirrors the check constraints in supabase/migrations/0001_initial_schema.sql
 * (username 3–24 chars alphanumeric/underscore, organization up to 120
 * chars, max 8 hubs). The field schemas are shared with the profile editor
 * so the rules can never drift between onboarding and later edits.
 */
export const onboardingSchema = z.object({
  username: usernameSchema,
  // Optional: non-students can leave this blank.
  organization: organizationSchema,
  selectedHobbies: selectedHobbiesSchema,
});

export type OnboardingInput = z.infer<typeof onboardingSchema>;
