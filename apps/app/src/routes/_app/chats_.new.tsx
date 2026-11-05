import { useState } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery } from "@tanstack/react-query";
import { Check, Search, UsersRound } from "lucide-react";
import { toast } from "sonner";
import { chatErrorMessage } from "@ap/core/messaging";

import { useOpenChat } from "@/components/chats/use-open-chat";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/ui/empty-state";
import { Field } from "@/components/ui/field";
import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";
import { chat, peopleYouMetQuery, personSearchQuery } from "@/lib/messaging";
import { useDebouncedValue } from "@/lib/use-debounced-value";

const appRoute = getRouteApi("/_app");

/**
 * New message (design 14.1): People you've met first, then a handle search. Tap a person to
 * message them; "New group" picks several. Someone you share no plan, hub or chapter with gets a
 * message request (one text message, accounts at least a day old).
 */
export const Route = createFileRoute("/_app/chats_/new")({
  loader: ({ context: { queryClient, session } }) => {
    void queryClient.prefetchQuery(peopleYouMetQuery(session.user.id));
  },
  component: NewChatPage,
});

interface Pickable {
  id: string;
  first_name: string;
  handle: string | null;
  avatar_url: string | null;
  hint?: string;
}

function NewChatPage() {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const navigate = useNavigate();
  const [q, setQ] = useState("");
  const term = useDebouncedValue(q.trim(), 300);
  const [group, setGroup] = useState(false);
  const [picked, setPicked] = useState<Map<string, Pickable>>(new Map());
  const [title, setTitle] = useState("");
  const met = useQuery(peopleYouMetQuery(userId));
  const search = useQuery({ ...personSearchQuery(term, userId), enabled: term.length >= 2 });
  const openChat = useOpenChat();

  const create = useMutation({
    mutationFn: () => chat.createGroup(title, [...picked.keys()]),
    onSuccess: async (r) => {
      if (r.skipped > 0) {
        toast(
          r.skipped === 1
            ? "1 person couldn't be added. Groups are for people you share a plan, hub or chapter with."
            : `${r.skipped} people couldn't be added. Groups are for people you share a plan, hub or chapter with.`,
        );
      }
      await navigate({ to: "/chats/$id", params: { id: r.conversation_id } });
    },
    onError: (err) => toast.error(chatErrorMessage(err)),
  });

  const metRows: Pickable[] = (met.data ?? []).map((p) => ({
    id: p.user_id,
    first_name: p.first_name,
    handle: p.handle,
    avatar_url: p.avatar_url,
    hint: p.last_plan?.title ? `Met at ${p.last_plan.title}` : undefined,
  }));
  const searchRows: Pickable[] = (search.data ?? []).map((p) => ({ ...p }));

  function choose(p: Pickable) {
    if (!group) {
      openChat.mutate({ kind: "dm", userId: p.id });
      return;
    }
    setPicked((prev) => {
      const next = new Map(prev);
      if (next.has(p.id)) next.delete(p.id);
      else next.set(p.id, p);
      return next;
    });
  }

  const list = (rows: Pickable[], label: string) => (
    <ul
      className="divide-y divide-border overflow-hidden rounded-card border border-border"
      aria-label={label}
    >
      {rows.map((p) => {
        const on = picked.has(p.id);
        return (
          <li key={p.id}>
            <button
              type="button"
              onClick={() => choose(p)}
              disabled={openChat.isPending}
              aria-pressed={group ? on : undefined}
              aria-label={
                group ? `${on ? "Remove" : "Add"} ${p.first_name}` : `Message ${p.first_name}`
              }
              className="flex min-h-14 w-full items-center gap-3 px-4 py-2.5 text-left transition-colors hover:bg-surface-2 disabled:opacity-60"
            >
              <Avatar src={p.avatar_url} name={p.first_name} size={40} />
              <span className="min-w-0 flex-1">
                <span className="block truncate text-[15px] font-semibold">{p.first_name}</span>
                <span className="block truncate text-[13px] text-text-2">
                  {p.hint ?? (p.handle ? `@${p.handle}` : "")}
                </span>
              </span>
              {group ? (
                <span
                  aria-hidden="true"
                  className={cn(
                    "flex size-6 shrink-0 items-center justify-center rounded-full border",
                    on ? "border-text bg-text text-surface" : "border-border-strong",
                  )}
                >
                  {on ? <Check className="size-4" /> : null}
                </span>
              ) : null}
            </button>
          </li>
        );
      })}
    </ul>
  );

  return (
    <>
      <TopBar
        title={group ? "New group" : "New message"}
        back
        actions={
          <Button
            variant="ghost"
            size="sm"
            onClick={() => {
              setGroup((g) => !g);
              setPicked(new Map());
            }}
          >
            {group ? "Cancel group" : "New group"}
          </Button>
        }
      />
      <main className="flex flex-col gap-5 pb-8 pt-2 safe-px">
        {group ? (
          <section className="flex flex-col gap-3">
            <Field
              label="Group name"
              maxLength={60}
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              hint="Pick two or more people you share a plan, hub or chapter with. Up to 50."
            />
            <Button
              block
              loading={create.isPending}
              disabled={picked.size < 2 || title.trim().length === 0}
              onClick={() => create.mutate()}
            >
              {picked.size > 0 ? `Create group with ${picked.size}` : "Create group"}
            </Button>
          </section>
        ) : null}

        <Field
          label="Search by handle"
          type="search"
          autoComplete="off"
          autoCapitalize="none"
          spellCheck={false}
          placeholder="handle"
          prefix="@"
          value={q}
          onChange={(e) => setQ(e.target.value)}
        />

        {term.length >= 2 ? (
          <section className="flex flex-col gap-2" aria-labelledby="new-search">
            <h2
              id="new-search"
              className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3"
            >
              Results
            </h2>
            {search.isPending ? (
              <Skeleton className="h-14 rounded-card" />
            ) : searchRows.length === 0 ? (
              <p className="text-[14px] text-text-2">No one with that handle.</p>
            ) : (
              list(searchRows, "Search results")
            )}
          </section>
        ) : null}

        <section className="flex flex-col gap-2" aria-labelledby="new-met">
          <h2
            id="new-met"
            className="text-[13px] font-bold uppercase tracking-[0.08em] text-text-3"
          >
            People you&apos;ve met
          </h2>
          {met.isPending ? (
            <div className="flex flex-col gap-2" aria-busy="true">
              <Skeleton className="h-14 rounded-card" />
              <Skeleton className="h-14 rounded-card" />
            </div>
          ) : metRows.length === 0 ? (
            <EmptyState
              icon={UsersRound}
              title="No one yet"
              body="After a plan, pick who you met. When they pick you too, they show up here."
              className="py-6"
              action={
                <Link
                  to="/"
                  className="inline-flex min-h-11 items-center gap-1.5 font-semibold text-primary-text"
                >
                  <Search className="size-4" aria-hidden="true" />
                  Find a plan
                </Link>
              }
            />
          ) : (
            list(metRows, "People you've met")
          )}
        </section>
      </main>
    </>
  );
}
