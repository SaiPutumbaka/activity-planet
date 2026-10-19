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
 *   apps/web/src/app/icon.svg                 favicon for the public site (Next.js convention)
 *   apps/web/src/app/apple-icon.png           180 px square tile
 *   docs/design/brand/mark.svg, tile.svg, cover.svg   reference copies for decks and listings
 */
import { mkdir, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import sharp from "sharp";
import { markSvg, tileSvg, coverSvg } from "../packages/ui/src/brand/scene.ts";

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

const mark = markSvg();
const tileRounded = tileSvg({ rounded: true });
const tileSquare = tileSvg();
const tileMaskable = tileSvg({ maskable: true });

await write("apps/app/public/icon.svg", mark);
await write("apps/app/public/icons/icon-192.png", await png(tileRounded, 192));
await write("apps/app/public/icons/icon-512.png", await png(tileRounded, 512));
await write("apps/app/public/icons/icon-maskable-512.png", await png(tileMaskable, 512));
await write("apps/app/public/icons/apple-touch-icon.png", await png(tileSquare, 180));

await write("apps/web/src/app/icon.svg", mark);
await write("apps/web/src/app/apple-icon.png", await png(tileSquare, 180));

await write("docs/design/brand/mark.svg", mark);
await write("docs/design/brand/tile.svg", tileSquare);
await write("docs/design/brand/cover.svg", coverSvg());
await write("docs/design/brand/mark-512.png", await png(mark, 512));
