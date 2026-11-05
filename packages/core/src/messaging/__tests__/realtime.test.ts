import { describe, expect, it, vi } from "vitest";

import { subscribeConversation, subscribeUserChats } from "../realtime";

type Handler = (m: unknown) => void;

function fakeClient() {
  const handlers = new Map<string, Handler>();
  const channel = {
    on: vi.fn((_type: string, filter: { event: string }, cb: Handler) => {
      handlers.set(filter.event, cb);
      return channel;
    }),
    subscribe: vi.fn((cb: (s: string) => void) => {
      cb("SUBSCRIBED");
      return channel;
    }),
    send: vi.fn().mockResolvedValue("ok"),
  };
  const client = {
    channel: vi.fn(() => channel),
    removeChannel: vi.fn().mockResolvedValue("ok"),
    realtime: { setAuth: vi.fn().mockResolvedValue(undefined) },
  };
  return { client, channel, handlers };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("subscribeConversation", () => {
  it("joins conv:<id> as a private channel and routes valid signals only", async () => {
    const { client, channel, handlers } = fakeClient();
    const onMessage = vi.fn();
    const onUpdate = vi.fn();
    const onTyping = vi.fn();
    const onStatus = vi.fn();
    const sub = subscribeConversation(client as never, "c1", {
      onMessage,
      onUpdate,
      onTyping,
      onStatus,
    });
    expect(client.channel).toHaveBeenCalledWith("conv:c1", {
      config: { private: true, broadcast: { self: false } },
    });
    await flush();
    expect(client.realtime.setAuth).toHaveBeenCalled();
    expect(onStatus).toHaveBeenCalledWith("SUBSCRIBED");

    handlers.get("msg")?.({ payload: { conversation_id: "c1", message_id: "m", seq: 4 } });
    handlers.get("msg")?.({ payload: { conversation_id: "other", seq: 5 } });
    handlers.get("msg")?.({ payload: { body: "a forged message" } });
    handlers.get("msg_update")?.({ payload: { conversation_id: "c1", seq: 2, op: "update" } });
    handlers.get("typing")?.({ payload: { user_id: "u2", first_name: "Sam" } });
    expect(onMessage).toHaveBeenCalledTimes(1);
    expect(onMessage.mock.calls[0]?.[0]).toMatchObject({ seq: 4 });
    expect(onUpdate).toHaveBeenCalledTimes(1);
    expect(onTyping).toHaveBeenCalledWith({ user_id: "u2", first_name: "Sam" });

    sub.sendTyping({ user_id: "me", first_name: "Me" });
    expect(channel.send).toHaveBeenCalledWith({
      type: "broadcast",
      event: "typing",
      payload: { user_id: "me", first_name: "Me" },
    });
    sub.unsubscribe();
    expect(client.removeChannel).toHaveBeenCalledWith(channel);
    sub.sendTyping({ user_id: "me" });
    expect(channel.send).toHaveBeenCalledTimes(1);
  });

  it("does not subscribe when left before authorization finished", async () => {
    const { client, channel } = fakeClient();
    subscribeConversation(client as never, "c1", {}).unsubscribe();
    await flush();
    expect(channel.subscribe).not.toHaveBeenCalled();
  });
});

describe("subscribeUserChats", () => {
  it("joins user:<uid>:chats and splits activity from requests", async () => {
    const { client, handlers } = fakeClient();
    const onActivity = vi.fn();
    const onRequest = vi.fn();
    subscribeUserChats(client as never, "u1", { onActivity, onRequest });
    expect(client.channel).toHaveBeenCalledWith("user:u1:chats", expect.anything());
    await flush();
    handlers.get("chat_activity")?.({ payload: { conversation_id: "c1", seq: 3 } });
    handlers.get("request")?.({ payload: { conversation_id: "c2", seq: 1 } });
    handlers.get("request")?.({ payload: {} });
    expect(onActivity).toHaveBeenCalledWith({ conversation_id: "c1", seq: 3 });
    expect(onRequest).toHaveBeenCalledTimes(1);
  });
});
