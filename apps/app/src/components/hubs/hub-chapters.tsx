import { useState } from "react";
import { useQuery } from "@tanstack/react-query";

import { Button } from "@/components/ui/button";
import { Sheet } from "@/components/ui/sheet";
import { formatMembers, hubChaptersQuery } from "@/lib/hubs";

import { InlineError, ListSkeleton } from "./hub-states";

/**
 * The hub's chapters (a hub at one campus) with a Claim button. Claiming is a week-4 feature with
 * no RPC yet, so the button explains how verification will work.
 */
export function HubChapters({
  hubId,
  hubName,
  isSensitive,
}: {
  hubId: string;
  hubName: string;
  /** Membership counts are hidden by RLS in sensitive categories, so they are not shown. */
  isSensitive: boolean;
}) {
  const chapters = useQuery(hubChaptersQuery(hubId));
  const [claimOpen, setClaimOpen] = useState(false);

  return (
    <>
      {chapters.isPending ? (
        <ListSkeleton rows={2} rowClassName="h-16" />
      ) : chapters.isError ? (
        <InlineError
          message="Couldn't load chapters."
          onRetry={() => {
            void chapters.refetch();
          }}
        />
      ) : chapters.data.length === 0 ? (
        <div className="rounded-card border border-border p-4">
          <p className="text-[15px] font-semibold">No chapter at Georgia State yet</p>
          <p className="mt-1 text-[14px] text-text-2">
            A chapter is {hubName} at one campus, with its own plans, captains and chat.
          </p>
          <Button variant="secondary" className="mt-3" onClick={() => setClaimOpen(true)}>
            Start a chapter
          </Button>
        </div>
      ) : (
        <ul className="divide-y divide-border rounded-card border border-border bg-surface">
          {chapters.data.map((chapter) => {
            const count = chapter.chapter_members[0]?.count ?? 0;
            const meta = [
              chapter.org_campuses?.name ?? "All campuses",
              isSensitive ? "" : formatMembers(count),
            ]
              .filter(Boolean)
              .join(" · ");
            return (
              <li key={chapter.id} className="flex min-h-16 items-center gap-3 px-4 py-2">
                <div className="min-w-0 flex-1">
                  <p className="truncate text-[15px] font-semibold">{chapter.name}</p>
                  <p className="truncate text-[13px] text-text-2">{meta}</p>
                </div>
                <Button
                  variant="outline"
                  onClick={() => setClaimOpen(true)}
                  aria-label={`Claim ${chapter.name}`}
                >
                  Claim
                </Button>
              </li>
            );
          })}
        </ul>
      )}
      <ClaimChapterSheet open={claimOpen} onClose={() => setClaimOpen(false)} />
    </>
  );
}

function ClaimChapterSheet({ open, onClose }: { open: boolean; onClose: () => void }) {
  return (
    <Sheet
      open={open}
      onClose={onClose}
      title="Claim a chapter"
      footer={
        <Button variant="secondary" size="lg" block onClick={onClose}>
          Got it
        </Button>
      }
    >
      <div className="flex flex-col gap-3 pt-1 text-[15px] text-text-2">
        <p>
          Chapters are run by a registered student org or a verified captain, so everyone knows who
          is hosting.
        </p>
        <p>
          Claiming opens in the week-4 build. RSO officers verify with their PIN listing or a .edu
          email plus a reference; captains add an ID check and sign the Captain Program agreement.
        </p>
        <p>Until then, post plans in the hub itself. Anyone can.</p>
      </div>
    </Sheet>
  );
}
