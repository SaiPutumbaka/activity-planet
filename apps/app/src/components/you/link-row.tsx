import type { ReactNode } from "react";
import { Link, type LinkProps } from "@tanstack/react-router";
import { ChevronRight } from "lucide-react";

import { cn } from "@/lib/cn";

/**
 * A settings row that goes somewhere: label and hint on the left, the current value and a
 * chevron on the right. Sits inside the same divided card as the plain rows on the You tab.
 */
export function LinkRow({
  to,
  label,
  value,
  hint,
  valueClassName,
}: {
  to: LinkProps["to"];
  label: string;
  value: ReactNode;
  hint?: string;
  valueClassName?: string;
}) {
  return (
    <Link
      to={to}
      className="flex min-h-11 items-center justify-between gap-4 px-4 py-3 transition-colors hover:bg-surface-2"
    >
      <span className="min-w-0">
        <span className="block text-[15px] font-medium">{label}</span>
        {hint ? <span className="block text-[12px] text-text-3">{hint}</span> : null}
      </span>
      <span className="flex min-w-0 shrink-0 items-center gap-1 text-[15px] text-text-2">
        <span className={cn("max-w-[40vw] truncate", valueClassName)}>{value}</span>
        <ChevronRight className="size-4 shrink-0 text-text-3" aria-hidden="true" />
      </span>
    </Link>
  );
}
