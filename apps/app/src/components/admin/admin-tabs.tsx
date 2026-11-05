import { Link } from "@tanstack/react-router";

import { cn } from "@/lib/cn";

const TABS = [
  { to: "/admin", label: "Overview" },
  { to: "/admin/reports", label: "Reports" },
  { to: "/admin/takedowns", label: "Image requests" },
  { to: "/admin/users", label: "Users" },
  { to: "/admin/claims", label: "Chapter claims" },
  { to: "/admin/places", label: "Places" },
  { to: "/admin/calendars", label: "Calendars" },
  { to: "/admin/health", label: "Map health" },
] as const;

export type AdminTab = (typeof TABS)[number]["to"];

/**
 * The moderator pages side by side (admin panel v1, migration 53): the overview (scorecard and
 * the one queue), reports, intimate-image requests, user lookup, chapter claims, places (hub map
 * slice 12), member calendar suggestions (D-042 slice 7) and map health (slice 15). Scrolls
 * sideways on a phone instead of squeezing eight labels into one row.
 */
export function AdminTabs({ current }: { current: AdminTab }) {
  return (
    <nav aria-label="Moderation" className="no-scrollbar -mx-4 overflow-x-auto px-4">
      <div className="flex w-max gap-1 rounded-control bg-surface-2 p-1">
        {TABS.map((t) => (
          <Link
            key={t.to}
            to={t.to}
            replace
            aria-current={t.to === current ? "page" : undefined}
            className={cn(
              "flex h-9 shrink-0 items-center justify-center rounded-[10px] px-3 text-[14px] font-semibold whitespace-nowrap transition-colors",
              t.to === current ? "bg-surface text-text shadow-sm" : "text-text-2 hover:text-text",
            )}
          >
            {t.label}
          </Link>
        ))}
      </div>
    </nav>
  );
}

/** The SLA timer pill: red when overdue, amber inside the last 4 hours. */
export function DuePill({ tone, children }: { tone: "overdue" | "soon" | "ok"; children: string }) {
  return (
    <span
      className={cn(
        "inline-flex h-6 shrink-0 items-center rounded-full px-2.5 text-[12px] font-semibold tabular whitespace-nowrap",
        tone === "overdue"
          ? "bg-danger-tint text-danger"
          : tone === "soon"
            ? "bg-warning-tint text-warning"
            : "bg-surface-2 text-text-2",
      )}
    >
      {children}
    </span>
  );
}
