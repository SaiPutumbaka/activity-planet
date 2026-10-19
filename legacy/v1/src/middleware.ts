import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { getSupabasePublishableKey, getSupabaseUrl } from "@/lib/env";

/** Routes reachable without a session. Everything else requires auth. */
function isPublicPath(pathname: string): boolean {
  return (
    pathname === "/" ||
    pathname === "/login" ||
    pathname === "/signup" ||
    pathname.startsWith("/auth/")
  );
}

export async function middleware(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });

  const supabase = createServerClient(
    getSupabaseUrl(),
    getSupabasePublishableKey(),
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) =>
            request.cookies.set(name, value),
          );
          supabaseResponse = NextResponse.next({ request });
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options),
          );
        },
      },
    },
  );

  // Do not run other logic between createServerClient and getClaims —
  // it can cause hard-to-debug session desync issues.
  const { data } = await supabase.auth.getClaims();
  const claims = data?.claims;

  const { pathname } = request.nextUrl;

  // Any redirect we return must carry the (possibly refreshed) auth cookies,
  // otherwise the browser is left with a stale session.
  const redirectWithCookies = (url: URL): NextResponse => {
    const response = NextResponse.redirect(url);
    supabaseResponse.cookies
      .getAll()
      .forEach((cookie) => response.cookies.set(cookie));
    return response;
  };

  if (!claims && !isPublicPath(pathname)) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = "";
    url.searchParams.set("next", pathname);
    return redirectWithCookies(url);
  }

  if (
    claims &&
    (pathname === "/" || pathname === "/login" || pathname === "/signup")
  ) {
    const url = request.nextUrl.clone();
    url.pathname = "/home";
    url.search = "";
    return redirectWithCookies(url);
  }

  return supabaseResponse;
}

export const config = {
  matcher: [
    /*
     * Run on everything except static assets:
     * - _next/static, _next/image
     * - favicon and common image/font files
     */
    "/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico|woff2?)$).*)",
  ],
};
