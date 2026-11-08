import type { NextConfig } from "next";

/**
 * Image sources (security review, migration 22). The database accepts only own-storage URLs for
 * avatars and human-made covers; imported events keep their feeds' own https covers (D-037), so
 * those image hosts are listed too. The map tile host is OpenFreeMap (D-038). Only img-src is
 * set, so scripts, styles and connections are unaffected; OG images are rendered server-side
 * and served from 'self'. Keep this list in step with apps/app/vite.config.ts.
 */
const IMPORTED_IMAGE_HOSTS = [
  "https://localist-images.azureedge.net", // GSU Localist
  "https://se-images.campuslabs.com", // PIN (Campus Labs Engage)
];
const MAP_TILE_HOST = "https://tiles.openfreemap.org";

/** This project's Storage origin; any Supabase project host only if the build has no URL. */
function storageOrigin(): string {
  const raw = process.env.NEXT_PUBLIC_SUPABASE_URL;
  try {
    if (raw) return new URL(raw).origin;
  } catch {
    /* fall through */
  }
  return "https://*.supabase.co";
}

const imgSrc = ["'self'", "data:", "blob:", storageOrigin(), MAP_TILE_HOST, ...IMPORTED_IMAGE_HOSTS]
  .filter(Boolean)
  .join(" ");

/**
 * Launch audit M10: the full policy, Report-Only first (browsers log what it would block). Next
 * injects inline bootstrap scripts, so script-src keeps 'unsafe-inline' until a nonce middleware
 * lands; Turnstile loads from challenges.cloudflare.com on the two request forms.
 */
const reportOnly = [
  "default-src 'self'",
  "script-src 'self' 'unsafe-inline' https://challenges.cloudflare.com",
  "style-src 'self' 'unsafe-inline'",
  `img-src ${imgSrc}`,
  "font-src 'self' data:",
  `connect-src 'self' ${storageOrigin()} https://challenges.cloudflare.com`,
  "frame-src https://challenges.cloudflare.com",
  "object-src 'none'",
  "base-uri 'self'",
  "form-action 'self'",
  "frame-ancestors 'none'",
].join("; ");

const securityHeaders = [
  // Enforced: images, plus the directives that cannot break a page.
  {
    key: "Content-Security-Policy",
    value: `img-src ${imgSrc}; object-src 'none'; base-uri 'self'; frame-ancestors 'none'`,
  },
  { key: "Content-Security-Policy-Report-Only", value: reportOnly },
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  // geolocation=(self) so the app's own location features work; v1 had geolocation=() which blocked them.
  { key: "Permissions-Policy", value: "camera=(self), microphone=(), geolocation=(self)" },
];

const nextConfig: NextConfig = {
  transpilePackages: ["@ap/core", "@ap/ui"],
  // Launch audit L11: no X-Powered-By header.
  poweredByHeader: false,
  typedRoutes: true,
  async headers() {
    return [
      { source: "/(.*)", headers: securityHeaders },
      // AASA and assetlinks (their routes set application/json). Apple's CDN and Android's
      // verifier cache these; an hour keeps a newly set APPLE_TEAM_ID or ANDROID_CERT_SHA256,
      // or a 404 before them, from sticking for long.
      {
        source: "/.well-known/:path*",
        headers: [{ key: "Cache-Control", value: "public, max-age=3600" }],
      },
    ];
  },
};

export default nextConfig;
