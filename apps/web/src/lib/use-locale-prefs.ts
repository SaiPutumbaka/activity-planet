"use client";

import { useSyncExternalStore } from "react";
import { US_PREFS, viewerPrefs, type LocalePrefs } from "@ap/core/locale";

const subscribe = (onChange: () => void) => {
  window.addEventListener("languagechange", onChange);
  return () => window.removeEventListener("languagechange", onChange);
};
const serverPrefs = () => US_PREFS;

/**
 * The reader's units and formats (miles or km, 12- or 24-hour clock, month or day first). The
 * server render and hydration use US_PREFS, so the cached HTML is the same for everyone; the
 * browser's locale applies right after hydration, without a mismatch.
 */
export function useLocalePrefs(): LocalePrefs {
  return useSyncExternalStore(subscribe, viewerPrefs, serverPrefs);
}
