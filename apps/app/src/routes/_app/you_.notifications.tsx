import { useState } from "react";
import { createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { toast } from "sonner";

import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { Field, FormError } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { Switch } from "@/components/ui/switch";
import {
  deviceTimeZone,
  fromTimeInput,
  notificationPrefsQuery,
  toTimeInput,
  updateNotificationPrefs,
  type NotificationPrefs,
  type PrefsPatch,
} from "@/lib/notifications";

const appRoute = getRouteApi("/_app");

/**
 * Notification settings at /you/notifications (a sibling of the You tab, like you_.photo.tsx).
 * Each switch writes one column of the viewer's notification_prefs row. The inbox always keeps
 * a copy; these choose what also goes out by email and push once that delivery starts.
 */
export const Route = createFileRoute("/_app/you_/notifications")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(notificationPrefsQuery(session.user.id));
  },
  component: NotificationSettingsPage,
});

type BoolKey =
  | "email_enabled"
  | "push_enabled"
  | "event_reminders"
  | "event_updates"
  | "hub_activity"
  | "messages"
  | "checkin_prompts"
  | "weekly_digest";

const CHANNELS: { key: BoolKey; label: string; hint: string }[] = [
  { key: "email_enabled", label: "Email", hint: "To the address you sign in with" },
  { key: "push_enabled", label: "Push", hint: "On devices where you allow it" },
];

const TOPICS: { key: BoolKey; label: string; hint: string }[] = [
  { key: "event_reminders", label: "Reminders", hint: "The day before and 2 hours before" },
  {
    key: "event_updates",
    label: "Plan changes",
    hint: "New time or place, cancellations, messages from the host",
  },
  {
    key: "hub_activity",
    label: "Your plans and hubs",
    hint: "Who joins plans you run, new plans in your hubs",
  },
  { key: "checkin_prompts", label: "Check-in prompts", hint: "After a plan you went to" },
  { key: "messages", label: "Messages", hint: "When chats arrive" },
  { key: "weekly_digest", label: "Weekly digest", hint: "What's coming up near you" },
];

function NotificationSettingsPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const prefs = useQuery(notificationPrefsQuery(userId));
  const key = notificationPrefsQuery(userId).queryKey;

  const save = useMutation({
    mutationFn: (patch: PrefsPatch) => updateNotificationPrefs(userId, patch),
    onMutate: async (patch) => {
      await queryClient.cancelQueries({ queryKey: key });
      const previous = queryClient.getQueryData(key);
      queryClient.setQueryData(key, (old) => (old ? { ...old, ...patch } : old));
      return { previous };
    },
    onError: (_err, _patch, ctx) => {
      if (ctx) queryClient.setQueryData(key, ctx.previous);
      toast.error("Couldn't save that. Try again.");
    },
    onSuccess: (row) => queryClient.setQueryData(key, row),
  });

  return (
    <>
      <TopBar title="Notifications" back />
      <main className="flex flex-col gap-6 pb-8 pt-2 safe-px">
        {prefs.isPending ? (
          <div className="flex flex-col gap-3" aria-busy="true">
            <Skeleton className="h-28 rounded-card" />
            <Skeleton className="h-64 rounded-card" />
          </div>
        ) : prefs.isError || !prefs.data ? (
          <div className="flex flex-col gap-3">
            <FormError>Couldn't load your settings. Check your connection and try again.</FormError>
            <Button variant="secondary" onClick={() => void prefs.refetch()}>
              Try again
            </Button>
          </div>
        ) : (
          <PrefsForm prefs={prefs.data} saving={save.isPending} onSave={(p) => save.mutate(p)} />
        )}
      </main>
    </>
  );
}

