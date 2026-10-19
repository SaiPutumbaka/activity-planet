import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import type { Database } from "../types/database";

export type AppSupabaseClient = SupabaseClient<Database>;

/**
 * Browser client for the product app (Vite) and any client-side code in the site.
 * Uses the publishable key; every read and write is governed by Row Level Security.
 */
export function createBrowserSupabaseClient(
  url: string,
  publishableKey: string,
): AppSupabaseClient {
  return createClient<Database>(url, publishableKey, {
    auth: {
      flowType: "pkce",
      persistSession: true,
      autoRefreshToken: true,
      detectSessionInUrl: true,
    },
  });
}
