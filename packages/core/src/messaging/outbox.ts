import type { ChatMessage } from "./schemas";

/**
 * The optimistic outbox (design 14.2). Each bubble the composer shows before the server answers
 * is an OutboxItem keyed by its client id; the same client id goes with every retry, so the
 * server never stores it twice. Kept in memory only (no message text in browser storage).
 *
 *   sending --sent--> sent (dropped once the server row is in the history)
 *   sending --failed--> failed --retry--> sending
 */

export type OutboxState = "sending" | "failed" | "sent";

export interface OutboxItem {
  clientId: string;
  conversationId: string;
  body: string;
  state: OutboxState;
  attempts: number;
  createdAt: string;
  /** The server row once sent. */
  id?: string;
  seq?: number;
}

export type OutboxAction =
  | { type: "add"; item: Pick<OutboxItem, "clientId" | "conversationId" | "body" | "createdAt"> }
  | { type: "attempt"; clientId: string }
  | { type: "sent"; clientId: string; id: string; seq: number; createdAt?: string }
  | { type: "failed"; clientId: string }
  | { type: "retry"; clientId: string }
  | { type: "remove"; clientId: string }
  /** Drops sent items whose server row the history now holds. */
  | { type: "reconcile"; messages: readonly Pick<ChatMessage, "id" | "client_id">[] };

export function outboxReducer(state: readonly OutboxItem[], action: OutboxAction): OutboxItem[] {
  switch (action.type) {
    case "add":
      if (state.some((i) => i.clientId === action.item.clientId)) return [...state];
      return [...state, { ...action.item, state: "sending", attempts: 0 }];
    case "attempt":
      return state.map((i) =>
        i.clientId === action.clientId ? { ...i, state: "sending", attempts: i.attempts + 1 } : i,
      );
    case "sent":
      return state.map((i) =>
        i.clientId === action.clientId
          ? {
              ...i,
              state: "sent",
              id: action.id,
              seq: action.seq,
              createdAt: action.createdAt ?? i.createdAt,
            }
          : i,
      );
    case "failed":
      return state.map((i) =>
        i.clientId === action.clientId && i.state !== "sent" ? { ...i, state: "failed" } : i,
      );
    case "retry":
      return state.map((i) =>
        i.clientId === action.clientId && i.state === "failed"
          ? { ...i, state: "sending", attempts: 0 }
          : i,
      );
    case "remove":
      return state.filter((i) => i.clientId !== action.clientId);
    case "reconcile": {
      const ids = new Set(action.messages.map((m) => m.id));
      const clientIds = new Set(action.messages.map((m) => m.client_id).filter(Boolean));
      return state.filter(
        (i) => !(i.state === "sent" && ((i.id && ids.has(i.id)) || clientIds.has(i.clientId))),
      );
    }
  }
}

/** Newest first, one row per id; a later copy of a row (an update) wins. */
export function mergeMessages(...lists: readonly (readonly ChatMessage[])[]): ChatMessage[] {
  const byId = new Map<string, ChatMessage>();
  for (const list of lists) for (const m of list) byId.set(m.id, m);
  return [...byId.values()].sort((a, b) => b.seq - a.seq);
}

/** The highest seq in a newest-first list, or 0. */
export function highestSeq(messages: readonly Pick<ChatMessage, "seq">[]): number {
  let max = 0;
  for (const m of messages) if (m.seq > max) max = m.seq;
  return max;
}

/** Outbox items still to show beside the history: not yet in it, in send order. */
export function pendingBubbles(
  outbox: readonly OutboxItem[],
  conversationId: string,
  messages: readonly Pick<ChatMessage, "id" | "client_id">[],
): OutboxItem[] {
  const ids = new Set(messages.map((m) => m.id));
  const clientIds = new Set(messages.map((m) => m.client_id).filter(Boolean));
  return outbox.filter(
    (i) =>
      i.conversationId === conversationId && !clientIds.has(i.clientId) && !(i.id && ids.has(i.id)),
  );
}

/** Backoff before retry n (1-based) after a network error: 1 s, 2 s, 4 s. */
export function retryDelayMs(attempt: number): number {
  return 1000 * 2 ** Math.max(0, attempt - 1);
}

/** How many times a network failure is retried before the bubble says "Not sent". */
export const SEND_TRIES = 3;
