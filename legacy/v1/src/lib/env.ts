/**
 * Validated environment variable access.
 *
 * NEXT_PUBLIC_* values are inlined at build time and safe to expose to the
 * browser (the Supabase publishable key is designed to be public — data
 * access is enforced by Row Level Security, not by hiding this key). Never
 * add a secret/service-role key here or anywhere reachable from client code.
 */
function requireEnv(name: string, value: string | undefined): string {
  if (!value) {
    throw new Error(
      `Missing required environment variable: ${name}. ` +
        `Copy .env.example to .env.local and fill in your Supabase project values.`,
    );
  }
  return value;
}

export function getSupabaseUrl(): string {
  return requireEnv(
    "NEXT_PUBLIC_SUPABASE_URL",
    process.env.NEXT_PUBLIC_SUPABASE_URL,
  );
}

export function getSupabasePublishableKey(): string {
  return requireEnv(
    "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY",
    process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  );
}
