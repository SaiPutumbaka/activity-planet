"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";

import { updateHubsAction } from "@/actions/profile";
import { HubPicker } from "@/components/shared/hub-picker";
import { MAX_HUBS } from "@/lib/validation/profile";
import type { Hub } from "@/types/database";

interface HubManagerProps {
  initialHubs: Hub[];
}

/**
 * Add/remove hubs from your profile. Each change saves immediately
 * (optimistic update, reverted on error) rather than requiring a save step.
 */
export function HubManager({ initialHubs }: HubManagerProps) {
  const [selected, setSelected] = useState<Hub[]>(initialHubs);
  const [, startTransition] = useTransition();

  function handleChange(next: Hub[]) {
    const previous = selected;
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
    <HubPicker mode="multi" value={selected} onChange={handleChange} max={MAX_HUBS} />
  );
}
