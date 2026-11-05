import { NextResponse } from "next/server";
import { parseTakedownRequest, takedownErrorCode, takedownRpcArgs } from "@ap/core/validation";

import { createAnonServerClient } from "@/lib/supabase-server";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * POST /api/takedown: the public intimate-image removal request (migration 52). No account and
 * no cookies: the anon client calls submit_takedown_request, which checks the same rules again
 * and holds the rate limits (3 a day per email, 200 an hour overall). Answers
 * {reference, due_at} or {error: code}; the request body is never logged.
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

  let supabase;
  try {
    supabase = createAnonServerClient();
  } catch {
    return NextResponse.json({ error: "unavailable" }, { status: 503 });
  }
  const { data, error } = await supabase.rpc(
    "submit_takedown_request",
    takedownRpcArgs(parsed.value),
  );
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
