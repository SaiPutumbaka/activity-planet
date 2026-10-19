import { createBrowserSupabaseClient } from "@ap/core/supabase";

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const key = import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY as string | undefined;

if (!url || !key) {
  throw new Error(
    "Missing VITE_SUPABASE_URL or VITE_SUPABASE_PUBLISHABLE_KEY. Copy apps/app/.env.example to .env.local.",
  );
}

export const supabase = createBrowserSupabaseClient(url, key);
