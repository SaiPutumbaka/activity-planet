"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import {
  createEventSchema,
  deleteEventSchema,
  rsvpSchema,
} from "@/lib/validation/event";

export type EventActionResult =
  | { status: "ok" }
  | { status: "error"; message: string };

const DUPLICATE_KEY = "23505";

function revalidateEventPages(): void {
  revalidatePath("/home");
  revalidatePath("/discover");
  revalidatePath("/profile");
}

export async function createEventAction(
  input: unknown,
): Promise<EventActionResult> {
  const parsed = createEventSchema.safeParse(input);
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

  // RLS enforces creator_id = auth.uid(); a forged payload cannot post as
  // someone else. Values reach Postgres as bound parameters — no injection.
  const { error } = await supabase.from("events").insert({
    creator_id: user.id,
    title: parsed.data.title,
    description: parsed.data.description,
    category: parsed.data.category,
    location: parsed.data.location,
    latitude: parsed.data.latitude ?? null,
    longitude: parsed.data.longitude ?? null,
    event_timestamp: new Date(parsed.data.eventTimestamp).toISOString(),
  });

  if (error) {
    return {
      status: "error",
      message: "Could not create the event. Please try again.",
    };
  }

  revalidateEventPages();
  redirect("/home");
}

export async function rsvpAction(input: unknown): Promise<EventActionResult> {
  const parsed = rsvpSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Invalid request." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  if (parsed.data.attend) {
    const { error } = await supabase.from("rsvps").insert({
      event_id: parsed.data.eventId,
      user_id: user.id,
    });
    // Already joined (double tap / stale UI) is not an error.
    if (error && error.code !== DUPLICATE_KEY) {
      return {
        status: "error",
        message: "Could not join this event. Please try again.",
      };
    }
  } else {
    const { error } = await supabase
      .from("rsvps")
      .delete()
      .eq("event_id", parsed.data.eventId)
      .eq("user_id", user.id);
    if (error) {
      return {
        status: "error",
        message: "Could not leave this event. Please try again.",
      };
    }
  }

  revalidateEventPages();
  return { status: "ok" };
}

export async function deleteEventAction(
  input: unknown,
): Promise<EventActionResult> {
  const parsed = deleteEventSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Invalid request." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  // RLS only allows deleting rows where creator_id = auth.uid(); deleting
  // someone else's event silently affects zero rows.
  const { error } = await supabase
    .from("events")
    .delete()
    .eq("id", parsed.data.eventId);

  if (error) {
    return {
      status: "error",
      message: "Could not delete the event. Please try again.",
    };
  }

  revalidateEventPages();
  return { status: "ok" };
}
