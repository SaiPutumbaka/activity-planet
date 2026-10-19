import type { SVGProps } from "react";
import { BRAND_COLORS, COVER } from "./scene";

export interface DefaultCoverProps extends Omit<SVGProps<SVGSVGElement>, "children"> {
  /**
   * Shifts the sun a little per event or hub so a column of default covers does not repeat
   * exactly. Any string works; the same seed always gives the same position.
   */
  seed?: string;
}

function hash(seed: string): number {
  let h = 2166136261;
  for (let i = 0; i < seed.length; i++) {
    h ^= seed.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0) / 4294967295;
}

/**
 * The planet scene as a wide cover for events and chapters that have no photo yet (board A's
 * idea, kept in D-029). Fills its box; put it in a container with a fixed height or aspect ratio.
 */
export function DefaultCover({ seed, className, ...rest }: DefaultCoverProps) {
  const { width, height, sun, hill } = COVER;
  const t = seed ? hash(seed) : 0.5;
  const sunX = sun.cx - 60 + Math.round(t * 120);

  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      preserveAspectRatio="xMidYMid slice"
      width="100%"
      height="100%"
      aria-hidden="true"
      className={className}
      {...rest}
    >
      <rect width={width} height={height} fill={`var(--color-sky, ${BRAND_COLORS.sky})`} />
      <circle cx={sunX} cy={sun.cy} r={sun.r} fill={`var(--color-sun, ${BRAND_COLORS.sun})`} />
      <circle
        cx={hill.cx}
        cy={hill.cy}
        r={hill.r}
        fill={`var(--color-grass, ${BRAND_COLORS.grass})`}
      />
    </svg>
  );
}
