import { forwardRef, type ReactNode, type TextareaHTMLAttributes } from "react";

import { cn } from "@/lib/cn";
import { FieldShell } from "./field";

/**
 * Multi-line text. `TextArea` is the bare control styled like inputClassName; `FieldTextArea`
 * adds the label/hint/error frame from field.tsx.
 *
 *   <FieldTextArea label="Description" rows={4} maxLength={2000} value={v} onChange={...} />
 */
export const textareaClassName =
  "min-h-[120px] w-full resize-y rounded-input border border-border bg-surface px-4 py-3 text-[16px] leading-[1.4] text-text placeholder:text-text-3 outline-none transition-colors focus:border-primary focus:ring-2 focus:ring-primary/30 aria-invalid:border-danger aria-invalid:focus:ring-danger/30 disabled:opacity-50";

export type TextAreaProps = TextareaHTMLAttributes<HTMLTextAreaElement>;

export const TextArea = forwardRef<HTMLTextAreaElement, TextAreaProps>(function TextArea(
  { className, ...rest },
  ref,
) {
  return <textarea ref={ref} className={cn(textareaClassName, className)} {...rest} />;
});

export interface FieldTextAreaProps extends TextAreaProps {
  label: string;
  hint?: ReactNode;
  error?: string;
}

export const FieldTextArea = forwardRef<HTMLTextAreaElement, FieldTextAreaProps>(
  function FieldTextArea({ label, hint, error, className, id, ...rest }, ref) {
    return (
      <FieldShell label={label} hint={hint} error={error} id={id} className={className}>
        {(control) => <TextArea ref={ref} {...control} {...rest} />}
      </FieldShell>
    );
  },
);
