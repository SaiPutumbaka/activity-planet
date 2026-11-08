import { supabase } from "./supabase";

/**
 * The 18+ gate's memory on this device (launch audit M8). Once someone enters a birthday under
 * 18, the block is remembered here (an expiry time only, never the date) so going back or
 * reloading does not offer the birthday step again, and the account they signed up with is closed
 * through the normal deletion path (request_account_deletion, then the delete-account function),
 * so neither the profile nor the email address is kept beyond the deletion ledger (D-031).
 *
 * The block lasts AGE_BLOCK_MS (one day), then clears itself: an adult who mistyped a birthday,
 * or the next person on a shared device, is not shut out for good. The server-side check in
 * complete_onboarding still refuses any birthday under 18.
 */
export const AGE_BLOCK_KEY = "ap-age-block";
export const AGE_BLOCK_MS = 24 * 60 * 60 * 1000;

type BlockStorage = Pick<Storage, "getItem"> & Partial<Pick<Storage, "removeItem">>;

export function ageBlocked(
  storage: BlockStorage | undefined = safeStorage(),
  now: number = Date.now(),
): boolean {
  try {
    const raw = storage?.getItem(AGE_BLOCK_KEY);
    if (raw == null) return false;
    const until = Number(raw);
    // A finite expiry still in the future (and no further out than one block) holds; anything
    // else (the old "1" flag, a past time, a tampered value) is cleared.
    if (Number.isFinite(until) && until > now && until <= now + AGE_BLOCK_MS) return true;
    storage?.removeItem?.(AGE_BLOCK_KEY);
    return false;
  } catch {
    return false;
  }
}

export function rememberAgeBlock(
  storage: Pick<Storage, "setItem"> | undefined = safeStorage(),
  now: number = Date.now(),
): void {
  try {
    storage?.setItem(AGE_BLOCK_KEY, String(now + AGE_BLOCK_MS));
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
