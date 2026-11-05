import { useState } from "react";
import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  BadgeCheck,
  BarChart3,
  CalendarPlus,
  CalendarSync,
  CircleAlert,
  Compass,
  ExternalLink,
  UserX,
} from "lucide-react";
import { toast } from "sonner";

import { ClaimChapterSheet } from "@/components/chapters/claim-chapter-sheet";
import { EventRow } from "@/components/hubs/hub-events";
import {
  HubPageSkeleton,
  InlineError,
  ListSkeleton,
  SectionHeading,
} from "@/components/hubs/hub-states";
import {
  PersonActionsButton,
  PersonSheet,
  type SafetyPerson,
} from "@/components/safety/person-sheet";
import { ChatEntryButton } from "@/components/chats/chat-entry-button";
import { ReportButton } from "@/components/safety/report-button";
import { TopBar } from "@/components/shell/top-bar";
import { Avatar } from "@/components/ui/avatar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { Select } from "@/components/ui/select";
import { Sheet } from "@/components/ui/sheet";
import {
  GSU_DISCLAIMER,
  canManageChapter,
  chapterBySlugQuery,
  chapterErrorMessage,
  chapterKeys,
  chapterMembersQuery,
  chapterPlaceLabel,
  chapterUpcomingEventsQuery,
  isGsuBranded,
  isModeratorQuery,
  joinChapter,
  leaveChapter,
  memberActions,
  removeChapterMember,
  roleLabel,
  setChapterRole,
  type ChapterDetail,
  type ChapterMember,
  type ChapterRole,
} from "@/lib/chapters";
import { cn } from "@/lib/cn";
import { formatMembers } from "@/lib/hubs";
import { membershipQuery } from "@/lib/verification";

const appRoute = getRouteApi("/_app");

/**
 * One chapter (D-035): about, Join, upcoming plans, and for its captains and organizers the
 * members panel (roles and remove) plus links to post as the chapter, to add a weekly
 * schedule and to the attendance dashboard. `chapters_.$slug.tsx` keeps /chapters/:slug free of any parent list route.
 */
export const Route = createFileRoute("/_app/chapters_/$slug")({
  loader: ({ context: { queryClient }, params }) => {
    void queryClient.prefetchQuery(chapterBySlugQuery(params.slug));
  },
  component: ChapterPageRoute,
});

function ChapterPageRoute() {
  const { slug } = Route.useParams();
  const chapter = useQuery(chapterBySlugQuery(slug));

  return (
    <>
      <TopBar title={chapter.data?.name ?? "Chapter"} back />
      <main className="flex flex-col gap-7 pb-8 safe-px">
        {chapter.isPending ? (
          <HubPageSkeleton />
        ) : chapter.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't load this chapter"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void chapter.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !chapter.data ? (
          <EmptyState
            icon={Compass}
            title="No chapter here"
            body="That chapter doesn't exist, or it isn't active anymore."
            action={
              <Link to="/hubs" className={buttonVariants({ variant: "secondary" })}>
                Browse hubs
              </Link>
            }
          />
        ) : (
          <ChapterContent chapter={chapter.data} />
        )}
      </main>
    </>
  );
}

