import type { AppSupabaseClient } from "../supabase/index";
import type { Database } from "../types/database";
import {
  chatListRowSchema,
  conversationInfoSchema,
  groupResultSchema,
  messageRowSchema,
  openRoomResultSchema,
  parseRows,
  personMetSchema,
  sendResultSchema,
  startDmResultSchema,
  unreadTotalSchema,
  type ChatListRow,
  type ChatMessage,
  type ConversationInfo,
  type GroupResult,
  type PersonMet,
  type SendResult,
  type StartDmResult,
  type UnreadTotal,
} from "./schemas";

/**
 * Typed calls for the messaging RPCs (migration 58). Every rule lives in the database; these
 * shape arguments, parse jsonb answers and throw the PostgREST error (its message is the code,
 * see errors.ts). send_message's filter refusal comes back as `{ error }`, not thrown.
 *
 *   const chat = createMessagingApi(supabase);
 *   await chat.chatList("requests");
 *   await chat.send(conversationId, crypto.randomUUID(), "On my way");
 */

export const MESSAGES_PAGE = 50;

export type ChatTab = "chats" | "requests";
export type RequestAction = "accept" | "decline";

/** Mute choices the app offers (design 7: 1 hour, 8 hours, 1 week, until turned back on). */
export const MUTE_CHOICES = [
  { key: "1h", label: "For 1 hour", ms: 60 * 60 * 1000 },
  { key: "8h", label: "For 8 hours", ms: 8 * 60 * 60 * 1000 },
  { key: "1w", label: "For 1 week", ms: 7 * 24 * 60 * 60 * 1000 },
  { key: "forever", label: "Until I turn it back on", ms: null },
] as const;
export type MuteChoice = (typeof MUTE_CHOICES)[number]["key"];

/** The p_until for a mute choice: an ISO time, or "infinity". */
export function muteUntil(choice: MuteChoice, now: Date = new Date()): string {
  const c = MUTE_CHOICES.find((m) => m.key === choice);
  if (!c || c.ms === null) return "infinity";
  return new Date(now.getTime() + c.ms).toISOString();
}

/** Whether a muted_until value is in force now ("infinity" always is). */
export function isMuted(mutedUntil: string | null | undefined, now: Date = new Date()): boolean {
  if (!mutedUntil) return false;
  if (mutedUntil === "infinity") return true;
  const t = new Date(mutedUntil).getTime();
  return Number.isFinite(t) && t > now.getTime();
}

