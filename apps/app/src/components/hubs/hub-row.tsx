import { Link } from "@tanstack/react-router";
import { BellOff, Ellipsis } from "lucide-react";

import { cn } from "@/lib/cn";
import { categoryTone, formatMembers } from "@/lib/hubs";
import type { CatalogHub } from "@/lib/profile";

import { HubBadges } from "./hub-badges";

/**
 * A joined hub in "Your hubs": the row opens the hub page, the "…" button opens the settings
 * sheet (notifications, leave). Two separate controls, side by side, never nested.
 */
export function HubRow({
  hub,
  categoryName,
  colorKey,
  count,
  notify,
  onMore,
}: {
  hub: CatalogHub;
  categoryName: string;
  colorKey: string | undefined;
  count: number | undefined;
  notify: boolean;
  onMore: () => void;
}) {
  const meta = [categoryName, formatMembers(count)].filter(Boolean).join(" · ");
  return (
    <div className="flex items-center gap-1 pr-1 pl-3">
      <Link
        to="/hubs/$slug"
        params={{ slug: hub.slug }}
        className="flex min-h-16 min-w-0 flex-1 items-center gap-3 rounded-input py-2"
      >
        <span
          className={cn(
            "flex size-11 shrink-0 items-center justify-center rounded-tile text-[22px] leading-none",
            categoryTone(colorKey),
          )}
          aria-hidden="true"
        >
          {hub.emoji}
        </span>
        <span className="min-w-0 flex-1">
          <span className="flex items-center gap-1.5">
            <span className="truncate text-[15px] font-semibold">{hub.name}</span>
            <HubBadges minAge={hub.min_age} scope={hub.scope} />
            {!notify ? (
              <BellOff
                className="size-3.5 shrink-0 text-text-3"
                role="img"
                aria-label="Notifications off"
              />
            ) : null}
          </span>
          <span className="block truncate text-[13px] text-text-2">{meta}</span>
        </span>
      </Link>
      <button
        type="button"
        onClick={onMore}
        aria-label={`Options for ${hub.name}`}
        className="flex size-11 shrink-0 items-center justify-center rounded-full text-text-2 hover:bg-surface-2"
      >
        <Ellipsis className="size-5" aria-hidden="true" />
      </button>
    </div>
  );
}
