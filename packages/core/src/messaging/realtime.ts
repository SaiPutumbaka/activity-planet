import type { RealtimeChannel } from "@supabase/supabase-js";

import type { AppSupabaseClient } from "../supabase/index";
import {
  chatActivitySchema,
  messageSignalSchema,
  typingSignalSchema,
  type ChatActivity,
  type MessageSignal,
  type TypingSignal,
} from "./schemas";

/**
 * Realtime Broadcast on private channels (design section 5). The database sends thin signals
 * (ids and seq, never a body); the client then reads through get_messages, which applies every
 * rule at read time. Clients send only `typing`, and only on conv: topics they can post in.
 *
 *   const sub = subscribeConversation(supabase, id, { onMessage, onUpdate, onTyping, onStatus });
 *   sub.sendTyping({ user_id, first_name });
 *   sub.unsubscribe();
 */

export function conversationTopic(conversationId: string): string {
  return `conv:${conversationId}`;
}

export function userChatsTopic(userId: string): string {
  return `user:${userId}:chats`;
}

/** Send typing at most this often while the composer changes. */
export const TYPING_SEND_MS = 3000;
/** A typing line disappears this long after the last signal. */
export const TYPING_TTL_MS = 5000;
/** Poll fallback while a channel is not SUBSCRIBED. */
export const CHAT_POLL_MS = 30_000;

export type ChannelStatus = "SUBSCRIBED" | "TIMED_OUT" | "CLOSED" | "CHANNEL_ERROR" | "JOINING";

export interface ConversationHandlers {
  onMessage?: (signal: MessageSignal) => void;
  onUpdate?: (signal: MessageSignal) => void;
  onTyping?: (signal: TypingSignal) => void;
  onStatus?: (status: ChannelStatus) => void;
}

export interface UserChatsHandlers {
  onActivity?: (signal: ChatActivity) => void;
  onRequest?: (signal: ChatActivity) => void;
  onStatus?: (status: ChannelStatus) => void;
}

export interface Subscription {
  channel: RealtimeChannel;
  unsubscribe: () => void;
}

export interface ConversationSubscription extends Subscription {
  sendTyping: (signal: TypingSignal) => void;
}

/** A broadcast's payload, validated; null for anything that does not fit. */
export function readSignal<T>(
  schema: { safeParse: (v: unknown) => { success: true; data: T } | { success: false } },
  message: unknown,
): T | null {
  const payload =
    message && typeof message === "object" && "payload" in message
      ? (message as { payload: unknown }).payload
      : null;
  const p = schema.safeParse(payload);
  return p.success ? p.data : null;
}

function privateChannel(client: AppSupabaseClient, topic: string): RealtimeChannel {
  return client.channel(topic, { config: { private: true, broadcast: { self: false } } });
}

async function authorize(client: AppSupabaseClient): Promise<void> {
  try {
    await client.realtime.setAuth();
  } catch {
    /* the socket uses the client's session anyway */
  }
}

/** The conv:<id> channel: new messages, updates and typing from other members. */
export function subscribeConversation(
  client: AppSupabaseClient,
  conversationId: string,
  handlers: ConversationHandlers,
): ConversationSubscription {
  const topic = conversationTopic(conversationId);
  const channel = privateChannel(client, topic);
  let closed = false;
  channel
    .on("broadcast", { event: "msg" }, (m) => {
      const s = readSignal(messageSignalSchema, m);
      if (s && s.conversation_id === conversationId) handlers.onMessage?.(s);
    })
    .on("broadcast", { event: "msg_update" }, (m) => {
      const s = readSignal(messageSignalSchema, m);
      if (s && s.conversation_id === conversationId) handlers.onUpdate?.(s);
    })
    .on("broadcast", { event: "typing" }, (m) => {
      const s = readSignal(typingSignalSchema, m);
      if (s) handlers.onTyping?.(s);
    });
  void authorize(client).then(() => {
    if (closed) return;
    channel.subscribe((status) => handlers.onStatus?.(status as ChannelStatus));
  });
  return {
    channel,
    sendTyping(signal) {
      if (closed) return;
      void channel.send({ type: "broadcast", event: "typing", payload: signal }).catch(() => {});
    },
    unsubscribe() {
      closed = true;
      void client.removeChannel(channel);
    },
  };
}

/** The user:<uid>:chats channel: news in a dm or group, and requests to the user. */
export function subscribeUserChats(
  client: AppSupabaseClient,
  userId: string,
  handlers: UserChatsHandlers,
): Subscription {
  const channel = privateChannel(client, userChatsTopic(userId));
  let closed = false;
  channel
    .on("broadcast", { event: "chat_activity" }, (m) => {
      const s = readSignal(chatActivitySchema, m);
      if (s) handlers.onActivity?.(s);
    })
    .on("broadcast", { event: "request" }, (m) => {
      const s = readSignal(chatActivitySchema, m);
      if (s) handlers.onRequest?.(s);
    });
  void authorize(client).then(() => {
    if (closed) return;
    channel.subscribe((status) => handlers.onStatus?.(status as ChannelStatus));
  });
  return {
    channel,
    unsubscribe() {
      closed = true;
      void client.removeChannel(channel);
    },
  };
}

/**
 * Typing state: who is typing now, from signals, filtered to people the viewer can see in the
 * room (a forged id for a stranger shows nothing). Pure, so the hook stays small.
 */
export function typingNames(
  seen: ReadonlyMap<string, { name: string; at: number }>,
  allowed: ReadonlySet<string>,
  selfId: string,
  now: number,
): string[] {
  const out: string[] = [];
  for (const [id, v] of seen) {
    if (id === selfId || !allowed.has(id)) continue;
    if (now - v.at <= TYPING_TTL_MS) out.push(v.name);
  }
  return out.sort();
}

/** "Sam is typing", "Sam and Ana are typing", "3 people are typing", or null. */
export function typingLine(names: readonly string[]): string | null {
  if (names.length === 0) return null;
  if (names.length === 1) return `${names[0]} is typing`;
  if (names.length === 2) return `${names[0]} and ${names[1]} are typing`;
  return `${names.length} people are typing`;
}