export function createMessagingApi(client: AppSupabaseClient) {
  type RpcName = keyof Database["public"]["Functions"];
  async function rpcJson(fn: RpcName, args: Record<string, unknown>): Promise<unknown> {
    // Names are checked against the generated types; arguments are shaped by each wrapper
    // (some take null, which the generated Args do not say), and answers by the schemas.
    const { data, error } = await (
      client.rpc as unknown as (
        f: RpcName,
        a: Record<string, unknown>,
      ) => Promise<{ data: unknown; error: unknown }>
    )(fn, args);
    if (error) throw error;
    return data;
  }

  return {
    /**
     * Newest activity first. To page, pass the last row's activity_at as `before` and its
     * conversation_id as `beforeId` (rows with the same time are not skipped; migration 59).
     */
    async chatList(
      tab: ChatTab = "chats",
      before?: string | null,
      limit = 30,
      beforeId?: string | null,
    ) {
      const data = await rpcJson("chat_list", {
        p_tab: tab,
        p_limit: limit,
        ...(before ? { p_before: before } : {}),
        ...(before && beforeId ? { p_before_id: beforeId } : {}),
      });
      return parseRows(chatListRowSchema, data) satisfies ChatListRow[];
    },

    async unreadTotal(): Promise<UnreadTotal> {
      const data = await rpcJson("chat_unread_total", {});
      const p = unreadTotalSchema.safeParse(data);
      return p.success ? p.data : { chats: 0, requests: 0 };
    },

    /** Newest first. `before` pages back; `after` fetches what came since (for signals). */
    async messages(
      conversationId: string,
      opts: { before?: number | null; after?: number | null; limit?: number } = {},
    ): Promise<ChatMessage[]> {
      const data = await rpcJson("get_messages", {
        p_conversation: conversationId,
        p_limit: opts.limit ?? MESSAGES_PAGE,
        ...(opts.before != null ? { p_before_seq: opts.before } : {}),
        ...(opts.after != null ? { p_after_seq: opts.after } : {}),
      });
      return parseRows(messageRowSchema, data);
    },

    async info(conversationId: string): Promise<ConversationInfo> {
      const data = await rpcJson("conversation_info", { p_conversation: conversationId });
      return conversationInfoSchema.parse(data);
    },

    async startDm(userId: string): Promise<StartDmResult> {
      return startDmResultSchema.parse(await rpcJson("start_dm", { p_user: userId }));
    },

    async createGroup(title: string, userIds: string[]): Promise<GroupResult> {
      return groupResultSchema.parse(
        await rpcJson("create_group", { p_title: title, p_users: userIds }),
      );
    },

    async openEventChat(eventId: string): Promise<string> {
      return openRoomResultSchema.parse(await rpcJson("open_event_chat", { p_event: eventId }))
        .conversation_id;
    },

    async openHubChat(hubId: string): Promise<string> {
      return openRoomResultSchema.parse(await rpcJson("open_hub_chat", { p_hub: hubId }))
        .conversation_id;
    },

    async openChapterChat(chapterId: string): Promise<string> {
      return openRoomResultSchema.parse(
        await rpcJson("open_chapter_chat", { p_chapter: chapterId }),
      ).conversation_id;
    },

    /** Sends text, or a photo (an uploaded chat-images path, chatImagePath) with an optional caption. */
    async send(
      conversationId: string,
      clientId: string,
      body: string,
      imagePath?: string | null,
    ): Promise<SendResult> {
      return sendResultSchema.parse(
        await rpcJson("send_message", {
          p_conversation: conversationId,
          p_client_id: clientId,
          p_body: body,
          ...(imagePath ? { p_image_path: imagePath } : {}),
        }),
      );
    },

    async deleteMessage(messageId: string): Promise<void> {
      await rpcJson("delete_message", { p_message: messageId });
    },

    async markRead(conversationId: string, seq: number): Promise<void> {
      await rpcJson("mark_conversation_read", { p_conversation: conversationId, p_seq: seq });
    },

    /** null unmutes; "infinity" mutes until turned back on. */
    async mute(conversationId: string, until: string | null): Promise<void> {
      await rpcJson("mute_conversation", { p_conversation: conversationId, p_until: until });
    },

    async setNotify(conversationId: string, notify: boolean): Promise<void> {
      await rpcJson("set_conversation_notify", {
        p_conversation: conversationId,
        p_notify: notify,
      });
    },

    async respondRequest(conversationId: string, action: RequestAction): Promise<void> {
      await rpcJson("respond_message_request", {
        p_conversation: conversationId,
        p_action: action,
      });
    },

    async leave(conversationId: string): Promise<void> {
      await rpcJson("leave_conversation", { p_conversation: conversationId });
    },

    /** Newest shared plan first. To page, pass the last row's last_plan.starts_at and user_id. */
    async peopleYouMet(
      before?: string | null,
      limit = 30,
      beforeId?: string | null,
    ): Promise<PersonMet[]> {
      const data = await rpcJson("people_you_met", {
        p_limit: limit,
        ...(before ? { p_before: before } : {}),
        ...(before && beforeId ? { p_before_id: beforeId } : {}),
      });
      return parseRows(personMetSchema, data);
    },
  };
}

export type MessagingApi = ReturnType<typeof createMessagingApi>;
