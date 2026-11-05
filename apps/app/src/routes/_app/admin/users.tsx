import { useState, type FormEvent } from "react";
import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Search, UserX } from "lucide-react";
import { toast } from "sonner";
import { z } from "zod";

import { AdminTabs } from "@/components/admin/admin-tabs";
import { ModeratorGate } from "@/components/admin/moderator-gate";
import { InlineError, ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { Field } from "@/components/ui/field";
import { FieldTextArea } from "@/components/ui/textarea";
import {
  MAX_REASON_LENGTH,
  STATUS_LABELS,
  actionLabel,
  adminErrorMessage,
  adminKeys,
  banUser,
  formatWhen,
  reasonError,
  searchQueryKind,
  targetKindLabel,
  unbanUser,
  userRecordQuery,
  userSearchQuery,
  type UserRecord,
} from "@/lib/admin";

const searchSchema = z.object({
  q: z.string().max(254).optional(),
  user: z.string().uuid().optional(),
});

/**
 * User lookup (mod_user_search, mod_user_lookup; migration 53) with ban and unban
 * (mod_ban_user, mod_unban_user; migration 51). Minimal fields only, never email, birth date or
 * location. The database logs every search and every record opened, so a search runs on
 * submit, not as you type. A ban needs a reason; it goes in the moderation log.
 */
export const Route = createFileRoute("/_app/admin/users")({
  validateSearch: searchSchema,
  component: UsersPage,
});

function UsersPage() {
  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/users" />
        <ModeratorGate>
          <Lookup />
        </ModeratorGate>
      </main>
    </>
  );
}

function Lookup() {
  const search = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });
  const [draft, setDraft] = useState(search.q ?? "");
  const [error, setError] = useState<string | undefined>();
  const q = search.q ?? "";

  function onSubmit(e: FormEvent) {
    e.preventDefault();
    const t = draft.trim();
    if (!searchQueryKind(t)) {
      setError("Type a handle (2 or more characters), an account email or a user id.");
      return;
    }
    setError(undefined);
    void navigate({ search: { q: t }, replace: true });
  }

  return (
    <>
      <form onSubmit={onSubmit} className="flex flex-col gap-2" role="search">
        <Field
          label="Find an account"
          hint="Handle, account email or user id. Every search is logged."
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          autoComplete="off"
          autoCapitalize="none"
          spellCheck={false}
          error={error}
        />
        <div className="flex justify-end">
          <Button type="submit" size="sm" variant="secondary">
            <Search className="size-4" aria-hidden="true" />
            Search
          </Button>
        </div>
      </form>
      {search.user ? (
        <UserPanel
          userId={search.user}
          onClose={() => void navigate({ search: { q: q || undefined }, replace: true })}
        />
      ) : q ? (
        <Results q={q} onOpen={(id) => void navigate({ search: { q, user: id } })} />
      ) : null}
    </>
  );
}

function Results({ q, onOpen }: { q: string; onOpen: (id: string) => void }) {
  const rows = useQuery(userSearchQuery(q));
  if (rows.isPending) return <ListSkeleton rows={3} />;
  if (rows.isError) {
    return (
      <InlineError message={adminErrorMessage(rows.error)} onRetry={() => void rows.refetch()} />
    );
  }
  if (rows.data.length === 0) {
    return (
      <EmptyState icon={UserX} title="No accounts found" body="Check the spelling and try again." />
    );
  }
  return (
    <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
      {rows.data.map((r) => (
        <li key={r.id}>
          <button
            type="button"
            onClick={() => onOpen(r.id)}
            className="flex min-h-14 w-full items-center gap-3 px-4 py-3 text-left transition-colors hover:bg-surface-2"
          >
            <Avatar src={r.avatar_url} name={r.first_name || r.handle} size={36} />
            <span className="min-w-0 flex-1">
              <span className="block truncate text-[15px] font-medium">{r.first_name}</span>
              <span className="block truncate text-[13px] text-text-2">@{r.handle}</span>
            </span>
            <span className="shrink-0 text-[13px] text-text-2">
              {STATUS_LABELS[r.status] ?? r.status}
            </span>
          </button>
        </li>
      ))}
    </ul>
  );
}

function UserPanel({ userId, onClose }: { userId: string; onClose: () => void }) {
  const record = useQuery(userRecordQuery(userId));
  if (record.isPending) return <ListSkeleton rows={2} rowClassName="h-40" />;
  if (record.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't open this account"
        body={adminErrorMessage(record.error)}
        action={
          <Button variant="secondary" onClick={onClose}>
            Back to results
          </Button>
        }
      />
    );
  }
  return <UserCard u={record.data} onClose={onClose} />;
}

