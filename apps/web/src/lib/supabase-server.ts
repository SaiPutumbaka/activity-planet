import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "@ap/core/types";

export type ServerSupabaseClient = SupabaseClient<Database>;

/**
 * Anonymous server-side client for the public site: the publishable key and no session, so a
 * server render sees exactly what a logged-out visitor sees (RLS plus the anon-callable RPCs).
 * A new instance per call; it holds no state and never touches cookies.
 */
export function createAnonServerClient(): ServerSupabaseClient {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY;
  if (!url || !key) {
    throw new Error("Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY");
  }
  return createClient<Database>(url, key, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
}
