/**
 * Generates every raster and vector brand asset from packages/ui/src/brand/scene.ts.
 *
 *   node --experimental-strip-types scripts/gen-icons.mts
 *
 * Outputs
 *   apps/app/public/icon.svg                  round mark, favicon for the product app
 *   apps/app/public/icons/icon-192.png        PWA icon, purpose "any" (rounded tile on transparent)
 *   apps/app/public/icons/icon-512.png
 *   apps/app/public/icons/icon-maskable-512.png  full-bleed tile, sun inside the safe zone
 *   apps/app/public/icons/apple-touch-icon.png   180 px square tile (iOS rounds it)
 *   apps/app/public/icons/icon-maskable-192.png  maskable at 192 px
 *   apps/app/public/icons/icon-monochrome-512.png  one-colour silhouette (Android themed icons)
 *   apps/app/public/icons/shortcut-{post,map,chats}-96.png  manifest shortcut icons
 *   apps/app/public/splash/iphone-<w>x<h>.png    apple-touch-startup-image, current iPhone sizes
 *   apps/app/public/screenshots/{narrow-1,narrow-2,wide-1}.png  manifest screenshots (install sheet)
 *   apps/web/src/app/icon.svg                 favicon for the public site (Next.js convention)
 *   apps/web/src/app/apple-icon.png           180 px square tile
 *   docs/design/brand/mark.svg, tile.svg, cover.svg   reference copies for decks and listings
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import {
  BRAND_COLORS,
  COVER,
  MARK,
  TILE,
  markSvg,
  tileSvg,
  coverSvg,
} from "../packages/ui/src/brand/scene.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");

async function write(path: string, data: string | Buffer) {
  const full = join(root, path);
  await mkdir(dirname(full), { recursive: true });
  await writeFile(full, data);
  console.log("wrote", path);
}

async function png(svg: string, size: number): Promise<Buffer> {
  return sharp(Buffer.from(svg), { density: 384 }).resize(size, size).png().toBuffer();
}

async function pngWH(svg: string, width: number, height: number): Promise<Buffer> {
  return sharp(Buffer.from(svg), { density: 144 })
    .resize(width, height)
    .png({ compressionLevel: 9, palette: true })
    .toBuffer();
}

/**
 * Android themed icons use only the alpha channel: the planet as a white disc with the sun's
 * rim and the horizon cut out, so the scene still reads in one colour.
 */
function monochromeSvg(): string {
  const { clip, sun, hill, horizonStroke } = MARK;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-8 -8 80 80" width="80" height="80">` +
    `<defs><mask id="m"><rect x="-8" y="-8" width="80" height="80" fill="#000"/>` +
    `<circle cx="${clip.cx}" cy="${clip.cy}" r="${clip.r}" fill="#fff"/>` +
    `<circle cx="${sun.cx}" cy="${sun.cy}" r="${sun.r + 2}" fill="#000"/>` +
    `<circle cx="${sun.cx}" cy="${sun.cy}" r="${sun.r - 1}" fill="#fff"/>` +
    `<circle cx="${hill.cx}" cy="${hill.cy}" r="${hill.r + horizonStroke}" fill="#000"/>` +
    `<circle cx="${hill.cx}" cy="${hill.cy}" r="${hill.r}" fill="#fff"/>` +
    `</mask></defs>` +
    `<rect x="-8" y="-8" width="80" height="80" fill="#fff" mask="url(#m)"/></svg>`
  );
}

/** A 96 px shortcut icon: the sky tile with a simple white glyph. */
function shortcutSvg(glyph: "post" | "map" | "chats"): string {
  const paths = {
    post: `<path d="M32 18v28M18 32h28" stroke="#fff" stroke-width="6" stroke-linecap="round"/>`,
    map: `<path d="M32 50s-13-12.5-13-22a13 13 0 0 1 26 0c0 9.5-13 22-13 22z" fill="#fff"/><circle cx="32" cy="28" r="5" fill="${BRAND_COLORS.sky}"/>`,
    chats: `<path d="M17 22a6 6 0 0 1 6-6h18a6 6 0 0 1 6 6v12a6 6 0 0 1-6 6H28l-9 7v-7.5A6 6 0 0 1 17 34z" fill="#fff"/>`,
  } as const;
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="64" height="64">` +
    `<rect width="64" height="64" rx="${TILE.cornerRadius}" fill="${BRAND_COLORS.sky}"/>` +
    paths[glyph] +
    `</svg>`
  );
}

/** iOS launch image: the round mark centred on white, a quarter of the short side wide. */
function splashSvg(width: number, height: number): string {
  const size = Math.round(Math.min(width, height) / 4);
  const x = Math.round((width - size) / 2);
  const y = Math.round((height - size) / 2);
  const inner = markSvg()
    .replace(/^<svg[^>]*>/, "")
    .replace(/<\/svg>$/, "");
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}">` +
    `<rect width="${width}" height="${height}" fill="#ffffff"/>` +
    `<svg x="${x}" y="${y}" width="${size}" height="${size}" viewBox="0 0 64 64">${inner}</svg>` +
    `</svg>`
  );
}

/**
 * Manifest screenshots for Android's install sheet: the cover scene, the line from the store
 * listing and a few empty card shapes. Brand art, never a real member's screen.
 */
