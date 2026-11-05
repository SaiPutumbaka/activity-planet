import { useCallback, useEffect, useRef, useState, useSyncExternalStore } from "react";
import {
  infiniteQueryOptions,
  queryOptions,
  useQuery,
  useQueryClient,
  type InfiniteData,
  type QueryClient,
} from "@tanstack/react-query";
import {
  CHAT_POLL_MS,
  MESSAGES_PAGE,
  TYPING_SEND_MS,
  TYPING_TTL_MS,
  createMessagingApi,
  mergeMessages,
  subscribeConversation,
  subscribeUserChats,
  typingLine,
  typingNames,
  type ChatListRow,
  type ChatMessage,
  type ChatTab,
  type ConversationSubscription,
  type UnreadTotal,
} from "@ap/core/messaging";

import { supabase } from "./supabase";

/**
 * Messaging in the app (D-043, design section 14). The typed RPC calls, schemas, topics and the
 * outbox reducer are in @ap/core/messaging; this file holds the query options and the hooks.
 *
 *   useQuery(chatListQuery(userId, "chats"))          // the Chats list (or "requests")
 *   useUnreadChats(userId)                            // { chats, requests } for the top-bar badge
 *   useInfiniteQuery(messagesQuery(conversationId))   // newest first, pages of 50 going back
 *   useConversationLive(conversationId, ...)          // conv:<id> signals, typing, poll fallback
 *   <ChatsRealtime userId />                          // one user:<uid>:chats channel, in the shell
 */

export const chat = createMessagingApi(supabase);

export const chatKeys = {
  all: ["chats"] as const,
  list: (userId: string, tab: ChatTab) => ["chats", "list", userId, tab] as const,
  unread: (userId: string) => ["chats", "unread", userId] as const,
  info: (conversationId: string) => ["chats", "info", conversationId] as const,
  messages: (conversationId: string) => ["chats", "messages", conversationId] as const,
  met: (userId: string) => ["chats", "met", userId] as const,
  search: (q: string) => ["chats", "search", q] as const,
};

export const chatListQuery = (userId: string, tab: ChatTab) =>
  queryOptions({
    queryKey: chatKeys.list(userId, tab),
    queryFn: () => chat.chatList(tab, null, 50),
    staleTime: 10_000,
  });

export const unreadChatsQuery = (userId: string) =>
  queryOptions({
    queryKey: chatKeys.unread(userId),
    queryFn: (): Promise<UnreadTotal> => chat.unreadTotal(),
    staleTime: 15_000,
  });

export const conversationInfoQuery = (conversationId: string) =>
  queryOptions({
    queryKey: chatKeys.info(conversationId),
    queryFn: () => chat.info(conversationId),
    staleTime: 15_000,
    retry: (count, err) => count < 1 && !/not_found|forbidden/.test(String((err as Error).message)),
  });

/** Pages newest first; the cursor is the lowest seq of the last page. */
export const messagesQuery = (conversationId: string) =>
  infiniteQueryOptions({
    queryKey: chatKeys.messages(conversationId),
    queryFn: ({ pageParam }) =>
      chat.messages(conversationId, { before: pageParam, limit: MESSAGES_PAGE }),
    initialPageParam: null as number | null,
    getNextPageParam: (last: ChatMessage[]) =>
      last.length < MESSAGES_PAGE ? null : (last[last.length - 1]?.seq ?? null),
    staleTime: Infinity,
    // Signals keep the first page fresh; refetching every page on focus is not needed.
    refetchOnWindowFocus: false,
  });

export const peopleYouMetQuery = (userId: string) =>
  queryOptions({
    queryKey: chatKeys.met(userId),
    queryFn: () => chat.peopleYouMet(null, 50),
    staleTime: 60_000,
  });

export interface PersonResult {
  id: string;
  first_name: string;
  handle: string;
  avatar_url: string | null;
}

/** People by handle prefix (profiles RLS shows active adults; blocks hide both ways). */
export const personSearchQuery = (q: string, selfId: string) =>
  queryOptions({
    queryKey: chatKeys.search(q),
    queryFn: async (): Promise<PersonResult[]> => {
      const term = q.trim().replace(/^@/, "").toLowerCase();
      if (term.length < 2 || !/^[a-z0-9_.]+$/.test(term)) return [];
      const { data, error } = await supabase
        .from("profiles")
        .select("id,first_name,handle,avatar_url")
        .ilike("handle", `${term.replace(/_/g, "\\_")}%`)
        .neq("id", selfId)
        .eq("status", "active")
        .order("handle")
        .limit(10);
      if (error) throw error;
      return data;
    },
    staleTime: 30_000,
  });

/* ------------------------------------------------------------------ */
/* The user's chats channel                                            */
/* ------------------------------------------------------------------ */

let chatsLive = false;
const liveListeners = new Set<() => void>();
function setChatsLive(v: boolean) {
  if (chatsLive === v) return;
  chatsLive = v;
  for (const l of liveListeners) l();
}

