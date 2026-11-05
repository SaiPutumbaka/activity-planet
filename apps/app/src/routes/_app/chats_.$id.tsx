import {
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
  type FormEvent,
  type ReactNode,
} from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Ban, Check, Flag, Info, MessageCircle, SendHorizontal, Trash2, X } from "lucide-react";
import { toast } from "sonner";
import {
  MESSAGE_MAX,
  SEND_TRIES,
  bodyProblem,
  chatError,
  chatErrorMessage,
  cleanBody,
  composerNotice,
  dayLabel,
  highestSeq,
  isNetworkError,
  kindLabel,
  outboxReducer,
  pendingBubbles,
  retryDelayMs,
  type ChatMessage,
  type ConversationInfo,
  type OutboxItem,
} from "@ap/core/messaging";

import { MessageBubble, PendingBubble } from "@/components/chats/message-bubble";
import { ReportForm } from "@/components/safety/report-form";
import { NextBookingBanner } from "@/components/coaching/next-booking-banner";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Spinner } from "@/components/ui/spinner";
import { cn } from "@/lib/cn";
import {
  chat,
  chatKeys,
  conversationInfoQuery,
  fetchNewer,
  messagesQuery,
  useConversationLive,
  useMarkRead,
} from "@/lib/messaging";
import { blockUser, safetyErrorMessage } from "@/lib/safety";
import { SITE_URL } from "@/lib/site";

const appRoute = getRouteApi("/_app");

/**
 * A conversation (design 14.1, 14.2): history newest first in pages of 50 (scroll up for older),
 * an optimistic composer with client ids and retries, typing in DMs and groups, the request
 * banner for the recipient, and the posting gates (photo, 24 hours, closed, read-only) in plain
 * words. Signals on conv:<id> fetch through get_messages, so a block or removal applies at once.
 */
export const Route = createFileRoute("/_app/chats_/$id")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(conversationInfoQuery(params.id));
    void queryClient.prefetchInfiniteQuery(messagesQuery(params.id));
  },
  component: ConversationPage,
});

function conversationTitle(info: ConversationInfo | undefined): string {
  if (!info) return "Chat";
  if (info.kind === "dm") return info.other?.first_name ?? "Conversation";
  return info.title?.trim() || kindLabel(info.kind);
}

function ConversationPage() {
  const { id } = Route.useParams();
  const info = useQuery(conversationInfoQuery(id));
  const title = conversationTitle(info.data);
  const missing = info.isError;

  return (
    // The page is the height of the screen above the tab bar; only the history scrolls.
    <div className="flex h-[calc(100dvh-3.5rem-env(safe-area-inset-bottom,0px))] flex-col">
      <TopBar
        title={title}
        back
        className="shrink-0"
        actions={
          info.data ? (
            <Link
              to="/chats/$id/info"
              params={{ id }}
              aria-label="Chat info"
              className={cn(
                buttonVariants({ variant: "secondary", size: "icon-sm" }),
                "rounded-full",
              )}
            >
              <Info className="size-5" aria-hidden="true" />
            </Link>
          ) : null
        }
      />
      {missing ? (
        <EmptyState
          icon={MessageCircle}
          title="This conversation isn't available"
          body="It may have been closed, or you're no longer in it."
          action={
            <Link to="/chats" className={buttonVariants({ variant: "secondary" })}>
              Back to Chats
            </Link>
          }
        />
      ) : !info.data ? (
        <div className="flex flex-col gap-3 p-4" aria-busy="true">
          <Skeleton className="ml-auto h-10 w-2/3 rounded-[20px]" />
          <Skeleton className="h-10 w-1/2 rounded-[20px]" />
          <Skeleton className="ml-auto h-10 w-1/3 rounded-[20px]" />
        </div>
      ) : (
        <Conversation key={id} info={info.data} />
      )}
    </div>
  );
}

