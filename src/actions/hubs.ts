"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";
import { z } from "zod";

import { createClient } from "@/lib/supabase/server";
import { HUBS } from "@/types/database";

export type HubActionResult =
  | { status: "ok" }
  | { status: "error"; message: string };

const hubInputSchema = z.object({ hub: z.enum(HUBS) });

function revalidateHubPages(): void {
  revalidatePath("/profile");
  revalidatePath("/discover");
  revalidatePath("/home");
}

/**
 * Read-modify-write against selected_hobbies (a text[] column). Adds one hub
 * without disturbing the rest — the Discover page and hub pages call this
 * with a single hub rather than needing to know the caller's full list.
 */
export async function joinHubAction(input: unknown): Promise<HubActionResult> {
  const parsed = hubInputSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Invalid hub." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { data: profile, error: fetchError } = await supabase
    .from("profiles")
    .select("selected_hobbies")
    .eq("id", user.id)
    .maybeSingle();

  if (fetchError || !profile) {
    if (fetchError) {
      console.error("joinHubAction fetch failed:", fetchError.code, fetchError.message);
    }
    return { status: "error", message: "Could not load your profile." };
  }

  if (profile.selected_hobbies.includes(parsed.data.hub)) {
    return { status: "ok" };
  }

  const nextHobbies = [...profile.selected_hobbies, parsed.data.hub];
  const { error } = await supabase
    .from("profiles")
    .update({ selected_hobbies: nextHobbies })
    .eq("id", user.id);

  if (error) {
    console.error("joinHubAction update failed:", error.code, error.message);
    return { status: "error", message: "Could not join this hub. Please try again." };
  }

  revalidateHubPages();
  return { status: "ok" };
}

export async function leaveHubAction(
  input: unknown,
): Promise<HubActionResult> {
  const parsed = hubInputSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Invalid hub." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { data: profile, error: fetchError } = await supabase
    .from("profiles")
    .select("selected_hobbies")
    .eq("id", user.id)
    .maybeSingle();

  if (fetchError || !profile) {
    if (fetchError) {
      console.error("leaveHubAction fetch failed:", fetchError.code, fetchError.message);
    }
    return { status: "error", message: "Could not load your profile." };
  }

  const nextHobbies = profile.selected_hobbies.filter(
    (hub) => hub !== parsed.data.hub,
  );

  if (nextHobbies.length === 0) {
    return {
      status: "error",
      message: "You need at least one hub — join another before leaving this one.",
    };
  }

  const { error } = await supabase
    .from("profiles")
    .update({ selected_hobbies: nextHobbies })
    .eq("id", user.id);

  if (error) {
    console.error("leaveHubAction update failed:", error.code, error.message);
    return { status: "error", message: "Could not leave this hub. Please try again." };
  }

  revalidateHubPages();
  return { status: "ok" };
}