function ChapterContent({ chapter }: { chapter: ChapterDetail }) {
  const { session } = appRoute.useRouteContext();
  const userId = session.user.id;
  const queryClient = useQueryClient();
  const members = useQuery(chapterMembersQuery(chapter.id));
  const isMod = useQuery(isModeratorQuery(userId));
  const membership = useQuery(membershipQuery(userId));
  const [claimOpen, setClaimOpen] = useState(false);

  const mine = members.data?.find((m) => m.user_id === userId) ?? null;
  const viewerRole = mine?.role ?? null;
  const isModerator = isMod.data === true;
  const manages = canManageChapter(viewerRole, isModerator);
  const hasOrganizer =
    Boolean(chapter.verified_at) || (members.data ?? []).some((m) => m.role === "organizer");
  const place = chapterPlaceLabel(chapter);
  const orgName = chapter.organizations?.name ?? null;
  const gsu = isGsuBranded(orgName, chapter.org_campuses?.name);
  // An organization's chapter is for verified members of that organization (RLS on the insert).
  const canJoin =
    !chapter.org_id || (membership.data != null && membership.data.org_id === chapter.org_id);

  const invalidate = () => {
    void queryClient.invalidateQueries({ queryKey: chapterKeys.members(chapter.id) });
    void queryClient.invalidateQueries({ queryKey: ["hubs", "chapters", chapter.hub_id] });
    void queryClient.invalidateQueries({ queryKey: chapterKeys.managed(userId) });
  };

  const join = useMutation({
    mutationFn: () => joinChapter(userId, chapter.id),
    onSuccess: () => {
      invalidate();
      toast.success(`You're in ${chapter.name}.`);
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });
  const leave = useMutation({
    mutationFn: () => leaveChapter(userId, chapter.id),
    onSuccess: () => {
      invalidate();
      toast(`You left ${chapter.name}.`);
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });

  const count = members.data?.length;

  return (
    <>
      <section className="flex flex-col gap-3 pt-2">
        {chapter.hubs ? (
          <Link
            to="/hubs/$slug"
            params={{ slug: chapter.hubs.slug }}
            className="inline-flex min-h-11 items-center gap-1.5 self-start rounded-control border border-border bg-surface px-3 text-[14px] font-semibold hover:bg-surface-2"
          >
            <span aria-hidden="true">{chapter.hubs.emoji}</span>
            {chapter.hubs.name}
          </Link>
        ) : null}
        <div>
          <h2 className="text-[26px] leading-tight font-extrabold tracking-[-0.02em] text-balance">
            {chapter.name}
          </h2>
          <p className="mt-1 flex flex-wrap items-center gap-x-2 text-[14px] text-text-2">
            {place ? <span>{place}</span> : null}
            {count !== undefined ? <span>{formatMembers(count)}</span> : null}
            {chapter.verified_at ? (
              <span className="inline-flex items-center gap-1 font-semibold text-going">
                <BadgeCheck className="size-4" aria-hidden="true" />
                Verified organizer
              </span>
            ) : null}
          </p>
        </div>
        {chapter.rso_name ? <p className="text-[14px]">{chapter.rso_name}</p> : null}
        {chapter.pin_url ? (
          <a
            href={chapter.pin_url}
            target="_blank"
            rel="noreferrer"
            className="inline-flex items-center gap-1.5 self-start text-[14px] font-semibold text-primary-text underline-offset-2 hover:underline"
          >
            <ExternalLink className="size-4" aria-hidden="true" />
            Organization listing
          </a>
        ) : null}
        {chapter.description ? (
          <p className="text-[15px] whitespace-pre-wrap">{chapter.description}</p>
        ) : null}

        {members.isPending ? null : mine ? (
          <div className="flex items-center gap-3">
            <span className="text-[14px] font-semibold text-going">
              You're{" "}
              {viewerRole === "member" ? "a member" : `a ${roleLabel(mine.role).toLowerCase()}`}
            </span>
            <Button
              variant="ghost"
              size="sm"
              loading={leave.isPending}
              onClick={() => leave.mutate()}
            >
              Leave
            </Button>
          </div>
        ) : canJoin ? (
          <Button size="lg" block loading={join.isPending} onClick={() => join.mutate()}>
            Join
          </Button>
        ) : (
          <div className="flex flex-col gap-2 rounded-card border border-border p-4">
            <p className="text-[15px]">
              This chapter is for verified members of {orgName ?? "its organization"}.
            </p>
            <Link to="/you/verify" className={buttonVariants({ variant: "secondary" })}>
              Verify a school email
            </Link>
          </div>
        )}

        {!hasOrganizer && !members.isPending ? (
          <div className="rounded-card border border-border p-4">
            <p className="text-[15px] font-semibold">Nobody runs this chapter yet</p>
            <p className="mt-1 text-[14px] text-text-2">
              Organize it and you can post as the chapter and name captains.
            </p>
            <Button variant="secondary" className="mt-3" onClick={() => setClaimOpen(true)}>
              Claim this chapter
            </Button>
          </div>
        ) : null}

        {gsu ? <p className="text-[12px] text-text-3">{GSU_DISCLAIMER}</p> : null}
      </section>

      {manages ? (
        <section className="flex flex-col gap-2" aria-label="Chapter tools">
          <Link
            to="/post"
            search={{ chapterId: chapter.id }}
            className={buttonVariants({ variant: "secondary", block: true })}
          >
            <CalendarPlus className="size-4" aria-hidden="true" />
            Post a plan as the chapter
          </Link>
          <Link
            to="/chapters/$slug/schedule"
            params={{ slug: chapter.slug }}
            className={buttonVariants({ variant: "outline", block: true })}
          >
            <CalendarSync className="size-4" aria-hidden="true" />
            Add a weekly schedule
          </Link>
          <Link
            to="/chapters/$slug/dashboard"
            params={{ slug: chapter.slug }}
            className={buttonVariants({ variant: "outline", block: true })}
          >
            <BarChart3 className="size-4" aria-hidden="true" />
            Attendance dashboard
          </Link>
        </section>
      ) : null}

      {mine ? (
        <ChatEntryButton
          target={{ kind: "chapter", chapterId: chapter.id }}
          label="Chapter chat"
          className="self-start"
        />
      ) : null}

      <section className="flex flex-col gap-3" aria-labelledby="chapter-upcoming">
        <SectionHeading id="chapter-upcoming" title="Upcoming" />
        <ChapterEvents chapterId={chapter.id} />
      </section>

      {manages ? (
        <section className="flex flex-col gap-3" aria-labelledby="chapter-members">
          <SectionHeading
            id="chapter-members"
            title="Members"
            trailing={count !== undefined ? formatMembers(count) : undefined}
          />
          {members.isPending ? (
            <ListSkeleton rows={3} rowClassName="h-14" />
          ) : members.isError ? (
            <InlineError message="Couldn't load members." onRetry={() => void members.refetch()} />
          ) : (
            <MembersPanel
              chapterId={chapter.id}
              members={members.data}
              viewerId={userId}
              viewerRole={viewerRole}
              isModerator={isModerator}
              onChanged={invalidate}
            />
          )}
        </section>
      ) : null}

      {viewerRole === "organizer" || viewerRole === "captain" ? null : (
        <ReportButton kind="chapter" targetId={chapter.id} />
      )}

      {chapter.hubs ? (
        <ClaimChapterSheet
          open={claimOpen}
          onClose={() => setClaimOpen(false)}
          userId={userId}
          hub={{ id: chapter.hubs.id, name: chapter.hubs.name }}
          chapter={chapter}
        />
      ) : null}
    </>
  );
}

function ChapterEvents({ chapterId }: { chapterId: string }) {
  const events = useQuery(chapterUpcomingEventsQuery(chapterId));
  if (events.isPending) return <ListSkeleton rows={2} rowClassName="h-24" />;
  if (events.isError) {
    return (
      <InlineError
        message="Couldn't load this chapter's plans."
        onRetry={() => void events.refetch()}
      />
    );
  }
  if (events.data.length === 0) {
    return <p className="text-[14px] text-text-2">Nothing scheduled yet.</p>;
  }
  return (
    <ul className="flex flex-col gap-3">
      {events.data.map((event) => (
        <li key={event.id}>
          <EventRow event={event} />
        </li>
      ))}
    </ul>
  );
}

function MembersPanel({
  chapterId,
  members,
  viewerId,
  viewerRole,
  isModerator,
  onChanged,
}: {
  chapterId: string;
  members: ChapterMember[];
  viewerId: string;
  viewerRole: ChapterRole | null;
  isModerator: boolean;
  onChanged: () => void;
}) {
  const [removing, setRemoving] = useState<ChapterMember | null>(null);
  const [person, setPerson] = useState<SafetyPerson | null>(null);
  const organizerCount = members.filter((m) => m.role === "organizer").length;

  const role = useMutation({
    mutationFn: ({ userId, next }: { userId: string; next: ChapterRole }) =>
      setChapterRole(chapterId, userId, next),
    onSuccess: (_, { next }) => {
      onChanged();
      toast.success(`Now ${roleLabel(next).toLowerCase()}.`);
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });
  const remove = useMutation({
    mutationFn: (userId: string) => removeChapterMember(chapterId, userId),
    onSuccess: () => {
      onChanged();
      setRemoving(null);
      toast.success("Removed from the chapter.");
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });

  if (members.length === 0) return <p className="text-[14px] text-text-2">No members yet.</p>;

  return (
    <>
      <ul className="divide-y divide-border overflow-hidden rounded-card border border-border">
        {members.map((m) => {
          const name = m.profiles?.first_name ?? "Member";
          const actions = memberActions({
            viewerId,
            viewerRole,
            isModerator,
            target: m,
            organizerCount,
          });
          const busy = role.isPending && role.variables?.userId === m.user_id;
          const profile = m.profiles;
          return (
            <li key={m.user_id} className="flex min-h-14 items-center gap-3 px-4 py-2">
              <Avatar src={m.profiles?.avatar_url} name={name} size={36} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-[15px] font-semibold">
                  {name}
                  {m.user_id === viewerId ? (
                    <span className="font-normal text-text-3"> (you)</span>
                  ) : null}
                </p>
                {m.profiles?.handle ? (
                  <p className="truncate text-[13px] text-text-2">@{m.profiles.handle}</p>
                ) : null}
              </div>
              {actions.roles.length > 0 ? (
                <Select
                  aria-label={`Role for ${name}`}
                  className={cn("h-11 w-[124px] text-[14px]", busy && "opacity-50")}
                  value={m.role}
                  disabled={busy}
                  onChange={(e) =>
                    role.mutate({ userId: m.user_id, next: e.target.value as ChapterRole })
                  }
                >
                  {[m.role, ...actions.roles].map((r) => (
                    <option key={r} value={r}>
                      {roleLabel(r)}
                    </option>
                  ))}
                </Select>
              ) : (
                <span className="text-[13px] font-semibold text-text-2">{roleLabel(m.role)}</span>
              )}
              {profile && m.user_id !== viewerId ? (
                <PersonActionsButton
                  name={name}
                  onClick={() => setPerson({ user_id: m.user_id, ...profile })}
                />
              ) : null}
              {actions.canRemove ? (
                <Button
                  variant="ghost"
                  size="icon"
                  className="text-text-2"
                  aria-label={`Remove ${name}`}
                  onClick={() => setRemoving(m)}
                >
                  <UserX className="size-5" aria-hidden="true" />
                </Button>
              ) : null}
            </li>
          );
        })}
      </ul>
      <Sheet
        open={removing !== null}
        onClose={() => setRemoving(null)}
        title={removing ? `Remove ${removing.profiles?.first_name ?? "this member"}?` : "Remove"}
        footer={
          <Button
            variant="danger"
            size="lg"
            block
            loading={remove.isPending}
            onClick={() => removing && remove.mutate(removing.user_id)}
          >
            Remove from the chapter
          </Button>
        }
      >
        <p className="text-[15px] text-text-2">
          They leave the chapter and lose any role in it. They can join again later.
        </p>
      </Sheet>
      <PersonSheet person={person} viewerId={viewerId} onClose={() => setPerson(null)} />
    </>
  );
}
