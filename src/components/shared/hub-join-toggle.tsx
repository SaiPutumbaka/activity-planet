"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { Check, Loader2, Plus } from "lucide-react";
import { toast } from "sonner";

import { joinHubAction, leaveHubAction } from "@/actions/hubs";
import { Button } from "@/components/ui/button";
import type { Hub } from "@/types/database";

interface HubJoinToggleProps {
  hub: Hub;
  initialIsMember: boolean;
}

export function HubJoinToggle({ hub, initialIsMember }: HubJoinToggleProps) {
  const router = useRouter();
  const [isMember, setIsMember] = useState(initialIsMember);
  const [isPending, startTransition] = useTransition();

  function toggle() {
    const wasMember = isMember;
    startTransition(async () => {
      const result = wasMember
        ? await leaveHubAction({ hub })
        : await joinHubAction({ hub });
      if (result.status === "error") {
        toast.error(result.message);
        return;
      }
      setIsMember(!wasMember);
      toast.success(wasMember ? `Left ${hub}.` : `Joined ${hub}!`);
      // The chat tab's server-fetched membership check needs fresh data.
      router.refresh();
    });
  }

  return (
    <Button
      onClick={toggle}
      disabled={isPending}
      variant={isMember ? "secondary" : "default"}
    >
      {isPending ? (
        <Loader2 className="h-4 w-4 animate-spin" aria-hidden />
      ) : isMember ? (
        <Check className="h-4 w-4" aria-hidden />
      ) : (
        <Plus className="h-4 w-4" aria-hidden />
      )}
      {isMember ? "Joined" : "Join hub"}
    </Button>
  );
}
