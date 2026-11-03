import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Check, PartyPopper } from "lucide-react";
import { toast } from "sonner";

import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import {
  MAX_MET,
  attendanceConfirmation,
  attendanceErrorMessage,
  attendanceKeys,
  myAttendanceQuery,
  pendingAttendancePromptsQuery,
  submitAttendance,
  toggleMet,
  type PromptAttendee,
  type SubmitResult,
} from "@/lib/attendance";
import { cn } from "@/lib/cn";
import { eventRsvpsQuery } from "@/lib/events";
import { notificationKeys } from "@/lib/notifications";

/**
 * The morning-after prompt (PLAN.md 4.9): step 1 "Did you go?" (Yes / No / Not now); for Yes,
 * step 2 "Who did you meet?" (pick from the other people who were going, skippable); then a
 * friendly confirmation. Opened from the Home card, the inbox's checkin_prompt row and the
 * event page's Over state. "Not now" only closes the sheet; the Home card's dismiss button is
 * what hides the prompt for good.
 *
 *   <MorningAfterSheet open={open} onClose={close} eventId={id} title={title} userId={uid} />
 */
export interface MorningAfterSheetProps {
  open: boolean;
  onClose: () => void;
  eventId: string;
  title: string;
  userId: string;
}

export function MorningAfterSheet(props: MorningAfterSheetProps) {
  // A fresh flow (step, picks) each time the sheet opens.
  return <MorningAfterFlow key={props.open ? props.eventId : "closed"} {...props} />;
}

type Step = "ask" | "met" | "done";

