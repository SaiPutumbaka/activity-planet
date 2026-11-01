import { BRAND_COLORS } from "@ap/ui/brand";

/**
 * Shared pieces of the generated link previews: the site default (app/opengraph-image.tsx) and
 * the per-plan one (app/e/[id]/opengraph-image.tsx). Satori layout: every div with more than one
 * child needs display flex.
 */
export const OG_SIZE = { width: 1200, height: 630 };

// Light tokens from packages/ui/src/tokens.css; a PNG has no theme to follow.
export const INK = "#0e0f11";
export const TEXT_2 = "#65696f";
export const PAPER = "#ffffff";

/**
 * Figtree from Google Fonts. Asking with an old browser user agent returns a plain WOFF, which
 * Satori can read (it cannot read WOFF2). Cached across requests; on any failure the image falls
 * back to Satori's default font rather than failing the preview.
 */
async function figtree(weight: 500 | 800): Promise<ArrayBuffer | null> {
  try {
    const css = await fetch(`https://fonts.googleapis.com/css2?family=Figtree:wght@${weight}`, {
      headers: {
        "User-Agent":
          "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_6_8) AppleWebKit/534.59.10 (KHTML, like Gecko) Version/5.1.9 Safari/534.59.10",
      },
      cache: "force-cache",
    }).then((r) => (r.ok ? r.text() : ""));
    const url = /src:\s*url\(([^)]+)\)\s*format\('(?:woff|truetype|opentype)'\)/.exec(css)?.[1];
    if (!url) return null;
    const res = await fetch(url, { cache: "force-cache" });
    return res.ok ? await res.arrayBuffer() : null;
  } catch {
    return null;
  }
}

/** Figtree 800 and 500 in ImageResponse's fonts shape, minus any weight that failed to load. */
export async function ogFonts() {
  const [bold, medium] = await Promise.all([figtree(800), figtree(500)]);
  return [
    bold ? { name: "Figtree", data: bold, weight: 800 as const, style: "normal" as const } : null,
    medium
      ? { name: "Figtree", data: medium, weight: 500 as const, style: "normal" as const }
      : null,
  ].filter((f) => f !== null);
}

export function truncate(text: string, max: number): string {
  const clean = text.replace(/\s+/g, " ").trim();
  if (clean.length <= max) return clean;
  const head = clean.slice(0, max + 1);
  const space = head.lastIndexOf(" ");
  return `${(space > max * 0.6 ? head.slice(0, space) : head.slice(0, max)).replace(/[\s,;:.\-–—]+$/, "")}…`;
}

/**
 * The 1200 x 630 card: the planet band on top, a title and a meta line, the lockup bottom left
 * and an optional line bottom right.
 */
export function OgCard({
  title,
  meta,
  aside,
}: {
  title: string;
  meta: string;
  aside?: string | null;
}) {
  return (
    <div
      style={{
        width: OG_SIZE.width,
        height: OG_SIZE.height,
        display: "flex",
        flexDirection: "column",
        background: PAPER,
        fontFamily: "Figtree, sans-serif",
        color: INK,
      }}
    >
      <PlanetBand />

      <div
        style={{
          display: "flex",
          flex: 1,
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "40px 64px 44px",
        }}
      >
        <div style={{ display: "flex", flexDirection: "column", gap: 16 }}>
          <div
            style={{
              fontSize: title.length > 40 ? 56 : 66,
              fontWeight: 800,
              lineHeight: 1.08,
              letterSpacing: "-0.025em",
              lineClamp: 2,
            }}
          >
            {title}
          </div>
          <div
            style={{
              fontSize: 28,
              fontWeight: 500,
              lineHeight: 1.3,
              color: TEXT_2,
              lineClamp: 2,
            }}
          >
            {meta}
          </div>
        </div>

        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "space-between",
            gap: 24,
          }}
        >
          <Lockup />
          {aside ? (
            <div style={{ fontSize: 24, fontWeight: 500, color: TEXT_2 }}>{aside}</div>
          ) : null}
        </div>
      </div>
    </div>
  );
}

/**
 * The site's default preview, also used for campus and 21+ plans, whose share card carries
 * nothing that may be shown logged out.
 */
export function GenericOgCard() {
  return (
    <OgCard
      title="Find your people and something to do with them this week."
      meta="Hubs for every interest, real plans, real connection."
    />
  );
}

/** The planet as a band: sky, the sun half-risen on the band's edge, the hill on the left. */
function PlanetBand() {
  return (
    <div
      style={{
        position: "relative",
        display: "flex",
        width: OG_SIZE.width,
        height: 236,
        overflow: "hidden",
        background: BRAND_COLORS.sky,
      }}
    >
      <div
        style={{
          position: "absolute",
          left: 840,
          top: 96,
          width: 184,
          height: 184,
          borderRadius: 9999,
          background: BRAND_COLORS.sun,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: -520,
          top: 120,
          width: 1860,
          height: 1860,
          borderRadius: 9999,
          background: BRAND_COLORS.grass,
        }}
      />
    </div>
  );
}

/** The round mark (packages/ui/src/brand/scene.ts geometry scaled from 64) next to the name. */
function Lockup() {
  const s = 52 / 64;
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14 }}>
      <div
        style={{
          position: "relative",
          display: "flex",
          width: 52,
          height: 52,
          borderRadius: 9999,
          overflow: "hidden",
          background: BRAND_COLORS.sky,
        }}
      >
        <div
          style={{
            position: "absolute",
            left: (41 - 14) * s,
            top: (35 - 14) * s,
            width: 28 * s,
            height: 28 * s,
            borderRadius: 9999,
            background: BRAND_COLORS.sun,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: (26 - 40) * s,
            top: (78 - 40) * s,
            width: 80 * s,
            height: 80 * s,
            borderRadius: 9999,
            background: BRAND_COLORS.grass,
          }}
        />
      </div>
      <div style={{ fontSize: 28, fontWeight: 800, letterSpacing: "-0.015em" }}>
        Activity Planet
      </div>
    </div>
  );
}
