/**
 * The Activity Planet mark, "Sunrise" (decision D-030): a round planet, sky above a hill, the sun
 * coming up behind the crest. Every brand asset is built from these numbers so the favicon, the
 * PWA icons, the in-app component and the default event cover are the same scene.
 *
 * All geometry is in a 64 x 64 box. Colors default to the light tokens; the React components
 * read the CSS custom properties instead so the mark follows the theme.
 */
export const BRAND_COLORS = {
  sky: "#3BA7F0",
  grass: "#2DB15B",
  sun: "#F25C0A",
  skyDark: "#2E8FD9",
  sunDark: "#FF7A1F",
} as const;

/** The round mark: planet clip, sky, sun, hill. */
export const MARK = {
  clip: { cx: 32, cy: 32, r: 30 },
  sun: { cx: 41, cy: 35, r: 14 },
  hill: { cx: 26, cy: 78, r: 40 },
  horizonStroke: 3.5,
} as const;

/** The app icon: the same scene filling a square tile. */
export const TILE = {
  sun: { cx: 45, cy: 35, r: 17 },
  hill: { cx: 24, cy: 88, r: 54 },
  /** Maskable icons keep the sun inside the 80% safe zone. */
  maskableSun: { cx: 41, cy: 34, r: 14 },
  cornerRadius: 14,
} as const;

/** The default event cover, 345 x 132, cropped with xMidYMid slice. */
export const COVER = {
  width: 345,
  height: 132,
  sun: { cx: 250, cy: 92, r: 40 },
  hill: { cx: 150, cy: 270, r: 190 },
} as const;

export interface SceneColors {
  sky: string;
  grass: string;
  sun: string;
}

const LIGHT: SceneColors = {
  sky: BRAND_COLORS.sky,
  grass: BRAND_COLORS.grass,
  sun: BRAND_COLORS.sun,
};

/** Standalone SVG of the round mark, for favicons and static images. */
export function markSvg(colors: SceneColors = LIGHT): string {
  const { clip, sun, hill } = MARK;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` +
    `<defs><clipPath id="p"><circle cx="${clip.cx}" cy="${clip.cy}" r="${clip.r}"/></clipPath></defs>` +
    `<g clip-path="url(#p)">` +
    `<rect width="64" height="64" fill="${colors.sky}"/>` +
    `<circle cx="${sun.cx}" cy="${sun.cy}" r="${sun.r}" fill="${colors.sun}"/>` +
    `<circle cx="${hill.cx}" cy="${hill.cy}" r="${hill.r}" fill="${colors.grass}"/>` +
    `</g></svg>`
  );
}

/** Standalone SVG of the square app icon. `maskable` keeps the sun inside the safe zone. */
export function tileSvg(
  opts: { maskable?: boolean; rounded?: boolean; colors?: SceneColors } = {},
): string {
  const colors = opts.colors ?? LIGHT;
  const sun = opts.maskable ? TILE.maskableSun : TILE.sun;
  const { hill } = TILE;
  const clip = opts.rounded
    ? `<defs><clipPath id="t"><rect width="64" height="64" rx="${TILE.cornerRadius}"/></clipPath></defs><g clip-path="url(#t)">`
    : `<g>`;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` +
    clip +
    `<rect width="64" height="64" fill="${colors.sky}"/>` +
    `<circle cx="${sun.cx}" cy="${sun.cy}" r="${sun.r}" fill="${colors.sun}"/>` +
    `<circle cx="${hill.cx}" cy="${hill.cy}" r="${hill.r}" fill="${colors.grass}"/>` +
    `</g></svg>`
  );
}

/** Standalone SVG of the default event cover. */
export function coverSvg(colors: SceneColors = LIGHT): string {
  const { width, height, sun, hill } = COVER;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}">` +
    `<rect width="${width}" height="${height}" fill="${colors.sky}"/>` +
    `<circle cx="${sun.cx}" cy="${sun.cy}" r="${sun.r}" fill="${colors.sun}"/>` +
    `<circle cx="${hill.cx}" cy="${hill.cy}" r="${hill.r}" fill="${colors.grass}"/>` +
    `</svg>`
  );
}
