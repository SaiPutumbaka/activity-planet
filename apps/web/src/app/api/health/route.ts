import { NextResponse } from "next/server";
import { createClient } from "@supabase/supabase-js";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

/**
 * Liveness + schema probe. Selects the newest column the deployed code depends on so a
 * missing migration fails here, loudly, instead of in a user's signup. Also the target of
 * the keep-alive cron that stops the free-tier database from pausing.
 */
export async function GET() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) {
    return NextResponse.json({ ok: false, error: "missing_env" }, { status: 500 });
  }

  const supabase = createClient(url, key, { auth: { persistSession: false } });
  // public.meta is readable by anon and carries the schema version written by each migration,
  // so a deploy that outruns its migration shows up here as a version mismatch.
  const { data, error } = await supabase
    .from("meta")
    .select("value")
    .eq("key", "schema_version")
    .maybeSingle();

  if (error) {
    return NextResponse.json(
      { ok: false, error: error.code ?? "db_error", message: error.message },
      { status: 503 },
    );
  }
  const schema = data?.value ?? null;
  const expected = process.env.EXPECTED_SCHEMA_VERSION ?? null;
  const ok = schema !== null && (expected === null || schema === expected);
  return NextResponse.json(
    { ok, schema, expected, checkedAt: new Date().toISOString() },
    { status: ok ? 200 : 503 },
  );
}
