"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { getSupabaseUrl } from "@/lib/env";
import { createClient } from "@/lib/supabase/server";
import {
  avatarUrlSchema,
  hubsSchema,
  profileDetailsSchema,
} from "@/lib/validation/profile";

export type ProfileActionResult =
  | { status: "ok" }
  | { status: "error"; message: string };

const UNIQUE_VIOLATION = "23505";

function revalidateProfilePages(): void {
  revalidatePath("/profile");
  revalidatePath("/profile/edit");
  revalidatePath("/discover");
}

export async function updateProfileAction(
  input: unknown,
): Promise<ProfileActionResult> {
  const parsed = profileDetailsSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Please fix the errors and try again." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { error } = await supabase
    .from("profiles")
    .update({
      username: parsed.data.username,
      full_name: parsed.data.fullName,
      organization: parsed.data.organization,
      bio: parsed.data.bio,
      birthday: parsed.data.birthday,
      location_text: parsed.data.locationText,
      latitude: parsed.data.latitude ?? null,
      longitude: parsed.data.longitude ?? null,
    })
    .eq("id", user.id);

  if (error) {
    if (error.code === UNIQUE_VIOLATION) {
      return {
        status: "error",
        message: "That username is already taken. Try another one.",
      };
    }
    console.error("updateProfileAction failed:", error.code, error.message);
    return {
      status: "error",
      message: "Something went wrong saving your profile. Please try again.",
    };
  }

  revalidateProfilePages();
  return { status: "ok" };
}

export async function updateHubsAction(
  input: unknown,
): Promise<ProfileActionResult> {
  const parsed = hubsSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Pick at least one hub." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { error } = await supabase
    .from("profiles")
    .update({ selected_hobbies: parsed.data.selectedHobbies })
    .eq("id", user.id);

  if (error) {
    console.error("updateHubsAction failed:", error.code, error.message);
    return {
      status: "error",
      message: "Could not update your hubs. Please try again.",
    };
  }

  revalidateProfilePages();
  revalidatePath("/home");
  return { status: "ok" };
}

/**
 * Persists an avatar's public URL after the browser has already uploaded the
 * file to Supabase Storage (RLS restricts writes to the caller's own
 * `avatars/<user_id>/` folder — see migration 0003). This re-checks that the
 * URL actually points into that folder before trusting it, in case a
 * tampered client ever sends an arbitrary URL.
 */
export async function updateAvatarAction(
  input: unknown,
): Promise<ProfileActionResult> {
  const parsed = avatarUrlSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Invalid image." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const expectedPrefix = `${getSupabaseUrl()}/storage/v1/object/public/avatars/${user.id}/`;
  if (!parsed.data.avatarUrl.startsWith(expectedPrefix)) {
    return { status: "error", message: "That image doesn't belong to you." };
  }

  const { error } = await supabase
    .from("profiles")
    .update({ avatar_url: parsed.data.avatarUrl })
    .eq("id", user.id);

  if (error) {
    console.error("updateAvatarAction failed:", error.code, error.message);
    return {
      status: "error",
      message: "Could not save your photo. Please try again.",
    };
  }

  revalidateProfilePages();
  return { status: "ok" };
}
