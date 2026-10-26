import { useRef, type KeyboardEvent } from "react";

import { cn } from "@/lib/cn";

/**
 * Two to four exclusive choices in one pill (theme, Today / This week / Later, going / interested).
 * A radiogroup: Tab lands on the chosen option, arrow keys move the choice. The selected segment
 * is a raised surface, not the accent.
 *
 *   <SegmentedControl value={v} onChange={setV} label="Theme"
 *     options={[{ value: "light", label: "Light" }, { value: "dark", label: "Dark" }]} />
 */
export interface SegmentedOption<T extends string> {
  value: T;
  label: string;
}

export interface SegmentedControlProps<T extends string> {
  value: T;
  onChange: (value: T) => void;
  options: readonly SegmentedOption<T>[];
  /** Accessible name of the group. */
  label?: string;
  className?: string;
}

export function SegmentedControl<T extends string>({
  value,
  onChange,
  options,
  label,
  className,
}: SegmentedControlProps<T>) {
  const groupRef = useRef<HTMLDivElement>(null);

  function onKeyDown(event: KeyboardEvent<HTMLDivElement>) {
    const step =
      event.key === "ArrowRight" || event.key === "ArrowDown"
        ? 1
        : event.key === "ArrowLeft" || event.key === "ArrowUp"
          ? -1
          : 0;
    if (step === 0 || options.length === 0) return;
    event.preventDefault();
    const index = options.findIndex((o) => o.value === value);
    const next = options[(index + step + options.length) % options.length];
    if (!next) return;
    onChange(next.value);
    const buttons = groupRef.current?.querySelectorAll<HTMLButtonElement>('[role="radio"]');
    buttons?.[(index + step + options.length) % options.length]?.focus();
  }

  return (
    <div
      ref={groupRef}
      role="radiogroup"
      aria-label={label}
      onKeyDown={onKeyDown}
      className={cn("flex rounded-control bg-surface-2 p-1", className)}
    >
      {options.map((o) => {
        const selected = o.value === value;
        return (
          <button
            key={o.value}
            type="button"
            role="radio"
            aria-checked={selected}
            tabIndex={selected ? 0 : -1}
            onClick={() => onChange(o.value)}
            className={cn(
              "h-10 min-w-0 flex-1 truncate rounded-control px-2 text-[14px] font-semibold transition-colors",
              selected ? "bg-surface text-text shadow-[var(--shadow-card)]" : "text-text-2",
            )}
          >
            {o.label}
          </button>
        );
      })}
    </div>
  );
}
