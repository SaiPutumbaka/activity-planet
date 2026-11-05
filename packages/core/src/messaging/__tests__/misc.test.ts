import { describe, expect, it, vi } from "vitest";

import { createMessagingApi, isMuted, muteUntil } from "../api";
import { chatTitle, chatPreview, removedLabel, unreadLabel } from "../display";
import { chatError, chatErrorMessage, composerNotice, isNetworkError } from "../errors";
import {
  conversationTopic,
  readSignal,
  typingLine,
  typingNames,
  userChatsTopic,
  TYPING_TTL_MS,
} from "../realtime";
import {
  chatListRowSchema,
  messageRowSchema,
  messageSignalSchema,
  parseRows,
  typingSignalSchema,
} from "../schemas";

describe("topics", () => {
  it("builds the topics the realtime policies check", () => {
    expect(conversationTopic("abc")).toBe("conv:abc");
    expect(userChatsTopic("u1")).toBe("user:u1:chats");
  });
});

describe("signals", () => {
  it("accepts id-only payloads and ignores anything else", () => {
    expect(
      readSignal(messageSignalSchema, {
        payload: { conversation_id: "c", message_id: "m", seq: 3, op: "insert" },
      }),
    ).toMatchObject({ seq: 3 });
    expect(readSignal(messageSignalSchema, { payload: { body: "hi" } })).toBeNull();
    expect(readSignal(typingSignalSchema, { payload: { user_id: 5 } })).toBeNull();
    expect(readSignal(typingSignalSchema, null)).toBeNull();
  });

  it("shows typing only for members the viewer can see, and only while fresh", () => {
    const seen = new Map([
      ["a", { name: "Sam", at: 1000 }],
      ["b", { name: "Ana", at: 1000 }],
      ["x", { name: "Forged", at: 1000 }],
      ["me", { name: "Me", at: 1000 }],
    ]);
    const allowed = new Set(["a", "b", "me"]);
    expect(typingNames(seen, allowed, "me", 2000)).toEqual(["Ana", "Sam"]);
    expect(typingNames(seen, allowed, "me", 1000 + TYPING_TTL_MS + 1)).toEqual([]);
    expect(typingLine(["Sam"])).toBe("Sam is typing");
    expect(typingLine(["Ana", "Sam"])).toBe("Ana and Sam are typing");
    expect(typingLine(["a", "b", "c"])).toBe("3 people are typing");
    expect(typingLine([])).toBeNull();
  });
});

describe("schemas", () => {
  it("parses chat_list rows and drops malformed ones", () => {
    const rows = parseRows(chatListRowSchema, [
      {
        conversation_id: "c1",
        kind: "dm",
        title: null,
        other: { id: "u2", first_name: "Sam", handle: "sam", avatar_url: null },
        context: null,
        last_message: { preview: "hi", at: "2026-11-05T10:00:00Z", mine: true, kind: "text" },
        unread: 2,
        muted: false,
        closed: false,
        request: null,
        activity_at: "2026-11-05T10:00:00Z",
      },
      { kind: "nope" },
    ]);
    expect(rows).toHaveLength(1);
    expect(chatTitle(rows[0]!)).toBe("Sam");
    expect(chatPreview(rows[0]!)).toBe("You: hi");
  });

  it("parses get_messages rows with nulls", () => {
    const m = messageRowSchema.parse({
      id: "m1",
      seq: 1,
      author: null,
      kind: "text",
      body: "",
      image: null,
      created_at: "2026-11-05T10:00:00Z",
      deleted: "author",
      hidden: false,
      mine: false,
      client_id: null,
    });
    expect(removedLabel(m)).toBe("Message deleted");
  });
});

describe("display", () => {
  it("labels unread counts and fallbacks", () => {
    expect(unreadLabel(0)).toBeNull();
    expect(unreadLabel(5)).toBe("5");
    expect(unreadLabel(99)).toBe("99+");
    expect(chatTitle({ kind: "dm", title: null, other: null })).toBe("Deleted user");
    expect(chatTitle({ kind: "event", title: "Saturday run", other: null })).toBe("Saturday run");
    expect(chatPreview({ last_message: null, request: "sent" })).toBe("Request sent");
  });
});

