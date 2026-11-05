import { NextResponse } from "next/server";

import { createAnonServerClient } from "@/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const TOKEN_RE = /^[0-9a-f-]{36}\.[0-9a-f]{64}$/;

/**
 * POST /api/unsubscribe?t=<token>: turns notification email off for the token's person
 * (migration 55, unsubscribe_email_with_token; the token is an HMAC made inside the database, so
 * this route holds no secret and uses the public key). Two callers:
 *   - mail clients' one-click unsubscribe (RFC 8058: List-Unsubscribe-Post, body
 *     "List-Unsubscribe=One-Click"): answered 200 with no page;
 *   - the button on /unsubscribe (a plain form): redirected back to that page with the result.
 * GET never unsubscribes (link scanners follow links); it sends people to the page. The token is
 * never logged.
 */
export async function POST(request: Request) {
  const url = new URL(request.url);
  let token = url.searchParams.get("t") ?? "";
  let oneClick = false;
  const type = request.headers.get("content-type") ?? "";
  if (type.includes("application/x-www-form-urlencoded") || type.includes("multipart/form-data")) {
    const form = await request.formData().catch(() => null);
    oneClick = form?.get("List-Unsubscribe") === "One-Click";
    const fromForm = form?.get("t");
    if (!token && typeof fromForm === "string") token = fromForm;
  }

  let status: "done" | "invalid" | "error" = "invalid";
  if (TOKEN_RE.test(token)) {
    const { error } = await createAnonServerClient().rpc("unsubscribe_email_with_token", {
      p_token: token,
    });
    if (!error) status = "done";
    else if (error.message.includes("invalid_token")) status = "invalid";
    else {
      status = "error";
      console.error("unsubscribe: rpc failed", error.code ?? "");
    }
  }

  if (oneClick) {
    return new NextResponse(status === "done" ? "Unsubscribed." : "Not unsubscribed.", {
      status: status === "done" ? 200 : status === "invalid" ? 400 : 503,
      headers: { "Content-Type": "text/plain; charset=utf-8" },
    });
  }
  return NextResponse.redirect(new URL(`/unsubscribe?status=${status}`, url.origin), 303);
}

export function GET(request: Request) {
  const url = new URL(request.url);
  const t = url.searchParams.get("t") ?? "";
  const next = new URL("/unsubscribe", url.origin);
  if (TOKEN_RE.test(t)) next.searchParams.set("t", t);
  return NextResponse.redirect(next, 303);
}