/** Whether the user:<uid>:chats channel is subscribed now. */
export function useChatsLiveStatus(): boolean {
  return useSyncExternalStore(
    (cb) => {
      liveListeners.add(cb);
      return () => liveListeners.delete(cb);
    },
    () => chatsLive,
    () => false,
  );
}

function refreshChatLists(queryClient: QueryClient, userId: string) {
  void queryClient.invalidateQueries({ queryKey: ["chats", "list", userId] });
  void queryClient.invalidateQueries({ queryKey: chatKeys.unread(userId) });
}

/**
 * One user:<uid>:chats channel while signed in (mounted once in the app shell). A dm or group
 * signal refreshes the list and the badge; event, hub and chapter rooms have no personal signal
 * and refresh on the list's own poll and focus.
 */
export function ChatsRealtime({ userId }: { userId: string }) {
  const queryClient = useQueryClient();
  useEffect(() => {
    const sub = subscribeUserChats(supabase, userId, {
      onActivity: (s) => {
        refreshChatLists(queryClient, userId);
        void queryClient.invalidateQueries({ queryKey: chatKeys.info(s.conversation_id) });
      },
      onRequest: () => refreshChatLists(queryClient, userId),
      onStatus: (status) => setChatsLive(status === "SUBSCRIBED"),
    });
    return () => {
      setChatsLive(false);
      sub.unsubscribe();
    };
  }, [queryClient, userId]);
  return null;
}

/** The badge numbers, live over the chats channel and polled every 60 s and on focus. */
export function useUnreadChats(userId: string): UnreadTotal {
  const live = useChatsLiveStatus();
  const q = useQuery({
    ...unreadChatsQuery(userId),
    refetchInterval: live ? 60_000 : CHAT_POLL_MS,
    refetchIntervalInBackground: false,
  });
  return q.data ?? { chats: 0, requests: 0 };
}

/* ------------------------------------------------------------------ */
/* A conversation                                                       */
/* ------------------------------------------------------------------ */

type MessagePages = InfiniteData<ChatMessage[], number | null>;

/** Puts newer (or changed) messages into the first page of the cached history. */
export function mergeIntoPages(
  data: MessagePages | undefined,
  incoming: readonly ChatMessage[],
): MessagePages | undefined {
  if (!data || incoming.length === 0) return data;
  const byId = new Map(incoming.map((m) => [m.id, m]));
  const pages = data.pages.map((p) => p.map((m) => byId.get(m.id) ?? m));
  const known = new Set(pages.flat().map((m) => m.id));
  const fresh = incoming.filter((m) => !known.has(m.id));
  const [first = [], ...rest] = pages;
  return { ...data, pages: [mergeMessages(first, fresh), ...rest] };
}

/** Fetches what came after the newest message held (and refreshes updated rows). */
export async function fetchNewer(
  queryClient: QueryClient,
  conversationId: string,
  updatedSeq?: number,
): Promise<void> {
  const key = chatKeys.messages(conversationId);
  const data = queryClient.getQueryData<MessagePages>(key);
  if (!data) {
    await queryClient.invalidateQueries({ queryKey: key });
    return;
  }
  const newest = data.pages[0]?.[0]?.seq ?? 0;
  const tasks: Promise<ChatMessage[]>[] = [chat.messages(conversationId, { after: newest })];
  if (updatedSeq != null && updatedSeq <= newest) {
    // An update to a message already shown: read that one row again.
    tasks.push(chat.messages(conversationId, { before: updatedSeq + 1, limit: 1 }));
  }
  const results = (await Promise.all(tasks)).flat();
  // An updated row the reader may no longer see (a block, a ban) is dropped from the cache.
  const gone =
    updatedSeq != null && updatedSeq <= newest && !results.some((m) => m.seq === updatedSeq);
  queryClient.setQueryData<MessagePages>(key, (old) => {
    const merged = mergeIntoPages(old, results);
    if (!merged || !gone) return merged;
    return { ...merged, pages: merged.pages.map((p) => p.filter((m) => m.seq !== updatedSeq)) };
  });
}

export interface ConversationLive {
  live: boolean;
  /** The typing line for the room, or null. */
  typing: string | null;
  /** Call on composer changes; sends at most every 3 seconds. */
  notifyTyping: () => void;
}

/**
 * The conv:<id> channel for an open conversation: a `msg` or `msg_update` signal fetches through
 * get_messages; typing (dm and group only) is shown for members the viewer can see. While the
 * channel is not subscribed the history is polled every 30 s.
 */
