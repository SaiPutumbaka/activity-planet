import { Link, createFileRoute, getRouteApi } from "@tanstack/react-router";
import { useQuery } from "@tanstack/react-query";
import { Bell, Search } from "lucide-react";
import { DefaultCover } from "@ap/ui/brand";

import { TopBar } from "@/components/shell/top-bar";
import { Button } from "@/components/ui/button";
import { myHubsQuery } from "@/lib/profile";

const appRoute = getRouteApi("/_app");

export const Route = createFileRoute("/_app/")({
  component: HomePage,
});

function HomePage() {
  const { session, profile } = appRoute.useRouteContext();
  const hubs = useQuery(myHubsQuery(session.user.id));

  return (
    <>
      <TopBar
        actions={
          <>
            <Button variant="secondary" size="icon-sm" className="rounded-full" aria-label="Search">
              <Search className="size-5" aria-hidden="true" />
            </Button>
            <Button
              variant="secondary"
              size="icon-sm"
              className="rounded-full"
              aria-label="Notifications"
            >
              <Bell className="size-5" aria-hidden="true" />
            </Button>
          </>
        }
      />
      <main className="flex flex-col gap-5 pb-6 safe-px">
        <section className="pt-2">
          <h2 className="text-[28px] font-extrabold tracking-[-0.025em]">
            Hi, {profile.first_name}.
          </h2>
          <p className="text-text-2">Here's what your hubs are up to this week.</p>
        </section>

        <section>
          <div className="flex items-baseline justify-between">
            <h3 className="text-[17px] font-bold tracking-[-0.01em]">Your hubs</h3>
            <Link to="/hubs" className="text-[14px] font-semibold text-primary-text">
              Edit
            </Link>
          </div>
          <div className="no-scrollbar -mx-4 mt-3 flex gap-3 overflow-x-auto px-4">
            {(hubs.data ?? []).map((m) =>
              m.hubs ? (
                <div key={m.hub_id} className="flex w-16 shrink-0 flex-col items-center gap-1.5">
                  <div className="flex size-16 items-center justify-center rounded-full border-2 border-border-strong bg-surface-2 text-[26px]">
                    <span aria-hidden="true">{m.hubs.emoji}</span>
                  </div>
                  <span className="w-full truncate text-center text-[11px] font-medium">
                    {m.hubs.name}
                  </span>
                </div>
              ) : null,
            )}
            {hubs.isPending
              ? Array.from({ length: 5 }).map((_, i) => (
                  <div
                    key={i}
                    className="size-16 shrink-0 animate-pulse rounded-full bg-surface-2"
                  />
                ))
              : null}
          </div>
        </section>

        <section>
          <h3 className="text-[17px] font-bold tracking-[-0.01em]">This week at Georgia State</h3>
          <div className="mt-3 overflow-hidden rounded-card border border-border bg-surface shadow-[var(--shadow-card)]">
            <div className="h-[132px]">
              <DefaultCover seed={session.user.id} />
            </div>
            <div className="p-4">
              <p className="text-[17px] font-semibold">Your feed is on its way</p>
              <p className="mt-1 text-[14px] text-text-2">
                Events from chapters, members and the campus calendar start landing here in the next
                build. Your hubs are saved, so the first week shows what you care about.
              </p>
            </div>
          </div>
        </section>
      </main>
    </>
  );
}
