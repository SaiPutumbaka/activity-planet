import { useQuery } from "@tanstack/react-query";
import { MessageCircle } from "lucide-react";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { recPrefsQuery, recsPeopleQuery } from "@/lib/recs";
import { RecCardMenu } from "./rec-card-menu";
import { ReasonChips } from "./reason-chips";
import { RecRow } from "./rec-row";

/**
 * "People you might click with" at the top of People you've met: only people you already share
 * a plan or a chapter with, and only when both of you leave suggestions on. The reasons name the
 * shared plan or chapter and nothing else.
 */
export function PeopleRow({ userId }: { userId: string }) {
  const prefs = useQuery(recPrefsQuery(userId));
  const off = prefs.data?.people_suggestions === false;
  const recs = useQuery({ ...recsPeopleQuery(userId), enabled: prefs.isSuccess && !off });
  const openChat = useOpenChat();
  const rows = recs.data ?? [];
  if (off || rows.length === 0) return null;
  return (
    <RecRow
      id="people-you-might-click-with"
      title="People you might click with"
      subtitle="From plans and chapters you share."
      layout="list"
    >
      {rows.map((p) => (
        <li
          key={p.user_id}
          data-testid="rec-person-card"
          className="flex min-h-16 items-center gap-3 rounded-card border border-border bg-surface px-3 py-2.5"
        >
          <Avatar src={p.avatar_url} name={p.first_name} size={44} />
          <span className="flex min-w-0 flex-1 flex-col gap-1">
            <span className="truncate text-[15px] font-semibold">{p.first_name}</span>
            <ReasonChips reasons={p.reasons} />
          </span>
          <Button
            variant="secondary"
            size="icon-sm"
            aria-label={`Message ${p.first_name}`}
            disabled={openChat.isPending}
            onClick={() => openChat.mutate({ kind: "dm", userId: p.user_id })}
          >
            <MessageCircle className="size-4" aria-hidden="true" />
          </Button>
          <RecCardMenu
            kind="person"
            id={p.user_id}
            name={p.first_name}
            reasons={p.reasons}
            why="people"
            className="inline-flex size-9 shrink-0 items-center justify-center rounded-full text-text-2 hover:bg-surface-2 hover:text-text"
          />
        </li>
      ))}
    </RecRow>
  );
}