function UserCard({ u, onClose }: { u: UserRecord; onClose: () => void }) {
  const c = u.counts;
  const facts: [string, string | number][] = [
    ["Status", STATUS_LABELS[u.status] ?? u.status],
    [
      "Joined",
      `${formatWhen(u.joined_at)} (${u.account_days} ${u.account_days === 1 ? "day" : "days"})`,
    ],
    ["Set up", u.onboarded ? "Finished" : "Not finished"],
    ["Roles", u.roles.length ? u.roles.join(", ") : "Member"],
    ["Profile", u.moderation_state === "hidden" ? "Hidden for review" : "Visible"],
    ["Open reports", c.open_reports],
    ["Reports about them", c.reports_total],
    ["Reports they filed, 30 days", c.reports_filed_30d],
    ["Plans hosted", `${c.hosted_total} (${c.hosted_upcoming} upcoming)`],
    ["Upcoming RSVPs", c.rsvps_upcoming],
    ["Chapters they run", c.chapters_running],
    ["Image requests about them", c.takedowns_about],
  ];
  return (
    <article className="flex flex-col gap-4 rounded-card border border-border p-4">
      <header className="flex items-center gap-3">
        <Avatar src={u.avatar_url} name={u.first_name || u.handle} size={48} />
        <div className="min-w-0 flex-1">
          <h2 className="truncate text-[17px] font-bold">{u.first_name}</h2>
          <p className="truncate text-[14px] text-text-2">@{u.handle}</p>
        </div>
        <Button size="sm" variant="ghost" onClick={onClose}>
          Close
        </Button>
      </header>
      {u.bio ? <p className="text-[14px] break-words whitespace-pre-wrap">{u.bio}</p> : null}

      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        {facts.map(([k, v]) => (
          <div key={k} className="contents">
            <dt className="text-text-2">{k}</dt>
            <dd className="min-w-0 break-words tabular">{v}</dd>
          </div>
        ))}
      </dl>

      <section className="flex flex-col gap-1 text-[14px]" aria-label="Moderation history">
        <p className="font-semibold">Moderation history</p>
        {u.actions.length === 0 ? (
          <p className="text-text-2">Nothing yet.</p>
        ) : (
          <ul className="flex flex-col gap-1">
            {u.actions.map((a, i) => (
              <li key={i} className="break-words">
                <span className="font-medium">{actionLabel(a.action)}</span>
                <span className="text-text-2">
                  {" "}
                  · {targetKindLabel(a.kind)} · {formatWhen(a.created_at)}
                  {a.automatic ? " · automatic" : a.by_me ? " · you" : ""}
                </span>
                {a.note ? <span className="block text-text-2">“{a.note}”</span> : null}
              </li>
            ))}
          </ul>
        )}
      </section>

      {u.is_self ? (
        <p className="text-[14px] text-text-2">This is your account.</p>
      ) : u.can_ban || u.can_unban ? (
        <BanForm u={u} />
      ) : u.status !== "deleted" ? (
        <p className="text-[14px] text-text-2">
          {u.roles.includes("admin")
            ? "Admins can't be banned."
            : u.roles.length
              ? "Only an admin can ban a moderator."
              : "This one involves you. Another moderator handles it."}
        </p>
      ) : null}
    </article>
  );
}

function BanForm({ u }: { u: UserRecord }) {
  const queryClient = useQueryClient();
  const [reason, setReason] = useState("");
  const [touched, setTouched] = useState(false);
  const [confirming, setConfirming] = useState(false);
  const unban = u.can_unban;
  const err = reasonError(reason);

  const act = useMutation({
    mutationFn: () => (unban ? unbanUser(u.id, reason) : banUser(u.id, reason)),
    onSuccess: () => {
      setReason("");
      setTouched(false);
      setConfirming(false);
      void queryClient.invalidateQueries({ queryKey: adminKeys.all });
      toast.success(unban ? "Ban lifted." : "Account banned.");
    },
    onError: (e) => toast.error(adminErrorMessage(e)),
  });

  return (
    <form
      className="flex flex-col gap-2 border-t border-border pt-4"
      onSubmit={(e) => {
        e.preventDefault();
        setTouched(true);
        if (err) return;
        if (!unban && !confirming) {
          setConfirming(true);
          return;
        }
        act.mutate();
      }}
    >
      <FieldTextArea
        label={unban ? "Why lift the ban?" : "Why ban this account?"}
        hint={
          unban
            ? "Goes in the moderation log. Cancelled plans and removed RSVPs stay as they are."
            : "Goes in the moderation log. Signing in stops at once, their upcoming plans are cancelled with attendees told, and their RSVPs go."
        }
        rows={3}
        maxLength={MAX_REASON_LENGTH}
        value={reason}
        onChange={(e) => {
          setReason(e.target.value);
          setConfirming(false);
        }}
        onBlur={() => setTouched(true)}
        error={touched && err ? err : undefined}
        disabled={act.isPending}
      />
      {confirming ? (
        <p role="alert" className="rounded-tile bg-danger-tint p-3 text-[14px] text-danger">
          Ban @{u.handle}? You can lift it later, but cancelled plans won't come back.
        </p>
      ) : null}
      <div className="flex flex-wrap justify-end gap-2">
        {confirming ? (
          <Button
            type="button"
            size="sm"
            variant="secondary"
            disabled={act.isPending}
            onClick={() => setConfirming(false)}
          >
            Cancel
          </Button>
        ) : null}
        <Button
          type="submit"
          size="sm"
          variant={unban ? "secondary" : "danger"}
          loading={act.isPending}
          disabled={act.isPending}
        >
          {unban ? "Lift ban" : confirming ? "Ban account" : "Ban…"}
        </Button>
      </div>
    </form>
  );
}
