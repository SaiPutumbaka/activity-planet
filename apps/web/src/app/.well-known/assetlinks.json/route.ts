import { NATIVE_APP_ID } from "@/lib/site";

/**
 * GET /.well-known/assetlinks.json: Android App Links for the store build (D-013), the Play
 * counterpart of the apple-app-site-association route. 404 until ANDROID_CERT_SHA256 is set; it
 * takes a comma-separated list, since the upload key and Play App Signing key differ.
 */
export const dynamic = "force-dynamic";

export function GET() {
  const fingerprints = (process.env.ANDROID_CERT_SHA256 ?? "")
    .split(",")
    .map((f) => f.trim().toUpperCase())
    .filter(Boolean);
  if (fingerprints.length === 0) return new Response("Not found", { status: 404 });

  return Response.json([
    {
      relation: ["delegate_permission/common.handle_all_urls"],
      target: {
        namespace: "android_app",
        package_name: NATIVE_APP_ID,
        sha256_cert_fingerprints: fingerprints,
      },
    },
  ]);
}
