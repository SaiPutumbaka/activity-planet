import { Skeleton } from "@/components/ui/skeleton";
import { cn } from "@/lib/cn";

/** Loading, error and heading pieces shared by the Hubs tab and the hub page. */

export function SectionHeading({
  id,
  title,
  trailing,
}: {
  id?: string;
  title: string;
  /** Small text on the right: a count, a window. */
  trailing?: string;
}) {
  return (
    <div className="flex items-baseline justify-between gap-3">
      <h3 id={id} className="text-[17px] font-bold tracking-[-0.01em]">
        {title}
      </h3>
      {trailing ? <span className="text-[13px] text-text-2 tabular">{trailing}</span> : null}
    </div>
  );
}

export function ListSkeleton({
  rows = 3,
  rowClassName = "h-16",
}: {
  rows?: number;
  rowClassName?: string;
}) {
  return (
    <div className="flex flex-col gap-2">
      {Array.from({ length: rows }, (_, i) => (
        <Skeleton key={i} className={cn("w-full rounded-card", rowClassName)} />
      ))}
    </div>
  );
}

/** A list that failed to load: one sentence and a retry, inside the section it belongs to. */
export function InlineError({ message, onRetry }: { message: string; onRetry: () => void }) {
  return (
    <div
      role="alert"
      className="flex min-h-12 items-center justify-between gap-3 rounded-input bg-danger-tint px-4 py-2 text-[14px] font-medium text-danger"
    >
      <span>{message}</span>
      <button
        type="button"
        onClick={onRetry}
        className="shrink-0 rounded-control px-2 py-2 font-semibold underline-offset-2 hover:underline"
      >
        Try again
      </button>
    </div>
  );
}

const CHIP_WIDTHS = ["w-28", "w-36", "w-24", "w-32", "w-40", "w-28", "w-32", "w-24"];

export function HubsTabSkeleton() {
  return (
    <div className="flex flex-col gap-6" aria-busy="true" aria-label="Loading hubs">
      <div className="flex flex-col gap-3">
        <Skeleton className="h-5 w-24" />
        <ListSkeleton rows={3} />
      </div>
      {[0, 1].map((section) => (
        <div key={section} className="flex flex-col gap-3">
          <Skeleton className="h-4 w-32" />
          <div className="flex flex-wrap gap-2">
            {CHIP_WIDTHS.map((w, i) => (
              <Skeleton key={i} className={cn("h-11 rounded-control", w)} />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

export function HubPageSkeleton() {
  return (
    <div className="flex flex-col gap-7 pt-2" aria-busy="true" aria-label="Loading hub">
      <div className="flex flex-col gap-4">
        <div className="flex items-start gap-4">
          <Skeleton className="size-16" />
          <div className="flex flex-1 flex-col gap-2 pt-1">
            <Skeleton className="h-6 w-40" />
            <Skeleton className="h-4 w-28" />
          </div>
        </div>
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-13 w-full rounded-control" />
      </div>
      <div className="flex flex-col gap-3">
        <Skeleton className="h-5 w-24" />
        <ListSkeleton rows={2} rowClassName="h-24" />
      </div>
      <div className="flex flex-col gap-3">
        <Skeleton className="h-5 w-24" />
        <ListSkeleton rows={1} />
      </div>
    </div>
  );
}
