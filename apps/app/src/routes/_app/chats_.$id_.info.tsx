import { useState } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { Bell, BellOff, LogOut } from "lucide-react";
import { toast } from "sonner";
import {
  MUTE_CHOICES,
  chatErrorMessage,
  isMuted,
  kindLabel,
  muteUntil,
  type ConversationInfo,
  type MuteChoice,
} from "@ap/core/messaging";

import {
  PersonActionsButton,
  PersonSheet,
  type SafetyPerson,
} from "@/components/safety/person-sheet";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { FormError } from "@/components/ui/field";
import { Sheet } from "@/components/ui/sheet";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import { chat, chatKeys, conversationInfoQuery } from "@/lib/messaging";
import { SITE_URL } from "@/lib/site";

const appRoute = getRouteApi("/_app");

/**
 * Chat info (design 14.1): who is in it, mute and notifications, leave (DMs and groups), and the
 * person's profile card for Block and Report. Event, hub and chapter chats are left by leaving
 * the plan, hub or chapter; mute is the quiet option.
 */
export const Route = createFileRoute("/_app/chats_/$id_/info")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(conversationInfoQuery(params.id));
  },
  component: ChatInfoPage,
});

function muteText(until: string | null): string {
  if (!isMuted(until)) return "Off";
  if (until === "infinity") return "Until you turn it back on";
  const d = new Date(until ?? "");
  return `Until ${new Intl.DateTimeFormat("en-US", {
    weekday: "short",
    hour: "numeric",
    minute: "2-digit",
  }).format(d)}`;
}

function ChatInfoPage() {
  const { id } = Route.useParams();
  const info = useQuery(conversationInfoQuery(id));
  return (
    <>
      <TopBar title="Chat info" back />
      <main className="flex flex-col gap-6 pb-8 pt-2 safe-px">
        {info.isPending ? (
          <div className="flex flex-col gap-3" aria-busy="true">
            <Skeleton className="h-16 rounded-card" />
            <Skeleton className="h-24 rounded-card" />
          </div>
        ) : info.isError ? (
          <FormError>This conversation isn&apos;t available.</FormError>
        ) : (
          <InfoBody info={info.data} />
        )}
      </main>
    </>
  );
}