function Conversation({ info }: { info: ConversationInfo }) {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const id = info.conversation_id;
  const queryClient = useQueryClient();
  const history = useInfiniteQuery(messagesQuery(id));
  const messages = useMemo(() => history.data?.pages.flat() ?? [], [history.data]);
  const [outbox, dispatch] = useReducer(outboxReducer, [] as OutboxItem[]);
  const [draft, setDraft] = useState("");
  const [sendError, setSendError] = useState<string | null>(null);
  const [actionsFor, setActionsFor] = useState<ChatMessage | null>(null);
  const [bottomVisible, setBottomVisible] = useState(true);
  const scrollerRef = useRef<HTMLDivElement>(null);
  const bottomRef = useRef<HTMLDivElement>(null);
  const topRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLTextAreaElement>(null);

  const members = useMemo(() => {
    const ids = new Set<string>();
    const names = new Map<string, string>();
    for (const m of info.members ?? []) {
      ids.add(m.id);
      names.set(m.id, m.first_name);
    }
    return { ids, names };
  }, [info.members]);

  const { typing, notifyTyping } = useConversationLive(id, {
    userId,
    typingEnabled: info.kind === "dm" || info.kind === "group",
    members: members.ids,
    names: members.names,
    canPost: info.can_post === null,
  });

  const newestSeq = highestSeq(messages);
  useMarkRead(id, userId, newestSeq, bottomVisible);

  // Sent bubbles leave the outbox once their row is in the history.
  useEffect(() => {
    if (outbox.some((o) => o.state === "sent")) dispatch({ type: "reconcile", messages });
  }, [messages, outbox]);

  // The newest message on screen (for read state) and the top sentinel (for older pages).
  const historyRef = useRef(history);
  useEffect(() => {
    historyRef.current = history;
  });
  useEffect(() => {
    const root = scrollerRef.current;
    const bottom = bottomRef.current;
    const top = topRef.current;
    if (!root || !bottom || !top) return;
    const io = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.target === bottom) setBottomVisible(e.isIntersecting);
          const h = historyRef.current;
          if (e.target === top && e.isIntersecting && h.hasNextPage && !h.isFetchingNextPage) {
            void h.fetchNextPage();
          }
        }
      },
      { root, rootMargin: "200px 0px" },
    );
    io.observe(bottom);
    io.observe(top);
    return () => io.disconnect();
  }, [history.isPending]);

  const refreshInfo = () => void queryClient.invalidateQueries({ queryKey: chatKeys.info(id) });

  async function deliver(item: { clientId: string; body: string }) {
    for (let attempt = 1; attempt <= SEND_TRIES; attempt++) {
      dispatch({ type: "attempt", clientId: item.clientId });
      try {
        const r = await chat.send(id, item.clientId, item.body);
        if ("error" in r) {
          // The filter's refusal: the text goes back to the composer with the reason.
          dispatch({ type: "remove", clientId: item.clientId });
          setDraft((d) => (d ? d : item.body));
          setSendError(chatErrorMessage(r));
          return;
        }
        dispatch({
          type: "sent",
          clientId: item.clientId,
          id: r.id,
          seq: r.seq,
          createdAt: r.created_at,
        });
        await fetchNewer(queryClient, id);
        void queryClient.invalidateQueries({ queryKey: ["chats", "list", userId] });
        // A request's one message, or a reply that accepted one, changes what the composer allows.
        if (info.request) refreshInfo();
        return;
      } catch (err) {
        if (isNetworkError(err)) {
          if (attempt < SEND_TRIES) {
            await new Promise((r) => setTimeout(r, retryDelayMs(attempt)));
            continue;
          }
          dispatch({ type: "failed", clientId: item.clientId });
          return;
        }
        dispatch({ type: "remove", clientId: item.clientId });
        setDraft((d) => (d ? d : item.body));
        setSendError(chatErrorMessage(err));
        const { code } = chatError(err);
        if (code && code !== "rate_limited" && code !== "slow_mode") refreshInfo();
        // Closed (a block or a deleted account): what this reader may see changed too.
        if (code === "conversation_closed" || code === "forbidden") {
          void queryClient.invalidateQueries({ queryKey: chatKeys.messages(id) });
        }
        return;
      }
    }
  }

  function onSubmit(e?: FormEvent) {
    e?.preventDefault();
    const body = cleanBody(draft);
    const problem = bodyProblem(draft, {
      linksAllowed: info.request !== "sent",
    });
    if (problem === "empty") return;
    if (problem === "too_long") {
      setSendError(`Messages are up to ${MESSAGE_MAX.toLocaleString("en-US")} characters.`);
      return;
    }
    if (problem === "link_not_allowed") {
      setSendError(chatErrorMessage({ message: "link_not_allowed" }));
      return;
    }
    setSendError(null);
    const clientId = crypto.randomUUID();
    dispatch({
      type: "add",
      item: { clientId, conversationId: id, body, createdAt: new Date().toISOString() },
    });
    setDraft("");
    bottomRef.current?.scrollIntoView({ block: "end" });
    void deliver({ clientId, body });
  }

  const pending = pendingBubbles(outbox, id, messages);
  const canPost = info.can_post === null;
  const notice = composerNotice(info.can_post);
  const other = info.other;

  // Newest first in the DOM; the column is reversed so the newest sits at the bottom.
  const rows: ReactNode[] = [];
  for (let i = 0; i < messages.length; i++) {
    const m = messages[i]!;
    const older = messages[i + 1];
    const showAuthor =
      info.kind !== "dm" &&
      !m.mine &&
      (!older ||
        older.author?.id !== m.author?.id ||
        dayLabel(older.created_at) !== dayLabel(m.created_at));
    rows.push(
      <li key={m.id} className="py-0.5">
        <MessageBubble
          message={m}
          showAuthor={showAuthor}
          onOpenActions={m.deleted ? undefined : () => setActionsFor(m)}
        />
      </li>,
    );
    if (!older || dayLabel(older.created_at) !== dayLabel(m.created_at)) {
      rows.push(
        <li key={`day-${m.id}`} className="py-3 text-center text-[12px] font-semibold text-text-3">
          {dayLabel(m.created_at)}
        </li>,
      );
    }
  }

  return (
    <>
      {info.kind === "dm" && other ? <NextBookingBanner userId={other.id} /> : null}
      <div
        ref={scrollerRef}
        className="flex min-h-0 flex-1 flex-col-reverse overflow-y-auto overscroll-contain px-3"
        aria-label="Messages"
        role="region"
      >
        <div ref={bottomRef} className="h-2 shrink-0" />
        {typing ? (
          <p className="px-11 pb-1 text-[13px] text-text-2" aria-live="polite">
            {typing}…
          </p>
        ) : null}
        <ol className="flex flex-col-reverse" aria-label="Sending">
          {[...pending].reverse().map((p) => (
            <li key={p.clientId} className="py-0.5">
              <PendingBubble
                body={p.body}
                failed={p.state === "failed"}
                onRetry={() => {
                  dispatch({ type: "retry", clientId: p.clientId });
                  void deliver({ clientId: p.clientId, body: p.body });
                }}
              />
            </li>
          ))}
        </ol>
        {history.isPending ? (
          <div className="flex justify-center py-6">
            <Spinner className="size-6" />
          </div>
        ) : history.isError ? (
          <div className="py-4">
            <FormError>Couldn&apos;t load messages.</FormError>
            <Button variant="secondary" className="mt-2" onClick={() => void history.refetch()}>
              Try again
            </Button>
          </div>
        ) : (
          <ol className="flex flex-col-reverse" aria-label="Conversation history">
            {rows}
          </ol>
        )}
        <div ref={topRef} className="flex shrink-0 justify-center py-3">
          {history.isFetchingNextPage ? <Spinner className="size-5" /> : null}
          {!history.isPending && !history.hasNextPage ? (
            <ConversationStart info={info} empty={messages.length === 0} />
          ) : null}
        </div>
      </div>

      <div className="shrink-0 border-t border-border bg-surface px-3 pt-2 pb-2">
        {info.request === "received" && other ? (
          <RequestBanner info={info} firstMessage={messages.find((m) => !m.mine) ?? null} />
        ) : null}
        {info.request === "sent" && canPost ? (
          <p className="px-1 pb-2 text-[13px] text-text-2">
            This is a message request. You can send one text message without links;{" "}
            {other?.first_name ?? "they"} can reply once they see it.
          </p>
        ) : null}
        <FormError>{sendError}</FormError>
        {canPost ? (
          <form onSubmit={onSubmit} className="flex items-end gap-2 pt-1">
            <label htmlFor="composer" className="sr-only">
              Message
            </label>
            <textarea
              id="composer"
              ref={inputRef}
              rows={1}
              value={draft}
              maxLength={MESSAGE_MAX + 200}
              placeholder="Message"
              onChange={(e) => {
                setDraft(e.target.value);
                if (sendError) setSendError(null);
                notifyTyping();
              }}
              onKeyDown={(e) => {
                if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                  e.preventDefault();
                  onSubmit();
                }
              }}
              className="max-h-32 min-h-11 min-w-0 flex-1 resize-none rounded-[22px] border border-border bg-surface px-4 py-2.5 text-[16px] leading-[1.35] outline-none focus:border-primary focus:ring-2 focus:ring-primary/30"
            />
            <Button
              type="submit"
              size="icon"
              className="rounded-full"
              aria-label="Send"
              disabled={cleanBody(draft).length === 0}
            >
              <SendHorizontal className="size-5" aria-hidden="true" />
            </Button>
          </form>
        ) : (
          <ComposerGate code={info.can_post} notice={notice} />
        )}
      </div>

      <MessageActions message={actionsFor} info={info} onClose={() => setActionsFor(null)} />
    </>
  );
}

