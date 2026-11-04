import { Link } from "@tanstack/react-router";

import { cn } from "@/lib/cn";

const TABS = [
  { to: "/admin/claims", label: "Chapter claims" },
  { to: "/admin/places", label: "Places" },
  { to: "/admin/health", label: "Map health" },
] as const;

/**
 * The moderator pages, side by side: chapter claims and places (hub map slice 12), and the map
 * health panel (slice 15).
 */
export function AdminTabs({ current }: { current: (typeof TABS)[number]["to"] }) {
  return (
    <nav aria-label="Moderation queues" className="flex gap-1 rounded-control bg-surface-2 p-1">
      {TABS.map((t) => (
        <Link
          key={t.to}
          to={t.to}
          replace
          aria-current={t.to === current ? "page" : undefined}
          className={cn(
            "flex h-9 flex-1 items-center justify-center rounded-[10px] text-[14px] font-semibold transition-colors",
            t.to === current ? "bg-surface text-text shadow-sm" : "text-text-2 hover:text-text",
          )}
        >
          {t.label}
        </Link>
      ))}
    </nav>
  );
}
