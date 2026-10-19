import { createFileRoute } from "@tanstack/react-router";
import { MessageCircle } from "lucide-react";

import { TopBar } from "@/components/shell/top-bar";
import { ComingSoon } from "@/components/shell/coming-soon";

export const Route = createFileRoute("/_app/chats")({
  component: () => (
    <>
      <TopBar title="Chats" />
      <ComingSoon
        icon={MessageCircle}
        title="Every plan gets a chat"
        body="Event threads, hub chats and direct messages, with block, report and mute from day one. Arrives in week 5."
      />
    </>
  ),
});
