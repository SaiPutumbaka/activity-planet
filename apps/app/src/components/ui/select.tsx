import { forwardRef, type ReactNode, type SelectHTMLAttributes } from "react";
import { ChevronDown } from "lucide-react";

import { cn } from "@/lib/cn";
import { FieldShell } from "./field";

/**
 * Native <select> styled like inputClassName, for short fixed lists (weekday, duration, 18+/21+).
 * Options are ordinary <option> children so the OS picker does the work on phones.
 *
 *   <FieldSelect label="Weekday" value={v} onChange={(e) => setV(e.target.value)}>
 *     <option value="1">Monday</option>
 *   </FieldSelect>
 */
export const selectClassName =
  "h-12 w-full appearance-none rounded-input border border-border bg-surface pl-4 pr-11 text-[16px] text-text outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/30 aria-invalid:border-danger aria-invalid:focus:ring-danger/30 disabled:opacity-50";

export type SelectProps = SelectHTMLAttributes<HTMLSelectElement>;

export const Select = forwardRef<HTMLSelectElement, SelectProps>(function Select(
  { className, children, ...rest },
  ref,
) {
  return (
    <div className={cn("relative", className)}>
      <select ref={ref} className={selectClassName} {...rest}>
        {children}
      </select>
      <ChevronDown
        className="pointer-events-none absolute inset-y-0 right-4 my-auto size-5 text-text-2"
        aria-hidden="true"
      />
    </div>
  );
});

export interface FieldSelectProps extends SelectProps {
  label: string;
  hint?: ReactNode;
  error?: string;
}

export const FieldSelect = forwardRef<HTMLSelectElement, FieldSelectProps>(function FieldSelect(
  { label, hint, error, className, id, ...rest },
  ref,
) {
  return (
    <FieldShell label={label} hint={hint} error={error} id={id} className={className}>
      {(control) => <Select ref={ref} {...control} {...rest} />}
    </FieldShell>
  );
});
