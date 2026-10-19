import { Link } from "@tanstack/react-router";
import { Home, MessageCircle, PlusSquare, UserRound, Users } from "lucide-react";

const TABS = [
  { to: "/", label: "Home", icon: Home, exact: true },
  { to: "/hubs", label: "Hubs", icon: Users },
  { to: "/post", label: "Post", icon: PlusSquare },
  { to: "/chats", label: "Chats", icon: MessageCircle },
  { to: "/you", label: "You", icon: UserRound },
] as const;

/** Bottom tabs. Fixed, above the home indicator, five destinations, no accent color (board rule). */
export function TabBar() {
  return (
    <nav
      aria-label="Primary"
      className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface/95 backdrop-blur safe-pb"
    >
      <div className="mx-auto flex h-14 max-w-lg items-stretch justify-around px-1">
        {TABS.map(({ to, label, icon: Icon, ...tab }) => (
          <Link
            key={to}
            to={to}
            activeOptions={{ exact: "exact" in tab ? tab.exact : false }}
            className="flex w-16 flex-col items-center justify-center gap-0.5 text-[10px] font-semibold text-text-3"
            activeProps={{ className: "text-text", "aria-current": "page" }}
          >
            {({ isActive }) => (
              <>
                <Icon className="size-6" strokeWidth={isActive ? 2.4 : 1.8} aria-hidden="true" />
                {label}
              </>
            )}
          </Link>
        ))}
      </div>
    </nav>
  );
}
