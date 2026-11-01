import type { NextConfig } from "next";

const securityHeaders = [
  { key: "X-Content-Type-Options", value: "nosniff" },
  { key: "X-Frame-Options", value: "DENY" },
  { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
  // geolocation=(self) so the app's own location features work; v1 had geolocation=() which blocked them.
  { key: "Permissions-Policy", value: "camera=(self), microphone=(), geolocation=(self)" },
];

const nextConfig: NextConfig = {
  transpilePackages: ["@ap/core", "@ap/ui"],
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
