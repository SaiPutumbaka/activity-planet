import { forwardRef, useId, type InputHTMLAttributes, type ReactNode } from "react";

import { cn } from "@/lib/cn";

/**
 * Text input with label, hint and error. `FieldShell` is the label/hint/error frame on its own,
 * shared with FieldTextArea (textarea.tsx) and FieldSelect (select.tsx): it owns the ids and
 * hands the control its `id`, `aria-describedby` and `aria-invalid` through a render prop.
 *
 *   <Field label="First name" value={v} onChange={...} error={err} />
 *   <FieldShell label="Weekday" hint="Local time">{(a) => <select {...a}>...</select>}</FieldShell>
 */
export const inputClassName =
  "h-12 w-full rounded-input border border-border bg-surface px-4 text-[16px] text-text placeholder:text-text-3 outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/30 aria-invalid:border-danger aria-invalid:focus:ring-danger/30 disabled:opacity-50";

/** What FieldShell passes to the control it wraps. Spread it onto the input/textarea/select. */
export interface FieldControlProps {
  id: string;
  "aria-describedby": string | undefined;
  "aria-invalid": true | undefined;
}

export interface FieldShellProps {
  label: string;
  hint?: ReactNode;
  error?: string;
  /** Forwarded to the control; generated when omitted. */
  id?: string;
  className?: string;
  children: (control: FieldControlProps) => ReactNode;
}

/** Label, control, hint and error wired together with the right aria attributes. */
export function FieldShell({
  label,
  hint,
  error,
  id: idProp,
  className,
  children,
}: FieldShellProps) {
  const autoId = useId();
  const id = idProp ?? autoId;
  const hintId = `${id}-hint`;
  const errorId = `${id}-error`;
  const describedBy =
    [hint ? hintId : null, error ? errorId : null].filter(Boolean).join(" ") || undefined;

  return (
    <div className={cn("flex flex-col gap-1.5", className)}>
      <label htmlFor={id} className="text-[14px] font-semibold text-text">
        {label}
      </label>
      {children({ id, "aria-describedby": describedBy, "aria-invalid": error ? true : undefined })}
      {error ? (
        <p id={errorId} role="alert" className="text-[13px] font-medium text-danger">
          {error}
        </p>
      ) : hint ? (
        <p id={hintId} className="text-[13px] text-text-2">
          {hint}
        </p>
      ) : null}
    </div>
  );
}

export interface FieldProps extends Omit<InputHTMLAttributes<HTMLInputElement>, "prefix"> {
  label: string;
  hint?: ReactNode;
  error?: string;
  /** Rendered inside the input on the left, for prefixes like "@". */
  prefix?: ReactNode;
  /** Rendered inside the input on the right, for status like a spinner or a check. */
  suffix?: ReactNode;
}

export const Field = forwardRef<HTMLInputElement, FieldProps>(function Field(
  { label, hint, error, prefix, suffix, className, id, ...rest },
  ref,
) {
  return (
    <FieldShell label={label} hint={hint} error={error} id={id} className={className}>
      {(control) => (
        <div className="relative">
          {prefix ? (
            <span className="pointer-events-none absolute inset-y-0 left-4 flex items-center text-text-2">
              {prefix}
            </span>
          ) : null}
          <input
            ref={ref}
            className={cn(inputClassName, prefix && "pl-9", suffix && "pr-11")}
            {...control}
            {...rest}
          />
          {suffix ? (
            <span className="absolute inset-y-0 right-3 flex items-center">{suffix}</span>
          ) : null}
        </div>
      )}
    </FieldShell>
  );
});

/** A form-level error (not tied to one field). */
export function FormError({ children }: { children?: ReactNode }) {
  if (!children) return null;
  return (
    <div
      role="alert"
      className="rounded-input bg-danger-tint px-4 py-3 text-[14px] font-medium text-danger"
    >
      {children}
    </div>
  );
}
