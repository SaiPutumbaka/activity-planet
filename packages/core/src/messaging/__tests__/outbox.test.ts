import { describe, expect, it } from "vitest";

import {
  highestSeq,
  mergeMessages,
  outboxReducer,
  pendingBubbles,
  retryDelayMs,
  type OutboxItem,
} from "../outbox";
import type { ChatMessage } from "../schemas";

const msg = (seq: number, extra: Partial<ChatMessage> = {}): ChatMessage => ({
  id: `m${seq}`,
  seq,
  author: { id: "u1", first_name: "Sam", avatar_url: null },
  kind: "text",
  body: `body ${seq}`,
  image: null,
  created_at: "2026-11-05T10:00:00Z",
  deleted: null,
  hidden: false,
  mine: false,
  client_id: null,
  ...extra,
});

const add = (clientId: string) =>
  ({
    type: "add",
    item: { clientId, conversationId: "c1", body: "hi", createdAt: "2026-11-05T10:00:00Z" },
  }) as const;

describe("outboxReducer", () => {
  it("adds once per client id (a double tap does not make two bubbles)", () => {
    const s = outboxReducer(outboxReducer([], add("a")), add("a"));
    expect(s).toHaveLength(1);
    expect(s[0]?.state).toBe("sending");
  });

  it("goes sending to sent with the server id and seq", () => {
    let s: OutboxItem[] = outboxReducer([], add("a"));
    s = outboxReducer(s, { type: "attempt", clientId: "a" });
    s = outboxReducer(s, { type: "sent", clientId: "a", id: "m9", seq: 9 });
    expect(s[0]).toMatchObject({ state: "sent", id: "m9", seq: 9, attempts: 1 });
  });

  it("fails, retries with the same client id, and never un-sends", () => {
    let s: OutboxItem[] = outboxReducer([], add("a"));
    s = outboxReducer(s, { type: "failed", clientId: "a" });
    expect(s[0]?.state).toBe("failed");
    s = outboxReducer(s, { type: "retry", clientId: "a" });
    expect(s[0]).toMatchObject({ state: "sending", clientId: "a", attempts: 0 });
    s = outboxReducer(s, { type: "sent", clientId: "a", id: "m1", seq: 1 });
    s = outboxReducer(s, { type: "failed", clientId: "a" });
    expect(s[0]?.state).toBe("sent");
  });

  it("drops sent items once the history holds them, by id or client id", () => {
    let s: OutboxItem[] = outboxReducer(outboxReducer([], add("a")), add("b"));
    s = outboxReducer(s, { type: "sent", clientId: "a", id: "m1", seq: 1 });
    s = outboxReducer(s, { type: "sent", clientId: "b", id: "m2", seq: 2 });
    s = outboxReducer(s, {
      type: "reconcile",
      messages: [msg(1), msg(2, { id: "other", client_id: "b" })],
    });
    expect(s).toHaveLength(0);
  });

  it("removes an item (a rule error puts the text back in the composer)", () => {
    expect(outboxReducer(outboxReducer([], add("a")), { type: "remove", clientId: "a" })).toEqual(
      [],
    );
  });
});

describe("mergeMessages", () => {
  it("merges pages newest first without repeats; a later copy wins", () => {
    const merged = mergeMessages([msg(3), msg(2)], [msg(2, { body: "edited" }), msg(1)], [msg(4)]);
    expect(merged.map((m) => m.seq)).toEqual([4, 3, 2, 1]);
    expect(merged.find((m) => m.seq === 2)?.body).toBe("edited");
    expect(highestSeq(merged)).toBe(4);
    expect(highestSeq([])).toBe(0);
  });
});

describe("pendingBubbles", () => {
  it("shows outbox items of this conversation that the history does not hold", () => {
    let s: OutboxItem[] = outboxReducer(outboxReducer([], add("a")), add("b"));
    s = outboxReducer(s, { type: "sent", clientId: "a", id: "m1", seq: 1 });
    expect(pendingBubbles(s, "c1", [msg(1)]).map((i) => i.clientId)).toEqual(["b"]);
    expect(pendingBubbles(s, "other", [])).toEqual([]);
  });
});

describe("retryDelayMs", () => {
  it("backs off 1 s, 2 s, 4 s", () => {
    expect([1, 2, 3].map(retryDelayMs)).toEqual([1000, 2000, 4000]);
  });
});
