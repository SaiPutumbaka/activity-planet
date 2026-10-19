import { cn } from "@/lib/utils";

/**
 * Brand mark: a solid planet with an orbit ring and a small moon, drawn in
 * currentColor so it inherits text color (defaults to the tan primary).
 * Pure SVG — crisp at any size, no image assets.
 */
export function Logo({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 48 48"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={cn("h-8 w-8 text-primary", className)}
      aria-hidden
    >
      {/* Planet */}
      <circle cx="24" cy="24" r="11.5" fill="currentColor" />
      {/* Orbit ring */}
      <ellipse
        cx="24"
        cy="24"
        rx="20"
        ry="7.5"
        stroke="currentColor"
        strokeWidth="1.75"
        opacity="0.55"
        transform="rotate(-20 24 24)"
      />
      {/* Moon on the orbit */}
      <circle cx="41.5" cy="17" r="2.4" fill="currentColor" />
    </svg>
  );
}

export function LogoWordmark({
  className,
  markClassName,
}: {
  className?: string;
  markClassName?: string;
}) {
  return (
    <span
      className={cn(
        "inline-flex items-center gap-2 font-display font-semibold tracking-tight",
        className,
      )}
    >
      <Logo className={markClassName} />
      <span>
        Activity <span className="italic text-primary">Planet</span>
      </span>
    </span>
  );
}