/** The top of the history: who this is with, and how the room works. */
function ConversationStart({ info, empty }: { info: ConversationInfo; empty: boolean }) {
  if (info.kind === "dm" && info.other) {
    return (
      <div className="flex flex-col items-center gap-2 pb-2 pt-4 text-center">
        <Avatar src={info.other.avatar_url} name={info.other.first_name} size={64} />
        <p className="text-[17px] font-bold">{info.other.first_name}</p>
        {info.other.handle ? <p className="text-[13px] text-text-2">@{info.other.handle}</p> : null}
        {empty ? (
          <p className="max-w-[32ch] text-[13px] text-text-2">
            Say hi. Meeting up? Pick a public place and tell a friend where you&apos;re going.
          </p>
        ) : null}
      </div>
    );
  }
  return (
    <p className="max-w-[36ch] pb-2 pt-4 text-center text-[13px] text-text-2">
      {info.kind === "event"
        ? "Everyone on this plan can read and post here. Leaving the plan leaves the chat."
        : info.kind === "hub"
          ? "Members of this hub can read this chat. Slow mode keeps it calm."
          : info.kind === "chapter"
            ? "Members of this chapter can read and post here."
            : "The start of the group. Everyone in it can read and post."}
    </p>
  );
}

/** What replaces the composer when the server says this person can't post here yet. */
function ComposerGate({ code, notice }: { code: string | null; notice: string | null }) {
  return (
    <div
      className="flex flex-col gap-2 rounded-input bg-surface-2 px-4 py-3 text-[14px]"
      role="status"
    >
      <p>{notice}</p>
      {code === "photo_required" ? (
        <Link to="/you/photo" className={cn(buttonVariants({ size: "sm" }), "self-start")}>
          Add a photo
        </Link>
      ) : null}
      {code === "conversation_closed" ? (
        <p className="text-[13px] text-text-2">
          If you blocked this person, you can unblock them in{" "}
          <Link
            to="/you/blocked"
            className="font-semibold text-link underline-offset-2 hover:underline"
          >
            Blocked accounts
          </Link>
          .
        </p>
      ) : null}
    </div>
  );
}