function screenshotSvg(width: number, height: number, line: string): string {
  const bannerH = Math.round(height * (width > height ? 0.36 : 0.3));
  const cover = coverSvg()
    .replace(/^<svg[^>]*>/, "")
    .replace(/<\/svg>$/, "");
  const pad = Math.round(width * 0.07);
  const font = Math.round(Math.min(width, height) * 0.055);
  const cardW = width > height ? Math.round((width - pad * 4) / 3) : width - pad * 2;
  const cardH = Math.round(Math.min(width, height) * 0.16);
  const cardsTop = bannerH + pad + font * 2.6;
  const cards: string[] = [];
  for (let i = 0; i < 3; i += 1) {
    const cx = width > height ? pad + i * (cardW + pad) : pad;
    const cy = width > height ? cardsTop : cardsTop + i * (cardH + pad / 2);
    if (cy + cardH > height - pad) break;
    cards.push(
      `<rect x="${cx}" y="${cy}" width="${cardW}" height="${cardH}" rx="${Math.round(cardH * 0.14)}" fill="#ffffff" stroke="#e4e6ea" stroke-width="3"/>` +
        `<rect x="${cx + cardH * 0.18}" y="${cy + cardH * 0.22}" width="${cardW * 0.55}" height="${cardH * 0.16}" rx="${cardH * 0.08}" fill="#0e0f11"/>` +
        `<rect x="${cx + cardH * 0.18}" y="${cy + cardH * 0.56}" width="${cardW * 0.35}" height="${cardH * 0.12}" rx="${cardH * 0.06}" fill="#c9ced5"/>`,
    );
  }
  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${width} ${height}" width="${width}" height="${height}">` +
    `<rect width="${width}" height="${height}" fill="#f2f3f5"/>` +
    `<svg x="0" y="0" width="${width}" height="${bannerH}" viewBox="0 0 ${COVER.width} ${COVER.height}" preserveAspectRatio="xMidYMid slice">${cover}</svg>` +
    `<text x="${pad}" y="${bannerH + pad + font}" font-family="Inter, DejaVu Sans, sans-serif" font-weight="800" font-size="${font}" fill="#0e0f11">${line}</text>` +
    cards.join("") +
    `</svg>`
  );
}

/** Current iPhones in portrait: device pixels and CSS pixels at their scale. */
export const IPHONE_SPLASH = [
  { w: 1320, h: 2868, dw: 440, dh: 956, r: 3 },
  { w: 1206, h: 2622, dw: 402, dh: 874, r: 3 },
  { w: 1290, h: 2796, dw: 430, dh: 932, r: 3 },
  { w: 1179, h: 2556, dw: 393, dh: 852, r: 3 },
  { w: 1284, h: 2778, dw: 428, dh: 926, r: 3 },
  { w: 1170, h: 2532, dw: 390, dh: 844, r: 3 },
  { w: 1125, h: 2436, dw: 375, dh: 812, r: 3 },
  { w: 1242, h: 2688, dw: 414, dh: 896, r: 3 },
  { w: 828, h: 1792, dw: 414, dh: 896, r: 2 },
  { w: 750, h: 1334, dw: 375, dh: 667, r: 2 },
] as const;

const mark = markSvg();
const tileRounded = tileSvg({ rounded: true });
const tileSquare = tileSvg();
const tileMaskable = tileSvg({ maskable: true });

await write("apps/app/public/icon.svg", mark);
await write("apps/app/public/icons/icon-192.png", await png(tileRounded, 192));
await write("apps/app/public/icons/icon-512.png", await png(tileRounded, 512));
await write("apps/app/public/icons/icon-maskable-512.png", await png(tileMaskable, 512));
await write("apps/app/public/icons/apple-touch-icon.png", await png(tileSquare, 180));
await write("apps/app/public/icons/icon-maskable-192.png", await png(tileMaskable, 192));
await write("apps/app/public/icons/icon-monochrome-512.png", await png(monochromeSvg(), 512));
for (const g of ["post", "map", "chats"] as const) {
  await write(`apps/app/public/icons/shortcut-${g}-96.png`, await png(shortcutSvg(g), 96));
}
for (const s of IPHONE_SPLASH) {
  await write(
    `apps/app/public/splash/iphone-${s.w}x${s.h}.png`,
    await pngWH(splashSvg(s.w, s.h), s.w, s.h),
  );
}
await write(
  "apps/app/public/screenshots/narrow-1.png",
  await pngWH(screenshotSvg(1080, 1920, "Plans near you this week"), 1080, 1920),
);
await write(
  "apps/app/public/screenshots/narrow-2.png",
  await pngWH(screenshotSvg(1080, 1920, "Hubs for what you're into"), 1080, 1920),
);
await write(
  "apps/app/public/screenshots/wide-1.png",
  await pngWH(screenshotSvg(1920, 1080, "Find your people and something to do"), 1920, 1080),
);

await write("apps/web/src/app/icon.svg", mark);
await write("apps/web/src/app/apple-icon.png", await png(tileSquare, 180));

await write("docs/design/brand/mark.svg", mark);
await write("docs/design/brand/tile.svg", tileSquare);
await write("docs/design/brand/cover.svg", coverSvg());
await write("docs/design/brand/mark-512.png", await png(mark, 512));
