"use client";

import { useEffect, useRef, useState, useTransition } from "react";
import { Loader2, Send } from "lucide-react";
import { toast } from "sonner";

import { sendHubMessageAction } from "@/actions/hub-chat";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { createClient } from "@/lib/supabase/client";
import { cn } from "@/lib/utils";
import type { Hub } from "@/types/database";

export interface HubChatMessage {
  id: string;
  senderId: string;
  senderUsername: string;
  body: string;
  createdAt: string;
}

interface HubChatProps {
  hub: Hub;
  currentUserId: string;
  currentUsername: string;
  initialMessages: HubChatMessage[];
  isMember: boolean;
}

interface HubMessageInsertRow {
  id: string;
  sender_id: string;
  body: string;
  created_at: string;
}

const TIME_FORMAT = new Intl.DateTimeFormat("en-US", {
  hour: "numeric",
  minute: "2-digit",
});

export function HubChat({
  hub,
  currentUserId,
  currentUsername,
  initialMessages,
  isMember,
}: HubChatProps) {
  const [messages, setMessages] = useState<HubChatMessage[]>(initialMessages);
  const [draft, setDraft] = useState("");
  const [isPending, startTransition] = useTransition();
  const bottomRef = useRef<HTMLDivElement>(null);
  const usernameCache = useRef<Map<string, string>>(
    new Map<string, string>([
      [currentUserId, currentUsername],
      ...initialMessages.map(
        (message): [string, string] => [message.senderId, message.senderUsername],
      ),
    ]),
  );

  useEffect(() => {
    if (!isMember) {
      return;
    }
    const supabase = createClient();

    const channel = supabase
      .channel(`hub-chat-${hub}`)
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "hub_messages",
          filter: `hub=eq.${hub}`,
        },
        (payload) => {
          const row = payload.new as HubMessageInsertRow;

          void (async () => {
            let username = usernameCache.current.get(row.sender_id);
            if (!username) {
              const { data } = await supabase
                .from("profiles")
                .select("username")
                .eq("id", row.sender_id)
                .maybeSingle();
              username = data?.username ?? "Someone";
              usernameCache.current.set(row.sender_id, username);
            }

            setMessages((prev) => {
              if (prev.some((message) => message.id === row.id)) {
                return prev;
              }
              return [
                ...prev,
                {
                  id: row.id,
                  senderId: row.sender_id,
                  senderUsername: username ?? "Someone",
                  body: row.body,
                  createdAt: row.created_at,
                },
              ];
            });
          })();
        },
      )
      .subscribe();

    return () => {
      void supabase.removeChannel(channel);
    };
  }, [hub, isMember]);

  useEffect(() => {
    bottomRef.current?.scrollIntoView({ block: "nearest" });
  }, [messages.length]);

  function handleSend(event: React.FormEvent) {
    event.preventDefault();
    const body = draft.trim();
    if (!body) {
      return;
    }

    startTransition(async () => {
      const result = await sendHubMessageAction({ hub, body });
      if (result.status === "error") {
        toast.error(result.message);
      } else {
        setDraft("");
      }
    });
  }

  if (!isMember) {
    return (
      <div className="flex flex-col items-center gap-2 rounded-xl border border-dashed px-6 py-12 text-center">
        <p className="font-medium">Join {hub} to chat with other members</p>
        <p className="text-sm text-muted-foreground">
          Chat is only visible to people in this hub.
        </p>
      </div>
    );
  }

  return (
    <div className="flex h-[28rem] flex-col rounded-xl border">
      <div className="flex-1 space-y-3 overflow-y-auto p-4">
        {messages.length === 0 ? (
          <p className="py-8 text-center text-sm text-muted-foreground">
            No messages yet — say hello.
          </p>
        ) : (
          messages.map((message) => {
            const isMine = message.senderId === currentUserId;
            return (
              <div
                key={message.id}
                className={cn(
                  "max-w-[80%] rounded-2xl px-3 py-2 text-sm",
                  isMine
                    ? "ml-auto bg-primary text-primary-foreground"
                    : "bg-muted",
                )}
              >
                {!isMine ? (
                  <p className="text-xs font-semibold opacity-70">
                    @{message.senderUsername}
                  </p>
                ) : null}
                <p className="whitespace-pre-line">{message.body}</p>
                <p className="mt-0.5 text-[10px] opacity-60">
                  <time dateTime={message.createdAt} suppressHydrationWarning>
                    {TIME_FORMAT.format(new Date(message.createdAt))}
                  </time>
                </p>
              </div>
            );
          })
        )}
        <div ref={bottomRef} />
      </div>
      <form onSubmit={handleSend} className="flex items-center gap-2 border-t p-3">
        <Input
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
          placeholder={`Message #${hub}`}
          maxLength={1000}
          disabled={isPending}
        />
        <Button
          type="submit"
          size="icon"
          disabled={isPending || !draft.trim()}
          aria-label="Send message"
        >
          {isPending ? (
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
          ) : (
            <Send className="h-4 w-4" aria-hidden />
          )}
        </Button>
      </form>
    </div>
  );
}
