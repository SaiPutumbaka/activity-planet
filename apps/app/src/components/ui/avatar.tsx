import { useState } from "react";

import { cn } from "@/lib/cn";

/**
 * A person: their photo, or the first letter of their name on the accent tint. `AvatarStack`
 * overlaps a few of them for attendee rows and says the real count ("12 going").
 *
 *   <Avatar src={p.avatar_url} name={p.first_name} size={40} />
 *   <AvatarStack people={going} max={4} totalLabel={`${count} going`} />
 */
export interface AvatarProps {
  src?: string | null;
  name: string;
  /** Diameter in px. */
  size?: number;
  className?: string;
}

export function Avatar({ src, name, size = 40, className }: AvatarProps) {
  const [broken, setBroken] = useState(false);
  const showImage = Boolean(src) && !broken;
  const initial = name.trim().slice(0, 1).toUpperCase() || "?";

  return (
    <span
      role="img"
      aria-label={name}
      className={cn(
        "inline-flex shrink-0 select-none items-center justify-center overflow-hidden rounded-full bg-primary-tint font-bold text-primary-text",
        className,
      )}
      style={{ width: size, height: size, fontSize: Math.round(size * 0.42) }}
    >
      {showImage ? (
        <img
          src={src ?? undefined}
          alt=""
          width={size}
          height={size}
          loading="lazy"
          onError={() => setBroken(true)}
          className="size-full object-cover"
        />
      ) : (
        initial
      )}
    </span>
  );
}

export interface AvatarStackProps {
  people: { src?: string | null; name: string }[];
  /** How many faces to show before the "+N" bubble. */
  max?: number;
  /** Real count in words, e.g. "12 going". Rendered after the faces. */
  totalLabel?: string;
  size?: number;
  className?: string;
}

export function AvatarStack({
  people,
  max = 4,
  totalLabel,
  size = 28,
  className,
}: AvatarStackProps) {
  const shown = people.slice(0, max);
  const rest = people.length - shown.length;
  if (shown.length === 0 && !totalLabel) return null;

  return (
    <div className={cn("flex items-center gap-2", className)}>
      {shown.length > 0 ? (
        <div className="flex" aria-hidden={totalLabel ? true : undefined}>
          {shown.map((p, i) => (
            <Avatar
              key={`${p.name}-${i}`}
              src={p.src}
              name={p.name}
              size={size}
              className={cn("ring-2 ring-surface", i > 0 && "-ml-2")}
            />
          ))}
          {rest > 0 ? (
            <span
              className="-ml-2 inline-flex shrink-0 items-center justify-center rounded-full bg-surface-2 font-semibold text-text-2 ring-2 ring-surface tabular"
              style={{ width: size, height: size, fontSize: Math.round(size * 0.4) }}
            >
              +{rest}
            </span>
          ) : null}
        </div>
      ) : null}
      {totalLabel ? <span className="text-[13px] text-text-2 tabular">{totalLabel}</span> : null}
    </div>
  );
}
