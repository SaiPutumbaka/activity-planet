import { cva } from "class-variance-authority";

/**
 * Board rule: the primary variant is the one loud thing on a screen, and its text is ink, never
 * white (ink on the sun orange passes AA; white does not).
 */
export const buttonVariants = cva(
  "inline-flex shrink-0 select-none items-center justify-center gap-2 whitespace-nowrap rounded-control border border-transparent font-semibold transition-[transform,background-color,color,opacity] duration-150 active:scale-[.97] disabled:pointer-events-none disabled:opacity-50",
  {
    variants: {
      variant: {
        primary: "bg-primary text-on-primary hover:brightness-[1.03]",
        secondary: "bg-surface-2 text-text hover:bg-surface-3",
        outline: "border-border-strong bg-surface text-text hover:bg-surface-2",
        ghost: "bg-transparent text-primary-text hover:bg-primary-tint",
        danger: "bg-danger-tint text-danger hover:brightness-95",
      },
      size: {
        sm: "h-9 px-3.5 text-[14px]",
        md: "h-11 px-[18px] text-[15px]",
        lg: "h-13 px-[22px] text-[17px]",
        icon: "h-11 w-11 px-0",
        "icon-sm": "h-9 w-9 px-0",
      },
      block: { true: "w-full" },
    },
    defaultVariants: { variant: "primary", size: "md" },
  },
);
