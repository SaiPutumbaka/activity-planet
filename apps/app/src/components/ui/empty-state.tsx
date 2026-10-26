import type { ReactNode } from "react";
import type { LucideIcon } from "lucide-react";

import { cn } from "@/lib/cn";

/**
 * What a list shows when it has nothing to show: an icon, a plain sentence and (sometimes) one
 * action. Same look as the Coming soon screen, sized to sit inside a page rather than be one.
 *
 *   <EmptyState icon={CalendarX} title="Nothing this week" body="Join a hub to see its plans."
 *     action={<Button variant="secondary">Browse hubs</Button>} />
 */
export interface EmptyStateProps {
  icon: LucideIcon;
  title: string;
  body?: string;
  action?: ReactNode;
  className?: string;
}

export function EmptyState({ icon: Icon, title, body, action, className }: EmptyStateProps) {
  return (
    <div className={cn("flex flex-col items-center gap-3 px-6 py-12 text-center", className)}>
      <div className="flex size-16 items-center justify-center rounded-full bg-surface-2 text-text-2">
        <Icon className="size-7" aria-hidden="true" />
      </div>
      <h3 className="text-[17px] font-bold tracking-tight">{title}</h3>
      {body ? <p className="max-w-[32ch] text-[15px] text-text-2">{body}</p> : null}
      {action ? <div className="pt-1">{action}</div> : null}
    </div>
  );
}
