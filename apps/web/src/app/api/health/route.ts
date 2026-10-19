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
  // PostgREST validates requested columns against the schema before RLS filters rows, so a
  // 42703 here means "column missing" even though the anon role reads zero rows.
  const { error } = await supabase.from("profiles").select("id").limit(1);

  if (error) {
    return NextResponse.json(
      { ok: false, error: error.code ?? "db_error", message: error.message },
      { status: 503 },
    );
  }
  return NextResponse.json({ ok: true, schema: "v1", checkedAt: new Date().toISOString() });
}
