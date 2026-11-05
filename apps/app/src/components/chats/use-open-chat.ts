import { useMutation, useQueryClient } from "@tanstack/react-query";
import { useNavigate } from "@tanstack/react-router";
import { toast } from "sonner";
import { chatError, chatErrorMessage } from "@ap/core/messaging";

import { chat, chatKeys } from "@/lib/messaging";

export type ChatTarget =
  | { kind: "dm"; userId: string }
  | { kind: "event"; eventId: string }
  | { kind: "hub"; hubId: string }
  | { kind: "chapter"; chapterId: string };

async function open(target: ChatTarget): Promise<string> {
  switch (target.kind) {
    case "dm":
      return (await chat.startDm(target.userId)).conversation_id;
    case "event":
      return chat.openEventChat(target.eventId);
    case "hub":
      return chat.openHubChat(target.hubId);
    case "chapter":
      return chat.openChapterChat(target.chapterId);
  }
}

/**
 * Opens (or starts) a chat and goes to it: start_dm for a person, open_event_chat,
 * open_hub_chat or open_chapter_chat for a room. Gate errors (photo, 24 hours, cooldown) are a
 * toast; the photo one links to /you/photo.
 */
export function useOpenChat(onOpened?: () => void) {
  const navigate = useNavigate();
  const queryClient = useQueryClient();
  return useMutation({
    mutationFn: open,
    onSuccess: async (conversationId) => {
      void queryClient.invalidateQueries({ queryKey: chatKeys.all });
      onOpened?.();
      await navigate({ to: "/chats/$id", params: { id: conversationId } });
    },
    onError: (err) => {
      const { code } = chatError(err);
      if (code === "photo_required") {
        toast.error(chatErrorMessage(err), {
          action: { label: "Add photo", onClick: () => void navigate({ to: "/you/photo" }) },
        });
      } else {
        toast.error(chatErrorMessage(err));
      }
    },
  });
}
