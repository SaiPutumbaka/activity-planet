import { useSyncExternalStore } from "react";

export type ThemePreference = "system" | "light" | "dark";
export type ResolvedTheme = "light" | "dark";

const STORAGE_KEY = "ap-theme";
const listeners = new Set<() => void>();

function readPreference(): ThemePreference {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === "light" || v === "dark" ? v : "system";
  } catch {
    return "system";
  }
}

function systemTheme(): ResolvedTheme {
  return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

export function resolveTheme(pref: ThemePreference = readPreference()): ResolvedTheme {
  return pref === "system" ? systemTheme() : pref;
}

/** Writes data-theme on <html> (what tokens.css switches on) and keeps the browser chrome color in step. */
export function applyTheme(pref: ThemePreference): void {
  const root = document.documentElement;
  if (pref === "system") root.removeAttribute("data-theme");
  else root.setAttribute("data-theme", pref);
  const color = resolveTheme(pref) === "dark" ? "#000000" : "#ffffff";
  document.querySelectorAll<HTMLMetaElement>('meta[name="theme-color"]').forEach((m) => {
    m.content = color;
  });
}

export function setThemePreference(pref: ThemePreference): void {
  try {
    if (pref === "system") localStorage.removeItem(STORAGE_KEY);
    else localStorage.setItem(STORAGE_KEY, pref);
  } catch {
    /* storage unavailable: the choice still applies for this page */
  }
  applyTheme(pref);
  listeners.forEach((l) => l());
}

function subscribe(cb: () => void) {
  listeners.add(cb);
  const mq = window.matchMedia("(prefers-color-scheme: dark)");
  mq.addEventListener("change", cb);
  return () => {
    listeners.delete(cb);
    mq.removeEventListener("change", cb);
  };
}

export function useThemePreference(): ThemePreference {
  return useSyncExternalStore(subscribe, readPreference, () => "system");
}

export function useResolvedTheme(): ResolvedTheme {
  return useSyncExternalStore(
    subscribe,
    () => resolveTheme(),
    () => "light",
  );
}

/** Call once at startup; index.html already applied the stored choice before paint. */
export function initTheme(): void {
  applyTheme(readPreference());
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => {
    if (readPreference() === "system") applyTheme("system");
  });
}
