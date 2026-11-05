import { useSyncExternalStore } from "react";

/**
 * Add to Home Screen (PLAN 4.10, RECS_DESIGN section 9). Chromium fires `beforeinstallprompt`,
 * which is captured here as early as possible (main.tsx imports this module) and replayed by
 * the install card's button. iPhone has no prompt, so the card explains Share, then Add to Home
 * Screen. Nothing shows once the app runs installed, and a dismissal lasts 30 days. Storage reads
 * and writes are wrapped: a private window or blocked storage just means no memory.
 *
 *   const install = useInstallPrompt()
 *   install.standalone    // running from the home screen
 *   install.canPrompt     // Chromium has a prompt ready
 *   install.ios           // iPhone or iPad: show the Share instructions
 *   await install.prompt() // "accepted" | "dismissed" | "unavailable"
 */

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

const DISMISS_KEY = "ap-install-dismissed-at";
const RSVP_KEY = "ap-install-after-rsvp";
export const INSTALL_DISMISS_DAYS = 30;

let deferred: BeforeInstallPromptEvent | null = null;
let installed = false;
let version = 0;
const listeners = new Set<() => void>();

function emit() {
  version += 1;
  for (const l of listeners) l();
}

function subscribe(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

if (typeof window !== "undefined") {
  window.addEventListener("beforeinstallprompt", (event) => {
    // Keep the browser's mini-infobar away; our card offers the same thing at a better moment.
    event.preventDefault();
    deferred = event as BeforeInstallPromptEvent;
    emit();
  });
  window.addEventListener("appinstalled", () => {
    deferred = null;
    installed = true;
    emit();
  });
  try {
    window.matchMedia("(display-mode: standalone)").addEventListener("change", emit);
  } catch {
    /* old browsers: no live updates */
  }
}

/** Running as the installed app (Android, desktop or an iPhone home screen icon). */
export function isStandalone(): boolean {
  if (typeof window === "undefined") return false;
  if (installed) return true;
  try {
    if (window.matchMedia("(display-mode: standalone)").matches) return true;
    if (window.matchMedia("(display-mode: window-controls-overlay)").matches) return true;
  } catch {
    /* fall through */
  }
  return (navigator as Navigator & { standalone?: boolean }).standalone === true;
}

/** iPhone, iPod or iPad (iPadOS reports itself as a Mac with touch). */
export function isIos(
  ua: string = navigator.userAgent,
  touchPoints = navigator.maxTouchPoints,
): boolean {
  if (/iPhone|iPad|iPod/i.test(ua)) return true;
  return /Macintosh/i.test(ua) && touchPoints > 1;
}

function readNumber(key: string): number | null {
  try {
    const raw = localStorage.getItem(key);
    const n = raw ? Number(raw) : NaN;
    return Number.isFinite(n) ? n : null;
  } catch {
    return null;
  }
}

/** True for 30 days after "Not now". */
export function installDismissed(now = Date.now()): boolean {
  const at = readNumber(DISMISS_KEY);
  return at !== null && now - at < INSTALL_DISMISS_DAYS * 86_400_000;
}

export function dismissInstall(now = Date.now()) {
  try {
    localStorage.setItem(DISMISS_KEY, String(now));
  } catch {
    /* no memory: it may show again next time */
  }
  emit();
}

/** Called after an RSVP: the first one queues the card for the event page, once. */
export function noteRsvpForInstall() {
  try {
    if (localStorage.getItem(RSVP_KEY) === null) localStorage.setItem(RSVP_KEY, "pending");
  } catch {
    /* ignore */
  }
  emit();
}

export function installAfterRsvpPending(): boolean {
  try {
    return localStorage.getItem(RSVP_KEY) === "pending";
  } catch {
    return false;
  }
}

export function markInstallAfterRsvpShown() {
  try {
    localStorage.setItem(RSVP_KEY, "shown");
  } catch {
    /* ignore */
  }
}

export async function promptInstall(): Promise<"accepted" | "dismissed" | "unavailable"> {
  const event = deferred;
  if (!event) return "unavailable";
  deferred = null;
  emit();
  try {
    await event.prompt();
    const choice = await event.userChoice;
    if (choice.outcome === "accepted") installed = true;
    emit();
    return choice.outcome;
  } catch {
    return "unavailable";
  }
}

export interface InstallState {
  standalone: boolean;
  canPrompt: boolean;
  ios: boolean;
  dismissed: boolean;
  /** Something useful to offer: a ready prompt, or iPhone instructions. */
  available: boolean;
  prompt: typeof promptInstall;
  dismiss: () => void;
}

export function useInstallPrompt(): InstallState {
  useSyncExternalStore(
    subscribe,
    () => version,
    () => 0,
  );
  const standalone = isStandalone();
  const ios = typeof navigator !== "undefined" && isIos();
  const canPrompt = deferred !== null;
  const dismissed = installDismissed();
  return {
    standalone,
    canPrompt,
    ios,
    dismissed,
    available: !standalone && (canPrompt || ios),
    prompt: promptInstall,
    dismiss: () => dismissInstall(),
  };
}
