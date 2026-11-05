import { createHmac } from "node:crypto";
import { NextResponse } from "next/server";
import { parseTakedownRequest, takedownErrorCode, takedownRpcArgs } from "@ap/core/validation";

import { createServiceServerClient } from "@/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const TURNSTILE_VERIFY = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

/** The caller's address as Vercel reports it (the first x-forwarded-for hop), or null. */
function clientIp(request: Request): string | null {
  const forwarded = request.headers.get("x-forwarded-for")?.split(",")[0]?.trim();
  return forwarded || request.headers.get("x-real-ip")?.trim() || null;
}

/** Cloudflare Turnstile, when TURNSTILE_SECRET_KEY is set; true when it is not configured. */
async function turnstileOk(token: unknown, ip: string | null): Promise<boolean> {
  const secret = process.env.TURNSTILE_SECRET_KEY;
  if (!secret) return true;
  if (typeof token !== "string" || token === "" || token.length > 2048) return false;
  const form = new URLSearchParams({ secret, response: token });
  if (ip) form.set("remoteip", ip);
  try {
    const res = await fetch(TURNSTILE_VERIFY, { method: "POST", body: form });
    const answer = (await res.json()) as { success?: boolean };
    return answer.success === true;
  } catch {
    return false;
  }
}

/**
 * POST /api/takedown: the public intimate-image removal request (migrations 52 and 54). No
 * account and no cookies. Checks Turnstile (when configured), then files submit_takedown_request
 * with the service role (the function is not callable with the public key), passing an HMAC of
 * the caller's IP so the database caps a client at 5 a day beside 3 a day per email; past 200 an
 * hour overall requests are still taken, at a lower priority. Answers {reference, due_at} or
 * {error: code}; the request body and the address are never logged.
 */
export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }
  const parsed = parseTakedownRequest(body);
  if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

  const supabase = createServiceServerClient();
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabase || !serviceKey) {
    console.error("takedown: SUPABASE_SERVICE_ROLE_KEY is not configured");
    return NextResponse.json({ error: "unavailable" }, { status: 503 });
  }

  const ip = clientIp(request);
  const token = (body as { turnstileToken?: unknown }).turnstileToken;
  if (!(await turnstileOk(token, ip))) {
    return NextResponse.json({ error: "verification_failed" }, { status: 400 });
  }
  const clientHash = ip
    ? createHmac("sha256", process.env.TAKEDOWN_CLIENT_SALT || serviceKey)
        .update(ip)
        .digest("hex")
    : undefined;

  const { data, error } = await supabase.rpc("submit_takedown_request", {
    ...takedownRpcArgs(parsed.value),
    ...(clientHash ? { p_client_hash: clientHash } : {}),
  });
  if (error) {
    const code = takedownErrorCode(error.message);
    console.error("takedown: submit failed", code === "unavailable" ? error.code : code);
    return NextResponse.json(
      { error: code },
      { status: code === "rate_limited" ? 429 : code === "unavailable" ? 503 : 400 },
    );
  }
  const answer = (data ?? {}) as { reference?: string; due_at?: string };
  return NextResponse.json(
    { reference: answer.reference ?? null, due_at: answer.due_at ?? null },
    { status: 201 },
  );
}
