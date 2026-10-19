import { createFileRoute } from "@tanstack/react-router";
import { Users } from "lucide-react";

import { TopBar } from "@/components/shell/top-bar";
import { ComingSoon } from "@/components/shell/coming-soon";

export const Route = createFileRoute("/_app/hubs")({
  component: () => (
    <>
      <TopBar title="Hubs" />
      <ComingSoon
        icon={Users}
        title="Every interest has a hub"
        body="Browse all 612 hubs, join new ones, and claim your org's chapter. Arrives with the week-3 build."
      />
    </>
  ),
});
