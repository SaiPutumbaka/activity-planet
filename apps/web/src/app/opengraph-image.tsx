import { ImageResponse } from "next/og";

import { GenericOgCard, OG_SIZE, ogFonts } from "@/lib/og";

/**
 * The site's default link preview: the planet band, the tagline and the lockup. Routes with
 * their own opengraph-image (/e/[id]) replace it. Static: built once at build time.
 */
export const alt = "Activity Planet";
export const size = OG_SIZE;
export const contentType = "image/png";

export default async function OpenGraphImage() {
  return new ImageResponse(<GenericOgCard />, { ...size, fonts: await ogFonts() });
}
