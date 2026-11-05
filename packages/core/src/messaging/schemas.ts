import { z } from "zod";

/**
 * Shapes of the messaging RPC results (migration 58). The generated types call every jsonb
 * column `Json`; these schemas give them their real shape and drop anything malformed.
 */

export const CONVERSATION_KINDS = ["dm", "group", "event", "hub", "chapter"] as const;
export const conversationKindSchema = z.enum(CONVERSATION_KINDS);
export type ConversationKind = z.infer<typeof conversationKindSchema>;

export const conversationRoleSchema = z.enum(["owner", "admin", "member"]);
export type ConversationRole = z.infer<typeof conversationRoleSchema>;

const uuid = z.string().min(1);
const nullableString = z
  .string()
  .nullish()
  .transform((v) => v ?? null);

export const chatPersonSchema = z.object({
  id: uuid,
  first_name: z.string().catch("Member"),
  handle: nullableString,
  avatar_url: nullableString,
});
export type ChatPerson = z.infer<typeof chatPersonSchema>;

export const lastMessageSchema = z.object({
  preview: z.string().catch(""),
  at: z.string(),
  mine: z.boolean().catch(false),
  kind: z.string().catch("text"),
});
export type LastMessage = z.infer<typeof lastMessageSchema>;

export const chatContextSchema = z
  .object({
    event_id: z.string().optional(),
    starts_at: z.string().optional(),
    ends_at: z.string().optional(),
    status: z.string().optional(),
    hub_id: z.string().optional(),
    slug: z.string().optional(),
    emoji: z.string().nullish(),
    chapter_id: z.string().optional(),
  })
  .passthrough();
export type ChatContext = z.infer<typeof chatContextSchema>;

export const requestSideSchema = z.enum(["sent", "received"]);
export type RequestSide = z.infer<typeof requestSideSchema>;

export const chatListRowSchema = z.object({
  conversation_id: uuid,
  kind: conversationKindSchema,
  title: nullableString,
  other: chatPersonSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  context: chatContextSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  last_message: lastMessageSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  unread: z.number().int().nonnegative().catch(0),
  muted: z.boolean().catch(false),
  closed: z.boolean().catch(false),
  request: requestSideSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  activity_at: z.string(),
});
export type ChatListRow = z.infer<typeof chatListRowSchema>;

export const unreadTotalSchema = z.object({
  chats: z.number().int().nonnegative().catch(0),
  requests: z.number().int().nonnegative().catch(0),
});
export type UnreadTotal = z.infer<typeof unreadTotalSchema>;

export const DELETED_BY = ["author", "room_admin", "moderator"] as const;

export const messageRowSchema = z.object({
  id: uuid,
  seq: z.number().int(),
  author: z
    .object({ id: uuid, first_name: z.string().catch("Member"), avatar_url: nullableString })
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  kind: z.enum(["text", "image", "system"]).catch("text"),
  body: z.string().catch(""),
  image: z
    .object({ state: z.string().nullish(), path: z.string().nullish() })
    .nullish()
    .catch(null)
    .transform((v) => (v ? { state: v.state ?? null, path: v.path ?? null } : null)),
  created_at: z.string(),
  deleted: z
    .enum(DELETED_BY)
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  hidden: z.boolean().catch(false),
  mine: z.boolean().catch(false),
  client_id: nullableString,
});
export type ChatMessage = z.infer<typeof messageRowSchema>;

export const conversationMemberSchema = chatPersonSchema.extend({
  role: conversationRoleSchema.catch("member"),
});
export type ConversationMember = z.infer<typeof conversationMemberSchema>;

export const conversationInfoSchema = z.object({
  conversation_id: uuid,
  kind: conversationKindSchema,
  title: nullableString,
  role: conversationRoleSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  members: z
    .array(conversationMemberSchema)
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  member_count: z
    .number()
    .int()
    .nullish()
    .transform((v) => v ?? 0),
  admins: z
    .array(chatPersonSchema.partial({ avatar_url: true }))
    .nullish()
    .catch([])
    .transform((v) => v ?? []),
  other: chatPersonSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  event_id: nullableString,
  hub_id: nullableString,
  chapter_id: nullableString,
  muted_until: nullableString,
  notify: z.boolean().catch(true),
  last_read_seq: z.number().catch(0),
  last_seq: z.number().catch(0),
  can_post: nullableString,
  images_enabled: z.boolean().catch(false),
  request: requestSideSchema
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
});
export type ConversationInfo = z.infer<typeof conversationInfoSchema>;

export const startDmResultSchema = z.object({
  conversation_id: uuid,
  state: z.enum(["open", "request", "request_pending"]),
});
export type StartDmResult = z.infer<typeof startDmResultSchema>;

export const sendResultSchema = z.union([
  z.object({
    id: uuid,
    seq: z.number().int(),
    created_at: z.string(),
    duplicate: z.boolean().catch(false),
  }),
  z.object({ error: z.string() }),
]);
export type SendResult = z.infer<typeof sendResultSchema>;

export const openRoomResultSchema = z.object({ conversation_id: uuid });

export const groupResultSchema = z.object({
  conversation_id: uuid,
  added: z.number().int().catch(0),
  skipped: z.number().int().catch(0),
});
export type GroupResult = z.infer<typeof groupResultSchema>;

export const personMetSchema = z.object({
  user_id: uuid,
  handle: nullableString,
  first_name: z.string().catch("Member"),
  avatar_url: nullableString,
  last_plan: z
    .object({ id: z.string(), title: z.string().catch(""), starts_at: z.string() })
    .nullish()
    .catch(null)
    .transform((v) => v ?? null),
  can_message: z.boolean().catch(false),
});
export type PersonMet = z.infer<typeof personMetSchema>;

/* Realtime payloads. Signals carry ids only (design 5.2); anything else is ignored. */

export const messageSignalSchema = z.object({
  conversation_id: uuid,
  message_id: z.string().optional(),
  seq: z.number().int(),
  op: z.string().optional(),
});
export type MessageSignal = z.infer<typeof messageSignalSchema>;

export const chatActivitySchema = z.object({
  conversation_id: uuid,
  seq: z.number().int().optional(),
});
export type ChatActivity = z.infer<typeof chatActivitySchema>;

export const typingSignalSchema = z.object({
  user_id: uuid,
  first_name: z.string().max(80).optional(),
});
export type TypingSignal = z.infer<typeof typingSignalSchema>;

/** Parses a list, keeping the rows that fit and dropping the rest. */
export function parseRows<T>(schema: z.ZodType<T>, rows: unknown): T[] {
  if (!Array.isArray(rows)) return [];
  const out: T[] = [];
  for (const r of rows) {
    const p = schema.safeParse(r);
    if (p.success) out.push(p.data);
  }
  return out;
}
