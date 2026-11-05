import { useEffect, useRef } from "react";
import { RefreshCw, X } from "lucide-react";
import { useRegisterSW } from "virtual:pwa-register/react";

import { Button } from "@/components/ui/button";

const HOUR = 60 * 60_000;

/**
 * "A new version is ready" (RECS_DESIGN 9.2). The service worker no longer takes over an open
 * tab on its own (registerType "prompt"): a new build waits until the person taps Reload, so a
 * lazy route chunk from the old build never goes missing mid-session. While the app is visible
 * it checks for a new build once an hour.
 */
export function UpdateToast() {
  const timer = useRef<number | null>(null);
  const {
    needRefresh: [needRefresh, setNeedRefresh],
    updateServiceWorker,
  } = useRegisterSW({
    onRegisteredSW(_url, registration) {
      if (!registration || timer.current !== null) return;
      timer.current = window.setInterval(() => {
        if (document.visibilityState !== "visible" || !navigator.onLine) return;
        if (registration.installing) return;
        void registration.update().catch(() => undefined);
      }, HOUR);
    },
    onRegisterError() {
      /* no worker (private mode, a native shell): nothing to update */
    },
  });

  useEffect(
    () => () => {
      if (timer.current !== null) window.clearInterval(timer.current);
    },
    [],
  );

  // Ask the waiting worker to take over, then reload once it controls the page. The plugin
  // reloads on its own for an ordinary update; controllerchange also covers a worker that was
  // registered from elsewhere, and a page with nothing waiting simply reloads.
  async function reloadIntoNewVersion() {
    const sw = "serviceWorker" in navigator ? navigator.serviceWorker : null;
    const registration = await sw?.getRegistration().catch(() => undefined);
    if (!sw || !registration?.waiting) {
      window.location.reload();
      return;
    }
    sw.addEventListener("controllerchange", () => window.location.reload(), { once: true });
    await updateServiceWorker(true);
  }

  if (!needRefresh) return null;
  return (
    <div
      role="status"
      aria-live="polite"
      data-testid="update-toast"
      className="fixed inset-x-0 bottom-[calc(4rem+env(safe-area-inset-bottom,0px))] z-50 mx-auto flex w-[min(100%-2rem,28rem)] items-center gap-3 rounded-card bg-toast px-4 py-3 text-on-toast shadow-[var(--shadow-card)]"
    >
      <RefreshCw className="size-5 shrink-0" aria-hidden="true" />
      <p className="min-w-0 flex-1 text-[14px] font-semibold">A new version is ready</p>
      <Button size="sm" variant="primary" onClick={() => void reloadIntoNewVersion()}>
        Reload
      </Button>
      <button
        type="button"
        aria-label="Later"
        onClick={() => setNeedRefresh(false)}
        className="inline-flex size-9 shrink-0 items-center justify-center rounded-full hover:bg-white/10"
      >
        <X className="size-5" aria-hidden="true" />
      </button>
    </div>
  );
}