type RequestStep = "main" | "block" | "report";

/** For the recipient of a message request: Accept, Decline, Block or Report (design 3). */
function RequestBanner({
  info,
  firstMessage,
}: {
  info: ConversationInfo;
  firstMessage: ChatMessage | null;
}) {
  const { session } = appRoute.useRouteContext();
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [step, setStep] = useState<RequestStep>("main");
  const other = info.other!;
  const id = info.conversation_id;

  const done = async (message: string) => {
    void queryClient.invalidateQueries({ queryKey: chatKeys.all });
    toast.success(message);
    await navigate({ to: "/chats", search: { tab: "requests" } });
  };

  const accept = useMutation({
    mutationFn: () => chat.respondRequest(id, "accept"),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: chatKeys.info(id) });
      void queryClient.invalidateQueries({ queryKey: ["chats", "list", session.user.id] });
      void queryClient.invalidateQueries({ queryKey: chatKeys.unread(session.user.id) });
      toast.success(`You can message ${other.first_name} now.`);
    },
    onError: (err) => toast.error(chatErrorMessage(err)),
  });
  const decline = useMutation({
    mutationFn: () => chat.respondRequest(id, "decline"),
    onSuccess: () => done("Declined. They aren't told."),
    onError: (err) => toast.error(chatErrorMessage(err)),
  });
  const block = useMutation({
    mutationFn: async () => {
      await blockUser(other.id);
      // block_user declines a pending request too; this covers an older server.
      await chat.respondRequest(id, "decline").catch(() => undefined);
    },
    onSuccess: () => {
      void queryClient.invalidateQueries();
      void done(`You blocked ${other.first_name}.`);
    },
    onError: (err) => toast.error(safetyErrorMessage(err)),
  });
  const busy = accept.isPending || decline.isPending || block.isPending;

  return (
    <div
      className="mb-2 flex flex-col gap-3 rounded-card border border-border p-3"
      aria-label="Message request"
    >
      <p className="text-[14px]">
        <span className="font-semibold">{other.first_name}</span>
        {other.handle ? <span className="text-text-2"> @{other.handle}</span> : null} wants to
        message you. You don&apos;t share a plan, hub or chapter yet. They won&apos;t know
        you&apos;ve seen this unless you reply or accept.
      </p>
      <div className="grid grid-cols-2 gap-2">
        <Button
          size="sm"
          loading={accept.isPending}
          disabled={busy}
          leading={<Check className="size-4" aria-hidden="true" />}
          onClick={() => accept.mutate()}
        >
          Accept
        </Button>
        <Button
          size="sm"
          variant="secondary"
          loading={decline.isPending}
          disabled={busy}
          leading={<X className="size-4" aria-hidden="true" />}
          onClick={() => decline.mutate()}
        >
          Decline
        </Button>
        <Button
          size="sm"
          variant="danger"
          disabled={busy}
          leading={<Ban className="size-4" aria-hidden="true" />}
          onClick={() => setStep("block")}
        >
          Block
        </Button>
        <Button
          size="sm"
          variant="outline"
          disabled={busy || !firstMessage}
          leading={<Flag className="size-4" aria-hidden="true" />}
          onClick={() => setStep("report")}
        >
          Report
        </Button>
      </div>
      <Sheet
        open={step === "block"}
        onClose={() => setStep("main")}
        title={`Block ${other.first_name}?`}
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="secondary"
              size="lg"
              onClick={() => setStep("main")}
              disabled={block.isPending}
            >
              Back
            </Button>
            <Button
              variant="danger"
              size="lg"
              loading={block.isPending}
              onClick={() => block.mutate()}
            >
              Block
            </Button>
          </div>
        }
      >
        <p className="pt-1 text-[15px] text-text-2">
          The request is declined and neither of you can message or see the other. They aren&apos;t
          told. You can unblock them later in You, Blocked accounts.
        </p>
      </Sheet>
      <Sheet
        open={step === "report" && firstMessage !== null}
        onClose={() => setStep("main")}
        title="Report this message"
      >
        {firstMessage ? (
          <ReportForm
            kind="message"
            targetId={firstMessage.id}
            onCancel={() => setStep("main")}
            onDone={() => {
              setStep("main");
              // Reporting a request also declines it.
              decline.mutate();
            }}
          />
        ) : null}
      </Sheet>
    </div>
  );
}

