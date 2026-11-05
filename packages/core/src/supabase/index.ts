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

/**
 * SQLSTATEs of a database "not found" answer. Read RPCs raise PT404 (PostgREST answers HTTP 404,
 * migration 69); mutations and databases before migration 69 raise P0002 (HTTP 500). The message
 * is the documented code either way (not_found, place_not_found, ...).
 */
export const NOT_FOUND_CODES: readonly string[] = ["PT404", "P0002"];

/** True for a PostgREST error that is the database's not-found answer. */
export function isNotFoundError(error: unknown): boolean {
  if (!error || typeof error !== "object" || !("code" in error)) return false;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" && NOT_FOUND_CODES.includes(code);
}
