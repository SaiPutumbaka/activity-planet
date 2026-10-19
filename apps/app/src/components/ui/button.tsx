import { forwardRef, type ButtonHTMLAttributes, type ReactNode } from "react";
import type { VariantProps } from "class-variance-authority";

import { cn } from "@/lib/cn";
import { buttonVariants } from "./button-variants";
import { Spinner } from "./spinner";

export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>, VariantProps<typeof buttonVariants> {
  loading?: boolean;
  leading?: ReactNode;
  trailing?: ReactNode;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  {
    className,
    variant,
    size,
    block,
    loading = false,
    leading,
    trailing,
    disabled,
    children,
    type = "button",
    ...rest
  },
  ref,
) {
  return (
    <button
      ref={ref}
      type={type}
      className={cn(buttonVariants({ variant, size, block }), className)}
      disabled={disabled || loading}
      aria-busy={loading || undefined}
      {...rest}
    >
      {loading ? <Spinner className="size-[18px]" /> : leading}
      {children}
      {!loading && trailing}
    </button>
  );
});
