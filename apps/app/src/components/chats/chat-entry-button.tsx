import { MessageCircle } from "lucide-react";

import { Button } from "@/components/ui/button";

import { useOpenChat, type ChatTarget } from "./use-open-chat";

/**
 * "Chat" on a plan, hub or chapter page, for the people in it (design 14.1). The server decides
 * membership; a refusal is a toast.
 *
 *   <ChatEntryButton target={{ kind: "event", eventId }} label="Plan chat" />
 */
export function ChatEntryButton({
  target,
  label = "Chat",
  className,
}: {
  target: ChatTarget;
  label?: string;
  className?: string;
}) {
  const openChat = useOpenChat();
  return (
    <Button
      variant="secondary"
      className={className}
      loading={openChat.isPending}
      leading={<MessageCircle className="size-4" aria-hidden="true" />}
      onClick={() => openChat.mutate(target)}
    >
      {label}
    </Button>
  );
}
