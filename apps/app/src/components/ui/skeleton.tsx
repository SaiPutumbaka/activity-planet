import { cn } from "@/lib/cn";

/**
 * A loading placeholder shaped like the thing it stands in for. Size it with className.
 *
 *   <Skeleton className="h-4 w-40" />
 *   <Skeleton className="size-10 rounded-full" />
 */
export function Skeleton({ className }: { className?: string }) {
  return (
    <div aria-hidden="true" className={cn("animate-pulse rounded-tile bg-surface-2", className)} />
  );
}
