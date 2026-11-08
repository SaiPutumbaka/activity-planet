import { supabase } from "./supabase";

/**
 * The 18+ gate's memory on this device (launch audit M8). Once someone enters a birthday under
 * 18, the block is remembered here (a flag only, never the date) so going back or reloading does
 * not offer the birthday step again, and the account they signed up with is closed through the
 * normal deletion path (request_account_deletion, then the delete-account function), so neither
 * the profile nor the email address is kept beyond the deletion ledger (D-031).
 */
export const AGE_BLOCK_KEY = "ap-age-block";

export function ageBlocked(storage: Pick<Storage, "getItem"> | undefined = safeStorage()): boolean {
  try {
    return storage?.getItem(AGE_BLOCK_KEY) === "1";
  } catch {
    return false;
  }
}

export function rememberAgeBlock(
  storage: Pick<Storage, "setItem"> | undefined = safeStorage(),
): void {
  try {
    storage?.setItem(AGE_BLOCK_KEY, "1");
  } catch {
    /* private mode: the server-side deletion still happens */
  }
}

function safeStorage(): Storage | undefined {
  try {
    return typeof localStorage === "undefined" ? undefined : localStorage;
  } catch {
    return undefined;
  }
}

/** Closes the signed-in account of someone under 18. Best effort; returns whether it closed. */
export async function closeUnderageAccount(): Promise<boolean> {
  rememberAgeBlock();
  const { error } = await supabase.rpc("request_account_deletion", { p_reason: "under_18" });
  if (error) return false;
  // The sweep (migration 77) finishes it if this call does not.
  await supabase.functions.invoke("delete-account", { method: "POST" }).catch(() => undefined);
  const { error: signOutError } = await supabase.auth.signOut();
  if (signOutError) await supabase.auth.signOut({ scope: "local" });
  return true;
}
