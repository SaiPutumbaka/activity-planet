import type { ButtonHTMLAttributes, ReactNode } from "react";

import { cn } from "@/lib/cn";

export interface ChipProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  selected?: boolean;
  leading?: ReactNode;
}

/** A selectable pill. Selected state uses the accent tint with accent text, never a filled accent. */
export function Chip({ selected = false, leading, className, children, ...rest }: ChipProps) {
  return (
    <button
      type="button"
      aria-pressed={selected}
      className={cn(
        "inline-flex h-9 shrink-0 items-center gap-1.5 whitespace-nowrap rounded-control border px-3 text-[14px] font-semibold transition-colors active:scale-[.97]",
        selected
          ? "border-transparent bg-primary-tint text-primary-text"
          : "border-border bg-surface text-text hover:bg-surface-2",
        className,
      )}
      {...rest}
    >
      {leading ? <span className="text-[15px] leading-none">{leading}</span> : null}
      {children}
    </button>
  );
}