describe("errors", () => {
  it("reads the code and the wait hint", () => {
    expect(chatError({ message: "slow_mode", hint: "7" })).toEqual({
      code: "slow_mode",
      waitSeconds: 7,
    });
    expect(chatErrorMessage({ message: "slow_mode", hint: "7" })).toContain("7 seconds");
    expect(chatErrorMessage({ message: "rate_limited", hint: "3600" })).toContain("an hour");
    expect(chatErrorMessage({ error: "message_filtered" })).toContain("Community Guidelines");
    expect(chatErrorMessage({ message: "photo_required" })).toContain("profile photo");
    expect(chatErrorMessage({ message: "who knows" })).toBe("Something went wrong. Try again.");
  });

  it("tells network failures from rules", () => {
    expect(isNetworkError(new TypeError("Failed to fetch"))).toBe(true);
    expect(isNetworkError({ message: "rate_limited" })).toBe(false);
    expect(isNetworkError({ message: "", status: 503 })).toBe(true);
  });

  it("has composer copy for every can_post code and none when open", () => {
    expect(composerNotice(null)).toBeNull();
    for (const c of [
      "photo_required",
      "account_too_new",
      "conversation_closed",
      "read_only",
      "request_pending",
      "onboarding_required",
      "forbidden",
      "not_found",
      "something_new",
    ]) {
      expect(composerNotice(c)).toBeTruthy();
    }
    // A closed conversation never says why (a block reads like a deleted account).
    expect(composerNotice("conversation_closed")).not.toMatch(/block/i);
  });
});

describe("mute", () => {
  it("computes p_until and reads muted_until", () => {
    const now = new Date("2026-11-05T10:00:00Z");
    expect(muteUntil("1h", now)).toBe("2026-11-05T11:00:00.000Z");
    expect(muteUntil("forever", now)).toBe("infinity");
    expect(isMuted("infinity", now)).toBe(true);
    expect(isMuted("2026-11-05T09:00:00Z", now)).toBe(false);
    expect(isMuted(null, now)).toBe(false);
  });
});

describe("createMessagingApi", () => {
  function fakeClient(data: unknown, error: unknown = null) {
    const rpc = vi.fn().mockResolvedValue({ data, error });
    return { rpc, client: { rpc } as never };
  }

  it("calls get_messages with the cursor and parses rows", async () => {
    const { rpc, client } = fakeClient([
      {
        id: "m1",
        seq: 7,
        author: { id: "u", first_name: "Sam", avatar_url: null },
        kind: "text",
        body: "hi",
        image: null,
        created_at: "2026-11-05T10:00:00Z",
        deleted: null,
        hidden: false,
        mine: false,
        client_id: null,
      },
    ]);
    const api = createMessagingApi(client);
    const rows = await api.messages("c1", { before: 8 });
    expect(rpc).toHaveBeenCalledWith("get_messages", {
      p_conversation: "c1",
      p_limit: 50,
      p_before_seq: 8,
    });
    expect(rows[0]?.seq).toBe(7);
  });

  it("returns a filter refusal from send_message instead of throwing", async () => {
    const { client } = fakeClient({ error: "message_filtered" });
    const r = await createMessagingApi(client).send("c1", "k", "x");
    expect("error" in r && r.error).toBe("message_filtered");
  });

  it("throws the PostgREST error so callers can read its code", async () => {
    const { client } = fakeClient(null, { message: "request_pending" });
    await expect(createMessagingApi(client).send("c1", "k", "x")).rejects.toMatchObject({
      message: "request_pending",
    });
  });

  it("parses start_dm and the unread total", async () => {
    const a = fakeClient({ conversation_id: "c1", state: "request" });
    expect(await createMessagingApi(a.client).startDm("u2")).toEqual({
      conversation_id: "c1",
      state: "request",
    });
    const b = fakeClient({ chats: 3, requests: 1 });
    expect(await createMessagingApi(b.client).unreadTotal()).toEqual({ chats: 3, requests: 1 });
    const c = fakeClient(null);
    expect(await createMessagingApi(c.client).unreadTotal()).toEqual({ chats: 0, requests: 0 });
  });
});
