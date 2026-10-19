import { useId, type SVGProps } from "react";
import { BRAND_COLORS, MARK } from "./scene";

export interface MarkProps extends Omit<SVGProps<SVGSVGElement>, "children"> {
  /** Rendered width and height in pixels. */
  size?: number;
  /** One-color version: a solid half sun over a horizon line, drawn in currentColor. */
  mono?: boolean;
  /** Accessible name; omit (default) to hide the mark from assistive tech when text sits beside it. */
  label?: string;
}

/**
 * The round Activity Planet mark. Colors come from the theme tokens (--color-sky, --color-sun,
 * --color-grass) with the light values as fallbacks, so it renders correctly inside and outside
 * the app's stylesheet. `mono` uses --color-paper for the cut-outs so the horizon line matches the
 * surface it sits on.
 */
export function Mark({ size = 24, mono = false, label, ...rest }: MarkProps) {
  const clipId = useId();
  const { clip, sun, hill, horizonStroke } = MARK;
  const a11y = label ? { role: "img", "aria-label": label } : { "aria-hidden": true as const };

  return (
    <svg viewBox="0 0 64 64" width={size} height={size} {...a11y} {...rest}>
      <defs>
        <clipPath id={clipId}>
          <circle cx={clip.cx} cy={clip.cy} r={clip.r} />
        </clipPath>
      </defs>
      {mono ? (
        <g clipPath={`url(#${clipId})`}>
          <rect width="64" height="64" fill="currentColor" />
          <circle cx={sun.cx} cy={sun.cy} r={sun.r} fill="var(--color-paper, #ffffff)" />
          <circle cx={hill.cx} cy={hill.cy} r={hill.r} fill="var(--color-paper, #ffffff)" />
          <circle cx={hill.cx} cy={hill.cy} r={hill.r - horizonStroke} fill="currentColor" />
        </g>
      ) : (
        <g clipPath={`url(#${clipId})`}>
          <rect width="64" height="64" fill={`var(--color-sky, ${BRAND_COLORS.sky})`} />
          <circle
            cx={sun.cx}
            cy={sun.cy}
            r={sun.r}
            fill={`var(--color-sun, ${BRAND_COLORS.sun})`}
          />
          <circle
            cx={hill.cx}
            cy={hill.cy}
            r={hill.r}
            fill={`var(--color-grass, ${BRAND_COLORS.grass})`}
          />
        </g>
      )}
    </svg>
  );
}
