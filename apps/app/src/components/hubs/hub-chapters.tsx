import { useState } from "react";
import { Link } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { BadgeCheck, ChevronRight } from "lucide-react";

import { ClaimChapterSheet, type ClaimTarget } from "@/components/chapters/claim-chapter-sheet";
import { Button } from "@/components/ui/button";
import { chapterPlaceLabel } from "@/lib/chapters";
import { formatMembers, hubChaptersQuery } from "@/lib/hubs";

import { InlineError, ListSkeleton } from "./hub-states";

/**
 * The hub's chapters (the hub for one organization or one neighborhood, D-035), each a link to
 * its page. A chapter nobody runs yet offers Claim; "Start a chapter" asks for a new one. Both
 * open the claim sheet, which a moderator reviews.
 */
export function HubChapters({
  hubId,
  hubName,
  isSensitive,
  userId,
}: {
  hubId: string;
  hubName: string;
  /** Membership counts are hidden by RLS in sensitive categories, so they are not shown. */
  isSensitive: boolean;
  userId: string;
}) {
  const chapters = useQuery(hubChaptersQuery(hubId));
  const [claimOpen, setClaimOpen] = useState(false);
  const [target, setTarget] = useState<ClaimTarget | null>(null);

  function openClaim(next: ClaimTarget | null) {
    setTarget(next);
    setClaimOpen(true);
  }

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
          <p className="text-[15px] font-semibold">No chapter here yet</p>
          <p className="mt-1 text-[14px] text-text-2">
            A chapter is {hubName} for one group or one neighborhood, with its own plans and
            captains.
          </p>
          <Button variant="secondary" className="mt-3" onClick={() => openClaim(null)}>
            Start a chapter
          </Button>
        </div>
      ) : (
        <>
          <ul className="divide-y divide-border rounded-card border border-border bg-surface">
            {chapters.data.map((chapter) => {
              const count = chapter.chapter_members[0]?.count ?? 0;
              const meta = [chapterPlaceLabel(chapter), isSensitive ? "" : formatMembers(count)]
                .filter(Boolean)
                .join(" · ");
              return (
                <li key={chapter.id} className="flex min-h-16 items-center gap-2 pr-2">
                  <Link
                    to="/chapters/$slug"
                    params={{ slug: chapter.slug }}
                    className="flex min-w-0 flex-1 items-center gap-2 py-2 pl-4 hover:opacity-80"
                  >
                    <div className="min-w-0 flex-1">
                      <p className="flex items-center gap-1 truncate text-[15px] font-semibold">
                        <span className="truncate">{chapter.name}</span>
                        {chapter.verified_at ? (
                          <BadgeCheck
                            className="size-4 shrink-0 text-going"
                            aria-label="Verified organizer"
                          />
                        ) : null}
                      </p>
                      <p className="truncate text-[13px] text-text-2">{meta}</p>
                    </div>
                    {chapter.verified_at ? (
                      <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
                    ) : null}
                  </Link>
                  {chapter.verified_at ? null : (
                    <Button
                      variant="outline"
                      onClick={() => openClaim(chapter)}
                      aria-label={`Claim ${chapter.name}`}
                    >
                      Claim
                    </Button>
                  )}
                </li>
              );
            })}
          </ul>
          <Button variant="ghost" className="self-start" onClick={() => openClaim(null)}>
            Start another chapter
          </Button>
        </>
      )}
      <ClaimChapterSheet
        open={claimOpen}
        onClose={() => setClaimOpen(false)}
        userId={userId}
        hub={{ id: hubId, name: hubName }}
        chapter={target}
      />
    </>
  );
}
