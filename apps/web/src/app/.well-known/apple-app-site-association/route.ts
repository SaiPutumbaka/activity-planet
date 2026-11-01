import { NATIVE_APP_ID } from "@/lib/site";

/**
 * GET /.well-known/apple-app-site-association: Universal Links for the store build (D-013), so
 * a shared /e/[id] link opens the app when it is installed. 404 until APPLE_TEAM_ID is set: a
 * file with a placeholder Team ID would be cached by Apple's CDN and fail silently. Apple wants
 * application/json with no redirect and no extension.
 */
export const dynamic = "force-dynamic";

export function GET() {
  const teamId = process.env.APPLE_TEAM_ID?.trim();
  if (!teamId) return new Response("Not found", { status: 404 });

  const appId = `${teamId}.${NATIVE_APP_ID}`;
  return Response.json({
    applinks: {
      details: [{ appIDs: [appId], components: [{ "/": "/e/*", comment: "Shared plans" }] }],
    },
    webcredentials: { apps: [appId] },
  });
}
