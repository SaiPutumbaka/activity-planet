import { describe, expect, it, vi } from "vitest";
import type { InfiniteData } from "@tanstack/react-query";
import type { ChatMessage } from "@ap/core/messaging";

vi.mock("../supabase", () => ({ supabase: { rpc: vi.fn() } }));

const { contextLink, mergeIntoPages, messagesQuery } = await import("../messaging");

const msg = (seq: number, body = `m${seq}`): ChatMessage => ({
  id: `id${seq}`,
  seq,
  author: null,
  kind: "text",
  body,
  image: null,
  created_at: "2026-11-05T10:00:00Z",
  deleted: null,
  hidden: false,
  mine: false,
  client_id: null,
});

const pages = (...p: ChatMessage[][]): InfiniteData<ChatMessage[], number | null> => ({
  pages: p,
  pageParams: p.map((_, i) => (i === 0 ? null : 0)),
});

describe("mergeIntoPages", () => {
  it("puts new messages on the first page, newest first", () => {
    const out = mergeIntoPages(pages([msg(3), msg(2)], [msg(1)]), [msg(5), msg(4)]);
    expect(out?.pages[0]?.map((m) => m.seq)).toEqual([5, 4, 3, 2]);
    expect(out?.pages[1]?.map((m) => m.seq)).toEqual([1]);
  });

  it("replaces an updated row where it is, without duplicating it", () => {
    const out = mergeIntoPages(pages([msg(3)], [msg(2), msg(1)]), [msg(2, "")]);
    expect(out?.pages[1]?.[0]?.body).toBe("");
    expect(out?.pages.flat()).toHaveLength(3);
  });

  it("leaves the cache alone with nothing new", () => {
    const data = pages([msg(1)]);
    expect(mergeIntoPages(data, [])).toBe(data);
    expect(mergeIntoPages(undefined, [msg(1)])).toBeUndefined();
  });
});

describe("messagesQuery", () => {
  it("pages back from the lowest seq of a full page, and stops on a short one", () => {
    const q = messagesQuery("c1");
    const full = Array.from({ length: 50 }, (_, i) => msg(100 - i));
    expect(q.getNextPageParam(full, [full], null, [null])).toBe(51);
    expect(q.getNextPageParam([msg(3)], [[msg(3)]], null, [null])).toBeNull();
  });
});

describe("contextLink", () => {
  it("links a room's chat row to its plan, hub or chapter", () => {
    expect(contextLink({ kind: "event", context: { event_id: "e1" } })).toEqual({
      to: "/events/$id",
      params: { id: "e1" },
    });
    expect(contextLink({ kind: "hub", context: { slug: "running" } })?.to).toBe("/hubs/$slug");
    expect(contextLink({ kind: "dm", context: null })).toBeNull();
  });
});
