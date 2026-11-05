import { useState, type ImgHTMLAttributes } from "react";
import { DefaultCover } from "@ap/ui/brand";

/**
 * A plan's cover, or the drawn default when it has none or its image fails to load (an imported
 * feed's image host that is down or blocked would otherwise show a broken-image icon).
 */
export function EventCover({
  src,
  seed,
  ...img
}: { src: string | null | undefined; seed: string } & Omit<
  ImgHTMLAttributes<HTMLImageElement>,
  "src" | "alt" | "onError"
>) {
  const [broken, setBroken] = useState<string | null>(null);
  if (!src || broken === src) return <DefaultCover seed={seed} />;
  return (
    <img
      src={src}
      alt=""
      className="size-full object-cover"
      {...img}
      onError={() => setBroken(src)}
    />
  );
}
