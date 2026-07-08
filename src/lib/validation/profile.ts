import { z } from "zod";

import { stripControlChars } from "@/lib/validation/sanitize";
import { HUBS } from "@/types/database";

/**
 * Shared with onboarding — a username picked during onboarding follows the
 * same rules as one changed later from the profile editor.
 */
export const usernameSchema = z
  .string()
  .trim()
  .regex(
    /^[a-zA-Z0-9_]{3,24}$/,
    "3–24 characters. Letters, numbers, and underscores only.",
  );

export const organizationSchema = z
  .string()
  .trim()
  .max(120, "Organization must be at most 120 characters.");

export const selectedHobbiesSchema = z
  .array(z.enum(HUBS))
  .min(1, "Pick at least one hub to get started.")
  .max(8);

const latitudeSchema = z.number().min(-90).max(90);
const longitudeSchema = z.number().min(-180).max(180);
const MIN_AGE_YEARS = 13;

function isValidBirthday(value: string): boolean {
  const parsed = Date.parse(value);
  if (Number.isNaN(parsed)) {
    return false;
  }
  const date = new Date(parsed);
  const now = new Date();
  if (date > now || date < new Date("1900-01-01")) {
    return false;
  }
  const minAgeCutoff = new Date(
    now.getFullYear() - MIN_AGE_YEARS,
    now.getMonth(),
    now.getDate(),
  );
  return date <= minAgeCutoff;
}

export const profileDetailsSchema = z
  .object({
    username: usernameSchema,
    organization: organizationSchema,
    bio: z
      .string()
      .trim()
      .max(280, "Bio must be at most 280 characters.")
      .transform(stripControlChars),
    // Empty string means "not set" — mirrors the nullable DB column.
    birthday: z
      .string()
      .trim()
      .refine(
        (value) => value === "" || isValidBirthday(value),
        `Enter a valid birthday — you must be at least ${MIN_AGE_YEARS}.`,
      )
      .transform((value) => (value === "" ? null : value)),
    locationText: z
      .string()
      .trim()
      .max(120, "Location must be at most 120 characters.")
      .transform(stripControlChars),
    latitude: latitudeSchema.nullable().optional(),
    longitude: longitudeSchema.nullable().optional(),
  })
  .superRefine((data, ctx) => {
    const hasLat = data.latitude !== null && data.latitude !== undefined;
    const hasLng = data.longitude !== null && data.longitude !== undefined;
    if (hasLat !== hasLng) {
      ctx.addIssue({
        code: "custom",
        message: "Location coordinates are incomplete.",
        path: ["latitude"],
      });
    }
  });

export type ProfileDetailsInput = z.input<typeof profileDetailsSchema>;

export const hubsSchema = z.object({
  selectedHobbies: selectedHobbiesSchema,
});

export type HubsInput = z.infer<typeof hubsSchema>;

export const avatarUrlSchema = z.object({
  avatarUrl: z.url("Invalid avatar URL.").max(2048),
});

export type AvatarUrlInput = z.infer<typeof avatarUrlSchema>;
