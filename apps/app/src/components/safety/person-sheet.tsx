import { useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { BellOff, Bell, Ellipsis, Flag, Ban, MessageCircle } from "lucide-react";
import { toast } from "sonner";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import {
  blockUser,
  blockedText,
  muteUser,
  myMutesQuery,
  reportTitle,
  safetyErrorMessage,
  safetyKeys,
  unmuteUser,
} from "@/lib/safety";
import { SITE_URL } from "@/lib/site";

import { ReportForm } from "./report-form";

export interface SafetyPerson {
  user_id: string;
  first_name: string;
  handle?: string | null;
  avatar_url?: string | null;
}

type Step = "profile" | "block" | "mute" | "report";

/**
 * A person's profile card with Message (start_dm, migration 58), Mute, Block and Report
 * (migration 51). Every action asks first.
 * A block works both ways and the other person isn't told; a mute only quiets notifications.
 *
 *   <PersonSheet person={p} viewerId={userId} onClose={() => setPerson(null)} />
 */
export function PersonSheet({
  person,
  viewerId,
  onClose,
}: {
  /** null keeps the sheet closed. */
  person: SafetyPerson | null;
  viewerId: string;
  onClose: () => void;
}) {
  const queryClient = useQueryClient();
  const [step, setStep] = useState<Step>("profile");
  const mutes = useQuery({ ...myMutesQuery(viewerId), enabled: person !== null });
  const muted = person ? (mutes.data ?? []).includes(person.user_id) : false;
  const name = person?.first_name ?? "this person";

  function close() {
    setStep("profile");
    onClose();
  }

  const openChat = useOpenChat(() => {
    setStep("profile");
    onClose();
  });

  const block = useMutation({
    mutationFn: (userId: string) => blockUser(userId),
    onSuccess: (r) => {
      // Profiles, RSVP rows, members and the feed all change across a block.
      void queryClient.invalidateQueries();
      toast.success(blockedText(name, r));
      close();
    },
    onError: (err) => toast.error(safetyErrorMessage(err)),
  });

  const mute = useMutation({
    mutationFn: ({ userId, on }: { userId: string; on: boolean }) =>
      on ? muteUser(userId) : unmuteUser(userId),
    onSuccess: (_r, { on }) => {
      void queryClient.invalidateQueries({ queryKey: safetyKeys.mutes(viewerId) });
      toast.success(on ? `You muted ${name}.` : `You unmuted ${name}.`);
      close();
    },
    onError: (err) => toast.error(safetyErrorMessage(err)),
  });

  const isSelf = person?.user_id === viewerId;
  const title =
    step === "block"
      ? `Block ${name}?`
      : step === "mute"
        ? `Mute ${name}?`
        : step === "report"
          ? reportTitle("profile", person?.first_name)
          : name;

  return (
    <Sheet
      open={person !== null}
      onClose={close}
      title={title}
      footer={
        person && step === "block" ? (
          <ConfirmFooter
            confirm="Block"
            variant="danger"
            loading={block.isPending}
            onConfirm={() => block.mutate(person.user_id)}
            onCancel={() => setStep("profile")}
          />
        ) : person && step === "mute" ? (
          <ConfirmFooter
            confirm="Mute"
            variant="primary"
            loading={mute.isPending}
            onConfirm={() => mute.mutate({ userId: person.user_id, on: true })}
            onCancel={() => setStep("profile")}
          />
        ) : undefined
      }
    >
      {!person ? null : step === "profile" ? (
        <div className="flex flex-col gap-5 pt-1">
          <div className="flex items-center gap-4">
            <Avatar src={person.avatar_url} name={person.first_name} size={64} />
            <div className="min-w-0">
              <p className="truncate text-[20px] font-extrabold tracking-tight">
                {person.first_name}
              </p>
              {person.handle ? <p className="truncate text-text-2">@{person.handle}</p> : null}
            </div>
          </div>
          {isSelf ? null : (
            <div className="flex flex-col gap-2">
              <Button
                variant="primary"
                block
                leading={<MessageCircle className="size-4" aria-hidden="true" />}
                loading={openChat.isPending}
                onClick={() => openChat.mutate({ kind: "dm", userId: person.user_id })}
              >
                Message
              </Button>
              {muted ? (
                <Button
                  variant="secondary"
                  block
                  leading={<Bell className="size-4" aria-hidden="true" />}
                  loading={mute.isPending}
                  onClick={() => mute.mutate({ userId: person.user_id, on: false })}
                >
                  Unmute
                </Button>
              ) : (
                <Button
                  variant="secondary"
                  block
                  leading={<BellOff className="size-4" aria-hidden="true" />}
                  onClick={() => setStep("mute")}
                >
                  Mute
                </Button>
              )}
              <Button
                variant="danger"
                block
                leading={<Ban className="size-4" aria-hidden="true" />}
                onClick={() => setStep("block")}
              >
                Block
              </Button>
              <Button
                variant="outline"
                block
                leading={<Flag className="size-4" aria-hidden="true" />}
                onClick={() => setStep("report")}
              >
                Report
              </Button>
            </div>
          )}
        </div>
      ) : step === "block" ? (
        <div className="flex flex-col gap-3 pt-1 text-[15px] text-text-2">
          <p>A block works both ways, and {name} isn&apos;t told.</p>
          <ul className="flex list-disc flex-col gap-1.5 pl-5">
            <li>Neither of you sees the other&apos;s profile, RSVPs or memberships.</li>
            <li>They stop showing up in your notifications and after-plan lists.</li>
            <li>
              If you&apos;re both on a plan, only you get a heads-up, so you can decide whether to
              go.
            </li>
            <li>You can unblock them later in You, Blocked accounts.</li>
          </ul>
          <p className="text-[13px]">
            Feel unsafe? Report them too, or read the{" "}
            <a
              href={`${SITE_URL}/safety`}
              target="_blank"
              rel="noreferrer"
              className="font-semibold text-link underline-offset-2 hover:underline"
            >
              safety tips
            </a>
            .
          </p>
        </div>
      ) : step === "mute" ? (
        <p className="pt-1 text-[15px] text-text-2">
          You stop getting notifications about what {name} does. Nothing else changes, and they
          can&apos;t tell. You can unmute them from here any time.
        </p>
      ) : (
        <ReportForm
          kind="profile"
          targetId={person.user_id}
          onDone={close}
          onCancel={() => setStep("profile")}
        />
      )}
    </Sheet>
  );
}

function ConfirmFooter({
  confirm,
  variant,
  loading,
  onConfirm,
  onCancel,
}: {
  confirm: string;
  variant: "danger" | "primary";
  loading: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  return (
    <div className="grid grid-cols-2 gap-2">
      <Button variant="secondary" size="lg" onClick={onCancel} disabled={loading}>
        Back
      </Button>
      <Button variant={variant} size="lg" loading={loading} onClick={onConfirm}>
        {confirm}
      </Button>
    </div>
  );
}

/** The "more" button on a person's row that opens their profile card. */
export function PersonActionsButton({ name, onClick }: { name: string; onClick: () => void }) {
  return (
    <Button
      variant="ghost"
      size="icon"
      className="text-text-2"
      aria-label={`Profile and safety options for ${name}`}
      aria-haspopup="dialog"
      onClick={onClick}
    >
      <Ellipsis className="size-5" aria-hidden="true" />
    </Button>
  );
}