export function useConversationLive(
  conversationId: string,
  opts: {
    userId: string;
    firstName: string;
    typingEnabled: boolean;
    /** Member ids whose typing may be shown. */
    members: ReadonlySet<string>;
    names: ReadonlyMap<string, string>;
    canPost: boolean;
  },
): ConversationLive {
  const queryClient = useQueryClient();
  const [live, setLive] = useState(false);
  const [seen, setSeen] = useState<Map<string, { name: string; at: number }>>(new Map());
  const [now, setNow] = useState(() => Date.now());
  const subRef = useRef<ConversationSubscription | null>(null);
  const lastTypingRef = useRef(0);
  const { userId, firstName, typingEnabled, canPost } = opts;

  useEffect(() => {
    const sub = subscribeConversation(supabase, conversationId, {
      onMessage: () => {
        void fetchNewer(queryClient, conversationId);
        void queryClient.invalidateQueries({ queryKey: ["chats", "list", userId] });
        void queryClient.invalidateQueries({ queryKey: chatKeys.unread(userId) });
      },
      onUpdate: (s) => void fetchNewer(queryClient, conversationId, s.seq),
      onTyping: (s) => {
        setSeen((prev) => {
          const next = new Map(prev);
          next.set(s.user_id, { name: s.first_name ?? "Someone", at: Date.now() });
          return next;
        });
        setNow(Date.now());
      },
      onStatus: (status) => setLive(status === "SUBSCRIBED"),
    });
    subRef.current = sub;
    return () => {
      subRef.current = null;
      setLive(false);
      sub.unsubscribe();
    };
  }, [conversationId, queryClient, userId]);

  // Poll fallback while the channel is down.
  useEffect(() => {
    if (live) return;
    const t = window.setInterval(() => {
      if (document.visibilityState === "visible") void fetchNewer(queryClient, conversationId);
    }, CHAT_POLL_MS);
    return () => window.clearInterval(t);
  }, [conversationId, live, queryClient]);

  // Typing lines expire.
  useEffect(() => {
    if (seen.size === 0) return;
    const t = window.setTimeout(() => {
      const at = Date.now();
      setNow(at);
      setSeen((prev) => {
        const next = new Map([...prev].filter(([, v]) => at - v.at <= TYPING_TTL_MS));
        return next.size === prev.size ? prev : next;
      });
    }, 1000);
    return () => window.clearTimeout(t);
  }, [seen, now]);

  const notifyTyping = useCallback(() => {
    if (!typingEnabled || !canPost) return;
    const t = Date.now();
    if (t - lastTypingRef.current < TYPING_SEND_MS) return;
    lastTypingRef.current = t;
    subRef.current?.sendTyping({ user_id: userId, first_name: firstName });
  }, [canPost, firstName, typingEnabled, userId]);

  // Names come from the member list, not from the payload (a forged name shows nothing new).
  const named = new Map(
    [...seen].map(([id, v]) => [id, { ...v, name: opts.names.get(id) ?? v.name }] as const),
  );
  const typing = typingEnabled ? typingLine(typingNames(named, opts.members, userId, now)) : null;
  return { live, typing, notifyTyping };
}

/**
 * Marks the conversation read up to `seq` when the newest message is on screen and the tab is
 * visible, at most once a second, and never backwards.
 */
export function useMarkRead(
  conversationId: string,
  userId: string,
  seq: number,
  onScreen: boolean,
) {
  const queryClient = useQueryClient();
  const sentRef = useRef(0);
  useEffect(() => {
    if (!onScreen || seq <= sentRef.current) return;
    const t = window.setTimeout(() => {
      if (document.visibilityState !== "visible" || seq <= sentRef.current) return;
      sentRef.current = seq;
      void chat
        .markRead(conversationId, seq)
        .then(() => {
          void queryClient.invalidateQueries({ queryKey: chatKeys.unread(userId) });
          void queryClient.invalidateQueries({ queryKey: ["chats", "list", userId] });
        })
        .catch(() => {
          sentRef.current = 0;
        });
    }, 1000);
    return () => window.clearTimeout(t);
  }, [conversationId, onScreen, queryClient, seq, userId]);
}

/** A signed URL (1 hour) for a visible chat image, cached per path. */
export const chatImageUrlQuery = (path: string) =>
  queryOptions({
    queryKey: ["chats", "image", path] as const,
    queryFn: async (): Promise<string> => {
      const { data, error } = await supabase.storage
        .from("chat-images")
        .createSignedUrl(path, 3600);
      if (error) throw error;
      return data.signedUrl;
    },
    staleTime: 50 * 60 * 1000,
  });

/** Where a chat row's context links: the plan, hub or chapter. */
export function contextLink(
  row: Pick<ChatListRow, "kind" | "context">,
):
  | { to: "/events/$id"; params: { id: string } }
  | { to: "/hubs/$slug"; params: { slug: string } }
  | { to: "/chapters/$slug"; params: { slug: string } }
  | null {
  const c = row.context;
  if (!c) return null;
  if (row.kind === "event" && c.event_id) return { to: "/events/$id", params: { id: c.event_id } };
  if (row.kind === "hub" && c.slug) return { to: "/hubs/$slug", params: { slug: c.slug } };
  if (row.kind === "chapter" && c.slug) return { to: "/chapters/$slug", params: { slug: c.slug } };
  return null;
}
