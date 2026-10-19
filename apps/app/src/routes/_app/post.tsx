import { createFileRoute } from "@tanstack/react-router";
import { PlusSquare } from "lucide-react";

import { TopBar } from "@/components/shell/top-bar";
import { ComingSoon } from "@/components/shell/coming-soon";

export const Route = createFileRoute("/_app/post")({
  component: () => (
    <>
      <TopBar title="Post a plan" />
      <ComingSoon
        icon={PlusSquare}
        title="Anyone can post a plan"
        body="Pick a hub, a time and a place, and the people in that hub see it. Arrives with the week-3 build."
      />
    </>
  ),
});
