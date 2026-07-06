import { cn } from "@/lib/utils";

/**
 * Brand mark: a violet planet with an orbit ring and a small moon.
 * Pure SVG — crisp at any size, no image assets, themable via gradients.
 */
export function Logo({ className }: { className?: string }) {
  return (
    <svg
      viewBox="0 0 48 48"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={cn("h-8 w-8", className)}
      aria-hidden
    >
      <defs>
        <linearGradient id="ap-planet" x1="10" y1="10" x2="38" y2="38">
          <stop offset="0%" stopColor="#a855f7" />
          <stop offset="55%" stopColor="#7c3aed" />
          <stop offset="100%" stopColor="#d946ef" />
        </linearGradient>
        <linearGradient id="ap-ring" x1="2" y1="24" x2="46" y2="24">
          <stop offset="0%" stopColor="#22d3ee" />
          <stop offset="50%" stopColor="#a855f7" />
          <stop offset="100%" stopColor="#d946ef" />
        </linearGradient>
      </defs>
      {/* Planet */}
      <circle cx="24" cy="24" r="13" fill="url(#ap-planet)" />
      {/* Highlight */}
      <circle cx="19" cy="19" r="4.5" fill="white" fillOpacity="0.28" />
      {/* Orbit ring */}
      <ellipse
        cx="24"
        cy="24"
        rx="21"
        ry="8.5"
        stroke="url(#ap-ring)"
        strokeWidth="2.5"
        transform="rotate(-18 24 24)"
      />
      {/* Moon on the orbit */}
      <circle cx="42" cy="17" r="3.2" fill="#22d3ee" />
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
        "inline-flex items-center gap-2 font-bold tracking-tight",
        className,
      )}
    >
      <Logo className={markClassName} />
      <span>
        Activity <span className="text-gradient">Planet</span>
      </span>
    </span>
  );
}
