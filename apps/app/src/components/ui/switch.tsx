import { cn } from "@/lib/cn";

/**
 * On/off row: label on the left, track on the right, the whole row is the 44 px tap target.
 * The track is ink when on and the thumb is the surface: a setting is neither the primary action
 * nor a live state, so it never takes the accent (board rule: one loud thing).
 *
 *   <Switch label="Waitlist when full" checked={v} onCheckedChange={setV} hint="Up to 20 people" />
 */
export interface SwitchProps {
  checked: boolean;
  onCheckedChange: (checked: boolean) => void;
  label: string;
  hint?: string;
  disabled?: boolean;
  className?: string;
}

export function Switch({
  checked,
  onCheckedChange,
  label,
  hint,
  disabled,
  className,
}: SwitchProps) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      disabled={disabled}
      onClick={() => onCheckedChange(!checked)}
      className={cn(
        "flex min-h-11 w-full items-center justify-between gap-4 rounded-input text-left disabled:opacity-50",
        className,
      )}
    >
      <span className="min-w-0">
        <span className="block text-[15px] font-medium text-text">{label}</span>
        {hint ? <span className="block text-[13px] text-text-2">{hint}</span> : null}
      </span>
      <span
        aria-hidden="true"
        className={cn(
          "relative h-[30px] w-[50px] shrink-0 rounded-control transition-colors duration-150",
          checked ? "bg-text" : "bg-border-strong",
        )}
      >
        <span
          className={cn(
            "absolute top-[3px] left-[3px] size-6 rounded-full bg-surface transition-[translate] duration-150",
            checked && "translate-x-5",
          )}
        />
      </span>
    </button>
  );
}
