/**
 * Launch audit L8: /auth/reset opens its form only right after a password-recovery link was
 * verified on this tab (here or by /auth/confirm), never for any signed-in session, so someone
 * using an unlocked, signed-in device cannot set a new password without the reset email.
 */
const KEY = "ap-recovery-verified";
const WINDOW_MS = 15 * 60 * 1000;

export function markRecoveryVerified(now: number = Date.now()): void {
  try {
    sessionStorage.setItem(KEY, String(now));
  } catch {
    /* without storage the reset page asks for the link again */
  }
}

/** True once per verification, within 15 minutes of it; the mark is consumed. */
export function takeRecoveryVerified(now: number = Date.now()): boolean {
  try {
    const raw = sessionStorage.getItem(KEY);
    sessionStorage.removeItem(KEY);
    const at = raw ? Number(raw) : NaN;
    return Number.isFinite(at) && now - at >= 0 && now - at < WINDOW_MS;
  } catch {
    return false;
  }
}
