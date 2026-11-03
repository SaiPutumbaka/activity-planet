import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { X } from "lucide-react";
import { toast } from "sonner";

import { AvatarStack } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import {
  attendanceErrorMessage,
  attendanceKeys,
  attendeesLine,
  dismissAttendancePrompt,
  pendingAttendancePromptsQuery,
  type AttendancePrompt,
} from "@/lib/attendance";
import { formatEventTime } from "@/lib/datetime";
import { notificationKeys } from "@/lib/notifications";
import { MorningAfterSheet } from "./morning-after-sheet";

/**
 * Top of Home: the newest plan the viewer went to (or meant to) and hasn't answered for yet.
 * Renders nothing while loading, on error, or when there is nothing to ask.
 */
export function AttendancePromptCard({ userId }: { userId: string }) {
  const prompts = useQuery(pendingAttendancePromptsQuery(userId));
  const [openId, setOpenId] = useState<string | null>(null);
  const items = prompts.data ?? [];
  const prompt = items[0];
  // Keep the sheet mounted on the plan it opened for, even after answering drops it from the list.
  const [sheetTitle, setSheetTitle] = useState("");

  if (!prompt && !openId) return null;

  return (
    <>
      {prompt ? (
        <PromptCard
          prompt={prompt}
          more={items.length - 1}
          onAnswer={() => {
            setSheetTitle(prompt.title);
            setOpenId(prompt.event_id);
          }}
        />
      ) : null}
      {openId ? (
        <MorningAfterSheet
          open
          onClose={() => setOpenId(null)}
          eventId={openId}
          title={sheetTitle}
          userId={userId}
        />
      ) : null}
    </>
  );
}

function PromptCard({
  prompt,
  more,
  onAnswer,
}: {
  prompt: AttendancePrompt;
  more: number;
  onAnswer: () => void;
}) {
  const queryClient = useQueryClient();
  const dismiss = useMutation({
    mutationFn: () => dismissAttendancePrompt(prompt.event_id),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: attendanceKeys.all });
      void queryClient.invalidateQueries({ queryKey: notificationKeys.all });
    },
    onError: (err) => toast.error(attendanceErrorMessage(err)),
  });
  const line = attendeesLine(prompt.attendees);

  return (
    <section
      aria-labelledby={`prompt-${prompt.event_id}`}
      className="flex flex-col gap-3 rounded-card border border-border bg-surface p-4"
    >
      <div className="flex items-start gap-2">
        <div className="min-w-0 flex-1">
          <p className="text-[13px] font-semibold text-text-2">
            <span aria-hidden="true">{prompt.hub_emoji}</span> {prompt.hub_name} ·{" "}
            {formatEventTime(prompt.starts_at, prompt.ends_at, prompt.timezone)}
          </p>
          <h3
            id={`prompt-${prompt.event_id}`}
            className="mt-0.5 text-[17px] font-bold tracking-[-0.01em] text-balance"
          >
            Did you go to{" "}
            <Link
              to="/events/$id"
              params={{ id: prompt.event_id }}
              className="underline-offset-2 hover:underline"
            >
              {prompt.title}
            </Link>
            ?
          </h3>
        </div>
        <Button
          variant="secondary"
          size="icon-sm"
          className="-mt-1 -mr-1 rounded-full"
          aria-label={`Don't ask about ${prompt.title}`}
          loading={dismiss.isPending}
          onClick={() => dismiss.mutate()}
        >
          <X className="size-4" aria-hidden="true" />
        </Button>
      </div>
      {line ? (
        <AvatarStack
          people={prompt.attendees.map((a) => ({ src: a.avatar_url, name: a.first_name }))}
          max={4}
          size={28}
          totalLabel={line}
        />
      ) : null}
      <div className="flex items-center gap-3">
        <Button onClick={onAnswer}>Tell us</Button>
        {more > 0 ? (
          <span className="text-[13px] text-text-2">
            {more === 1 ? "1 more plan to answer" : `${more} more plans to answer`}
          </span>
        ) : null}
      </div>
    </section>
  );
}