type ActionStep = "menu" | "delete" | "report";

/** A message's actions: delete your own (or as a room admin), report someone else's. */
function MessageActions({
  message,
  info,
  onClose,
}: {
  message: ChatMessage | null;
  info: ConversationInfo;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [step, setStep] = useState<ActionStep>("menu");
  const id = info.conversation_id;
  const roomAdmin =
    (info.role === "owner" || info.role === "admin") &&
    (info.kind === "group" || info.kind === "event" || info.kind === "chapter");
  const canDelete = message !== null && (message.mine || roomAdmin);
  const canReport = message !== null && !message.mine;

  function close() {
    setStep("menu");
    onClose();
  }

  const remove = useMutation({
    mutationFn: (messageId: string) => chat.deleteMessage(messageId),
    onSuccess: async () => {
      if (message) await fetchNewer(queryClient, id, message.seq);
      void queryClient.invalidateQueries({ queryKey: ["chats", "list"] });
      toast.success(message?.mine ? "Message deleted." : "Message removed.");
      close();
    },
    onError: (err) => toast.error(chatErrorMessage(err)),
  });

  const title =
    step === "delete"
      ? message?.mine
        ? "Delete this message?"
        : "Remove this message?"
      : step === "report"
        ? "Report this message"
        : "Message";

  return (
    <Sheet
      open={message !== null}
      onClose={close}
      title={title}
      footer={
        message && step === "delete" ? (
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="secondary"
              size="lg"
              onClick={() => setStep("menu")}
              disabled={remove.isPending}
            >
              Back
            </Button>
            <Button
              variant="danger"
              size="lg"
              loading={remove.isPending}
              onClick={() => remove.mutate(message.id)}
            >
              {message.mine ? "Delete" : "Remove"}
            </Button>
          </div>
        ) : undefined
      }
    >
      {!message ? null : step === "menu" ? (
        <div className="flex flex-col gap-2 pt-1">
          {message.body ? (
            <p className="line-clamp-4 rounded-input bg-surface-2 px-3 py-2 text-[14px] whitespace-pre-wrap [overflow-wrap:anywhere]">
              {message.body}
            </p>
          ) : null}
          {canDelete ? (
            <Button
              variant="danger"
              block
              leading={<Trash2 className="size-4" aria-hidden="true" />}
              onClick={() => setStep("delete")}
            >
              {message.mine ? "Delete message" : "Remove message"}
            </Button>
          ) : null}
          {canReport ? (
            <Button
              variant="outline"
              block
              leading={<Flag className="size-4" aria-hidden="true" />}
              onClick={() => setStep("report")}
            >
              Report message
            </Button>
          ) : null}
          {info.kind === "dm" ? (
            <a
              href={`${SITE_URL}/safety`}
              target="_blank"
              rel="noreferrer"
              className="self-center py-2 text-[13px] font-semibold text-link underline-offset-2 hover:underline"
            >
              Safety Center
            </a>
          ) : null}
        </div>
      ) : step === "delete" ? (
        <p className="pt-1 text-[15px] text-text-2">
          {message.mine
            ? "Everyone in the chat sees “Message deleted” instead."
            : "Everyone in the chat sees “Removed by the host” instead."}{" "}
          A copy is kept for 30 days in case it&apos;s reported, then erased.
        </p>
      ) : (
        <ReportForm
          kind="message"
          targetId={message.id}
          onDone={close}
          onCancel={() => setStep("menu")}
        />
      )}
    </Sheet>
  );
}
