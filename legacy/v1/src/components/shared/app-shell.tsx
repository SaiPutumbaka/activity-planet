"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { CirclePlus, CircleUser, Compass, Home } from "lucide-react";

import { LogoWordmark } from "@/components/shared/logo";
import { ThemeToggle } from "@/components/shared/theme-toggle";
import { useUser } from "@/components/shared/user-provider";
import { hubToSlug } from "@/lib/hub-slug";
import { HUB_EMOJI } from "@/lib/hubs";
import { cn } from "@/lib/utils";
import { isHub } from "@/types/database";

function BetaBadge() {
  return (
    <span className="rounded-full bg-secondary px-2 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-secondary-foreground">
      Beta
    </span>
  );
}

const NAV_ITEMS = [
  { href: "/home", label: "Home", icon: Home },
  { href: "/discover", label: "Discover", icon: Compass },
  { href: "/create", label: "Create", icon: CirclePlus },
  { href: "/profile", label: "Profile", icon: CircleUser },
] as const;

export function AppShell({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  const pathname = usePathname();
  const user = useUser();
  const userHubs = user.selectedHobbies.filter(isHub);

  return (
    <div className="min-h-dvh">
      {/* Desktop side rail */}
      <aside className="fixed inset-y-0 left-0 z-40 hidden w-56 flex-col border-r bg-background md:flex">
        <Link
          href="/home"
          className="flex items-center gap-2 px-5 py-5"
          aria-label="Activity Planet home"
        >
          <LogoWordmark className="text-base" markClassName="h-7 w-7" />
          <BetaBadge />
        </Link>
        <nav aria-label="Main" className="flex flex-1 flex-col gap-1 overflow-y-auto px-3">
          {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
            const active = pathname.startsWith(href);
            return (
              <Link
                key={href}
                href={href}
                aria-current={active ? "page" : undefined}
                className={cn(
                  "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                  active
                    ? "bg-primary/10 text-primary"
                    : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
                )}
              >
                <Icon className="h-5 w-5" aria-hidden />
                {label}
              </Link>
            );
          })}

          {userHubs.length > 0 ? (
            <>
              <p className="mt-4 px-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
                Your hubs
              </p>
              {userHubs.map((hub) => {
                const href = `/hubs/${hubToSlug(hub)}`;
                const active = pathname.startsWith(href);
                return (
                  <Link
                    key={hub}
                    href={href}
                    aria-current={active ? "page" : undefined}
                    className={cn(
                      "flex items-center gap-3 rounded-lg px-3 py-2 text-sm font-medium transition-colors",
                      active
                        ? "bg-primary/10 text-primary"
                        : "text-muted-foreground hover:bg-accent hover:text-accent-foreground",
                    )}
                  >
                    <span className="text-base" aria-hidden>
                      {HUB_EMOJI[hub]}
                    </span>
                    <span className="truncate">{hub}</span>
                  </Link>
                );
              })}
            </>
          ) : null}
        </nav>
        <div className="flex items-center justify-between border-t px-4 py-3">
          <span className="truncate text-sm font-medium">@{user.username}</span>
          <ThemeToggle />
        </div>
      </aside>

      {/* Mobile top bar */}
      <header className="sticky top-0 z-40 border-b bg-background/95 backdrop-blur md:hidden">
        <div className="flex items-center justify-between px-4 py-3">
          <Link
            href="/home"
            className="flex items-center gap-2"
            aria-label="Activity Planet home"
          >
            <LogoWordmark className="text-base" markClassName="h-7 w-7" />
            <BetaBadge />
          </Link>
          <ThemeToggle />
        </div>
        {userHubs.length > 0 ? (
          <div className="flex gap-2 overflow-x-auto px-4 pb-3">
            {userHubs.map((hub) => (
              <Link
                key={hub}
                href={`/hubs/${hubToSlug(hub)}`}
                className="inline-flex shrink-0 items-center gap-1.5 rounded-full border bg-card px-3 py-1 text-xs font-medium"
              >
                <span aria-hidden>{HUB_EMOJI[hub]}</span>
                {hub}
              </Link>
            ))}
          </div>
        ) : null}
      </header>

      <main className="md:ml-56">
        <div className="mx-auto w-full max-w-2xl px-4 pb-24 pt-4 md:pb-10 md:pt-8 lg:max-w-3xl">
          {children}
        </div>
      </main>

      {/* Mobile bottom navigation */}
      <nav
        aria-label="Main"
        className="fixed inset-x-0 bottom-0 z-40 grid grid-cols-4 border-t bg-background/95 pb-[env(safe-area-inset-bottom)] backdrop-blur md:hidden"
      >
        {NAV_ITEMS.map(({ href, label, icon: Icon }) => {
          const active = pathname.startsWith(href);
          return (
            <Link
              key={href}
              href={href}
              aria-current={active ? "page" : undefined}
              className={cn(
                "flex flex-col items-center gap-1 py-2 text-xs font-medium transition-colors",
                active ? "text-primary" : "text-muted-foreground",
              )}
            >
              <Icon className="h-5 w-5" aria-hidden />
              {label}
            </Link>
          );
        })}
      </nav>
    </div>
  );
}
