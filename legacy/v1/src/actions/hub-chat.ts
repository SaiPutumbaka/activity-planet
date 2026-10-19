"use server";

import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";
import { hubMessageSchema } from "@/lib/validation/hub-chat";

export type HubChatActionResult =
  | { status: "ok" }
  | { status: "error"; message: string };

/**
 * Membership (hub is in the sender's selected_hobbies) is enforced by RLS
 * (see hub_messages_insert_members in migration 0003) — this action doesn't
 * duplicate that check, it just surfaces a friendly message if it fails.
 */
export async function sendHubMessageAction(
  input: unknown,
): Promise<HubChatActionResult> {
  const parsed = hubMessageSchema.safeParse(input);
  if (!parsed.success) {
    return { status: "error", message: "Message can't be empty." };
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) {
    redirect("/login");
  }

  const { error } = await supabase.from("hub_messages").insert({
    hub: parsed.data.hub,
    sender_id: user.id,
    body: parsed.data.body,
  });

  if (error) {
    console.error("sendHubMessageAction failed:", error.code, error.message);
    return {
      status: "error",
      message: "Join this hub to chat with other members.",
    };
  }

  return { status: "ok" };
}
