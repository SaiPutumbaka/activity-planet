import { z } from "zod";

import {
  fullNameSchema,
  organizationSchema,
  selectedHobbiesSchema,
  usernameSchema,
} from "@/lib/validation/profile";

/**
 * Mirrors the check constraints in the Supabase migrations (username 3–24
 * chars alphanumeric/underscore, organization up to 120 chars, up to
 * MAX_HUBS hubs). The field schemas are shared with the profile editor so
 * the rules can never drift between onboarding and later edits.
 */
export const onboardingSchema = z.object({
  username: usernameSchema,
  // Both optional: non-students can leave organization blank, and a display
  // name can always be added later from the profile editor.
  fullName: fullNameSchema,
  organization: organizationSchema,
  selectedHobbies: selectedHobbiesSchema,
});

export type OnboardingInput = z.infer<typeof onboardingSchema>;
