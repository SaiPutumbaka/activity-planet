import type { ReactNode } from "react";
import { useRouter } from "@tanstack/react-router";
import { ChevronLeft } from "lucide-react";
import { Mark } from "@ap/ui/brand";

import { cn } from "@/lib/cn";

interface TopBarProps {
  /** Plain title. When omitted the brand lockup is shown (Home). */
  title?: string;
  /** Show a back button that pops history. */
  back?: boolean;
  actions?: ReactNode;
  className?: string;
}

/** Sticky header that clears the status bar on phones. */
export function TopBar({ title, back = false, actions, className }: TopBarProps) {
  const router = useRouter();
  return (
    <header className={cn("sticky top-0 z-20 bg-surface/90 backdrop-blur safe-pt", className)}>
      <div className="mx-auto flex h-14 max-w-lg items-center gap-2 safe-px">
        {back ? (
          <button
            type="button"
            onClick={() => router.history.back()}
            className="-ml-2 flex size-10 items-center justify-center rounded-full text-text hover:bg-surface-2"
            aria-label="Back"
          >
            <ChevronLeft className="size-6" aria-hidden="true" />
          </button>
        ) : title ? null : (
          <Mark size={28} />
        )}
        <h1 className="truncate text-[20px] font-extrabold tracking-[-0.02em]">
          {title ?? "Activity Planet"}
        </h1>
        <div className="flex-1" />
        {actions ? <div className="flex items-center gap-1">{actions}</div> : null}
      </div>
    </header>
  );
}
