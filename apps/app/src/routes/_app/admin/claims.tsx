import { useState } from "react";
import { Link, createFileRoute, getRouteApi, useNavigate } from "@tanstack/react-router";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { CircleAlert, Inbox, ShieldX } from "lucide-react";
import { toast } from "sonner";

import { AdminTabs } from "@/components/admin/admin-tabs";
import { ListSkeleton } from "@/components/hubs/hub-states";
import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { buttonVariants } from "@/components/ui/button-variants";
import { EmptyState } from "@/components/ui/empty-state";
import { SegmentedControl } from "@/components/ui/segmented";
import { FieldTextArea } from "@/components/ui/textarea";
import { z } from "zod";
import { OrganizerClaims } from "@/components/admin/organizer-claims";
import {
  chapterErrorMessage,
  chapterKeys,
  isModeratorQuery,
  pendingClaimsQuery,
  reviewChapterClaim,
  type PendingClaim,
} from "@/lib/chapters";
import { formatRelativeDay } from "@/lib/datetime";

const appRoute = getRouteApi("/_app");

/**
 * Claims. Chapters: the moderator queue for chapter claims (review_chapter_claim). Minimal on purpose: each
 * pending claim with what the claimant told us, a note, Approve and Reject. Everyone else sees
 * a dead end; the RPC refuses non-moderators and a moderator's own claim regardless.
 * Organizers (collector Slice 2): organizer claims, verified automatically, with revoke.
 */
const searchSchema = z.object({
  tab: z.enum(["chapters", "organizers"]).optional(),
  closed: z.boolean().optional(),
});

export const Route = createFileRoute("/_app/admin/claims")({
  validateSearch: searchSchema,
  component: ClaimsQueuePage,
});

function ClaimsQueuePage() {
  const { session } = appRoute.useRouteContext();
  const isMod = useQuery(isModeratorQuery(session.user.id));
  const { tab = "chapters", closed = false } = Route.useSearch();
  const navigate = useNavigate({ from: Route.fullPath });

  return (
    <>
      <TopBar title="Moderation" back />
      <main className="flex flex-col gap-4 pt-2 pb-8 safe-px">
        <AdminTabs current="/admin/claims" />
        {isMod.isPending ? (
          <ListSkeleton rows={3} rowClassName="h-32" />
        ) : isMod.isError ? (
          <EmptyState
            icon={CircleAlert}
            title="Couldn't check your access"
            body="Check your connection and try again."
            action={
              <Button variant="secondary" onClick={() => void isMod.refetch()}>
                Try again
              </Button>
            }
          />
        ) : !isMod.data ? (
          <EmptyState
            icon={ShieldX}
            title="Moderators only"
            body="This page is for the people who review chapter claims."
            action={
              <Link to="/" className={buttonVariants({ variant: "secondary" })}>
                Go home
              </Link>
            }
          />
        ) : (
          <>
            <SegmentedControl
              label="Claims"
              value={tab}
              onChange={(t) => void navigate({ search: { tab: t }, replace: true })}
              options={[
                { value: "chapters", label: "Chapters" },
                { value: "organizers", label: "Organizers" },
              ]}
            />
            {tab === "organizers" ? (
              <>
                <SegmentedControl
                  label="Organizer claims"
                  value={closed ? "closed" : "open"}
                  onChange={(v) =>
                    void navigate({
                      search: { tab, closed: v === "closed" || undefined },
                      replace: true,
                    })
                  }
                  options={[
                    { value: "open", label: "Open" },
                    { value: "closed", label: "Closed" },
                  ]}
                />
                <OrganizerClaims closed={closed} />
              </>
            ) : (
              <Queue viewerId={session.user.id} />
            )}
          </>
        )}
      </main>
    </>
  );
}