function PrefsForm({
  prefs,
  saving,
  onSave,
}: {
  prefs: NotificationPrefs;
  saving: boolean;
  onSave: (patch: PrefsPatch) => void;
}) {
  const paused = prefs.unsubscribed_all_at !== null;
  const device = deviceTimeZone();

  return (
    <>
      <p className="text-[14px] text-text-2">
        Your inbox always keeps a copy. These choose what also reaches you by email and push. Email
        and push are on their way; what you set here applies as soon as they start.
      </p>

      <section className="flex flex-col gap-2">
        <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">
          Pause everything
        </h3>
        <div className="rounded-card border border-border px-4 py-1">
          <Switch
            label="Pause all email and push"
            hint={
              paused
                ? "Paused. Only the inbox gets updates."
                : "Stops every email and push. The inbox keeps working."
            }
            checked={paused}
            onCheckedChange={(on) =>
              onSave({ unsubscribed_all_at: on ? new Date().toISOString() : null })
            }
          />
        </div>
      </section>

      <SwitchGroup title="How" rows={CHANNELS} prefs={prefs} disabled={paused} onSave={onSave} />
      <SwitchGroup title="What" rows={TOPICS} prefs={prefs} disabled={paused} onSave={onSave} />

      <QuietHours prefs={prefs} saving={saving} onSave={onSave} />

      {device && device !== prefs.timezone ? (
        <section className="flex flex-col gap-2 rounded-card border border-border px-4 py-3">
          <p className="text-[14px]">
            Quiet hours and reminders use <span className="font-semibold">{prefs.timezone}</span>.
            This device is on <span className="font-semibold">{device}</span>.
          </p>
          <Button
            variant="secondary"
            size="sm"
            className="self-start"
            onClick={() => onSave({ timezone: device })}
          >
            Use {device}
          </Button>
        </section>
      ) : null}
    </>
  );
}

function SwitchGroup({
  title,
  rows,
  prefs,
  disabled,
  onSave,
}: {
  title: string;
  rows: { key: BoolKey; label: string; hint: string }[];
  prefs: NotificationPrefs;
  disabled: boolean;
  onSave: (patch: PrefsPatch) => void;
}) {
  return (
    <section className="flex flex-col gap-2">
      <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">{title}</h3>
      <div className="divide-y divide-border rounded-card border border-border px-4">
        {rows.map((r) => (
          <Switch
            key={r.key}
            label={r.label}
            hint={r.hint}
            checked={prefs[r.key]}
            disabled={disabled}
            className="py-2"
            onCheckedChange={(on) => onSave({ [r.key]: on })}
          />
        ))}
      </div>
    </section>
  );
}

function QuietHours({
  prefs,
  saving,
  onSave,
}: {
  prefs: NotificationPrefs;
  saving: boolean;
  onSave: (patch: PrefsPatch) => void;
}) {
  const enabled = prefs.quiet_start !== null && prefs.quiet_end !== null;
  const [start, setStart] = useState(toTimeInput(prefs.quiet_start) || "22:00");
  const [end, setEnd] = useState(toTimeInput(prefs.quiet_end) || "08:00");
  const startValue = fromTimeInput(start);
  const endValue = fromTimeInput(end);
  const invalid = !startValue || !endValue || startValue === endValue;
  const dirty = startValue !== prefs.quiet_start || endValue !== prefs.quiet_end;

  return (
    <section className="flex flex-col gap-2">
      <h3 className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3">Quiet hours</h3>
      <div className="flex flex-col gap-3 rounded-card border border-border px-4 py-2">
        <Switch
          label="Hold push overnight"
          hint="Push waits until quiet hours end. Email and the inbox aren't held."
          checked={enabled}
          onCheckedChange={(on) =>
            onSave(
              on && !invalid
                ? { quiet_start: startValue, quiet_end: endValue }
                : { quiet_start: null, quiet_end: null },
            )
          }
        />
        {enabled ? (
          <div className="flex flex-col gap-3 pb-2">
            <div className="grid grid-cols-2 gap-3">
              <Field
                label="From"
                type="time"
                value={start}
                onChange={(e) => setStart(e.target.value)}
              />
              <Field
                label="Until"
                type="time"
                value={end}
                onChange={(e) => setEnd(e.target.value)}
              />
            </div>
            {invalid ? (
              <p className="text-[13px] font-medium text-danger" role="alert">
                Pick two different times.
              </p>
            ) : null}
            {dirty ? (
              <Button
                variant="secondary"
                className="self-start"
                disabled={invalid}
                loading={saving}
                onClick={() => onSave({ quiet_start: startValue, quiet_end: endValue })}
              >
                Save quiet hours
              </Button>
            ) : null}
          </div>
        ) : null}
      </div>
    </section>
  );
}
