import { NextResponse, type NextRequest } from "next/server";
import { landingPoint } from "@ap/core/recs";

import { getWeekNear } from "@/lib/week";

/**
 * GET /api/week?lat=&lng= : the landing page's week cards for a picked city or a shared point.
 * The point is validated and rounded to 0.1 degree again here, so every city is one cached
 * response. No point (or a bad one) gives the Atlanta default. The route never reads the
 * caller's IP, x-forwarded-for, x-vercel-ip-* or request.geo, and logs nothing about the request.
 */
export async function GET(request: NextRequest) {
  const params = request.nextUrl.searchParams;
  const point = landingPoint(params.get("lat"), params.get("lng"));
  const cards = await getWeekNear(point);
  if (cards === null) {
    return NextResponse.json(
      { error: "unavailable" },
      { status: 503, headers: { "Cache-Control": "no-store" } },
    );
  }
  return NextResponse.json(
    { cards },
    { headers: { "Cache-Control": "public, s-maxage=600, stale-while-revalidate=3600" } },
  );
}