function Queue({ viewerId }: { viewerId: string }) {
  const claims = useQuery(pendingClaimsQuery());
  if (claims.isPending) return <ListSkeleton rows={3} rowClassName="h-32" />;
  if (claims.isError) {
    return (
      <EmptyState
        icon={CircleAlert}
        title="Couldn't load claims"
        body={chapterErrorMessage(claims.error)}
        action={
          <Button variant="secondary" onClick={() => void claims.refetch()}>
            Try again
          </Button>
        }
      />
    );
  }
  if (claims.data.length === 0) {
    return <EmptyState icon={Inbox} title="Nothing to review" body="New claims show up here." />;
  }
  return (
    <ul className="flex flex-col gap-3">
      {claims.data.map((c) => (
        <li key={c.id}>
          <ClaimCard claim={c} own={c.user_id === viewerId} />
        </li>
      ))}
    </ul>
  );
}

function ClaimCard({ claim, own }: { claim: PendingClaim; own: boolean }) {
  const queryClient = useQueryClient();
  const [note, setNote] = useState("");
  const place =
    claim.org_campuses?.name ?? claim.organizations?.name ?? claim.areas?.name ?? "Unknown place";

  const review = useMutation({
    mutationFn: (approve: boolean) => reviewChapterClaim(claim.id, approve, note),
    onSuccess: (_, approve) => {
      void queryClient.invalidateQueries({ queryKey: chapterKeys.pendingClaims });
      void queryClient.invalidateQueries({ queryKey: ["hubs", "chapters"] });
      toast.success(approve ? "Approved. They now organize the chapter." : "Claim rejected.");
    },
    onError: (err) => toast.error(chapterErrorMessage(err)),
  });

  const facts: [string, string | null][] = [
    ["Kind", claim.kind === "org" ? "School organization" : "Neighborhood group"],
    ["Place", place],
    ["Existing chapter", claim.chapter_id ? "Yes" : "No, a new one"],
    ["Registered name", claim.rso_name],
    ["Role", claim.officer_role_text],
    ["Reference", claim.reference_name],
    ["Reference contact", claim.reference_contact],
  ];

  return (
    <article className="flex flex-col gap-3 rounded-card border border-border p-4">
      <header>
        <p className="text-[13px] text-text-2">
          {claim.hubs ? `${claim.hubs.emoji} ${claim.hubs.name}` : "Hub"} ·{" "}
          {formatRelativeDay(claim.created_at)}
        </p>
        <h2 className="text-[17px] font-bold">{claim.proposed_name}</h2>
        <p className="text-[14px] text-text-2">
          {claim.profiles ? `${claim.profiles.first_name} @${claim.profiles.handle}` : "Member"}
        </p>
      </header>
      <dl className="grid grid-cols-[auto_1fr] gap-x-3 gap-y-1 text-[14px]">
        {facts
          .filter(([, v]) => v)
          .map(([k, v]) => (
            <div key={k} className="contents">
              <dt className="text-text-2">{k}</dt>
              <dd className="min-w-0 break-words">{v}</dd>
            </div>
          ))}
        {claim.pin_url ? (
          <div className="contents">
            <dt className="text-text-2">Listing</dt>
            <dd className="min-w-0 break-all">
              <a
                href={claim.pin_url}
                target="_blank"
                rel="noreferrer"
                className="font-semibold text-primary-text underline-offset-2 hover:underline"
              >
                {claim.pin_url.replace(/^https:\/\//, "")}
              </a>
            </dd>
          </div>
        ) : null}
      </dl>
      {claim.motivation ? (
        <p className="text-[14px] whitespace-pre-wrap">{claim.motivation}</p>
      ) : null}
      {own ? (
        <p className="text-[14px] text-text-2">Your own claim. Another moderator reviews it.</p>
      ) : (
        <>
          <FieldTextArea
            label="Note to the claimant (optional)"
            rows={2}
            maxLength={500}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            disabled={review.isPending}
          />
          <div className="grid grid-cols-2 gap-2">
            <Button
              variant="danger"
              loading={review.isPending && review.variables === false}
              disabled={review.isPending}
              onClick={() => review.mutate(false)}
            >
              Reject
            </Button>
            <Button
              loading={review.isPending && review.variables === true}
              disabled={review.isPending}
              onClick={() => review.mutate(true)}
            >
              Approve
            </Button>
          </div>
        </>
      )}
    </article>
  );
}
