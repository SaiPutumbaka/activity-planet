import { useQuery } from "@tanstack/react-query";
import { Lock } from "lucide-react";

import { AvatarStack } from "@/components/ui/avatar";
import { Skeleton } from "@/components/ui/skeleton";
import { MEMBER_PREVIEW_SIZE, formatMembers, hubMembersPreviewQuery } from "@/lib/hubs";

import { InlineError } from "./hub-states";

/**
 * The newest members as an avatar stack with the real count. In a sensitive category (faith,
 * culture and identity, wellness and support) membership is private: the list is not fetched and
 * the row says so. The same sentence covers RLS returning nothing for a hub that has members.
 */
export function HubMembers({
  hubId,
  count,
  isSensitive,
}: {
  hubId: string;
  /** From hub_member_counts; undefined while loading. */
  count: number | undefined;
  isSensitive: boolean;
}) {
  const members = useQuery({ ...hubMembersPreviewQuery(hubId), enabled: !isSensitive });

  if (isSensitive) return <PrivateMembers />;
  if (members.isPending) {
    return (
      <div className="flex items-center gap-2">
        <Skeleton className="h-8 w-32 rounded-full" />
        <Skeleton className="h-4 w-20" />
      </div>
    );
  }
  if (members.isError) {
    return (
      <InlineError
        message="Couldn't load members."
        onRetry={() => {
          void members.refetch();
        }}
      />
    );
  }

  const people = members.data.flatMap((m) =>
    m.profiles ? [{ src: m.profiles.avatar_url, name: m.profiles.first_name }] : [],
  );
  if (people.length === 0) {
    if ((count ?? 0) > 0) return <PrivateMembers />;
    return <p className="text-[14px] text-text-2">No members yet. Be the first.</p>;
  }
  return (
    <AvatarStack
      people={people}
      max={MEMBER_PREVIEW_SIZE}
      size={32}
      totalLabel={formatMembers(count ?? people.length)}
    />
  );
}

function PrivateMembers() {
  return (
    <p className="flex items-center gap-2 text-[14px] text-text-2">
      <Lock className="size-4 shrink-0 text-text-3" aria-hidden="true" />
      Members are private in this hub.
    </p>
  );
}
