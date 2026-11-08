import { createHmac } from "node:crypto";
import { NextResponse } from "next/server";
import { clientIp } from "@ap/core/turnstile";
import {
  listingRemovalErrorCode,
  listingRemovalRpcArgs,
  parseListingRemoval,
} from "@ap/core/validation";

import { turnstileFor } from "@/lib/turnstile";
import { createServiceServerClient } from "@/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/listing-removal: the public request to take down an imported listing or its whole
 * source (migration 62, COLLECTOR_COMPLETION 2.1 and 4a.1). No account and no cookies. Checks
 * Turnstile (when configured), then files submit_listing_removal with the service role (the
 * function is not callable with the public key), passing an HMAC of the caller's IP so the
 * database caps a client at 5 a day beside 3 a day per email and 200 an hour overall. Answers
 * {reference} or {error: code}; the request body and the address are never logged.
 */
export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "bad_request" }, { status: 400 });
  }
  const parsed = parseListingRemoval(body);
  if (!parsed.ok) return NextResponse.json({ error: parsed.error }, { status: 400 });

  const supabase = createServiceServerClient();
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!supabase || !serviceKey) {
    console.error("listing-removal: SUPABASE_SERVICE_ROLE_KEY is not configured");
    return NextResponse.json({ error: "unavailable" }, { status: 503 });
  }

  const ip = clientIp(request.headers);
  const token = (body as { turnstileToken?: unknown }).turnstileToken;
  const verdict = await turnstileFor(request, token, ip);
  if (verdict === "not_configured") {
    console.error("Turnstile: TURNSTILE_SECRET_KEY is not configured in production");
    return NextResponse.json({ error: "unavailable" }, { status: 503 });
  }
  if (verdict !== "ok") {
    return NextResponse.json({ error: "verification_failed" }, { status: 400 });
  }
  const clientHash = ip
    ? createHmac("sha256", process.env.TAKEDOWN_CLIENT_SALT || serviceKey)
        .update(`listing:${ip}`)
        .digest("hex")
    : undefined;

  const { data, error } = await supabase.rpc("submit_listing_removal", {
    ...listingRemovalRpcArgs(parsed.value),
    ...(clientHash ? { p_client_hash: clientHash } : {}),
  });
  if (error) {
    const code = listingRemovalErrorCode(error.message);
    console.error("listing-removal: submit failed", code === "unavailable" ? error.code : code);
    return NextResponse.json(
      { error: code },
      { status: code === "rate_limited" ? 429 : code === "unavailable" ? 503 : 400 },
    );
  }
  const answer = (data ?? {}) as { reference?: string };
  return NextResponse.json({ reference: answer.reference ?? null }, { status: 201 });
}
