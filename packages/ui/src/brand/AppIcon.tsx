import { useId, type SVGProps } from "react";
import { BRAND_COLORS, TILE } from "./scene";

export interface AppIconProps extends Omit<SVGProps<SVGSVGElement>, "children"> {
  size?: number;
  /** Corner radius as a fraction of the size; iOS uses about 0.225. */
  radius?: number;
}

/** The home-screen tile, for install prompts and the account screen. */
export function AppIcon({ size = 64, radius = 0.225, ...rest }: AppIconProps) {
  const clipId = useId();
  const { sun, hill } = TILE;
  return (
    <svg viewBox="0 0 64 64" width={size} height={size} aria-hidden="true" {...rest}>
      <defs>
        <clipPath id={clipId}>
          <rect width="64" height="64" rx={64 * radius} />
        </clipPath>
      </defs>
      <g clipPath={`url(#${clipId})`}>
        <rect width="64" height="64" fill={`var(--color-sky, ${BRAND_COLORS.sky})`} />
        <circle cx={sun.cx} cy={sun.cy} r={sun.r} fill={`var(--color-sun, ${BRAND_COLORS.sun})`} />
        <circle
          cx={hill.cx}
          cy={hill.cy}
          r={hill.r}
          fill={`var(--color-grass, ${BRAND_COLORS.grass})`}
        />
      </g>
    </svg>
  );
}