function MorningAfterFlow({ open, onClose, eventId, title, userId }: MorningAfterSheetProps) {
  const queryClient = useQueryClient();
  const [step, setStep] = useState<Step>("ask");
  const [picked, setPicked] = useState<string[] | null>(null);
  const [result, setResult] = useState<SubmitResult | null>(null);

  const mine = useQuery({ ...myAttendanceQuery(eventId, userId), enabled: open });
  const attendees = useSheetAttendees(eventId, userId, open);
  const selected = picked ?? (mine.data?.attended ? mine.data.met : []);

  const submit = useMutation({
    mutationFn: ({ attended, met }: { attended: boolean; met: string[] }) =>
      submitAttendance(eventId, attended, met),
    onSuccess: (res) => {
      setResult(res);
      setStep("done");
      void queryClient.invalidateQueries({ queryKey: attendanceKeys.all });
      void queryClient.invalidateQueries({ queryKey: notificationKeys.all });
      void queryClient.invalidateQueries({ queryKey: ["events", eventId] });
    },
    onError: (err) => toast.error(attendanceErrorMessage(err)),
  });

  function yes() {
    if (attendees.isPending || attendees.people.length > 0) setStep("met");
    else submit.mutate({ attended: true, met: [] });
  }

  const busy = submit.isPending;
  const sheetTitle = step === "done" ? "Thanks" : title;

  let body;
  let footer;
  if (step === "ask") {
    const earlier = mine.data?.answeredAt ? mine.data.attended : null;
    body = (
      <div className="flex flex-col gap-2 pt-1">
        <h3 className="text-[22px] font-extrabold tracking-[-0.02em]">Did you go?</h3>
        <p className="text-[15px] text-text-2">
          {earlier === true
            ? "You said you went. You can change your answer."
            : earlier === false
              ? "You said you didn't make it. You can change your answer."
              : "It helps the host, and it helps us show you more plans like this one."}
        </p>
      </div>
    );
    footer = (
      <>
        <div className="flex gap-2">
          <Button
            size="lg"
            className="flex-1"
            onClick={yes}
            disabled={busy}
            loading={busy && submit.variables?.attended === true}
          >
            Yes, I went
          </Button>
          <Button
            variant="secondary"
            size="lg"
            className="flex-1"
            onClick={() => submit.mutate({ attended: false, met: [] })}
            disabled={busy}
            loading={busy && submit.variables?.attended === false}
          >
            No
          </Button>
        </div>
        <Button variant="ghost" block onClick={onClose} disabled={busy}>
          Not now
        </Button>
      </>
    );
  } else if (step === "met") {
    body = (
      <div className="flex flex-col gap-3 pt-1">
        <div className="flex flex-col gap-1">
          <h3 className="text-[22px] font-extrabold tracking-[-0.02em]">Who did you meet?</h3>
          <p className="text-[14px] text-text-2">
            Pick anyone you talked to. Only you can see who you picked.
          </p>
        </div>
        {attendees.isPending ? (
          <div className="grid grid-cols-3 gap-2" aria-busy="true">
            {Array.from({ length: 6 }, (_, i) => (
              <Skeleton key={i} className="h-24 rounded-card" />
            ))}
          </div>
        ) : attendees.people.length === 0 ? (
          <p className="text-[15px] text-text-2">Nobody else was on the list for this one.</p>
        ) : (
          <ul className="grid grid-cols-3 gap-2" aria-label="People who were going">
            {attendees.people.map((p) => {
              const on = selected.includes(p.id);
              const full = !on && selected.length >= MAX_MET;
              return (
                <li key={p.id}>
                  <button
                    type="button"
                    aria-pressed={on}
                    disabled={busy || full}
                    onClick={() => setPicked(toggleMet(selected, p.id))}
                    className={cn(
                      "relative flex w-full flex-col items-center gap-1.5 rounded-card border px-1 py-3 text-center transition-colors disabled:opacity-50",
                      on
                        ? "border-primary bg-primary-tint"
                        : "border-border bg-surface hover:bg-surface-2",
                    )}
                  >
                    <Avatar src={p.avatar_url} name={p.first_name} size={48} />
                    <span className="w-full truncate text-[14px] font-semibold">
                      {p.first_name}
                    </span>
                    {on ? (
                      <span
                        aria-hidden="true"
                        className="absolute top-1.5 right-1.5 flex size-5 items-center justify-center rounded-full bg-primary text-on-primary"
                      >
                        <Check className="size-3.5" />
                      </span>
                    ) : null}
                  </button>
                </li>
              );
            })}
          </ul>
        )}
        {selected.length >= MAX_MET ? (
          <p className="text-[13px] text-text-2">That's the most you can pick ({MAX_MET}).</p>
        ) : null}
      </div>
    );
    footer = (
      <>
        <Button
          size="lg"
          block
          disabled={busy || selected.length === 0}
          loading={busy && (submit.variables?.met.length ?? 0) > 0}
          onClick={() => submit.mutate({ attended: true, met: selected })}
        >
          {selected.length > 0 ? `Done · ${selected.length}` : "Done"}
        </Button>
        <Button
          variant="ghost"
          block
          disabled={busy}
          loading={busy && submit.variables?.met.length === 0}
          onClick={() => submit.mutate({ attended: true, met: [] })}
        >
          Skip
        </Button>
      </>
    );
  } else {
    const copy = attendanceConfirmation(result ?? { attended: true, metCount: 0 });
    body = (
      <div className="flex flex-col items-center gap-3 py-4 text-center" role="status">
        <span
          aria-hidden="true"
          className="flex size-14 items-center justify-center rounded-full bg-going-tint text-going"
        >
          {result?.attended === false ? (
            <Check className="size-7" />
          ) : (
            <PartyPopper className="size-7" />
          )}
        </span>
        <h3 className="text-[22px] font-extrabold tracking-[-0.02em]">{copy.title}</h3>
        <p className="text-[15px] text-text-2">{copy.body}</p>
      </div>
    );
    footer = (
      <Button size="lg" block onClick={onClose}>
        Close
      </Button>
    );
  }

  return (
    <Sheet open={open} onClose={onClose} title={sheetTitle} footer={footer}>
      {body}
    </Sheet>
  );
}

/**
 * The people to pick from: the Home prompt's list when the plan is still pending (active
 * profiles, checked-in first), else the plan's going RSVPs. Never the viewer.
 */
function useSheetAttendees(eventId: string, userId: string, open: boolean) {
  const prompts = useQuery({ ...pendingAttendancePromptsQuery(userId), enabled: open });
  const fromPrompt = prompts.data?.find((p) => p.event_id === eventId)?.attendees;
  const needRsvps = open && !prompts.isPending && !fromPrompt;
  const rsvps = useQuery({ ...eventRsvpsQuery(eventId), enabled: needRsvps });

  if (fromPrompt) {
    return { isPending: false, people: fromPrompt.filter((p) => p.id !== userId) };
  }
  if (prompts.isPending || (needRsvps && rsvps.isPending)) {
    return { isPending: true, people: [] as PromptAttendee[] };
  }
  const people: PromptAttendee[] = (rsvps.data ?? [])
    .filter((r) => r.status === "going" && r.user_id !== userId && r.profiles)
    .map((r) => ({
      id: r.user_id,
      first_name: r.profiles?.first_name ?? "Member",
      avatar_url: r.profiles?.avatar_url ?? null,
    }));
  return { isPending: false, people };
}
