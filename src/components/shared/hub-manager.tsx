"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";

import { updateHubsAction } from "@/actions/profile";
import { HUB_EMOJI } from "@/lib/hubs";
import { cn } from "@/lib/utils";
import { HUBS, type Hub } from "@/types/database";

interface HubManagerProps {
  initialHubs: Hub[];
}

/**
 * Add/remove hubs from your profile. Each tap saves immediately (optimistic
 * update, reverted on error) rather than requiring a separate save step.
 */
export function HubManager({ initialHubs }: HubManagerProps) {
  const [selected, setSelected] = useState<Hub[]>(initialHubs);
  const [isPending, startTransition] = useTransition();

  function toggleHub(hub: Hub) {
    const previous = selected;
    const next = previous.includes(hub)
      ? previous.filter((h) => h !== hub)
      : [...previous, hub];

    if (next.length === 0) {
      toast.error("Pick at least one hub — you need one to leave this one.");
      return;
    }

    setSelected(next);
    startTransition(async () => {
      const result = await updateHubsAction({ selectedHobbies: next });
      if (result.status === "error") {
        toast.error(result.message);
        setSelected(previous);
      }
    });
  }

  return (
    <div
      role="group"
      aria-label="Manage your hubs"
      className="grid grid-cols-2 gap-3 sm:grid-cols-4"
    >
      {HUBS.map((hub) => {
        const isSelected = selected.includes(hub);
        return (
          <button
            key={hub}
            type="button"
            aria-pressed={isSelected}
            disabled={isPending}
            onClick={() => toggleHub(hub)}
            className={cn(
              "flex flex-col items-center gap-2 rounded-xl border-2 p-4 text-center text-sm font-medium transition-colors",
              "hover:bg-accent hover:text-accent-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:opacity-60",
              isSelected
                ? "border-primary bg-primary/10 text-primary"
                : "border-border text-foreground",
            )}
          >
            <span className="text-3xl" aria-hidden>
              {HUB_EMOJI[hub]}
            </span>
            {hub}
          </button>
        );
      })}
    </div>
  );
}