function InfoBody({ info }: { info: ConversationInfo }) {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const navigate = useNavigate();
  const [person, setPerson] = useState<SafetyPerson | null>(null);
  const [muteOpen, setMuteOpen] = useState(false);
  const [leaveOpen, setLeaveOpen] = useState(false);
  const id = info.conversation_id;
  const muted = isMuted(info.muted_until);

  const refresh = () => {
    void queryClient.invalidateQueries({ queryKey: chatKeys.info(id) });
    void queryClient.invalidateQueries({ queryKey: ["chats", "list", userId] });
    void queryClient.invalidateQueries({ queryKey: chatKeys.unread(userId) });
  };

  const mute = useMutation({
    mutationFn: (choice: MuteChoice | null) => chat.mute(id, choice ? muteUntil(choice) : null),
    onSuccess: (_r, choice) => {
      refresh();
      setMuteOpen(false);
      toast.success(choice ? "Muted. You won't get notifications from this chat." : "Unmuted.");
    },
    onError: (err) => toast.error(chatErrorMessage(err)),
  });
  const notify = useMutation({
    mutationFn: (on: boolean) => chat.setNotify(id, on),
    onSuccess: refresh,
    onError: (err) => toast.error(chatErrorMessage(err)),
  });
  const leave = useMutation({
    mutationFn: () => chat.leave(id),
    onSuccess: async () => {
      void queryClient.invalidateQueries({ queryKey: chatKeys.all });
      toast.success("You left the conversation.");
      await navigate({ to: "/chats", replace: true });
    },
    onError: (err) => toast.error(chatErrorMessage(err)),
  });

  const title =
    info.kind === "dm"
      ? (info.other?.first_name ?? "Conversation")
      : (info.title ?? kindLabel(info.kind));
  const people = info.kind === "dm" || info.kind === "group" ? (info.members ?? []) : info.admins;

  return (
    <>
      <section className="flex items-center gap-4">
        {info.kind === "dm" ? <Avatar src={info.other?.avatar_url} name={title} size={56} /> : null}
        <div className="min-w-0">
          <p className="truncate text-[20px] font-extrabold tracking-tight">{title}</p>
          <p className="text-[14px] text-text-2">
            {info.kind === "dm"
              ? info.other?.handle
                ? `@${info.other.handle}`
                : "Direct message"
              : `${kindLabel(info.kind)} · ${info.member_count} ${info.member_count === 1 ? "person" : "people"}`}
          </p>
        </div>
      </section>

      <ContextLink info={info} />

      <section className="flex flex-col gap-2">
        <h2 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
          Notifications
        </h2>
        <div className="flex flex-col gap-1 rounded-card border border-border px-4 py-2">
          <div className="flex min-h-11 items-center justify-between gap-3">
            <span className="min-w-0">
              <span className="block text-[15px] font-medium">Mute</span>
              <span className="block text-[13px] text-text-2">{muteText(info.muted_until)}</span>
            </span>
            {muted ? (
              <Button
                variant="secondary"
                size="sm"
                loading={mute.isPending}
                leading={<Bell className="size-4" aria-hidden="true" />}
                onClick={() => mute.mutate(null)}
              >
                Unmute
              </Button>
            ) : (
              <Button
                variant="secondary"
                size="sm"
                leading={<BellOff className="size-4" aria-hidden="true" />}
                onClick={() => setMuteOpen(true)}
              >
                Mute
              </Button>
            )}
          </div>
          <Switch
            label="Push notifications"
            hint={
              info.kind === "hub" || info.kind === "chapter"
                ? "Off by default for hub and chapter chats."
                : "No message text is ever shown in a notification."
            }
            checked={info.notify}
            disabled={notify.isPending}
            onCheckedChange={(v) => notify.mutate(v)}
          />
        </div>
      </section>

      {people.length > 0 ? (
        <section className="flex flex-col gap-2">
          <h2 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
            {info.kind === "dm" || info.kind === "group" ? "People" : "Hosts and organizers"}
          </h2>
          <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
            {people.map((p) => (
              <li key={p.id} className="flex min-h-14 items-center gap-3 px-4 py-2">
                <Avatar src={p.avatar_url} name={p.first_name} size={40} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[15px] font-semibold">
                    {p.id === userId ? `${p.first_name} (you)` : p.first_name}
                  </span>
                  <span className="block truncate text-[13px] text-text-2">
                    {"role" in p && p.role !== "member"
                      ? `${p.role === "owner" ? "Owner" : "Admin"} · `
                      : ""}
                    {p.handle ? `@${p.handle}` : ""}
                  </span>
                </span>
                {p.id === userId ? null : (
                  <PersonActionsButton
                    name={p.first_name}
                    onClick={() =>
                      setPerson({
                        user_id: p.id,
                        first_name: p.first_name,
                        handle: p.handle,
                        avatar_url: p.avatar_url,
                      })
                    }
                  />
                )}
              </li>
            ))}
          </ul>
        </section>
      ) : null}

      <section className="flex flex-col gap-2">
        {info.kind === "dm" && info.other ? (
          <Button
            variant="outline"
            block
            onClick={() =>
              setPerson({
                user_id: info.other!.id,
                first_name: info.other!.first_name,
                handle: info.other!.handle,
                avatar_url: info.other!.avatar_url,
              })
            }
          >
            Block or report {info.other.first_name}
          </Button>
        ) : null}
        {info.kind === "dm" || info.kind === "group" ? (
          <Button
            variant="danger"
            block
            leading={<LogOut className="size-4" aria-hidden="true" />}
            onClick={() => setLeaveOpen(true)}
          >
            Leave conversation
          </Button>
        ) : (
          <p className="text-[13px] text-text-2">
            To leave this chat, leave the {info.kind === "event" ? "plan" : info.kind}. Mute it if
            you just want quiet.
          </p>
        )}
        <a
          href={`${SITE_URL}/safety`}
          target="_blank"
          rel="noreferrer"
          className="self-start py-2 text-[14px] font-semibold text-link underline-offset-2 hover:underline"
        >
          Safety Center
        </a>
      </section>

      <Sheet open={muteOpen} onClose={() => setMuteOpen(false)} title="Mute this chat">
        <div className="flex flex-col gap-2 pt-1">
          <p className="text-[14px] text-text-2">
            You won&apos;t get notifications or a badge for it. Nobody is told.
          </p>
          {MUTE_CHOICES.map((c) => (
            <Button
              key={c.key}
              variant="secondary"
              block
              disabled={mute.isPending}
              onClick={() => mute.mutate(c.key)}
            >
              {c.label}
            </Button>
          ))}
        </div>
      </Sheet>

      <Sheet
        open={leaveOpen}
        onClose={() => setLeaveOpen(false)}
        title="Leave this conversation?"
        footer={
          <div className="grid grid-cols-2 gap-2">
            <Button variant="secondary" size="lg" onClick={() => setLeaveOpen(false)}>
              Back
            </Button>
            <Button
              variant="danger"
              size="lg"
              loading={leave.isPending}
              onClick={() => leave.mutate()}
            >
              Leave
            </Button>
          </div>
        }
      >
        <p className="pt-1 text-[15px] text-text-2">
          It leaves your Chats.{" "}
          {info.kind === "group"
            ? "Someone in the group can add you back."
            : "Messaging them again starts it back up."}
        </p>
      </Sheet>

      <PersonSheet person={person} viewerId={userId} onClose={() => setPerson(null)} />
    </>
  );
}

function ContextLink({ info }: { info: ConversationInfo }) {
  if (info.event_id) {
    return (
      <Link
        to="/events/$id"
        params={{ id: info.event_id }}
        className={buttonVariants({ variant: "secondary", block: true })}
      >
        Open the plan
      </Link>
    );
  }
  // Hub and chapter ids are not slugs; the chat list rows carry the slugs for those links.
  return null;
}
