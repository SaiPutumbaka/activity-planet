import { Check } from "lucide-react";

import { Button } from "@/components/ui/button";
import { cn } from "@/lib/cn";
import { categoryTone, formatMembers, type HubPage } from "@/lib/hubs";

import { HubBadges } from "./hub-badges";

/**
 * Top of the hub page. Join is the one loud thing on the screen; once joined the button turns
 * into a quiet "Joined" that leaves again (with Undo in the toast).
 */
export function HubHeader({
  hub,
  count,
  joined,
  pending,
  blocked,
  onJoin,
  onLeave,
}: {
  hub: HubPage;
  count: number | undefined;
  joined: boolean;
  pending: boolean;
  /** Why joining is not possible right now (campus not verified, under 21), or null. */
  blocked: string | null;
  onJoin: () => void;
  onLeave: () => void;
}) {
  const category = hub.hub_categories;
  const meta = [category?.name ?? "Hub", formatMembers(count)].filter(Boolean).join(" · ");

  return (
    <section className="flex flex-col gap-4 pt-2">
      <div className="flex items-start gap-4">
        <span
          className={cn(
            "flex size-16 shrink-0 items-center justify-center rounded-tile text-[32px] leading-none",
            categoryTone(category?.color_key),
          )}
          aria-hidden="true"
        >
          {hub.emoji}
        </span>
        <div className="min-w-0 flex-1">
          <h2 className="text-[24px] font-extrabold tracking-[-0.02em] text-balance">{hub.name}</h2>
          <p className="mt-0.5 text-[14px] text-text-2">{meta}</p>
          <HubBadges minAge={hub.min_age} scope={hub.scope} className="mt-1.5" />
        </div>
      </div>

      {hub.description ? <p className="text-[15px] text-text-2">{hub.description}</p> : null}

      {joined ? (
        <Button
          variant="secondary"
          size="lg"
          block
          leading={<Check className="size-5" aria-hidden="true" />}
          loading={pending}
          onClick={onLeave}
        >
          Joined
        </Button>
      ) : blocked ? (
        <div className="flex flex-col gap-2">
          <Button variant="secondary" size="lg" block disabled>
            Join
          </Button>
          <p className="text-center text-[13px] text-text-2">{blocked}</p>
        </div>
      ) : (
        <Button size="lg" block loading={pending} onClick={onJoin}>
          Join
        </Button>
      )}
    </section>
  );
}
